# dbt Core + Snowflake runner image.
# Credentials are NOT baked in: pass SNOWFLAKE_ACCOUNT / SNOWFLAKE_USER / SNOWFLAKE_PASSWORD at runtime
# (e.g. `docker run --env-file .env trading-pnl`, which builds the dev target).
# Production only runs when `--target prod` is passed explicitly, as the scheduled workflow does.
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
# Safe default: a bare `docker run trading-pnl` builds dev, never production.
CMD ["build", "--target", "dev"]
