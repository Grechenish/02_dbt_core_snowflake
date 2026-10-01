-- One row per ticker in the market data, with its most recent descriptive attributes.
select
    ticker,
    max_by(asset_class, trade_date)           as asset_class,
    max_by(primary_exchange_name, trade_date) as primary_exchange_name,
    min(trade_date)                           as first_price_date,
    max(trade_date)                           as last_price_date
from {{ ref('int_stock_prices_daily') }}
group by ticker
