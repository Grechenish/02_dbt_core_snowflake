{{ config(materialized='view') }}

-- Risk: open exposure per trader and instrument, and its share of the book's market value
-- (concentration risk), with how stale the price behind it is. Closed positions are left out.
select
    pnl.book,
    pnl.trader,
    pnl.instrument,
    securities.asset_class,
    pnl.currency,
    pnl.position_date,
    pnl.shares_held,
    round(pnl.market_value, 2) as market_value,
    round(
        div0(pnl.market_value, sum(pnl.market_value) over (partition by pnl.book, pnl.position_date)), 4
    )                          as share_of_book,
    pnl.price_age_days
from {{ ref('fct_trading_pnl') }} as pnl
left join {{ ref('dim_security') }} as securities
    on pnl.instrument = securities.ticker
where pnl.shares_held <> 0
