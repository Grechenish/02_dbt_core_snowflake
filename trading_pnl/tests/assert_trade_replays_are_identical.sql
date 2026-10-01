-- BLOCK. A trade version that arrived more than once must say the same thing every time.
-- Identical replays (a resent file) are harmless: staging keeps one copy. Two different rows for
-- the same (trade_id, version) mean the upstream system reused a version number, and nobody can
-- tell which one is right. Staging would silently keep the first, so this checks RAW directly.
select
    trade_id,
    version,
    count(distinct hash(status, book, trader, instrument, side, quantity, price, currency, trade_date, booked_at))
        as distinct_contents,
    array_agg(distinct _source_file)
        as files
from {{ source('raw_trades', 'trades') }}
group by trade_id, version
having distinct_contents > 1
