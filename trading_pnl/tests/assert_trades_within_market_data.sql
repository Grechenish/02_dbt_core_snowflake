{{ config(severity='warn') }}

-- WARN. The free market-data feed runs weeks behind, so a trade can be newer than the newest
-- price. Such a trade is valid but has no PnL yet: it enters positions once prices for its date
-- arrive. This lists them so the gap is visible instead of silent.
select trades.trade_id, trades.trade_date, max_day.last_market_day
from {{ ref('int_trades_current') }} as trades
cross join (select max(date_day) as last_market_day from {{ ref('dim_date') }}) as max_day
where trades.trade_date > max_day.last_market_day
