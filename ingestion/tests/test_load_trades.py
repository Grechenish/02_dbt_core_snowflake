"""Tests for load_trades.py that run without Snowflake.

A fake connection stands in for Snowflake: it records every statement and answers PUT and COPY
the way Snowflake does, including remembering which files it has already loaded. That is enough
to check the loader's own logic (file checks, SQL, result parsing, run recording, re-runs).
Whether Snowflake itself behaves as assumed is only checked by running against a real account.
"""

import csv
import uuid
from pathlib import Path

import pytest

import load_trades

REPO_DATA_DIR = Path(__file__).resolve().parents[2] / "data" / "trades"


class FakeCursor:
    def __init__(self, snowflake):
        self.snowflake = snowflake
        self.description = None
        self._rows = []

    def execute(self, sql, params=None):
        self.snowflake.statements.append((sql, params))
        statement = sql.strip().lower()
        if statement.startswith("put"):
            name = Path(statement.split("'")[1].removeprefix("file://")).name
            status = "SKIPPED" if name in self.snowflake.staged else "UPLOADED"
            self.snowflake.staged.add(name)
            self._result(["source", "target", "status"], [(name, name + ".gz", status)])
        elif statement.startswith("copy into"):
            if self.snowflake.copy_error:
                raise RuntimeError(self.snowflake.copy_error)
            new = sorted(self.snowflake.staged - self.snowflake.loaded)
            self.snowflake.loaded |= set(new)
            if not new:
                self._result(["status"], [("Copy executed with 0 files processed.",)])
            else:
                self._result(
                    ["file", "status", "rows_parsed", "rows_loaded", "errors_seen", "first_error"],
                    [(f"trade_files/{name}.gz", "LOADED", 2, 2, 0, None) for name in new],
                )
        else:
            self._result([], [])

    def _result(self, columns, rows):
        self.description = [(column.upper(),) for column in columns]
        self._rows = rows

    def fetchall(self):
        return self._rows

    def close(self):
        pass


class FakeSnowflake:
    def __init__(self, copy_error=None):
        self.statements = []
        self.staged = set()
        self.loaded = set()
        self.copy_error = copy_error

    def cursor(self):
        return FakeCursor(self)

    def recorded_runs(self):
        return [params for sql, params in self.statements if "insert into raw.trades.load_runs" in sql]


def write_trade_file(directory: Path, name: str, header=None) -> Path:
    path = directory / name
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(header or load_trades.EXPECTED_HEADER)
        writer.writerow(["T-1", "1", "NEW", "Book1", "A", "AAPL", "BUY", "10", "100", "GBP", "2025-01-15", "2025-01-15T10:00:00Z"])
    return path


def test_repository_trade_files_all_pass_the_header_check():
    files = load_trades.discover_files(REPO_DATA_DIR)
    assert files, "no trade files found"
    for path in files:
        load_trades.check_header(path)


def test_discovery_only_picks_trade_files_in_date_order(tmp_path):
    write_trade_file(tmp_path, "trades_2025-02-01.csv")
    write_trade_file(tmp_path, "trades_2025-01-01.csv")
    (tmp_path / "README.md").write_text("not a trade file")
    assert [p.name for p in load_trades.discover_files(tmp_path)] == ["trades_2025-01-01.csv", "trades_2025-02-01.csv"]


def test_header_with_reordered_columns_is_refused(tmp_path):
    header = list(load_trades.EXPECTED_HEADER)
    header[7], header[8] = header[8], header[7]  # price before quantity would load prices as quantities
    path = write_trade_file(tmp_path, "trades_2025-01-01.csv", header=header)
    with pytest.raises(load_trades.FileCheckError):
        load_trades.check_header(path)


def test_copy_sql_captures_load_metadata_and_aborts_on_error():
    run_id = str(uuid.uuid4())
    sql = load_trades.build_copy_sql(run_id)
    for expected in ("metadata$filename", "metadata$file_row_number", "metadata$file_last_modified",
                     f"'{run_id}'", "on_error = abort_statement", "$12"):
        assert expected in sql
    assert "$13" not in sql


def test_copy_sql_rejects_anything_but_a_uuid_run_id():
    with pytest.raises(ValueError):
        load_trades.build_copy_sql("x'; drop table raw.trades.trades; --")


def test_first_run_loads_every_file_and_records_the_run(tmp_path):
    files = [write_trade_file(tmp_path, f"trades_2025-01-0{day}.csv") for day in (1, 2)]
    snowflake = FakeSnowflake()

    result = load_trades.load(snowflake, files)

    assert (result.status, result.files_uploaded, result.files_loaded, result.rows_loaded) == ("SUCCEEDED", 2, 2, 4)
    [run] = snowflake.recorded_runs()
    assert run[0] == result.run_id and run[2] == "SUCCEEDED"


def test_rerun_with_no_new_files_loads_nothing(tmp_path):
    files = [write_trade_file(tmp_path, "trades_2025-01-01.csv")]
    snowflake = FakeSnowflake()
    load_trades.load(snowflake, files)

    second = load_trades.load(snowflake, files)

    assert (second.files_uploaded, second.files_loaded, second.rows_loaded) == (0, 0, 0)
    assert second.copy_results == []
    assert len(snowflake.recorded_runs()) == 2  # the empty run is still recorded


def test_resent_file_under_a_new_name_is_loaded_again(tmp_path):
    # COPY's load history is per file, so a byte-identical resend with a new name loads again.
    # This is why dbt staging deduplicates on (trade_id, version).
    original = write_trade_file(tmp_path, "trades_2025-01-01.csv")
    snowflake = FakeSnowflake()
    load_trades.load(snowflake, [original])

    resend = tmp_path / "trades_2025-01-01_resend.csv"
    resend.write_bytes(original.read_bytes())
    result = load_trades.load(snowflake, [original, resend])

    assert result.files_loaded == 1


def test_failed_copy_is_recorded_and_raised(tmp_path):
    files = [write_trade_file(tmp_path, "trades_2025-01-01.csv")]
    snowflake = FakeSnowflake(copy_error="Number of columns in file (11) does not match")

    with pytest.raises(RuntimeError):
        load_trades.load(snowflake, files)

    [run] = snowflake.recorded_runs()
    assert run[2] == "FAILED" and "does not match" in run[7]


def test_dry_run_checks_files_without_connecting(tmp_path, monkeypatch):
    write_trade_file(tmp_path, "trades_2025-01-01.csv")
    monkeypatch.setattr(load_trades, "connect", lambda: pytest.fail("dry run must not connect"))
    assert load_trades.main(["--dry-run", "--data-dir", str(tmp_path)]) == 0


def test_bad_header_stops_the_run_before_connecting(tmp_path, monkeypatch):
    write_trade_file(tmp_path, "trades_2025-01-01.csv", header=["trade_id", "qty"])
    monkeypatch.setattr(load_trades, "connect", lambda: pytest.fail("must not connect"))
    assert load_trades.main(["--data-dir", str(tmp_path)]) == 1
