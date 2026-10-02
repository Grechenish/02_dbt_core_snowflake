# Runbook

What to do when something goes wrong with the daily production run (`dbt-daily.yml`).

## The run failed

Open the run in **Actions**. The job summary lists every test that failed or warned; the step that
went red tells you where.

| Failed step | Usual cause | What to do |
|---|---|---|
| Load trade files | a file `COPY` can't read (it aborts and loads nothing from that run), missing or rotated key | Check `RAW.TRADES.LOAD_RUNS` (below). A failed file stays on the stage and would abort every later run, so first remove it (below), then add the fixed file **under a new name** and rerun. |
| Check source freshness | the Marketplace feed stopped, or no successful load in ~3 days | Check the listing in Snowsight; nothing is rebuilt until the source recovers, so yesterday's marts stay as they were. |
| dbt build: a blocking test | real bad data or a bug | Read the failing test's SQL and description; it says what it protects. Downstream models were skipped. |
| dbt build: a model | SQL error, privilege error, statement timeout | The error is in the log; a timeout means a runaway query (10-minute limit). |

```sql
-- What did the loader do recently?
select run_id, started_at, status, files_found, files_uploaded, files_loaded, rows_loaded, error_message
from raw.trades.load_runs
order by started_at desc
limit 10;

-- Per-file COPY results of one run
select f.value:file::varchar as file, f.value:status::varchar as status,
       f.value:rows_loaded::number as rows_loaded, f.value:first_error::varchar as first_error
from raw.trades.load_runs, lateral flatten(input => copy_results) f
where run_id = '<run id>';

-- Remove a file that failed to load from the stage (as LOADER or SYSADMIN).
-- `list @raw.trades.trade_files;` shows the staged names.
remove @raw.trades.trade_files/<file name>.csv.gz;
```

The loader refuses a file before staging it if its header differs or any row has the wrong number
of fields. If a bad row still reached RAW (the loader can only insert), delete it as SYSADMIN
before resending the corrected file, or staging keeps the first version and
`assert_trade_replays_are_identical` fails:

```sql
delete from raw.trades.trades where _load_run_id = '<run id>' and _source_file = '<file name>.csv.gz';
```

## Rerunning

Every step is safe to repeat, so a rerun is just **Re-run all jobs** (or **Run workflow**):
the loader skips files already loaded, models are rebuilt from RAW and the source, and
incremental models re-merge their window. The exception is a file that failed `COPY`: it stays on
the stage and fails every rerun until it is removed (above).

## Stale data

1. `dbt source freshness --target prod` (or the step's log) says which source is behind.
2. Market data: compare `max(trade_date)` in `ANALYTICS.MARTS.DIM_DATE` with the source. The free
   listing is about 90 days behind on a normal day.
3. A single instrument: `price_age_days` in `fct_trading_pnl` / `risk_position_exposure_daily`
   shows how old its last price is; `monitoring_market_data_daily` shows whether the whole day was
   thin.
4. Trades: `LOAD_RUNS` shows whether files arrived; `assert_trades_within_market_data` lists trades
   waiting for prices.

## Full refresh of the market data

Needed when `assert_market_data_restatements_within_lookback` warns (the provider changed days
older than the window), after changing `start_date` or `report_currencies`, or when a column
change makes the incremental models fail with `on_schema_change`. In CI, a pull request that
changes those columns needs the `full-refresh` label ([CI_CD.md](CI_CD.md)).

**Actions → dbt daily build → Run workflow → full_refresh: true.** This rebuilds every
incremental model from all history (seconds on XSMALL at the current size).

## A bad deployment

A merge to `main` triggers a production run. If it published wrong numbers:

1. Revert the merge commit on GitHub (a new pull request; CI runs on it) and merge the revert.
   The production run that follows rebuilds from the previous code.
2. If the bad data must disappear sooner than that, restore the affected tables (below).

Note that department marts are views over `fct_trading_pnl`: they show a rebuilt fact
immediately, even if a test on it fails right after. A failed run is therefore not proof that
consumers saw nothing.

## Recovering a previous state

- **Time Travel** keeps earlier versions of data for the retention period (1 day by default;
  dbt's tables here are transient, which allows at most 1 day). How you use it depends on how the
  table was built:

  ```sql
  -- Incremental models (int_stock_prices_daily, fct_stock_history) are merged in place,
  -- so the same table can be read as of an earlier time and cloned from there:
  create table analytics.marts.fct_stock_history_restored
      clone analytics.marts.fct_stock_history at(offset => -3600);

  -- Table models (e.g. fct_trading_pnl) are rebuilt with CREATE OR REPLACE, which drops the old
  -- table. Within retention, the dropped version can be brought back:
  alter table analytics.marts.fct_trading_pnl rename to analytics.marts.fct_trading_pnl_bad;
  undrop table analytics.marts.fct_trading_pnl;
  ```

  The next production run replaces whatever was restored, so revert the code first.
- **RAW** is in a permanent database, so it also has Fail-safe (7 days, recoverable through
  Snowflake support). It is the one thing that can't be rebuilt from elsewhere.
- **Everything in ANALYTICS can be rebuilt** from RAW and the Marketplace share with a full
  refresh. That is the usual recovery; Time Travel is for when it must be faster.

## Rotating a service user's key

1. Generate a new key pair (see `snowflake/05_credentials.sql`).
2. `alter user <user> set rsa_public_key_2 = '<new public key>';`
3. Replace the GitHub secret with the new private key and run the workflow.
4. `alter user <user> unset rsa_public_key;`
