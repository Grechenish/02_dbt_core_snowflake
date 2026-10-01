# Developer Onboarding Guide: dbt_hol

This guide gets you from a fresh clone to a working pipeline run, then covers the commands you'll use day to day.

| If you want to… | Read |
|---|---|
| Understand how the system fits together | [SYSTEM_OVERVIEW.md](SYSTEM_OVERVIEW.md) |
| Look up a specific model, its logic or its tests | [MODELS_DICTIONARY.md](MODELS_DICTIONARY.md) |
| Check runtimes, warehouse sizing or cost | [PERFORMANCE.md](PERFORMANCE.md) |

The project builds daily stock history (USD, EUR, GBP) and a trading PnL mart from the Snowflake Marketplace listing *Snowflake Public Data (Free)*. It uses dbt Core and runs daily in Docker on GitHub Actions.

---

## 1. Prerequisites

| You need | Notes |
|---|---|
| Snowflake access | The account must already have the `dbt_*` roles, warehouses and databases, and the Marketplace listing installed. On a new account, an `ACCOUNTADMIN` runs the bootstrap script in [SYSTEM_OVERVIEW.md §3.5](SYSTEM_OVERVIEW.md#35-bootstrap-script) once. |
| The `dbt_user` password | Ask the project owner. Never commit it or paste it into a chat. |
| Git | To clone the repository |
| Docker Desktop | For the container workflow in section 2 |
| Python 3.11 or newer | Only for the local workflow in section 5. The project runs on 3.14. |

---

## 2. Quick start with Docker

Run these from the repository root.

**1. Clone the repository:**

```bash
git clone git@github.com:Grechenish/02_dbt_core_snowflake.git
cd 02_dbt_core_snowflake
```

**2. Create your `.env` from the template and fill it in** (section 3 describes each variable):

```bash
cp .env.example .env
```

On Windows PowerShell, use `Copy-Item .env.example .env`.

**3. Build the image:**

```bash
docker build -t dbt-hol .
```

**4. Check the connection.** It should end with `All checks passed!`:

```bash
docker run --rm --env-file .env dbt-hol debug --target dev
```

**5. Build everything in dev:**

```bash
docker run --rm --env-file .env dbt-hol build --target dev
```

This builds the seeds, all 11 models and all 50 tests in `DBT_HOL_DEV`, in about 40 seconds. A successful run ends with:

```
Done. PASS=63 WARN=0 ERROR=0 SKIP=0 NO-OP=0 REUSED=0 TOTAL=63
```

> ⚠️ **Always pass `--target dev` when developing.** The image's default command is `dbt build --target prod`, which is what the scheduled job runs. Running `docker run ... dbt-hol` with no arguments rebuilds **production**.

Anything after the image name is passed to `dbt`, so any dbt command works the same way:

```bash
docker run --rm --env-file .env dbt-hol <dbt command> --target dev
```

After changing SQL or YAML, **rebuild the image (step 3)** before running again. The project is copied into the image at build time and isn't mounted.

---

## 3. Environment variables

The image contains no credentials. `dbt_hol/profiles.yml` reads these variables when dbt starts.

| Variable | Required | Example (placeholder) | Description |
|---|---|---|---|
| `SNOWFLAKE_ACCOUNT` | ✅ | `MYORG-MYACCOUNT` | Account identifier in the form `<orgname>-<account_name>`. Find it in Snowsight under your profile → Account → View account details, or run `SELECT CURRENT_ORGANIZATION_NAME() \|\| '-' \|\| CURRENT_ACCOUNT_NAME();`. **Not a URL:** no `https://`, `.snowflakecomputing.com` or slashes. |
| `SNOWFLAKE_USER` | — | `dbt_user` | Login user. Defaults to `dbt_user` if not set. |
| `SNOWFLAKE_PASSWORD` | ✅ | `<your-password>` | Password for that user. |
| `DBT_PROFILES_DIR` | Local only | `C:\path\to\repo\dbt_hol` | Tells a local dbt where `profiles.yml` is. Already set inside the Docker image. |

**`.env` rules:**

- Write one `KEY=value` per line, **without quotes**. Docker's `--env-file` keeps quote characters as part of the value.
- `.env` is git-ignored and excluded from the Docker build context (`.dockerignore`). Keep it that way.

Everything that isn't secret is fixed per target in `profiles.yml`:

| Target | Role | Warehouse | Database |
|---|---|---|---|
| `dev` (default) | `dbt_dev_role` | `dbt_dev_wh` | `dbt_hol_dev` |
| `prod` | `dbt_prod_role` | `dbt_prod_wh` | `dbt_hol_prod` |

The **scheduled job** reads the same three variables from GitHub repository secrets with the same names. Find them under Settings → Secrets and variables → Actions.

---

## 4. Running the pipeline

All examples use Docker. For a local virtual environment, drop the `docker run --rm --env-file .env dbt-hol` prefix and run `dbt ...` from `dbt_hol/` (see section 5).

### 4.1 The full pipeline in one command (recommended)

```bash
docker run --rm --env-file .env dbt-hol build --target dev
```

`dbt build` runs seeds, models and tests together, in dependency order. If a model's test fails, dbt skips everything that depends on that model, so bad data doesn't spread.

### 4.2 Step by step: seed, run, test

Use this order on a fresh database:

```bash
docker run --rm --env-file .env dbt-hol seed --target dev   # 1. load trade blotters into SEEDS
docker run --rm --env-file .env dbt-hol run  --target dev   # 2. build all 11 models
docker run --rm --env-file .env dbt-hol test --target dev   # 3. run all 50 data tests
```

| Step | What it does | What you should see |
|---|---|---|
| `seed` | Loads `seeds/manual_book1.csv` (7 trades) and `manual_book2.csv` (5 trades) | `PASS=2` |
| `run` | Builds staging views, intermediate tables, marts | `PASS=11` |
| `test` | Runs generic tests from the YAML files and the singular tests in `tests/` | `PASS=50` |

**Order matters on a fresh database.** `int_trading_book` uses `dbt_utils.union_relations`, which reads the seed tables' columns when it runs. If you run `run` before `seed` has ever succeeded, it can't find those columns. It then generates an empty column list, and Snowflake rejects it with a **confusing SQL compilation error** about the union, not a "seed missing" message. `build` handles the order for you.

Unlike `build`, `run` doesn't stop at a failed test. With `seed` → `run` → `test`, bad data can reach the marts before `test` reports it.

### 4.3 Source freshness

```bash
docker run --rm --env-file .env dbt-hol source freshness --target dev
```

This checks that the Marketplace feed is still updating. It warns at 100 days old and errors at 150. The free listing is normally about 90 days behind, so a `PASS` is expected.

### 4.4 Running part of the project

dbt's node selection works as usual:

```bash
# one model
docker run --rm --env-file .env dbt-hol build --target dev -s fct_trading_pnl
# a model and everything downstream of it
docker run --rm --env-file .env dbt-hol build --target dev -s int_trading_book+
# a whole layer
docker run --rm --env-file .env dbt-hol build --target dev -s models/marts
```

### 4.5 Browsing the docs and lineage graph

`docs generate` and `docs serve` must run in the same container, because the container's files are discarded when it exits:

```bash
docker run --rm -p 8080:8080 --env-file .env --entrypoint sh dbt-hol \
  -c "dbt docs generate --target dev && dbt docs serve --host 0.0.0.0 --port 8080 --no-browser"
```

Then open <http://localhost:8080>.

### 4.6 Production

Production runs automatically every day at 07:00 UTC via `.github/workflows/dbt-daily.yml`.

- **To run it now:** GitHub → **Actions** → **dbt daily build** → **Run workflow**.
- **What a run produces:** each run uploads `run_results.json` and `manifest.json` as the `dbt-run-results` artifact.
- **Manual prod commands:** avoid running prod by hand from your machine. If you must, it's the same commands with `--target prod`.

---

## 5. Local development without Docker

This is faster for quick iteration, because there's no image rebuild after each change.

```bash
python -m venv .venv
# Windows:  .venv\Scripts\Activate.ps1      macOS/Linux:  source .venv/bin/activate
pip install -r requirements.txt

cd dbt_hol
dbt deps                       # installs dbt_utils (once, and after packages.yml changes)
dbt debug --profiles-dir .     # or set DBT_PROFILES_DIR and drop --profiles-dir
dbt build --profiles-dir .     # target dev is the default locally
```

Set the variables from section 3 in your shell or as user environment variables.

On Windows, these PowerShell commands save them permanently. Restart your terminal and VS Code afterwards so they take effect.

```powershell
[Environment]::SetEnvironmentVariable("SNOWFLAKE_ACCOUNT", "<orgname>-<account_name>", "User")
[Environment]::SetEnvironmentVariable("SNOWFLAKE_USER", "dbt_user", "User")
$p = Read-Host "Snowflake password" -AsSecureString
[Environment]::SetEnvironmentVariable("SNOWFLAKE_PASSWORD", [System.Net.NetworkCredential]::new("", $p).Password, "User")
[Environment]::SetEnvironmentVariable("DBT_PROFILES_DIR", "<repo path>\dbt_hol", "User")
```

---

## 6. Common tasks

| Task | How |
|---|---|
| **Add or fix a trade** | Edit `dbt_hol/seeds/manual_book*.csv`, then run `dbt build`. The trade date must be a trading day (test `assert_trades_on_trading_days`), the ticker must exist in the price data, and the quantity must be positive. |
| **Correct a trade older than 7 days** | Do the above, then run `dbt build --full-refresh -s fct_trading_pnl` once. The incremental fact only reprocesses the last `pnl_lookback_days` days. |
| **Add a trading desk** | Add `seeds/manual_book3.csv` with the same columns, add it to the `relations` list in `int_trading_book.sql`, and add it to `seeds/_seeds.yml`. |
| **Add a reporting currency** | Add it to `report_currencies` in `dbt_project.yml`, then add a `not_null` test for `close_price_<ccy>` in `models/marts/_marts.yml`. |
| **Load more history** | Change `start_date` in `dbt_project.yml`, or for one run only use `--vars '{start_date: "2024-01-01"}'`. More history means more rows and cost; see [PERFORMANCE.md](PERFORMANCE.md). |
| **Find a model's queries in Snowflake** | Query History → filter on `QUERY_TAG = 'dbt_hol.<model_name>'`. |

---

## 7. Troubleshooting

These errors all came up while the project was being set up.

| Error | Cause | Fix |
|---|---|---|
| `251001: Invalid account identifier ... no slashes or backslashes` | `SNOWFLAKE_ACCOUNT` contains a URL | Use only `<orgname>-<account_name>` (section 3) |
| `390100: Incorrect username or password` | Wrong or outdated password | Check `.env` or the user environment variable. After a password change, update the GitHub secret too. |
| `390186: Role 'DBT_DEV_ROLE' ... is not granted to this user` | Roles weren't granted to `dbt_user`. The original quickstart script's `GRANT ROLE a, b TO USER` syntax fails. | Run the bootstrap script in SYSTEM_OVERVIEW §3.5, which grants one role per statement |
| `Database 'SNOWFLAKE_PUBLIC_DATA_FREE' does not exist or not authorized` | The dbt role lacks access to the Marketplace database | `GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE_PUBLIC_DATA_FREE TO ROLE dbt_dev_role;` (and the same for `dbt_prod_role`) |
| `Activate.ps1 cannot be loaded because running scripts is disabled` (Windows) | PowerShell execution policy | `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`, or call `.venv\Scripts\dbt.exe` directly |
| `dbt: command not found` / `"dbt" is not recognized` | The virtual environment isn't activated | Activate it (section 5), or use Docker |
| Test `assert_trades_on_trading_days` fails | A trade is dated on a weekend, a holiday, or a day with no price data | Fix the date in the seed CSV |
| Test on `shares_held >= 0` fails | A seed sells more shares than were bought | Fix the quantities in the seed |
| Freshness `WARN` or `ERROR` | The Marketplace feed has slowed down or stopped | Check the listing in Snowsight. Models still build on the data that's available. |
| `DBT_DEV_WH` / `DBT_PROD_WH` left at a larger size | `fct_trading_pnl` failed, so its post-hook didn't reset the size | Re-run successfully, or `ALTER WAREHOUSE dbt_dev_wh SET WAREHOUSE_SIZE = 'XSMALL';` |
| Scheduled runs fail after about 30 days | The Snowflake trial ended and the account is suspended | Add a payment method to the account |
