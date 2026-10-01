# trading_pnl (dbt project)

Staging, intermediate and marts models over the Snowflake Public Data (Free) market data and the
trade files loaded by `ingestion/load_trades.py`.

```
models/
  staging/        one model per source table: rename, cast, deduplicate. Views.
  intermediate/   pivots, positions, forward-filled prices and PnL logic. Tables (prices incremental).
  marts/core/     dim_date, dim_security, dim_book, fct_stock_history, fct_trading_pnl
  marts/finance/  finance_book_pnl_daily          (views over fct_trading_pnl)
  marts/risk/     risk_position_exposure_daily
  marts/treasury/ treasury_cash_balance_daily
  marts/monitoring/ monitoring_market_data_daily  (observability, no consumers but people)
tests/            singular tests: reconciliations, trade-history rules, warnings
macros/           schema naming per environment, query tags, CI schema cleanup, restatement check
analyses/         market_data_restatement_depth: evidence for the incremental lookback window
seeds/            books.csv (reference data only; trades are ingested, not seeded)
```

How to run it, what each model does and why: [root README](../README.md) and [docs/](../docs).
