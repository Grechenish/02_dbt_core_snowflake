{#- Rows where the stored daily prices no longer match what the source says today, over the last
    `check_days` days. Shared by the restatement test (does anything differ outside the lookback
    window?) and the restatement-depth analysis (how far back do differences go?).
    `age_days` counts back from the newest loaded day, the same way the incremental lookback does. -#}
{% macro market_data_restatements(check_days) %}
with window_start as (
    select dateadd(day, -{{ check_days }}, max(trade_date)) as first_day, max(trade_date) as last_day
    from {{ ref('int_stock_prices_daily') }}
),

source_prices as (
    select
        ticker,
        trade_date,
        max(case when variable = 'post-market_close' then value end)  as close_price,
        max(case when variable = 'nasdaq_volume' then value end)::number(38, 0)  as volume
    from {{ ref('stg_public_data__stock_prices') }}
    where trade_date >= (select first_day from window_start)
    group by ticker, trade_date
    having close_price is not null
),

stored_prices as (
    select ticker, trade_date, close_price, volume
    from {{ ref('int_stock_prices_daily') }}
    where trade_date >= (select first_day from window_start)
)

select
    coalesce(source_prices.ticker, stored_prices.ticker)          as ticker,
    coalesce(source_prices.trade_date, stored_prices.trade_date)  as trade_date,
    datediff(
        day,
        coalesce(source_prices.trade_date, stored_prices.trade_date),
        (select last_day from window_start)
    )                                                              as age_days,
    case
        when stored_prices.ticker is null then 'missing_in_table'
        when source_prices.ticker is null then 'missing_in_source'
        else 'value_changed'
    end                                                            as difference,
    stored_prices.close_price  as stored_close_price,
    source_prices.close_price  as source_close_price,
    stored_prices.volume       as stored_volume,
    source_prices.volume       as source_volume
from source_prices
full outer join stored_prices
    on  stored_prices.ticker = source_prices.ticker
    and stored_prices.trade_date = source_prices.trade_date
where not equal_null(stored_prices.close_price, source_prices.close_price)
   or not equal_null(stored_prices.volume, source_prices.volume)
{% endmacro %}
