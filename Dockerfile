# dbt Core + Snowflake runner image, used by every GitHub Actions workflow.
# Credentials are NOT baked in: pass SNOWFLAKE_ACCOUNT and SNOWFLAKE_PRIVATE_KEY at runtime, and pick
# the environment explicitly with --target ci or --target prod.
FROM python:3.14-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DBT_PROFILES_DIR=/app/trading_pnl

WORKDIR /app
# requirements.txt is the full lock (every transitive package pinned), compiled from requirements.in.
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY trading_pnl/ trading_pnl/
WORKDIR /app/trading_pnl
RUN dbt deps

# Run as an unprivileged user; dbt writes target/ and logs/ into the project dir.
RUN useradd --create-home dbt && chown -R dbt:dbt /app
USER dbt

ENTRYPOINT ["dbt"]
# A bare `docker run trading-pnl` only prints the version: every real run names its command and target.
CMD ["--version"]
