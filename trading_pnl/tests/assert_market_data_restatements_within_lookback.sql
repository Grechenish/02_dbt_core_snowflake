{{ config(severity='warn') }}

-- WARN. The incremental market-data models only re-read the last var('market_data_lookback_days')
-- days. If the provider restates or back-fills a day older than that, the stored prices silently
-- keep the old value. This compares the stored prices with the source over a wider window and
-- returns every difference the lookback can no longer repair.
-- A failure means: run `dbt build --full-refresh --select int_stock_prices_daily+`, and consider
-- a longer lookback (analyses/market_data_restatement_depth.sql shows how far back changes go).
select *
from ({{ market_data_restatements(var('restatement_check_days')) }})
where age_days > {{ var('market_data_lookback_days') }}
