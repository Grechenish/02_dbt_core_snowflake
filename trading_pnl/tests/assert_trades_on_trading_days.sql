-- BLOCK. Positions are carried on trading days only, from var('start_date') onwards, so a trade
-- dated on a weekend, a market holiday or before the start date would never enter a position and
-- would vanish from PnL without an error. Trades newer than the newest market-data day are
-- covered by assert_trades_within_market_data instead.
select trades.trade_id, trades.trade_date, calendar.day_name
from {{ ref('int_trades_current') }} as trades
left join {{ ref('dim_date') }} as calendar
    on trades.trade_date = calendar.date_day
where trades.trade_date <= (select max(all_days.date_day) from {{ ref('dim_date') }} as all_days)
    and not coalesce(calendar.is_trading_day, false)
