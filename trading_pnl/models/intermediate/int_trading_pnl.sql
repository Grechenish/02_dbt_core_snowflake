-- Mark each daily position to market in its book currency and compute PnL.
-- pnl = market value of shares held + net cash spent/received so far.
-- Nothing is rounded here: rounding happens once, in the reporting marts, after aggregation.
with positions as (
    select * from {{ ref('int_daily_position') }}
),

prices as (
    select instrument, calendar_date, close_price_usd, last_price_date, price_age_days
    from {{ ref('int_instrument_prices_filled') }}
),

fx as (
    select quote_currency, rate_date, fx_rate
    from {{ ref('stg_public_data__fx_rates') }}
),

priced as (
    select
        positions.*,
        prices.close_price_usd,
        prices.last_price_date,
        prices.price_age_days,
        -- latest USD -> book-currency rate on or before the position date (not published every trading day)
        case when positions.currency = 'USD' then 1 else fx.fx_rate end as usd_fx_rate
    from positions
    inner join prices
        on positions.instrument = prices.instrument
            and positions.position_date = prices.calendar_date
    asof join fx
        match_condition(positions.position_date >= fx.rate_date)
        on positions.currency = fx.quote_currency
)

select
    book,
    trader,
    instrument,
    currency,
    position_date,
    action,
    traded_quantity,
    cash_flow,
    shares_held,
    close_price_usd,
    last_price_date,
    price_age_days,
    usd_fx_rate,
    close_price_usd * usd_fx_rate  as close_price,
    shares_held * close_price      as market_value,
    sum(cash_flow) over (
        partition by book, trader, instrument, currency
        order by position_date
        rows between unbounded preceding and current row
    )                              as cumulative_cash,
    market_value + cumulative_cash as pnl
from priced
