-- All desks' trades in one place. union_relations aligns the seeds' columns by name,
-- so a new desk only needs its seed added to the list.
with unioned as (
    {{ dbt_utils.union_relations(relations=[ref('manual_book1'), ref('manual_book2')]) }}
)

select
    book,
    trade_date,
    trader,
    instrument,
    upper(action)  as action,
    quantity,
    case when upper(action) = 'SELL' then -quantity else quantity end  as signed_quantity,
    price_per_share,
    currency,
    -- cash leaves the book on a BUY (negative) and comes back on a SELL (positive)
    -signed_quantity * price_per_share  as cash_flow
from unioned
