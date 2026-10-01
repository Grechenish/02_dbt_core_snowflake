{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['book', 'trader', 'instrument', 'position_date'],
        on_schema_change='append_new_columns',
        pre_hook="{% if var('use_heavy_compute', false) %}alter warehouse {{ target.warehouse }} set warehouse_size = '{{ var('heavy_warehouse_size') }}'{% endif %}",
        post_hook="{% if var('use_heavy_compute', false) %}alter warehouse {{ target.warehouse }} set warehouse_size = 'XSMALL'{% endif %}"
    )
}}

-- Daily PnL per book / trader / instrument. Incremental: each run only re-merges the last
-- var('pnl_lookback_days') days. Editing or deleting older trades in the seeds needs `--full-refresh`;
-- the equality test in _marts.yml fails the build until that happens.
-- The resize hooks only render when the run passes --vars '{use_heavy_compute: true}'.
select *
from {{ ref('int_trading_pnl') }}
{% if is_incremental() %}
where position_date >= (
    select dateadd(day, -{{ var('pnl_lookback_days') }}, max(position_date)) from {{ this }}
)
{% endif %}
