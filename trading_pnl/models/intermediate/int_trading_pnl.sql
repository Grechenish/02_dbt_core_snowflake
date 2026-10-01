-- Mark each daily position to market in its book currency and compute PnL.
-- pnl = market value of shares held + net cash spent/received so far.
with positions as (
    select * from {{ ref('int_daily_position') }}
),

prices as (
    select ticker, trade_date, close_price as close_price_usd
    from {{ ref('int_stock_prices_daily') }}
),

fx as (
    select quote_currency, rate_date, fx_rate
    from {{ ref('stg_public_data__fx_rates') }}
),

priced as (
    select
        positions.*,
        prices.close_price_usd,
        -- latest USD -> book-currency rate on or before the position date (not published every trading day)
        case when positions.currency = 'USD' then 1 else fx.fx_rate end  as usd_fx_rate
    from positions
    join prices
      on  prices.ticker     = positions.instrument
      and prices.trade_date = positions.position_date
    asof join fx
      match_condition (positions.position_date >= fx.rate_date)
      on fx.quote_currency = positions.currency
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
    usd_fx_rate,
    round(close_price_usd * usd_fx_rate, 4)                as close_price,
    round(shares_held * close_price_usd * usd_fx_rate, 2)  as market_value,
    sum(cash_flow) over (
        partition by book, trader, instrument, currency
        order by position_date
        rows between unbounded preceding and current row
    )                                                      as cumulative_cash,
    round(market_value + cumulative_cash, 2)               as pnl
from priced
