{{ config(materialized='view') }}

-- Risk: open exposure per trader and instrument, and its share of the book's market value.
select
    book,
    trader,
    instrument,
    currency,
    position_date,
    shares_held,
    market_value,
    round(div0(market_value, sum(market_value) over (partition by book, position_date)), 4)  as share_of_book
from {{ ref('fct_trading_pnl') }}
where shares_held <> 0
