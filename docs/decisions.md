# Decision log

Each entry: the problem, the options considered, what was chosen, why, and what it costs.
The context throughout is a **daily batch** platform with a few thousand trade-derived rows, a
~4M-row market-data history and one engineer.

---

## 1. Snowflake as the warehouse

**Problem.** Somewhere to store raw data and run SQL transformations, with the market data available.
**Options.** Snowflake; BigQuery; Postgres; DuckDB.
**Chosen.** Snowflake.
**Why.** The market data is a Snowflake Marketplace share: it appears as a read-only database
with no copying or ingestion job. Compute is separate from storage and billed per second, so
an XSMALL warehouse that runs a minute a day costs almost nothing. It also offers the
administration features the project exists to practise (roles, stages, resource monitors).
**Trade-offs.** Vendor lock-in (`ASOF JOIN`, `QUALIFY`, stages, `COPY` options are Snowflake
SQL); a 60-second minimum charge per warehouse resume dominates cost at this scale.

## 2. dbt Core for transformations

**Problem.** A dozen dependent SQL models, run in the right order, tested and documented.
**Options.** dbt Core; stored procedures and tasks in Snowflake; Python scripts.
**Chosen.** dbt Core.
**Why.** It derives the dependency graph from `ref()`, runs tests next to the models, swaps
schemas per environment, and its manifest makes "build only what changed" possible in CI.
Version-controlled SQL files are reviewable in a pull request; stored procedures are not.
**Trade-offs.** Another tool to learn and pin; Jinja makes some SQL harder to read and lint.

## 3. GitHub Actions for CI and scheduling

**Problem.** Run checks on pull requests and the pipeline once a day.
**Options.** GitHub Actions; Airflow; dbt Cloud; Snowflake tasks.
**Chosen.** GitHub Actions for both.
**Why.** The code is on GitHub already; it gives secrets, schedules, run history, artifacts and
failure emails with no infrastructure to run. One daily job with three steps doesn't need more.
**Trade-offs.** Cron scheduling only (no data-aware triggers or backfill UI), jobs can start a
few minutes late, and the run history lives in GitHub rather than with the data.

## 4. No Airflow

**Problem.** Should a "real" orchestrator run the pipeline?
**Options.** Airflow (or Dagster/Prefect); GitHub Actions.
**Chosen.** No orchestrator.
**Why.** The pipeline is linear (load → freshness → build) and daily. Airflow would add a
scheduler, a metadata database and workers to run three commands. It earns its place with many
interdependent pipelines, sensors, retries per task and backfills over date partitions.
**Trade-offs.** No per-step retries or backfill tooling; a rerun repeats the whole job (which is
safe, because every step is idempotent).

## 5. CSV files + a Python loader for trades

**Problem.** The quickstart typed trades into dbt seeds. That shows nothing about ingestion: no
landing area, no load history, no replays, no corrections.
**Options.** Keep seeds; Python inserting rows directly; files + `COPY INTO`; Snowpipe; Kafka.
**Chosen.** Versioned CSV files, loaded by `ingestion/load_trades.py` through a stage.
**Why.** Files are how most order-management systems hand over daily trades. A loader around
`PUT` + `COPY INTO` exercises the problems real ingestion has (late files, resends, corrections,
failed loads) at a size that fits a repository.
**Trade-offs.** The repository stands in for cloud storage; the files are synthetic and few.

## 6. Internal stage + `COPY INTO`

**Problem.** How rows get from files into a table.
**Options.** Row-by-row `INSERT` from Python; `write_pandas`; stage + `COPY INTO`; Snowpipe.
**Chosen.** `PUT` to an internal named stage, then one `COPY INTO`.
**Why.** `COPY INTO` keeps per-file load history (64 days) and skips files it already loaded,
which is the first layer of idempotency for free. It adds file name, row number and file
timestamp to every row (`METADATA$...`), loads in bulk, and with `ON_ERROR = ABORT_STATEMENT` a
malformed file loads nothing rather than half.
**Trade-offs.** Load history expires after 64 days (older files are then skipped as "uncertain",
which is safe but means a genuinely new file must have a recent stage timestamp). Snowpipe would
load continuously, which a daily batch doesn't need.

## 7. A raw layer that stores text

**Problem.** Where loaded rows go before dbt.
**Options.** Load straight into typed tables; load into a raw table of strings.
**Chosen.** `RAW.TRADES.TRADES`, every business column `VARCHAR`, never updated.
**Why.** A typed load rejects a file over one bad value and loses the original text. Raw keeps
exactly what arrived, plus where it came from, so any number downstream can be traced to a file
and a row, and staging logic can be fixed and rerun without reloading files. It is the only data
here that can't be rebuilt, so it is in a permanent database (Fail-safe on).
**Trade-offs.** Typing happens in staging (`TRY_TO_NUMBER`), so a bad value surfaces as a NULL
caught by a test, one step later than a typed load would catch it.

