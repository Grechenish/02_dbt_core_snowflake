-- BLOCK. Reconciliation between two published reports: on every day, the cumulative cash Finance
-- reports per book, summed per currency, must equal Treasury's cash balance for that currency.
-- Treasury sums daily cash flows over time; Finance sums each position's running cash. They only
-- agree if every position has a row on every trading day, so this catches gaps in the position
-- calendar that neither mart would show on its own. Both sides are rounded to cents, hence the tolerance.
with finance as (
    select currency, position_date, sum(cumulative_cash) as cumulative_cash
    from {{ ref('finance_book_pnl_daily') }}
    group by currency, position_date
)

select
    coalesce(finance.currency, treasury.currency)            as currency,
    coalesce(finance.position_date, treasury.position_date)  as position_date,
    finance.cumulative_cash,
    treasury.cash_balance
from finance
full outer join {{ ref('treasury_cash_balance_daily') }} as treasury
    on  treasury.currency = finance.currency
    and treasury.position_date = finance.position_date
where abs(coalesce(finance.cumulative_cash, 0) - coalesce(treasury.cash_balance, 0)) > 0.02
