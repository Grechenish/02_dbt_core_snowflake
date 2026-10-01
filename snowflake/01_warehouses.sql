-- 01: compute and cost controls. Warehouses are owned by SYSADMIN; the resource monitor needs ACCOUNTADMIN.
-- Idempotent: CREATE ... IF NOT EXISTS never touches an existing object, so every setting is
-- applied again with ALTER. Re-running the script resets drifted settings and changes nothing else.
use role sysadmin;

-- One XSMALL warehouse per workload. Separate warehouses cost nothing extra while suspended, and they
-- make cost attributable (credits per warehouse = credits per workload) and stop one workload
-- queueing behind another. The longest query in the project runs for seconds, so XSMALL is enough:
-- docs/PERFORMANCE.md measured that bigger sizes save a few seconds and cost more than they save.
create warehouse if not exists load_wh      initially_suspended = true;
create warehouse if not exists transform_wh initially_suspended = true;
create warehouse if not exists dev_wh       initially_suspended = true;
create warehouse if not exists reporting_wh initially_suspended = true;

-- AUTO_SUSPEND = 60: Snowflake bills at least 60 s per resume anyway, so suspending sooner saves
--   nothing for a batch job and only causes more resumes.
-- STATEMENT_TIMEOUT_IN_SECONDS: the slowest query takes seconds. A query running for minutes is a
--   runaway (a join on the wrong key, a missing filter), so it is cancelled instead of billed for
--   the default 2 days.
-- STATEMENT_QUEUED_TIMEOUT_IN_SECONDS: fail fast instead of waiting behind a stuck query.
alter warehouse load_wh set
    warehouse_size = xsmall auto_suspend = 60 auto_resume = true
    statement_timeout_in_seconds = 300 statement_queued_timeout_in_seconds = 300
    comment = 'Trade file loader (svc_loader)';
alter warehouse transform_wh set
    warehouse_size = xsmall auto_suspend = 60 auto_resume = true
    statement_timeout_in_seconds = 600 statement_queued_timeout_in_seconds = 300
    comment = 'Production dbt runs (svc_dbt_prod)';
alter warehouse dev_wh set
    warehouse_size = xsmall auto_suspend = 60 auto_resume = true
    statement_timeout_in_seconds = 600 statement_queued_timeout_in_seconds = 300
    comment = 'Developer and CI dbt runs';
alter warehouse reporting_wh set
    warehouse_size = xsmall auto_suspend = 60 auto_resume = true
    statement_timeout_in_seconds = 300 statement_queued_timeout_in_seconds = 300
    comment = 'Read-only queries on the marts (reporter)';

use role accountadmin;

-- A hard monthly budget for everything this project runs. docs/PERFORMANCE.md estimates about
-- 1 credit a month for the daily production build; the quota leaves room for development and CI
-- while capping what a runaway schedule or a forgotten loop can cost.
-- 75 %: email the account admins. 90 %: let running queries finish, then suspend.
-- 100 %: cancel running queries and suspend now.
create resource monitor if not exists trading_pnl_monthly with
    credit_quota = 10 frequency = monthly start_timestamp = immediately;
alter resource monitor trading_pnl_monthly set
    credit_quota = 10
    triggers on 75 percent do notify
             on 90 percent do suspend
             on 100 percent do suspend_immediate;

alter warehouse load_wh      set resource_monitor = trading_pnl_monthly;
alter warehouse transform_wh set resource_monitor = trading_pnl_monthly;
alter warehouse dev_wh       set resource_monitor = trading_pnl_monthly;
alter warehouse reporting_wh set resource_monitor = trading_pnl_monthly;
