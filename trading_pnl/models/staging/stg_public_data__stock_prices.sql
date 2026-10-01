select
    ticker,
    asset_class,
    primary_exchange_code,
    primary_exchange_name,
    variable,
    date  as trade_date,
    value::number(38, 6)  as value  -- FLOAT in the source; fixed-point from here on
from {{ source('public_data', 'stock_price_timeseries') }}
where date >= '{{ var("start_date") }}'
