{{ config(materialized='view') }}

-- Finance: daily market value, cumulative cash and PnL per book, each in the book's own currency.
-- Books are never summed across currencies. Amounts are summed at full precision, then rounded.
with daily as (
    select
        book,
        currency,
        position_date,
        sum(market_value)    as market_value,
        sum(cumulative_cash) as cumulative_cash,
        sum(pnl)             as pnl
    from {{ ref('fct_trading_pnl') }}
    group by all
),

with_change as (
    select
        *,
        -- day-on-day change; null on the book's first day
        pnl - lag(pnl) over (partition by book order by position_date) as daily_pnl
    from daily
)

select
    daily.book,
    books.desk_name,
    daily.currency,
    daily.position_date,
    round(daily.market_value, 2)    as market_value,
    round(daily.cumulative_cash, 2) as cumulative_cash,
    round(daily.pnl, 2)             as pnl,
    round(daily.daily_pnl, 2)       as daily_pnl
from with_change as daily
left join {{ ref('dim_book') }} as books
    on daily.book = books.book
