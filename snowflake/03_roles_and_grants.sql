-- 03: roles and what each one may do. Run as SECURITYADMIN, plus ACCOUNTADMIN for the Marketplace
-- share. Every GRANT is idempotent, so the script can be re-run after a change.
--
--   role              who uses it          can do
--   ----------------  -------------------  -------------------------------------------------------
--   loader            svc_loader           PUT to the trade stage, COPY/INSERT into RAW.TRADES
--   transformer_prod  svc_dbt_prod         read RAW + Marketplace, build schemas in ANALYTICS
--   transformer_ci    svc_dbt_ci           read RAW + Marketplace + ANALYTICS, build in ANALYTICS_DEV
--   developer         people               same as transformer_ci, for DEV_<name> schemas
--   reporter          people / BI tools    read the ANALYTICS marts
--
-- Nothing gets GRANT ALL, and no role can create warehouses, users or roles. Warehouses get USAGE
-- only: a role can run queries on it, but not resize it (MODIFY), suspend it (OPERATE) or drop it.
use role securityadmin;

create role if not exists loader           comment = 'Loads trade files into RAW';
create role if not exists transformer_prod comment = 'Runs dbt in production';
create role if not exists transformer_ci   comment = 'Runs dbt for pull requests';
create role if not exists developer        comment = 'People developing the dbt project';
create role if not exists reporter         comment = 'Reads the production marts';

-- SYSADMIN inherits every custom role, so administrators can see and fix everything they build.
grant role loader           to role sysadmin;
grant role transformer_prod to role sysadmin;
grant role transformer_ci   to role sysadmin;
grant role developer        to role sysadmin;
grant role reporter         to role sysadmin;

-- Compute: each role gets one warehouse, so its credits are visible per warehouse.
grant usage on warehouse load_wh      to role loader;
grant usage on warehouse transform_wh to role transformer_prod;
grant usage on warehouse dev_wh       to role transformer_ci;
grant usage on warehouse dev_wh       to role developer;
grant usage on warehouse reporting_wh to role reporter;

-- Loader: write-only into the landing objects. It cannot read the loaded rows, create tables or
-- touch anything dbt builds. COPY INTO needs INSERT on the table and READ on the stage; PUT needs WRITE.
grant usage on database raw                           to role loader;
grant usage on schema raw.trades                      to role loader;
grant usage on file format raw.trades.trade_csv       to role loader;
grant read, write on stage raw.trades.trade_files     to role loader;
grant insert on table raw.trades.trades               to role loader;
grant insert on table raw.trades.load_runs            to role loader;

-- Everyone who runs dbt reads RAW (read only).
grant usage on database raw to role transformer_prod;
grant usage on database raw to role transformer_ci;
grant usage on database raw to role developer;
grant usage on schema raw.trades to role transformer_prod;
grant usage on schema raw.trades to role transformer_ci;
grant usage on schema raw.trades to role developer;
grant select on all tables in schema raw.trades    to role transformer_prod;
grant select on all tables in schema raw.trades    to role transformer_ci;
grant select on all tables in schema raw.trades    to role developer;
grant select on future tables in schema raw.trades to role transformer_prod;
grant select on future tables in schema raw.trades to role transformer_ci;
grant select on future tables in schema raw.trades to role developer;

-- Production output: only transformer_prod can create schemas in ANALYTICS. It owns what dbt
-- builds there, and dbt's `grants` config (dbt_project.yml) gives SELECT on those objects to the
-- roles below.
grant usage, create schema on database analytics to role transformer_prod;

-- Read access to production for the roles that need it: reporter for the marts, and CI and
-- developers for `--defer` and `dbt clone`, which read unchanged models from production instead of
-- rebuilding them. Schema USAGE is granted here (dbt never replaces schemas, so it sticks); table
-- and view SELECT comes from dbt grants, because dbt revokes grants it was not configured with.
grant usage on database analytics to role reporter;
grant usage on database analytics to role transformer_ci;
grant usage on database analytics to role developer;
grant usage on all schemas in database analytics    to role reporter;
grant usage on all schemas in database analytics    to role transformer_ci;
grant usage on all schemas in database analytics    to role developer;
grant usage on future schemas in database analytics to role reporter;
grant usage on future schemas in database analytics to role transformer_ci;
grant usage on future schemas in database analytics to role developer;

-- Non-production output: CI and developers create their own schemas in ANALYTICS_DEV. A schema is
-- owned by the role that created it, so a developer can't drop a CI schema and CI can't drop a
-- developer's. Developers share one role, so DEV_<name> keeps them apart by convention only.
grant usage, create schema on database analytics_dev to role transformer_ci;
grant usage, create schema on database analytics_dev to role developer;

-- The Marketplace share only accepts IMPORTED PRIVILEGES, which only ACCOUNTADMIN can grant here.
use role accountadmin;
grant imported privileges on database snowflake_public_data_free to role transformer_prod;
grant imported privileges on database snowflake_public_data_free to role transformer_ci;
grant imported privileges on database snowflake_public_data_free to role developer;
