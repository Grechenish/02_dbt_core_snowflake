-- Pivot long-format price variables into one row per ticker per trading day.
select
    ticker,
    trade_date,
    any_value(asset_class)            as asset_class,
    any_value(primary_exchange_name)  as primary_exchange_name,
    max(case when variable = 'pre-market_open'             then value end) as open_price,
    max(case when variable = 'all-day_high'                then value end) as high_price,
    max(case when variable = 'all-day_low'                 then value end) as low_price,
    max(case when variable = 'post-market_close'           then value end) as close_price,
    max(case when variable = 'post-market_close_adjusted'  then value end) as close_price_adjusted,
    max(case when variable = 'nasdaq_volume'               then value end)::number(38, 0) as volume
from {{ ref('stg_public_data__stock_prices') }}
group by ticker, trade_date
-- The source has a handful of volume-only rows with no prices (e.g. PSTR, DSS on 2025-01-06); drop them.
having close_price is not null
