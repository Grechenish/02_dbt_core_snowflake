{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['book', 'trader', 'instrument', 'position_date'],
        pre_hook="alter warehouse {{ target.warehouse }} set warehouse_size = '{{ var('heavy_warehouse_size') }}'",
        post_hook="alter warehouse {{ target.warehouse }} set warehouse_size = 'XSMALL'"
    )
}}

-- Daily PnL per book / trader / instrument. Incremental: each run only re-merges the last
-- var('pnl_lookback_days') days. Editing historical trades in the seeds needs `--full-refresh`.
select *
from {{ ref('int_trading_pnl') }}
{% if is_incremental() %}
where position_date >= (
    select dateadd(day, -{{ var('pnl_lookback_days') }}, max(position_date)) from {{ this }}
)
{% endif %}
