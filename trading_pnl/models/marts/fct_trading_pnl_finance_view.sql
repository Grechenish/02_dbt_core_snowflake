{{ config(materialized='view') }}

-- Finance: daily book-level totals (each book reports in its own currency).
select
    book,
    currency,
    position_date,
    sum(market_value)     as market_value,
    sum(cumulative_cash)  as cumulative_cash,
    sum(pnl)              as pnl
from {{ ref('fct_trading_pnl') }}
group by all
