-- One row per traded instrument per trading day (shared calendar), with the close price carried
-- forward from the last day the instrument had one. A stock can miss a price on a day the market
-- traded (a halt, a late or missing record); positions still need a value that day, so they use
-- the last known close, and price_age_days tells consumers how old it is.
with instruments as (
    select distinct instrument from {{ ref('int_trades_current') }}
),

trading_days as (
    select date_day from {{ ref('dim_date') }} where is_trading_day
),

prices as (
    select ticker, trade_date, close_price
    from {{ ref('int_stock_prices_daily') }}
    where ticker in (select instrument from instruments)
),

daily as (
    select
        instruments.instrument,
        trading_days.date_day  as calendar_date,
        prices.close_price,
        prices.trade_date      as price_date
    from instruments
    cross join trading_days
    left join prices
        on  prices.ticker = instruments.instrument
        and prices.trade_date = trading_days.date_day
),

filled as (
    select
        instrument,
        calendar_date,
        close_price is not null  as has_own_price,
        last_value(close_price) ignore nulls over (
            partition by instrument order by calendar_date
            rows between unbounded preceding and current row
        )                        as close_price_usd,
        last_value(price_date) ignore nulls over (
            partition by instrument order by calendar_date
            rows between unbounded preceding and current row
        )                        as last_price_date
    from daily
)

select
    *,
    datediff(day, last_price_date, calendar_date)  as price_age_days
from filled
