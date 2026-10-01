-- 04: one service user per automated process. Run as SECURITYADMIN.
--
-- TYPE = SERVICE: the user cannot log in with a password or through the browser and is exempt from
-- MFA prompts. It can only authenticate with a key pair (or OAuth), which is what a scheduled job
-- needs. Each process gets its own user, so a leaked key exposes one role, can be rotated alone,
-- and LOGIN_HISTORY / QUERY_HISTORY show which process did what.
-- The public keys are set in 05_credentials.sql, which you edit before running.
use role securityadmin;

create user if not exists svc_loader;
alter user svc_loader set
    type = service
    default_role = loader
    default_warehouse = load_wh
    comment = 'GitHub Actions: ingestion/load_trades.py';
grant role loader to user svc_loader;

create user if not exists svc_dbt_prod;
alter user svc_dbt_prod set
    type = service
    default_role = transformer_prod
    default_warehouse = transform_wh
    comment = 'GitHub Actions: daily production dbt build';
grant role transformer_prod to user svc_dbt_prod;

create user if not exists svc_dbt_ci;
alter user svc_dbt_ci set
    type = service
    default_role = transformer_ci
    default_warehouse = dev_wh
    comment = 'GitHub Actions: pull request dbt builds';
grant role transformer_ci to user svc_dbt_ci;