## 8. Staging, intermediate and marts

**Problem.** How to organise models so source quirks, business logic and outputs don't mix.
**Chosen.** Three layers. Staging (views) is the only place that knows the source: the long
variable/value price format, `FLOAT` values, text trade columns, replays. Intermediate holds
reusable logic (pivot, current trades, positions, forward fill, PnL). Marts are what people query,
with names that say who they are for.
**Why.** If the Marketplace renames a column, only a staging model changes. If the PnL rule
changes, only `int_trading_pnl` changes. Department marts can be views because the work is done in
`fct_trading_pnl`.
**Trade-offs.** More models than a single big query. One exception: intermediate models read
`dim_date`, a mart, because the trading calendar is shared reference data rather than an output.

## 9. `fct_trading_pnl` is a plain table

**Problem.** It was `incremental` (merge, 7-day lookback), with an equality test against its
source to catch when the merge went stale.
**Options.** Keep it incremental; make it a table.
**Chosen.** Table, rebuilt every run.
**Why.** Incremental only saves work if the expensive part is skipped. Here every upstream model
(`int_daily_position`, `int_trading_pnl`) was still rebuilt in full every run, so the merge saved
the cost of writing ~1,500 rows and cost a full-table equality test every run. Worse, PnL is a
running total: a back-dated trade or an amendment changes every later day, which a 7-day window
can't repair. A full rebuild of a small table is always correct.
**Trade-offs.** If positions grew to millions of rows a day, this would need revisiting, starting
with incrementalising the position model, not the final table.

## 10. Market data is incremental

**Problem.** `int_stock_prices_daily` pivots ~35M source rows, the most expensive step, and almost
all of history is unchanged from yesterday.
**Chosen.** `int_stock_prices_daily` and `fct_stock_history` are incremental `merge` models keyed
on `(ticker, trade_date)`, re-reading the last `market_data_lookback_days` days.
**Why.** The grain is a natural key; a day's prices don't depend on other days, so reprocessing a
window is correct; and the saving is real (a window instead of all history).
**Trade-offs.** Restatements older than the window are missed (detected by a test, repaired with
`--full-refresh`); rows deleted at the source are never deleted here; schema changes need a full
refresh (`on_schema_change = 'fail'` makes that explicit instead of silently appending columns).
Adjusted prices were dropped: the provider rewrites them for the whole history on every split or
dividend, so they can't be maintained by any lookback window.

## 11. The lookback window

