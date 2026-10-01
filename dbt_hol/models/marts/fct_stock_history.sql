-- Daily stock history with close prices converted to each report currency.
-- FX rates are not published on every trading day (holidays differ between the US and the ECB),
-- so we ASOF-join the most recent rate on or before the trade date.
with prices as (
    select * from {{ ref('int_stock_prices_daily') }}
),

fx as (
    select * from {{ ref('stg_public_data__fx_rates') }}
)

{% for ccy in var("report_currencies") %}
, fx_{{ ccy | lower }} as (
    select rate_date, fx_rate from fx where quote_currency = '{{ ccy }}'
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
    prices.close_price_adjusted  as close_price_adjusted_usd,
    prices.volume
    {%- for ccy in var("report_currencies") %},
    fx_{{ ccy | lower }}.fx_rate                                       as usd_{{ ccy | lower }}_rate,
    round(prices.close_price * fx_{{ ccy | lower }}.fx_rate, 4)       as close_price_{{ ccy | lower }}
    {%- endfor %}
from prices
{%- for ccy in var("report_currencies") %}
asof join fx_{{ ccy | lower }}
    match_condition (prices.trade_date >= fx_{{ ccy | lower }}.rate_date)
{%- endfor %}
