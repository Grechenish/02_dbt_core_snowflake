-- The trades that are live now: the latest version of every trade, without cancelled ones.
-- An AMEND replaces everything the earlier version said (quantity, price, even trade date), and
-- a CANCEL as the latest version removes the trade, so positions and PnL never see it.
with latest_versions as (
    select *
    from {{ ref('stg_trades__trade_versions') }}
    qualify row_number() over (partition by trade_id order by version desc) = 1
)

select
    trade_id,
    version                                                  as current_version,
    book,
    trader,
    instrument,
    side,
    quantity,
    case when side = 'SELL' then -quantity else quantity end as signed_quantity,
    price,
    currency,
    trade_date,
    booked_at_utc,
    -- cash leaves the book on a BUY (negative) and comes back on a SELL (positive)
    -signed_quantity * price                                 as cash_flow
from latest_versions
where status <> 'CANCEL'