**Problem.** How many days to re-read.
**Options.** Pick a number; measure.
**Chosen.** 30 days, explicitly provisional, plus the means to measure the right number.
**Why.** The source's restatement behaviour isn't documented and couldn't be observed before the
incremental model existed (you need yesterday's stored copy to see what changed). The asymmetry
decides the starting point: a too-short window silently keeps wrong prices; a too-long one costs
re-pivoting ~10k rows per extra day on XSMALL. So: start generous, measure, then tighten.
Measurement is built in: the daily run executes `analyses/market_data_restatement_depth.sql`
*before* building and logs how old every changed day was; the warn test
`assert_market_data_restatements_within_lookback` compares 90 days of stored prices against the
source after every build.
**Trade-offs.** Until a few weeks of evidence exist, 30 is a judgement, not a measurement.

## 12. `ASOF JOIN` for FX

**Problem.** FX rates are missing on some US trading days (ECB holidays), so each day needs the
latest rate on or before it.
**Options.** `ASOF JOIN`; a correlated subquery; forward-filling FX over a calendar with
`LAST_VALUE IGNORE NULLS`; a range join with `QUALIFY`.
**Chosen.** `ASOF JOIN`.
**Why.** It states the intent in one clause and handles "no earlier rate" as a NULL, which a test
catches. The alternatives are longer and easier to get subtly wrong.
**Trade-offs.** Snowflake-specific; without an `ON` key it is not parallel (decision 13).

## 13. The ASOF optimisation

**Problem.** `fct_stock_history` took ~10 s on every warehouse size.
**Chosen.** As-of lookup on the 374 distinct trading days, then an equi-join to the prices.
**Why.** See [PERFORMANCE.md](PERFORMANCE.md): the slow part was serial, so only shrinking it
helps; a bigger warehouse just paid more for the same single worker.
**Trade-offs.** One more CTE per currency; correct only because the rate depends on the date alone.

## 14. Separate environments

**Problem.** Development, CI and production must not overwrite each other.
**Chosen.** `ANALYTICS` (production, only `transformer_prod` writes) and `ANALYTICS_DEV`
(transient; developers and CI). dbt's `generate_schema_name_for_env` builds `MARTS` in
production and puts everything in the target's own schema elsewhere (`DEV_VIKTOR`, `CI_PR_12`).
**Why.** Separate databases make the boundary a permission, not a convention: the CI and
developer roles have no write privilege on `ANALYTICS` at all.
**Trade-offs.** One Snowflake account for everything; a mistake in the grants script affects all
environments.

## 15. A schema set per pull request

**Problem.** CI needs to build somewhere real without colliding with other pull requests or
production.
**Chosen.** `ANALYTICS_DEV.CI_PR_<number>`, dropped by `ci-cleanup.yml` when the pull request
closes. Only changed models and their children are built (`state:modified+`); unchanged parents
are read from production (`--defer`); changed incremental models start from a zero-copy clone of
production so their incremental branch is what gets tested.
**Why.** Two pull requests building into one schema would test each other's tables. Building only
what changed keeps CI to the cost of the change.
**Trade-offs.** CI reads production data, which is fine for public and synthetic data but would
need masking for sensitive data. CI depends on the last production manifest artifact (falls back
to a full build if there is none). A pull request that changes an incremental model's columns
can't run the incremental branch against production's table, so it needs the `full-refresh` label.

## 16. Service users

**Problem.** The quickstart setup had one user with a password and every role, used by people and
jobs alike.
**Chosen.** One `TYPE = SERVICE` user per automated process (`svc_loader`, `svc_dbt_prod`,
`svc_dbt_ci`), each with exactly one role. People use their own users.
**Why.** A leaked CI key can't write production or load files; a key can be rotated without
touching the other jobs; login and query history say which process did what. `TYPE = SERVICE`
users can't log in with a password at all.
**Trade-offs.** Three keys and three secrets to manage.

## 17. Key-pair authentication

**Problem.** How automated jobs authenticate.
**Options.** Password; key pair; OAuth / workload identity federation.
**Chosen.** RSA key pairs.
**Why.** Passwords for service accounts get shared and can't use MFA. With a key pair the private
key never leaves the job's secret store and Snowflake only holds the public key;
`RSA_PUBLIC_KEY_2` allows rotation without downtime.
**Trade-offs.** Keys must be rotated by hand. Workload identity federation (GitHub OIDC, no
long-lived secret) would be better still but is more setup than this project needs.

## 18. A resource monitor and statement timeouts

**Problem.** A runaway query or a looping schedule can spend credits all night.
**Chosen.** A monthly 10-credit monitor on all four warehouses (notify at 75%, suspend at 90%,
cancel at 100%); statement timeouts of 5–10 minutes; 60 s auto-suspend.
**Why.** The daily run needs about 1 credit a month (estimated); 10 leaves room for development
while capping the worst case. The slowest query takes seconds, so anything running ten minutes is
a bug.
**Trade-offs.** Hitting the quota stops production too, by design.

## 19. No Kafka, Spark, Snowpipe, Dynamic Tables or Airflow

**Problem.** Should the project use the tools common in job descriptions?
**Chosen.** No.
**Why.** Each solves a problem this project doesn't have: Kafka (streaming events), Spark
(processing beyond one warehouse), Snowpipe (continuous file arrival), Dynamic Tables (declarative
refresh on a lag target), Airflow (many interdependent pipelines). Adding them would show that I
can install them, not that I know when to.
**Trade-offs.** The project doesn't demonstrate those tools.

## 20. Data quality tiers

**Problem.** Every failing test stopped the build, and some tests could never fail (a `HAVING
close_price IS NOT NULL` followed by a `not_null` test on `close_price`).
**Chosen.** Block (severity error), warn (severity warn) and observe (a monitoring view, no
test). Rows without a close are kept and counted instead of filtered before the test.
**Why.** A failure should stop publishing only when the output would be wrong (a trade lost or
double counted, cash not reconciling, a broken feed). A stale price on one instrument or a late
trade is worth knowing but not worth withholding every report.
**Trade-offs.** Warnings are only useful if someone reads the run summary.

## 21. Not over-engineering

**Problem.** How much platform does a two-book portfolio project need?
**Chosen.** The smallest set that makes each concept real: one loader, one stage, five roles,
three service users, two workflows plus cleanup, one monitoring view.
**Why.** Every component here exists because removing it would break something specific, and
each can be explained in a sentence. No snapshots (nothing needs history of a changing dimension),
no contracts or exposures (no external consumers to protect yet), no Terraform (a few idempotent
SQL scripts describe the account completely).
**Trade-offs.** Some things a larger team would want (masking policies, network policies, alerting
beyond email, blue/green deployments) are documented as limitations rather than built.
