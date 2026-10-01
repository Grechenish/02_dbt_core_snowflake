# Performance Validation

This document records the performance checks for the `trading_pnl` pipeline, run on 2026-10-01 against `DBT_HOL_DEV`. They cover:

- how long each part of the pipeline takes
- which warehouse size suits each heavy model
- one bottleneck that was found and fixed
- the estimated credit cost of the daily production run

Architecture context is in [SYSTEM_OVERVIEW.md](SYSTEM_OVERVIEW.md).

---

## 1. Summary

| Check | Result |
|---|---|
| Full `dbt build` (11 models, 2 seeds, 36 tests at the time) | **36 s** wall clock, all 49 nodes pass. It was 41 s before the fix below. |
| Data volume | 3.89 M rows each in `int_stock_prices_daily` and `fct_stock_history`. 1,495 rows in the trading PnL models. |
| Bottleneck found | `fct_stock_history` took about 10 s **on every warehouse size**. The cause was an `ASOF JOIN` with no `ON` key, which Snowflake can't run in parallel. |
| Fix | Look up FX rates per trading day, then use an ordinary equality join. The output is identical (0 rows differ), and the model is **2.8× faster** on XSMALL (9.6 s → 3.4 s). |
| Warehouse sizing | The pivot scales with size, but saves only about 4 s on LARGE. That doesn't justify resuming a LARGE warehouse every day (section 5), so the LARGE warehouse is now opt-in. |
| Estimated daily cost | About **0.03 credits per run** with the default config (everything on XSMALL), or about **0.2** with `use_heavy_compute`. |

---

## 2. Method

All measurements come from Snowflake, not from timing on the client.

- **Per-node timings:** dbt's `target/run_results.json` from a `dbt build --full-refresh`.
- **Per-model warehouse statistics:** `INFORMATION_SCHEMA.QUERY_HISTORY`, filtered on `QUERY_TAG`. The `query_tag` macro tags every query as `trading_pnl.<node>`, which is what makes this per-model breakdown possible.
- **Warehouse-size benchmark:** each heavy model's compiled SQL run as `CREATE TRANSIENT TABLE ... AS` on `DBT_DEV_WH` at XSMALL, SMALL, MEDIUM and LARGE. Every run:
  - started on a freshly resumed warehouse, so the local disk cache was empty
  - had `USE_CACHED_RESULT = FALSE`
  - reports `EXECUTION_TIME`, which excludes compile and queue time

  Afterwards the scratch table was dropped, and the warehouse was reset to XSMALL and suspended.
- **Compute credits** are calculated as `credits/hour × seconds / 3600`. XSMALL is 1 credit per hour, SMALL 2, MEDIUM 4 and LARGE 8.

---

## 3. Where the time goes

Execution time per model in the full build. Tests aren't shown: 36 tests took 3.7 s in total, with the longest at about 2 s.

| Model | Warehouse | Execution time (s) |
|---|---|---|
| `fct_stock_history` (before fix) | DBT_DEV_WH (XSMALL) | 9.92 |
| `int_stock_prices_daily` | DBT_DEV_HEAVY_WH (LARGE) | 1.79 |
| `fct_trading_pnl` (incl. hooks) | DBT_DEV_WH | 1.43 |
| `int_trading_pnl` | DBT_DEV_HEAVY_WH | 1.37 |
| `manual_book1` + `manual_book2` | DBT_DEV_WH | 2.25 |
| `int_daily_position` | DBT_DEV_HEAVY_WH | 1.08 |
| `int_trading_book` | DBT_DEV_HEAVY_WH | 0.74 |
| staging views (2) | DBT_DEV_WH | 0.94 |
| department views (3) | DBT_DEV_WH | 0.84 |

**Most of the 36-second wall clock isn't warehouse compute.** Models need about 20 s of compute in total. The rest is dbt overhead: compiling, metadata queries such as `SHOW` and `DESCRIBE`, and network round-trips. dbt runs 4 threads, so a bigger warehouse doesn't shorten this overhead.

Cloud-services usage for the whole build was **0.005 credits**, which is negligible.

---

## 4. Warehouse-size benchmark and the `fct_stock_history` fix

| Model | XSMALL | SMALL | MEDIUM | LARGE |
|---|---|---|---|---|
| `int_stock_prices_daily` (pivot of about 35 M source rows) | 5.39 s | 3.80 s | 2.44 s | **1.63 s** |
| `fct_stock_history`, **before** | 9.62 s | 9.49 s | 9.86 s | 10.18 s |
| `fct_stock_history`, **after** | **3.43 s** | 2.00 s | 1.69 s | 2.37 s |

**Pivot:** it scales reasonably, running 3.3× faster with 8× the compute. A `GROUP BY` over many tickers splits naturally across nodes.

**`fct_stock_history` before the fix: it didn't scale at all.** The model joined 3.9 M price rows to FX rates with:

```sql
from prices
asof join fx_eur match_condition (prices.trade_date >= fx_eur.rate_date)
```

An `ASOF JOIN` with no `ON` clause treats all rows as one partition. Snowflake can't split that across the warehouse's nodes, so one node did all the work regardless of warehouse size.

**The fix.** The FX rate depends only on the date, so the `ASOF` lookup now runs over the **distinct trading days** (374) instead of every price row. The price rows then join to that small daily table with a plain equality join, which runs in parallel:

