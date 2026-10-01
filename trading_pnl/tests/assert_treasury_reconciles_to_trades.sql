-- BLOCK. Reconciliation: the cash Treasury reports must equal the cash of the trades themselves.
-- The trade side is summed straight from int_trades_current, independently of the position
-- calendar, PnL and the Treasury mart. A difference means a trade was dropped or double counted
-- on the way (e.g. a lost calendar day or a duplicated join). Trades newer than the market data
-- aren't in the marts yet (assert_trades_within_market_data), so they are left out of both sides.
with last_market_day as (
    select max(date_day) as last_day from {{ ref('dim_date') }}
),

trade_cash as (
    select currency, sum(cash_flow) as cash_from_trades
    from {{ ref('int_trades_current') }}
    where trade_date <= (select last_market_day.last_day from last_market_day)
    group by currency
),

treasury_cash as (
    select currency, cash_balance
    from {{ ref('treasury_cash_balance_daily') }}
    where position_date = (select last_market_day.last_day from last_market_day)
)

select
    coalesce(trade_cash.currency, treasury_cash.currency) as currency,
    trade_cash.cash_from_trades,
    treasury_cash.cash_balance
from trade_cash
full outer join treasury_cash
    on trade_cash.currency = treasury_cash.currency
where abs(coalesce(trade_cash.cash_from_trades, 0) - coalesce(treasury_cash.cash_balance, 0)) > 0.01
