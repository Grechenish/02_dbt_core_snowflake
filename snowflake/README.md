# Snowflake setup

Idempotent scripts that create everything this project needs in a Snowflake account. Run them in
order in a Snowsight worksheet; re-running any of them is safe and resets drifted settings.

| Script | Run as | Creates |
|---|---|---|
| `01_warehouses.sql` | SYSADMIN, ACCOUNTADMIN | 4 XSMALL warehouses (auto-suspend 60 s, statement timeouts), a 10-credit monthly resource monitor |
| `02_databases.sql` | SYSADMIN | `RAW` (permanent), `ANALYTICS` (production), `ANALYTICS_DEV` (transient), the trade stage, file format and raw tables |
| `03_roles_and_grants.sql` | SECURITYADMIN, ACCOUNTADMIN | 5 roles and their privileges |
| `04_users.sql` | SECURITYADMIN | 3 service users, one role each |
| `05_credentials.sql` | SECURITYADMIN, ACCOUNTADMIN | **edit first**: public keys for the service users, roles for people |

Before running them, install the free **Snowflake Public Data (Free)** listing from the
Marketplace (it creates the database `SNOWFLAKE_PUBLIC_DATA_FREE`).

## Permission model

```
            RAW.TRADES                ANALYTICS (prod)            ANALYTICS_DEV
            stage   tables            schemas  objects            CI_PR_*   DEV_*
loader      write   insert            -        -                  -         -
transf_prod -       select            create   own                -         -
transf_ci   -       select            usage    select             own       -
developer   -       select            usage    select             -         own
reporter    -       -                 usage    select (marts)     -         -
```

- **Only one role can write each place.** The loader can't read what it loaded or touch dbt's
  output; production dbt can read RAW but not write it; CI and developers can read production
  (needed for `--defer` and `dbt clone`) but have no privilege to change it.
- **SELECT on dbt-built objects is granted by dbt** (`+grants` in `dbt_project.yml`), not by
  future grants. dbt revokes any grant it wasn't configured with after each build, so future
  grants on tables would be silently undone; schema `USAGE` is safe to grant here because dbt
  never replaces schemas.
- **Warehouses get `USAGE` only:** run queries, but not resize (`MODIFY`), suspend (`OPERATE`) or
  drop them.
- **Nothing is `GRANT ALL`.** All custom roles roll up to `SYSADMIN`, so administrators can manage
  every object.

## What this replaces

The quickstart-based setup had one password user (`dbt_user`) holding both the dev and prod roles,
`GRANT ALL` on both databases and all four warehouses, and the same credentials in every
environment. Concretely, that meant:

- a leaked CI or laptop password could rebuild, overwrite or drop **production**;
- `GRANT ALL ON WAREHOUSE` let dbt resize warehouses (the quickstart's hooks did exactly that; its
  guide resizes to XXLARGE, 32 times the XSMALL rate), so a bug or a forgotten reset hook kept
  billing at that rate;
- nothing in query or login history told you whether a person or a job ran a query.

## Not covered

- No network policy: GitHub-hosted runners don't have stable IP addresses.
- No masking or row-access policies: there is no sensitive data.
- Key rotation is manual (see [docs/RUNBOOK.md](../docs/RUNBOOK.md)).
