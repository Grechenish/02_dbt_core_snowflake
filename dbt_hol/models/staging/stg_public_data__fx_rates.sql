select
    base_currency_id   as base_currency,
    quote_currency_id  as quote_currency,
    quote_currency_name,
    date               as rate_date,
    value              as fx_rate,
    provenance:source::varchar     as rate_source,
    provenance:rate_type::varchar  as rate_type
from {{ source('public_data', 'fx_rates_timeseries') }}
where base_currency_id = 'USD'
  and quote_currency_id in ({{ "'" ~ var("report_currencies") | join("', '") ~ "'" }})
  and date >= '{{ var("start_date") }}'