```sql
trading_days as (select distinct trade_date from prices),
fx_eur as (
    select trading_days.trade_date, rates.fx_rate
    from trading_days
    asof join (select rate_date, fx_rate from fx where quote_currency = 'EUR') as rates
        match_condition (trading_days.trade_date >= rates.rate_date)
)
...
from prices
left join fx_eur on fx_eur.trade_date = prices.trade_date
```

`left join` keeps the left-outer behaviour of `ASOF JOIN`: a price row with no earlier FX rate keeps a NULL rate and isn't dropped.

**Checked as equivalent:** both versions have 3,890,440 rows, and `before MINUS after` and `after MINUS before` both return 0 rows. All 7 tests on the model and its upstream models pass.

`int_trading_pnl` also uses `ASOF JOIN`, but with an `ON quote_currency` key, and it only processes 1,495 rows, so it doesn't need the same change.

---

## 5. Cost of the daily run

### 5.1 Billing rules that matter here

- When a warehouse resumes, Snowflake bills **at least 60 seconds**, then per second.
- With `AUTO_SUSPEND = 60`, a warehouse keeps billing for up to **60 seconds of idle time** after its last query.
- When a running warehouse is resized up, the extra compute is billed for **at least 60 seconds**.

At this data size, these minimum charges cost more than the queries themselves.

### 5.2 Estimate per production run

These figures are estimates based on the measured runtimes. Section 5.4 shows how to get the real numbers.

| Item | With `use_heavy_compute` (the original configuration) | Default: everything on XSMALL |
|---|---|---|
| `DBT_PROD_WH` (XSMALL): about 40 s active plus 60 s idle | ≈ 0.028 | ≈ 0.031 (plus about 5 s for the pivot) |
| `DBT_PROD_HEAVY_WH` (LARGE): about 10 s active, 60 s minimum on resume, plus 60 s idle | ≈ 0.16 | 0 (not used) |
| `fct_trading_pnl` resize hook (XSMALL → SMALL, 60 s minimum on the added compute) | ≈ 0.017 | 0 (hooks removed) |
| **Total per run** | **≈ 0.2 credits** | **≈ 0.03 credits** |
| **Per month (30 daily runs)** | **≈ 6 credits** | **≈ 1 credit** |

**With `use_heavy_compute`, about 80% of the cost comes from resuming the LARGE warehouse to save about 4 seconds of pivot time.**

### 5.3 Recommendations

1. **Keep the `fct_stock_history` fix.** It's faster on every warehouse size and changes no output.
2. **Run the intermediate layer on the default XSMALL warehouse** while data stays at this size. **Done:** the `+snowflake_warehouse` routing for intermediate models and the `fct_trading_pnl` resize hooks now only apply with `--vars '{use_heavy_compute: true}'`, and are off by default. The model runs in about 1.4 s, so resizing the warehouse gains nothing and adds a 60-second minimum charge.

   The heavy warehouses and the resize-hook pattern come from the Snowflake quickstart guide (section 21). They're useful once a model runs for minutes, not seconds, which is why they stay available behind the var.
3. **Revisit when data grows.** For example, if `start_date` moves back to 2018, the stock source has about 5× more rows. Rerun the benchmark in section 4. A heavy warehouse starts paying off once a model's runtime is well above 60 seconds on XSMALL, and then turning on `use_heavy_compute` is a one-flag change.

### 5.4 Measuring actual credits

The dbt roles can't read billing data. Run these queries as `ACCOUNTADMIN`. `ACCOUNT_USAGE` data can lag by up to about 3 hours.

```sql
USE ROLE accountadmin;

-- Credits per warehouse per day
SELECT warehouse_name, TO_DATE(start_time) AS day, ROUND(SUM(credits_used), 4) AS credits
FROM snowflake.account_usage.warehouse_metering_history
WHERE warehouse_name LIKE 'DBT\\_%' ESCAPE '\\'
  AND start_time >= DATEADD(day, -7, CURRENT_DATE())
GROUP BY 1, 2
ORDER BY 2, 1;

-- Execution time and data scanned per dbt model (uses the trading_pnl.<node> query tags)
SELECT REPLACE(query_tag, 'trading_pnl.', '') AS node,
       warehouse_name, warehouse_size,
       COUNT(*)                                   AS queries,
       ROUND(SUM(execution_time) / 1000, 1)       AS exec_s,
       ROUND(SUM(bytes_scanned) / 1e9, 2)         AS gb_scanned,
       SUM(partitions_scanned)                    AS partitions_scanned,
       SUM(partitions_total)                      AS partitions_total
FROM snowflake.account_usage.query_history
WHERE query_tag LIKE 'trading_pnl.%'
  AND start_time >= DATEADD(day, -1, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3
ORDER BY exec_s DESC;
```

---

## 6. Reproducing the benchmark

1. Run `dbt compile` so the compiled SQL in `trading_pnl/target/compiled/` is current.
2. For each warehouse size:
   1. Suspend `DBT_DEV_WH`.
   2. Set its size.
   3. Resume it.
   4. Run `ALTER SESSION SET USE_CACHED_RESULT = FALSE`.
   5. Run `CREATE OR REPLACE TRANSIENT TABLE dbt_hol_dev.intermediate.perf_scratch AS <compiled SQL>`.
   6. Read `EXECUTION_TIME` for that query ID from `INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION()`.
3. Drop `perf_scratch`, set the warehouse back to XSMALL, and suspend it.

Tag the session (`ALTER SESSION SET QUERY_TAG = 'trading_pnl.perf_benchmark'`) so benchmark queries are easy to find in Query History and don't mix with pipeline runs.
