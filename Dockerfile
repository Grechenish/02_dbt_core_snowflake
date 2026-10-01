# dbt Core + Snowflake runner image.
# Credentials are NOT baked in: pass SNOWFLAKE_ACCOUNT / SNOWFLAKE_USER / SNOWFLAKE_PASSWORD at runtime
# (e.g. `docker run --env-file .env dbt-hol`).
FROM python:3.14-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DBT_PROFILES_DIR=/app/dbt_hol

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY dbt_hol/ dbt_hol/
WORKDIR /app/dbt_hol
RUN dbt deps

# Run as an unprivileged user; dbt writes target/ and logs/ into the project dir.
RUN useradd --create-home dbt && chown -R dbt:dbt /app
USER dbt

ENTRYPOINT ["dbt"]
CMD ["build", "--target", "prod"]
