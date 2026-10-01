-- How far back does the market-data provider change history? Used to choose
-- var('market_data_lookback_days') from evidence rather than a guess.
--
-- Run it BEFORE the daily build, while the stored table still holds what earlier runs loaded:
--   dbt show --select market_data_restatement_depth --target prod
-- (or `dbt compile` it and paste target/compiled/... into Snowsight). Every row is a day whose
-- prices changed in the source since they were loaded, bucketed by how old that day was.
-- Collect the output for a few weeks: the lookback must exceed the largest age seen.
select
    difference,
    case
        when age_days <= 5 then '0-5 days'
        when age_days <= 10 then '6-10 days'
        when age_days <= 30 then '11-30 days'
        else 'over 30 days'
    end                        as age_bucket,
    count(*)                   as ticker_days,
    count(distinct trade_date) as trade_dates,
    max(age_days)              as oldest_age_days
from ({{ market_data_restatements(var('restatement_check_days')) }})
group by difference, age_bucket
order by difference, age_bucket
