-- Daily PnL per book / trader / instrument. A plain table, rebuilt in full on every run: see the
-- model description for why incremental processing doesn't pay off here.
select *
from {{ ref('int_trading_pnl') }}
