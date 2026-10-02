{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['ticker', 'trade_date'],
        on_schema_change='fail'
    )
}}

-- Pivot long-format price variables into one row per ticker per trading day.
--
-- Incremental: this pivot reads ~35 M source rows on a full build and is the most expensive step in
-- the project. Each run re-pivots only the last var('market_data_lookback_days') days and merges them
-- on (ticker, trade_date), so a day that arrives late or is restated inside the window is updated in
-- place. Restatements older than the window are caught by the assert_market_data_restatements_within_lookback
-- test, and need `dbt build --full-refresh`. Adjusted prices are deliberately not kept: see the YAML.
with prices as (
    select *
    from {{ ref('stg_public_data__stock_prices') }}
    {% if is_incremental() %}
        -- coalesce: an existing but empty table (e.g. created by `dbt run --empty`) is loaded in full
        where trade_date >= (
                select
                    coalesce(
                        dateadd(day, -{{ var('market_data_lookback_days') }}, max(stored.trade_date)),
                        '1900-01-01'::date
                    )
                from {{ this }} as stored
            )
    {% endif %}
)

select
    ticker,
    trade_date,
    any_value(asset_class)                                                  as asset_class,
    any_value(primary_exchange_name)                                        as primary_exchange_name,
    max(case when variable = 'pre-market_open' then value end)              as open_price,
    max(case when variable = 'all-day_high' then value end)                 as high_price,
    max(case when variable = 'all-day_low' then value end)                  as low_price,
    max(case when variable = 'post-market_close' then value end)            as close_price,
    max(case when variable = 'nasdaq_volume' then value end)::number(38, 0) as volume
from prices
group by ticker, trade_date
-- Rows without a close are kept, not filtered out. The source has a handful of volume-only rows
-- (e.g. PSTR, DSS on 2025-01-06); dropping them here would also hide a feed that suddenly loses
-- most of its prices. monitoring_market_data_daily counts them and its tests decide whether that
-- is normal (observe), unusual (warn) or a broken feed (block). Downstream models skip them explicitly.
