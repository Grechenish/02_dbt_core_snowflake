-- BLOCK. A trade's history must make sense: version 1 is the NEW booking, every later version is
-- an AMEND or a CANCEL, and nothing follows a CANCEL. Anything else means the upstream feed is
-- broken, and picking "the latest version" would give an answer nobody can defend.
with versions as (
    select
        trade_id,
        version,
        status,
        lag(status) over (partition by trade_id order by version) as previous_status
    from {{ ref('stg_trades__trade_versions') }}
)

select *
from versions
where (version = 1 and status <> 'NEW')
   or (version > 1 and status not in ('AMEND', 'CANCEL'))
   or previous_status = 'CANCEL'
