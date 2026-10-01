-- Daily PnL per book / trader / instrument. A plain table, rebuilt in full on every run: see the
-- model description for why incremental processing doesn't pay off here.
-- Amounts are cast to fixed-point types with 6 decimals so every consumer sees the same types;
-- rounding to cents happens in the department marts, after they aggregate.
select
    book,
    trader,
    instrument,
    currency,
    position_date,
    action,
    traded_quantity,
    shares_held,
    cash_flow::number(38, 6)         as cash_flow,
    close_price_usd::number(38, 6)   as close_price_usd,
    usd_fx_rate::number(38, 10)      as usd_fx_rate,
    close_price::number(38, 6)       as close_price,
    last_price_date,
    price_age_days,
    market_value::number(38, 6)      as market_value,
    cumulative_cash::number(38, 6)   as cumulative_cash,
    pnl::number(38, 6)               as pnl
from {{ ref('int_trading_pnl') }}
