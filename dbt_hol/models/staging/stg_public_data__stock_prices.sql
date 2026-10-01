select
    ticker,
    asset_class,
    primary_exchange_code,
    primary_exchange_name,
    variable,
    date  as trade_date,
    value
from {{ source('public_data', 'stock_price_timeseries') }}
where date >= '{{ var("start_date") }}'
