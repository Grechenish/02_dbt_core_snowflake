-- Each book's open positions must add up to 100% of the book on every day.
-- share_of_book is rounded to 4 decimals, so allow a small rounding tolerance.
select book, position_date, sum(share_of_book) as total_share
from {{ ref('fct_trading_pnl_risk_view') }}
group by book, position_date
having abs(sum(share_of_book) - 1) > 0.001
