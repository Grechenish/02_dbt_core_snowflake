-- One row per trade version, typed. RAW keeps every row of every file as text; this model casts
-- each column and collapses replays: a file loaded twice (e.g. resent under another name) puts
-- the same (trade_id, version) into RAW twice, and only its first arrival is kept here.
-- Replays with *different* content are not hidden by this: assert_trade_replays_are_identical
-- checks RAW directly and fails the build.
with raw_rows as (
    select * from {{ source('raw_trades', 'trades') }}
),

typed as (
    select
        trim(trade_id)                                                       as trade_id,
        try_to_number(version)                                               as version,
        upper(trim(status))                                                  as status,
        trim(book)                                                           as book,
        trim(trader)                                                         as trader,
        upper(trim(instrument))                                              as instrument,
        upper(trim(side))                                                    as side,
        try_to_number(quantity, 18, 0)                                       as quantity,
        try_to_number(price, 18, 6)                                          as price,
        upper(trim(currency))                                                as currency,
        try_to_date(trade_date)                                              as trade_date,
        convert_timezone('UTC', try_to_timestamp_tz(booked_at))::timestamp_ntz  as booked_at_utc,
        _source_file,
        _source_row_number,
        _load_run_id,
        _loaded_at
    from raw_rows
)

select
    *,
    count(*) over (partition by trade_id, version)  as times_loaded
from typed
qualify row_number() over (
    partition by trade_id, version
    order by _loaded_at, _source_file, _source_row_number
) = 1
