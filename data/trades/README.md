# Trade files

Synthetic trade files standing in for the daily export of an order-management system. In a real
setup they would land in cloud storage; here the repository is the landing folder, and
`ingestion/load_trades.py` loads them into `RAW.TRADES.TRADES`.

Every row is one **version** of a trade. A trade starts as `NEW` (version 1); a correction arrives
as a later version with status `AMEND`, and a cancellation as a later version with status `CANCEL`.
Files are immutable: a correction is a new file, never an edit of an old one.

The files deliberately include the cases the pipeline must handle:

| Case | Files | What should happen |
|---|---|---|
| Normal trades | most files | One live trade each |
| Amendment | `T-1005` booked as 2,000 shares on 2025-06-02, amended to 200 in `trades_2025-06-03.csv` | Only version 2 (200 shares) counts |
| Cancellation | `T-1008` booked in `trades_2025-09-15.csv`, cancelled in `trades_2025-09-16.csv` | The trade disappears from positions and PnL |
| Back-dated trade | `T-1011` in `trades_2025-11-03.csv` has trade date 2025-10-20 | Positions and PnL from 2025-10-20 onwards include it |
| Replayed file | `trades_2025-03-10_resend.csv` is a byte-for-byte resend of `trades_2025-03-10.csv` under a new name | Loaded into RAW (new file name), but counted once |

Prices are in the book's currency and are illustrative, not real execution prices.
