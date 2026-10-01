-- One row per position per trading day from its first trade onwards, on the shared trading
-- calendar (dim_date). Days with a trade are BUY/SELL by net direction (MIXED if buys and sells
-- cancel out); every other trading day is a synthetic HOLD row.
with trades as (
    select
        book,
        trader,
        instrument,
        currency,
        trade_date,
        sum(signed_quantity)  as traded_quantity,
        sum(cash_flow)        as cash_flow
    from {{ ref('int_trades_current') }}
    group by all
),

positions as (
    select book, trader, instrument, currency, min(trade_date) as first_trade_date
    from trades
    group by all
),

trading_days as (
    select date_day from {{ ref('dim_date') }} where is_trading_day
),

calendar as (
    select
        positions.*,
        trading_days.date_day  as position_date
    from positions
    inner join trading_days
        on trading_days.date_day >= positions.first_trade_date
)

select
    calendar.book,
    calendar.trader,
    calendar.instrument,
    calendar.currency,
    calendar.position_date,
    case
        when trades.traded_quantity is null then 'HOLD'
        when trades.traded_quantity > 0     then 'BUY'
        when trades.traded_quantity < 0     then 'SELL'
        else 'MIXED'  -- same-day buys and sells that net to zero shares
    end                                  as action,
    coalesce(trades.traded_quantity, 0)  as traded_quantity,
    coalesce(trades.cash_flow, 0)        as cash_flow,
    sum(coalesce(trades.traded_quantity, 0)) over (
        partition by calendar.book, calendar.trader, calendar.instrument, calendar.currency
        order by calendar.position_date
        rows between unbounded preceding and current row
    )                                    as shares_held
from calendar
left join trades
    on  trades.book       = calendar.book
    and trades.trader     = calendar.trader
    and trades.instrument = calendar.instrument
    and trades.currency   = calendar.currency
    and trades.trade_date = calendar.position_date
