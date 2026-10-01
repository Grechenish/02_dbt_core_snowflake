{#- Shared column descriptions, referenced from the YAML files with {{ doc('col_...') }}
    so that a column means the same thing in every model it appears in. -#}

{% docs col_ticker %}
Security ticker symbol, e.g. `AAPL`.
{% enddocs %}

{% docs col_price_trade_date %}
Trading day of the price record.
{% enddocs %}

{% docs col_asset_class %}
Security type as reported by the source, e.g. `Equity`, `ETF-Index Fund Shares` or `Closed-End Funds`.
{% enddocs %}

{% docs col_primary_exchange_name %}
Exchange where the security has its primary listing, e.g. `NEW YORK STOCK EXCHANGE` or `NYSE ARCA`. Prices and volumes are from Nasdaq trading regardless of the listing exchange.
{% enddocs %}

{% docs col_open_price %}
Pre-market open price in USD (source variable `pre-market_open`).
{% enddocs %}

{% docs col_high_price %}
All-day high price in USD (source variable `all-day_high`).
{% enddocs %}

{% docs col_low_price %}
All-day low price in USD (source variable `all-day_low`).
{% enddocs %}

{% docs col_volume %}
Number of shares traded on Nasdaq that day (source variable `nasdaq_volume`).
{% enddocs %}

{% docs col_trade_id %}
Identifier the order-management system gives a trade. Stays the same across all its versions.
{% enddocs %}

{% docs col_book %}
Trading book (desk) that owns the position, e.g. `Book1`. Each book reports in a single currency.
{% enddocs %}

{% docs col_trader %}
Trader who booked the trades.
{% enddocs %}

{% docs col_instrument %}
Ticker of the traded stock. It must exist in the stock price history.
{% enddocs %}

{% docs col_currency %}
Book currency (`GBP`, `EUR` or `USD`). Cash, prices, values and PnL are expressed in it.
{% enddocs %}

{% docs col_position_date %}
Trading day the row describes. Days come from the instrument's price history, so weekends and market holidays have no rows.
{% enddocs %}

{% docs col_action %}
What happened to the position that day: `BUY` or `SELL` by the sign of the net traded quantity, `MIXED` when same-day buys and sells cancel out, and `HOLD` when there was no trade.
{% enddocs %}

{% docs col_traded_quantity %}
Net signed shares traded that day: positive when buying, negative when selling, 0 on `HOLD` days.
{% enddocs %}

{% docs col_daily_cash_flow %}
Net cash moved by that day's trades, in the book currency: negative when cash is paid out (buying), positive when it comes in (selling), 0 on `HOLD` days.
{% enddocs %}

{% docs col_shares_held %}
End-of-day number of shares held: the running total of `traded_quantity`. Never negative, because short positions aren't allowed.
{% enddocs %}

{% docs col_close_price_usd %}
Day's close price in USD (source variable `post-market_close`).
{% enddocs %}

{% docs col_usd_fx_rate %}
USD to book-currency rate used for the day: the latest rate published on or before the day. Always 1 for USD books.
{% enddocs %}

{% docs col_close_price_book %}
Day's close price in the book currency: `close_price_usd × usd_fx_rate`, rounded to 4 decimals.
{% enddocs %}

{% docs col_market_value %}
Value of the shares held at the day's close, in the book currency, rounded to 2 decimals.
{% enddocs %}

{% docs col_cumulative_cash %}
Running total of the position's cash flows since its first trade, in the book currency. Negative while more cash has been spent than received.
{% enddocs %}

{% docs col_pnl %}
Profit and loss to date in the book currency: `market_value + cumulative_cash`, rounded to 2 decimals. Once a position is fully sold, it equals the realized result.
{% enddocs %}
