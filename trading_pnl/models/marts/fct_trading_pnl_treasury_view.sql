{{ config(materialized='view') }}

-- Treasury: daily cash movements and running cash balance per currency.
with daily as (
    select currency, position_date, sum(cash_flow) as cash_flow
    from {{ ref('fct_trading_pnl') }}
    group by all
)

select
    currency,
    position_date,
    cash_flow,
    sum(cash_flow) over (
        partition by currency
        order by position_date
        rows between unbounded preceding and current row
    )  as cash_balance
from daily
