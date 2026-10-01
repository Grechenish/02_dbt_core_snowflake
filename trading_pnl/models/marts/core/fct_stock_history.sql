{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['ticker', 'trade_date'],
        on_schema_change='fail'
    )
}}

-- Daily stock history with close prices converted to each report currency.
-- FX rates are not published on every trading day (holidays differ between the US and the ECB),
-- so each trading day takes the most recent rate on or before it.
--
-- Performance: the ASOF JOIN runs against the ~400 distinct trading days, not the ~4M price rows.
-- An ASOF JOIN without an ON key can't be parallelised, so joining it to every price row took
-- ~10s on any warehouse size; the price rows then use a plain equi-join, which scales.
with prices as (
    select *
    from {{ ref('int_stock_prices_daily') }}
    -- ticker-days without a close have nothing to convert; monitoring_market_data_daily counts them
    where close_price is not null
    {% if is_incremental() %}
        -- same window as int_stock_prices_daily, so every day it re-merged is re-converted here too
        and trade_date >= (
            select dateadd(day, -{{ var('market_data_lookback_days') }}, max(trade_date)) from {{ this }}
        )
    {% endif %}
),

fx as (
    select * from {{ ref('stg_public_data__fx_rates') }}
),

trading_days as (
    select distinct trade_date from prices
)

{% for ccy in var("report_currencies") %}
, fx_{{ ccy | lower }} as (
    select trading_days.trade_date, rates.fx_rate
    from trading_days
    asof join (select rate_date, fx_rate from fx where quote_currency = '{{ ccy }}') as rates
        match_condition (trading_days.trade_date >= rates.rate_date)
)
{% endfor %}

select
    prices.ticker,
    prices.trade_date,
    prices.asset_class,
    prices.primary_exchange_name,
    prices.open_price,
    prices.high_price,
    prices.low_price,
    prices.close_price           as close_price_usd,
    prices.volume
    {%- for ccy in var("report_currencies") %},
    fx_{{ ccy | lower }}.fx_rate                                       as usd_{{ ccy | lower }}_rate,
    round(prices.close_price * fx_{{ ccy | lower }}.fx_rate, 4)       as close_price_{{ ccy | lower }}
    {%- endfor %}
from prices
{%- for ccy in var("report_currencies") %}
left join fx_{{ ccy | lower }}
    on fx_{{ ccy | lower }}.trade_date = prices.trade_date
{%- endfor %}
