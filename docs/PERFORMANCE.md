# Performance investigation: the ASOF JOIN that didn't scale

This is a write-up of one performance problem, how it was found, fixed and verified, and what it
taught about warehouse sizing and cost.

> **Provenance of the numbers.** Every number below was measured on 2026-10-01 against the dev
> database of the *previous* version of this project (before the refactor that added ingestion,
> incremental market data and the new roles). They have not been re-measured since. The fix itself
> is unchanged in the current `fct_stock_history`, but the model is now incremental, so a daily run
> processes a lookback window rather than all 3.9M rows. Query Profile screenshots were not saved
> at the time; [section 9](#9-reproducing-it) says how to capture them.

---

## 1. Summary

| | |
|---|---|
| **What was slow** | `fct_stock_history` (daily close prices converted to EUR and GBP): about 10 s per build |
| **The odd part** | It took the same ~10 s on XSMALL, SMALL, MEDIUM and LARGE |
| **Root cause** | An `ASOF JOIN` with no `ON` key: all 3.9M rows are one partition, processed by one node |
| **Fix** | Do the as-of lookup once per trading day (374 rows), then equi-join the prices to it |
| **Result** | 9.6 s → 3.4 s on XSMALL (2.8×), and now faster on bigger warehouses too |
| **Correctness** | Same row count (3,890,440); `before MINUS after` and `after MINUS before` both 0 rows |
| **Cost decision** | The LARGE warehouse saved ~4 s a day for ~80% of the run's cost, so it was removed |

---

## 2. The query

FX rates (USD → EUR, USD → GBP) are not published on every US trading day: ECB holidays differ
from US market holidays. So each price row takes the latest rate *on or before* its date. That is
exactly what `ASOF JOIN` does:

```sql
-- before
select prices.*, fx_eur.fx_rate as usd_eur_rate
from prices                                   -- 3.9M rows: ticker x trading day
asof join fx_eur                              -- a few hundred daily EUR rates
    match_condition (prices.trade_date >= fx_eur.rate_date)
```

Note there is no `ON` clause: the rate depends only on the date, not on the ticker, so there was
nothing obvious to put there.

## 3. How it was measured

- **Per-model timings** came from Snowflake, not from a stopwatch: the project's `query_tag`
  macro tags every query with the dbt model that ran it (`trading_pnl.<model>`), so
  `QUERY_HISTORY` can be filtered by model.
- **Warehouse-size benchmark:** each heavy model's compiled SQL was run as
  `CREATE TRANSIENT TABLE ... AS <sql>` on XSMALL, SMALL, MEDIUM and LARGE. For every run the
  warehouse was freshly resumed (empty local cache), `USE_CACHED_RESULT = FALSE`, and the number
  read was `EXECUTION_TIME` (excludes compilation and queuing).
- **Credits** are `credits per hour × seconds / 3600`: XSMALL 1, SMALL 2, MEDIUM 4, LARGE 8.

## 4. What was observed

| Model | XSMALL | SMALL | MEDIUM | LARGE |
|---|---|---|---|---|
| `int_stock_prices_daily` (pivot of ~35M source rows) | 5.39 s | 3.80 s | 2.44 s | 1.63 s |
| `fct_stock_history`, **before** | 9.62 s | 9.49 s | 9.86 s | 10.18 s |
| `fct_stock_history`, **after** | 3.43 s | 2.00 s | 1.69 s | 2.37 s |

The pivot behaves like normal parallel work: 8× the compute, 3.3× faster. `fct_stock_history`
did not get faster at all with 8× the compute. **When more nodes don't help, the work isn't being
split across nodes.**

## 5. Hypothesis and root cause

Snowflake parallelises a join by partitioning both sides on the join key, so each node handles
its own subset of keys. An `ASOF JOIN` partitions on its `ON` columns and then, within each
partition, walks both sides in `match_condition` order to find the latest earlier match. With no
`ON` columns there is exactly one partition: the whole 3.9M-row input, sorted and scanned by one
worker. Adding nodes adds workers with nothing to do.

What the Query Profile should show for the slow version (and what to look for when reproducing
it): the ASOF join operator taking most of the execution time, with the work concentrated on a
single worker rather than spread across them. This was inferred from the timing pattern above;
the profile itself was not saved.

## 6. The fix

The rate depends only on the date, and there are only 374 distinct trading days. So the expensive
as-of logic runs on 374 rows, and the 3.9M price rows use a plain equality join, which Snowflake
hash-partitions across all nodes:

```sql
trading_days as (select distinct trade_date from prices),       -- 374 rows
fx_eur as (
    select trading_days.trade_date, rates.fx_rate
    from trading_days
    asof join (select rate_date, fx_rate from fx where quote_currency = 'EUR') as rates
        match_condition (trading_days.trade_date >= rates.rate_date)
)
...
from prices
left join fx_eur on prices.trade_date = fx_eur.trade_date        -- parallel equi-join
```

`left join` keeps `ASOF JOIN`'s outer behaviour: a price row with no earlier FX rate keeps a NULL
rate instead of disappearing (and the `not_null` tests on the converted prices then fail the build).

The other `ASOF JOIN` in the project, in `int_trading_pnl`, has `ON quote_currency` and works on a
few thousand rows, so it was left alone.

## 7. Why it scales better

| | Before | After |
|---|---|---|
| Rows going through the as-of logic | 3.9M | 374 per currency |
| Partitions for the as-of logic | 1 | 1 (but tiny) |
| Join used for the 3.9M rows | ASOF (single partition) | hash equi-join (all nodes) |

The serial part shrank by four orders of magnitude; the large part became parallel.

## 8. Correctness and cost

**Correctness:** both versions were materialised side by side. Both had 3,890,440 rows, and
`select * from before minus select * from after` and the reverse both returned 0 rows. Checking
only one direction would miss rows that exist only in the new table; checking row counts alone
would miss changed values. All tests on the model and its parents passed.

**Cost model.** At this scale the minimum charges matter more than the queries:

- A warehouse bills at least 60 s every time it resumes, then per second.
- With `AUTO_SUSPEND = 60` it keeps billing for up to 60 s of idle time after the last query.

The quickstart this project started from routes heavy models to a LARGE warehouse and resizes the
main warehouse in hooks. Measured estimates per daily run:

| | Quickstart pattern (LARGE for heavy models) | Everything on XSMALL |
|---|---|---|
| Main warehouse (~40 s active + 60 s idle) | ≈ 0.03 credits | ≈ 0.03 credits |
| LARGE warehouse (~10 s active, 60 s minimum, 60 s idle) | ≈ 0.16 credits | 0 |
| Resize hook (60 s minimum on the added size) | ≈ 0.02 credits | 0 |
| **Per run / per month** | **≈ 0.2 / ≈ 6 credits** | **≈ 0.03 / ≈ 1 credit** |

So the LARGE warehouse cost about 80% of each run to save about 4 seconds. A bigger warehouse
pays off when a query runs well past the 60-second minimum *and* parallelises; neither was true
here. The heavy warehouses, the routing and the hooks have since been removed, and the
production warehouse is XSMALL under a monthly resource monitor (`snowflake/01_warehouses.sql`).

**Why a bigger warehouse could never have fixed the ASOF JOIN:** the slow part ran on one node.
A LARGE warehouse has eight times the nodes and the same single node doing that work, at eight
times the price per second.

## 9. Reproducing it

1. `dbt compile --select fct_stock_history`, then check out the pre-fix version of the model and
   compile it too (the commit "Validate pipeline performance and fix fct_stock_history bottleneck"
   has both).
2. For each warehouse size: suspend the warehouse, resize it, resume it, run
   `alter session set use_cached_result = false` and
   `alter session set query_tag = 'trading_pnl.perf_benchmark'`, then
   `create or replace transient table ... as <compiled sql>`.
3. Read `EXECUTION_TIME` for those queries from `table(information_schema.query_history_by_session())`.
4. In Snowsight, open each query's **Query Profile** and save a screenshot of the operator tree
   and the per-worker statistics of the join operator. That is the evidence missing from this
   write-up.
5. Run the two `MINUS` queries, then drop the scratch tables and set the warehouse back to XSMALL.

Credits per warehouse and per model (needs `ACCOUNTADMIN`; `ACCOUNT_USAGE` lags up to ~3 hours):

```sql
select warehouse_name, to_date(start_time) as day, round(sum(credits_used), 4) as credits
from snowflake.account_usage.warehouse_metering_history
where start_time >= dateadd(day, -7, current_date())
group by 1, 2 order by 2, 1;

select replace(query_tag, 'trading_pnl.', '') as model,
       warehouse_name, count(*) as queries,
       round(sum(execution_time) / 1000, 1) as exec_s,
       round(sum(bytes_scanned) / 1e9, 2)   as gb_scanned
from snowflake.account_usage.query_history
where query_tag like 'trading_pnl.%' and start_time >= dateadd(day, -1, current_timestamp())
group by 1, 2 order by exec_s desc;
```

## 10. What changed since

`int_stock_prices_daily` and `fct_stock_history` are now incremental: a daily run re-reads a
`market_data_lookback_days` window instead of all history, so the pivot's 5.4 s and the
conversion's 3.4 s on XSMALL become the cost of a full refresh, not of a normal day. How much a
normal day now costs has **not** been measured yet; the per-model query above will show it after
the first production runs.
