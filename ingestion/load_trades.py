"""Load trade CSV files into Snowflake: RAW.TRADES.TRADES.

    python ingestion/load_trades.py              # load every new file in data/trades
    python ingestion/load_trades.py --dry-run    # only check the files; no Snowflake connection

Each run:
  1. finds data/trades/trades_*.csv and checks every file has the expected header, and every row
     the same number of fields;
  2. PUTs them into the internal stage RAW.TRADES.TRADE_FILES (a file already there is skipped);
  3. runs one COPY INTO that loads every staged file Snowflake hasn't loaded before, adding the
     source file name, row number, file timestamp and this run's id to every row;
  4. records the run, including COPY's per-file result, in RAW.TRADES.LOAD_RUNS, whether it
     succeeded or failed.

Re-running is safe. PUT skips files already on the stage, and COPY INTO skips files it has
already loaded (Snowflake keeps that load history for 64 days, and by default also skips older
files whose history has expired). A file resent under a new name *is* loaded again; dbt
staging then keeps one row per (trade_id, version), so the replay is never counted twice.

Connection settings come from the environment:
  SNOWFLAKE_ACCOUNT       account identifier, e.g. myorg-myaccount
  SNOWFLAKE_PRIVATE_KEY   PEM private key of the service user (key-pair authentication)
  SNOWFLAKE_USER          optional, defaults to svc_loader
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "trades"
FILE_GLOB = "trades_*.csv"

EXPECTED_HEADER = [
    "trade_id", "version", "status", "book", "trader", "instrument",
    "side", "quantity", "price", "currency", "trade_date", "booked_at",
]

STAGE = "raw.trades.trade_files"
RAW_TABLE = "raw.trades.trades"
LOAD_RUNS_TABLE = "raw.trades.load_runs"

# COPY reads the CSV columns positionally ($1..$12), so check_file is what guarantees they line up
# with these column names. Snowflake ignores the file format's ERROR_ON_COLUMN_COUNT_MISMATCH when
# COPY loads from a query like this one, so a row with a stray comma would load shifted columns.
COPY_SQL = """
copy into {table} (
    {columns},
    _source_file, _source_row_number, _source_file_modified_at, _load_run_id, _loaded_at
)
from (
    select
        {positions},
        metadata$filename,
        metadata$file_row_number,
        metadata$file_last_modified,
        '{run_id}',
        current_timestamp()
    from @{stage}
)
pattern = '.*trades_.*[.]csv[.]gz'
on_error = abort_statement
"""

INSERT_RUN_SQL = f"""
insert into {LOAD_RUNS_TABLE} (
    run_id, started_at, finished_at, status, files_found, files_uploaded,
    files_loaded, rows_loaded, error_message, copy_results
)
select %s, %s::timestamp_ltz, current_timestamp(), %s, %s, %s, %s, %s, %s, parse_json(%s)
"""


class FileCheckError(Exception):
    """A trade file doesn't match the expected layout."""


@dataclass
class LoadResult:
    run_id: str
    started_at: str
    files_found: int = 0
    files_uploaded: int = 0
    files_loaded: int = 0
    rows_loaded: int = 0
    copy_results: list[dict] = field(default_factory=list)
    status: str = "SUCCEEDED"
    error_message: str | None = None


def discover_files(data_dir: Path) -> list[Path]:
    """Trade files to load, oldest first (file names start with the business date)."""
    return sorted(data_dir.glob(FILE_GLOB))


def check_file(path: Path) -> None:
    """Refuse a file whose columns aren't exactly the expected ones, in order, or with a row that
    has a different number of fields.

    COPY maps columns by position, so a reordered or renamed column, or a row with an unquoted
    comma or a missing field, would otherwise load silently into the wrong place. RAW is
    append-only for the loader, so a bad row is far easier to stop here than to remove later.
    """
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle)
        header = next(reader, None)
        if header is None:
            raise FileCheckError(f"{path.name}: file is empty")
        header = [column.strip().lower() for column in header]
        if header != EXPECTED_HEADER:
            raise FileCheckError(
                f"{path.name}: expected columns {EXPECTED_HEADER}, found {header}"
            )
        for row in reader:
            if len(row) != len(EXPECTED_HEADER):
                raise FileCheckError(
                    f"{path.name}: line {reader.line_num} has {len(row)} fields, "
                    f"expected {len(EXPECTED_HEADER)}"
                )


def build_copy_sql(run_id: str) -> str:
    # run_id is interpolated, not bound (COPY transformations don't take bind variables), so only
    # accept a real UUID.
    run_id = str(uuid.UUID(run_id))
    return COPY_SQL.format(
        table=RAW_TABLE,
        columns=", ".join(EXPECTED_HEADER),
        positions=", ".join(f"${i}" for i in range(1, len(EXPECTED_HEADER) + 1)),
        run_id=run_id,
        stage=STAGE,
    )


def put_sql(path: Path) -> str:
    # OVERWRITE = FALSE: a file name already on the stage is never replaced, so files stay immutable.
    return f"put 'file://{path.resolve().as_posix()}' @{STAGE} auto_compress = true overwrite = false"


