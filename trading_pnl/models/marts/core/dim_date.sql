-- One row per calendar day from var('start_date') to the newest market-data day, flagging the days
-- the market traded. This is the single trading calendar every model shares: positions are carried
-- over the same days for every instrument, so a stock that misses a price on a trading day still
-- gets a row (with its last known price) instead of silently skipping the day.
with priced_days as (
    select trade_date, count(*) as tickers_priced
    from {{ ref('int_stock_prices_daily') }}
    group by trade_date
),

bounds as (
    select '{{ var("start_date") }}'::date as first_day, max(trade_date) as last_day
    from priced_days
),

-- generator() rows are numbered with row_number(), because seq4() alone may have gaps
day_numbers as (
    select row_number() over (order by seq4()) - 1 as day_offset
    from table(generator(rowcount => 20000))
),

spine as (
    select dateadd(day, day_numbers.day_offset, bounds.first_day) as date_day
    from day_numbers
    cross join bounds
    where dateadd(day, day_numbers.day_offset, bounds.first_day) <= bounds.last_day
)

select
    spine.date_day,
    year(spine.date_day)                         as calendar_year,
    date_trunc(month, spine.date_day)            as calendar_month,
    dayname(spine.date_day)                      as day_name,
    dayofweekiso(spine.date_day) in (6, 7)       as is_weekend,
    priced_days.trade_date is not null           as is_trading_day,
    coalesce(priced_days.tickers_priced, 0)      as tickers_priced
from spine
left join priced_days
    on priced_days.trade_date = spine.date_day
