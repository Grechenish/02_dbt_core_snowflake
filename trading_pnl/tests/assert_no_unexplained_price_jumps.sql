{{ config(severity='warn') }}

-- WARN. Prices are unadjusted, and corporate actions are out of scope. On a 4-for-1 split the
-- close drops ~75% overnight while the trade records still hold the pre-split share count, so
-- market value and PnL would show a loss that never happened. This flags any traded instrument
-- whose close moves more than 40% from one trading day to the next, which is rare enough for a
-- large-cap stock that a person should check for a split before trusting the PnL.
with moves as (
    select
        instrument,
        calendar_date,
        close_price_usd,
        lag(close_price_usd) over (partition by instrument order by calendar_date)  as previous_close
    from {{ ref('int_instrument_prices_filled') }}
)

select
    *,
    div0(close_price_usd, previous_close) - 1  as relative_move
from moves
where abs(div0(close_price_usd, previous_close) - 1) > 0.4