def rows_as_dicts(cursor) -> list[dict]:
    names = [column[0].lower() for column in cursor.description or []]
    return [dict(zip(names, row)) for row in cursor.fetchall()]


def parse_copy_results(rows: list[dict]) -> tuple[int, int, list[dict]]:
    """(files loaded, rows loaded, per-file results) from COPY INTO's result set.

    When nothing new is staged, COPY returns a single row with only a status message
    ("Copy executed with 0 files processed."), which counts as zero files.
    """
    per_file = [row for row in rows if "file" in row]
    loaded = [row for row in per_file if str(row.get("status", "")).upper() in ("LOADED", "PARTIALLY_LOADED")]
    rows_loaded = sum(int(row.get("rows_loaded") or 0) for row in loaded)
    return len(loaded), rows_loaded, per_file


def load(connection, files: list[Path], run_id: str | None = None) -> LoadResult:
    """PUT and COPY the given files, then record the run. Raises if the load failed."""
    result = LoadResult(
        run_id=run_id or str(uuid.uuid4()),
        started_at=datetime.now(timezone.utc).isoformat(),
        files_found=len(files),
    )
    cursor = connection.cursor()
    try:
        for path in files:
            cursor.execute(put_sql(path))
            put_rows = rows_as_dicts(cursor)
            result.files_uploaded += sum(1 for row in put_rows if str(row.get("status", "")).upper() == "UPLOADED")

        cursor.execute(build_copy_sql(result.run_id))
        result.files_loaded, result.rows_loaded, result.copy_results = parse_copy_results(rows_as_dicts(cursor))
    except Exception as error:  # recorded in LOAD_RUNS, then re-raised
        result.status = "FAILED"
        result.error_message = str(error)[:4000]
        raise
    finally:
        try:
            record_run(cursor, result)
        except Exception as record_error:
            # Never hide the load's own error behind a failure to record it.
            print(f"Could not record run {result.run_id} in {LOAD_RUNS_TABLE}: {record_error}", file=sys.stderr)
            if result.status == "SUCCEEDED":
                raise
        finally:
            cursor.close()
    return result


def record_run(cursor, result: LoadResult) -> None:
    cursor.execute(
        INSERT_RUN_SQL,
        (
            result.run_id,
            result.started_at,
            result.status,
            result.files_found,
            result.files_uploaded,
            result.files_loaded,
            result.rows_loaded,
            result.error_message,
            json.dumps(result.copy_results, default=str),
        ),
    )


def private_key_der(text: str) -> bytes:
    """DER bytes of an unencrypted private key given as text, however the secret was pasted.

    Accepts the full .p8 file, the same flattened onto one line (newlines lost or written as a
    literal backslash-n), or only the base64 body without the BEGIN/END lines. dbt-snowflake
    accepts the same secret, so one value works for both.
    """
    import base64
    import binascii
    import re

    from cryptography.hazmat.primitives import serialization

    text = text.strip().replace("\\n", "\n")
    if "PUBLIC KEY-----" in text:
        raise ValueError("SNOWFLAKE_PRIVATE_KEY holds a public key; use the contents of the .p8 file")
    if "ENCRYPTED" in text:
        raise ValueError("SNOWFLAKE_PRIVATE_KEY is encrypted; generate the key with -nocrypt")
    match = re.fullmatch(r"-----BEGIN ([A-Z ]+)-----(.*)-----END \1-----", text, flags=re.DOTALL)
    body = match.group(2) if match else text
    try:
        der = base64.b64decode("".join(body.split()), validate=True)
        key = serialization.load_der_private_key(der, password=None)
    except (binascii.Error, ValueError) as error:
        raise ValueError(
            "SNOWFLAKE_PRIVATE_KEY is not a readable private key; paste the full contents of the .p8 file"
        ) from error
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def connect():
    import snowflake.connector

    private_key = private_key_der(os.environ["SNOWFLAKE_PRIVATE_KEY"])
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ.get("SNOWFLAKE_USER", "svc_loader"),
        private_key=private_key,
        role="loader",
        warehouse="load_wh",
        database="raw",
        schema="trades",
        session_parameters={"QUERY_TAG": "trading_pnl.load_trades"},
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    parser.add_argument("--dry-run", action="store_true", help="check the files without connecting to Snowflake")
    args = parser.parse_args(argv)

    files = discover_files(args.data_dir)
    try:
        for path in files:
            check_file(path)
    except FileCheckError as error:
        print(f"Refusing to load: {error}", file=sys.stderr)
        return 1
    print(f"{len(files)} trade files found in {args.data_dir}, all with the expected columns.")

    if args.dry_run:
        for path in files:
            print(f"  would stage {path.name}")
        return 0

    connection = connect()
    try:
        result = load(connection, files)
    except Exception as error:
        print(f"Load failed (recorded in {LOAD_RUNS_TABLE}): {error}", file=sys.stderr)
        return 1
    finally:
        connection.close()

    print(
        f"Run {result.run_id}: {result.files_uploaded} files uploaded to the stage, "
        f"{result.files_loaded} files / {result.rows_loaded} rows loaded into {RAW_TABLE}."
    )
    for row in result.copy_results:
        print(f"  {row.get('file')}: {row.get('status')} ({row.get('rows_loaded')} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
