# CI/CD

Three workflows in `.github/workflows`:

| Workflow | Runs on | Does |
|---|---|---|
| `ci.yml` | every pull request, every push to `main` | static checks; on pull requests also a dbt build on Snowflake |
| `ci-cleanup.yml` | a pull request closing (merged or not) | drops that pull request's CI schemas |
| `dbt-daily.yml` | 07:00 UTC daily, every merge that touches the pipeline, manual | production: load, freshness, build, docs |

## Environments

| | dev | ci | prod |
|---|---|---|---|
| Who | a person, locally | `ci.yml` | `dbt-daily.yml` |
| Snowflake user | your own (browser login) | `svc_dbt_ci` (key pair) | `svc_dbt_prod` (key pair) |
| Role | `developer` | `transformer_ci` | `transformer_prod` |
| Warehouse | `dev_wh` | `dev_wh` | `transform_wh` |
| Builds into | `ANALYTICS_DEV.DEV_<USER>_*` | `ANALYTICS_DEV.CI_PR_<N>_*` | `ANALYTICS.STAGING / INTERMEDIATE / MARTS / SEEDS` |
| Can write production | no | no | yes |

Schema names come from `macros/generate_schema_name.sql`: in prod a model's folder schema is used
as-is (`MARTS`); anywhere else it is prefixed with the target schema (`CI_PR_12_MARTS`).

## A pull request, step by step

1. **Static checks** (no Snowflake access, so they also run for forks):
   `sqlfluff lint` over every model, test and analysis; `pytest` for the loader and
   `load_trades.py --dry-run` over the real trade files; `docker build`; and `dbt parse
   --warn-error`, which renders every model, macro and config and fails on any warning.
2. **Fetch the production manifest.** The daily workflow uploads `manifest.json` after every
   successful production build as the `prod-manifest` artifact. CI downloads the newest one with
   the `gh` CLI. If there is none yet, CI builds the whole project instead.
3. **Clone changed incremental models** (`dbt clone --select "state:modified+,config.materialized:incremental"`).
   Without this, a changed incremental model would be built from scratch in the empty CI schema,
   and its incremental branch, the part most likely to be wrong, would never run in CI.
4. **Build** (`dbt build --select state:modified+ --defer --state prod-state`).
   `state:modified+` is every model whose code or config differs from production, plus
   everything downstream of it. `--defer` makes `ref()` to an unselected, unchanged parent point
   at the production table instead of a CI table that doesn't exist. Tests and unit tests of
   the selected models run in the same command.
5. **Summary and artifacts.** The job summary lists every test that warned or failed; the run
   results are uploaded.
6. **Cleanup.** When the pull request closes, `ci-cleanup.yml` runs
   `dbt run-operation drop_ci_schemas` for `CI_PR_<N>`. The macro refuses to run outside the
   `ci` target or for a prefix that doesn't start with `CI_PR_`.

Why parsing alone isn't enough: `dbt parse` proves the Jinja renders and the graph is valid. It
can't find a misspelt column, a join that duplicates rows, a type error, a failing test or a
privilege problem. Those only show up when Snowflake runs the SQL.

## A production run, step by step

1. **Load trade files** as `svc_loader` (idempotent; see `ingestion/load_trades.py`).
2. **`dbt source freshness`**: fails the run, before anything is rebuilt, if the market data has
   stopped updating or the loader hasn't succeeded recently.
3. **Measure restatements** (observe only, never fails the run): logs how far back the market data
   changed since the last run. This must run before the build overwrites the evidence.
4. **`dbt build --target prod`**: models and data tests in dependency order. A failing blocking
   test skips everything downstream of it. Unit tests check code, so they run in CI, not here.
5. **Job summary, manifest and run results** are uploaded; the manifest becomes CI's comparison
   point.
6. **dbt docs** are generated and deployed to GitHub Pages.

A failed run turns the workflow red, and GitHub emails the repository owner.
`concurrency: dbt-prod` stops two production runs from overlapping.

## Setting it up

1. Run `snowflake/01`–`05` (see [snowflake/README.md](../snowflake/README.md)).
2. Add repository secrets (**Settings → Secrets and variables → Actions**):

   | Secret | Value |
   |---|---|
   | `SNOWFLAKE_ACCOUNT` | account identifier, e.g. `myorg-myaccount` |
   | `SNOWFLAKE_LOADER_PRIVATE_KEY` | full contents of `svc_loader.p8` |
   | `SNOWFLAKE_DBT_PROD_PRIVATE_KEY` | full contents of `svc_dbt_prod.p8` |
   | `SNOWFLAKE_DBT_CI_PRIVATE_KEY` | full contents of `svc_dbt_ci.p8` |

3. **Settings → Pages → Source: GitHub Actions** for the docs site.
4. Run **dbt daily build** once by hand (**Actions → dbt daily build → Run workflow**). This
   creates the production tables and the first `prod-manifest` for CI.
5. Protect `main` (**Settings → Branches → Add branch ruleset**): require a pull request, and
   require the status checks **static checks** and **dbt build on Snowflake** to pass. A check
   appears in that list only after it has run once.

## Not covered

- Pull requests from forks get only the static checks (GitHub doesn't give them secrets).
- CI can't test loader changes against Snowflake: it has no write access to RAW, by design.
  Loader logic is covered by `pytest` with a fake connection.
- There is no automatic rollback; see [RUNBOOK.md](RUNBOOK.md).
