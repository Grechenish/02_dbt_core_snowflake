-- BLOCK. Each book reports in one currency (seed `books`), and cash, market value and PnL are
-- summed per book. A trade priced in another currency would be added to the book's totals as if
-- it were in the book currency.
select trades.trade_id, trades.book, trades.currency, books.base_currency
from {{ ref('int_trades_current') }} as trades
inner join {{ ref('books') }} as books
    on trades.book = books.book
where trades.currency <> books.base_currency
