-- Every trade must fall on a day the instrument has a price; otherwise it would
-- silently drop out of the daily position calendar.
select book.book, book.trader, book.instrument, book.trade_date
from {{ ref('int_trades_current') }} as book
where not exists (
    select 1
    from {{ ref('int_stock_prices_daily') }} as prices
    where prices.ticker = book.instrument
      and prices.trade_date = book.trade_date
)
