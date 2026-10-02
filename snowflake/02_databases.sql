-- 02: databases and the raw landing objects. Run as SYSADMIN, which owns them.
use role sysadmin;

-- RAW: the only copy of the loaded trade files. Permanent (Time Travel plus Fail-safe), because it
-- is the one dataset dbt cannot rebuild. Only the loader writes here.
create database if not exists raw comment = 'Landed source data. Written only by the loader.';
create schema if not exists raw.trades;

-- ANALYTICS: production dbt output (schemas STAGING, INTERMEDIATE, MARTS, SEEDS, created by dbt).
-- Only transformer_prod writes here. Everything in it can be rebuilt from RAW and the
-- Marketplace share, so dbt's default transient tables are fine here.
create database if not exists analytics comment = 'Production dbt models. Written only by transformer_prod.';

-- ANALYTICS_DEV: one schema per developer (DEV_<NAME>) and per pull request (CI_PR_<N>).
-- Transient database: no Fail-safe storage is paid for throwaway builds, and no Time Travel is kept.
create transient database if not exists analytics_dev data_retention_time_in_days = 0
    comment = 'Developer and CI dbt builds. Disposable.';

-- How the trade CSVs are parsed. ERROR_ON_COLUMN_COUNT_MISMATCH makes a malformed file fail the
-- COPY instead of loading shifted columns.
create file format if not exists raw.trades.trade_csv
    type = csv
    skip_header = 1
    field_optionally_enclosed_by = '"'
    empty_field_as_null = true
    trim_space = true
    error_on_column_count_mismatch = true;

-- Internal stage the loader PUTs files into before COPY INTO reads them. Snowflake keeps per-file
-- load metadata for 64 days, so the same file is never loaded twice from here.
create stage if not exists raw.trades.trade_files
    file_format = raw.trades.trade_csv
    comment = 'Landing area for trade CSV files (load_trades.py)';

-- Every business column is VARCHAR: raw keeps exactly what the file said, even values that would
-- fail a cast, and staging does the typing. The _ columns record where each row came from, so a
-- duplicate or a bad value can be traced to its file, row and load run.
create table if not exists raw.trades.trades (
    trade_id                  varchar,
    version                   varchar,
    status                    varchar,
    book                      varchar,
    trader                    varchar,
    instrument                varchar,
    side                      varchar,
    quantity                  varchar,
    price                     varchar,
    currency                  varchar,
    trade_date                varchar,
    booked_at                 varchar,
    _source_file              varchar        not null,  -- METADATA$FILENAME
    _source_row_number        number         not null,  -- METADATA$FILE_ROW_NUMBER
    _source_file_modified_at  timestamp_ntz,             -- METADATA$FILE_LAST_MODIFIED
    _load_run_id              varchar        not null,  -- load_runs.run_id of the run that loaded it
    _loaded_at                timestamp_ltz  not null
);

-- One row per loader run, including runs that found nothing new or failed. copy_results holds the
-- COPY INTO result for every file (loaded, skipped, error and first error message).
create table if not exists raw.trades.load_runs (
    run_id          varchar        not null,
    started_at      timestamp_ltz  not null,
    finished_at     timestamp_ltz,
    status          varchar        not null,  -- SUCCEEDED or FAILED
    files_found     number,
    files_uploaded  number,
    files_loaded    number,
    rows_loaded     number,
    error_message   varchar,
    copy_results    variant
);
