---
name: fireplace-api
description: |
  Reference for reading live Fireplace prediction-market data through the
  Fireplace MCP read tools. Maps the questions a user actually asks — "what's
  this market trading at?", "show me the orderbook", "who's holding this?",
  "what does smart money think?", "where do I stand?" — to the exact MCP tool
  and the exact parameters that tool needs. These are the 41 read-only tools
  that are always available; they never move funds. Use this skill to pick the
  right tool and avoid the common ID-type mistakes (numeric marketId vs
  condition-id string vs 0x trader address).
version: 0.1.0
platforms:
  - linux
  - darwin
metadata:
  hermes:
    category: markets
    tags:
      - fireplace
      - markets
      - data
      - orderbook
      - read-only
    related_skills:
      - fireplace-trading
      - fireplace-portfolio
      - fireplace-risk
---

# Fireplace API — reading live market data

## When to use

Use this skill whenever the user asks a question that can be answered by
*reading* Fireplace data: prices, orderbooks, candles, market/event metadata,
trader or wallet activity, smart-money flows, news, the leaderboard, or the
user's own account state. These tools are read-only and always enabled (the
default Fireplace profile is read-only by construction). For anything that
*places, edits, or cancels* an order, or that *redeems/merges/splits* a
position, stop and hand off to **fireplace-trading** — those are gated
execution tools and are off unless trading is explicitly enabled.

## ID types — get this right first

Fireplace uses three different identifiers and mixing them up is the #1 source
of failed calls:

- **Numeric `marketId`** — an integer id. Required by `get_market_orderbook`,
  `get_market_overview`, `get_market_top_positions`, the candle tools, etc.
- **Condition-id `marketId` (string)** — the long on-chain condition id string.
  This is what the *execution* tools (`place_limit_order` et al.) want. Do not
  pass a condition id where a numeric id is expected.
- **`trader_address` (0x… ETH address)** — required by every `get_trader_*`
  and wallet tool when inspecting *someone else's* book. The logged-in user's
  own reads (`my_*`) take **no** address.

When you only have a name or topic, resolve to an id first with
`search_markets` / `search_events` (or `search_wallets` for a person).

## Procedure — question → tool

**Find a market or event**
- Free-text search: `search_markets` (markets), `search_events` (events).
- Resolve a known event: `get_event_by_id` (eventId).
- Resolve a known market: `get_market_by_id` (numeric marketId).

**Price / quote / depth**
- Snapshot summary (volume, open interest, holders): `get_market_overview`
  (marketId required — NOT param-free).
- Live orderbook (bids/asks, price+size, every outcome): `get_market_orderbook`
  (numeric marketId). ALWAYS call this before quoting a tradeable price or
  before proposing any order — see **fireplace-trading** and **fireplace-risk**.
- Point-in-time book history: `get_market_orderbook_snapshots`.

**Candles / history**
- Historical OHLC: `get_market_historical_candles`.
- Most recent candles: `get_market_latest_candles`.
- Recent prints/tape: `get_market_recent_trades`.

**Concentration / who holds it**
- `get_market_top_positions` (market_id required; optional `amount`=100|1k|10k,
  `outcome`, `limit`, `offset`).
- `get_market_open_interest` (marketId) and `get_event_open_interest` (eventId).

**Any specific trader / wallet (needs 0x address)**
- Profile + PnL summary: `get_trader_overview`.
- Positions: `get_trader_positions` (trader_address required; optional
  `isActive`, `marketId`, `limit` default 50, `offset`, `sortBy`, `sortType`).
- Unredeemed (settled-but-unclaimed): `get_trader_unredeemed_positions`.
- Recent trades / full activity: `get_trader_recent_trades`,
  `get_trader_activity`.
- PnL curve: `get_trader_historical_pnl`.
- Raw wallet flows: `get_wallet_trades`, `get_wallet_market_trades`,
  `get_wallet_net_flows`.

**Smart money**
- Top wallets: `get_smart_money_wallets`.
- What they're doing now: `get_smart_money_trades`.

**The logged-in user's own account (param-free, no address)**
- `my_overview` — PnL, volume, win rate, active-position count.
- `my_positions` — current holdings; all optional: `isActive` ("true" open is
  the default / "false" settled), `marketId`, `limit` (1-1000), `offset`,
  `sortBy` (bought_value|sold_value|avg_entry_price|current_holdings|
  current_price|pnl|last_updated), `sortType` (asc|desc).
- `my_recent_trades` — the user's own tape.
- `my_followed_wallets`, `followed_wallets_recent_trades`,
  `followed_wallets_net_flows` — the user's copy/follow lens.
- Deep portfolio summarisation lives in **fireplace-portfolio**.

**Orders the user has working**
- `get_open_orders` (param-free) — all live limit/stop/pending-exit orders with
  market metadata.
- `get_order_status` (orderId) — single CLOB order state.
- `get_order_fills`, `get_order_audit` — fill and audit history for an order.
- `get_recent_trades_order_view` — recent trades in order-centric form.

**News / context**
- `get_news`, `get_news_events`, `get_news_event_stories`, `get_news_cluster`.
- `get_dispute_stats` — resolution/dispute health.

**Leaderboard**
- `get_leaderboard_categories` (param-free — also the canonical health check
  used by `fireplace doctor`).
- `get_leaderboard_user` — a user's standing.

## Pitfalls

- **Wrong ID type.** Numeric `marketId` for reads vs condition-id string for
  execution vs `0x` `trader_address` for trader reads. Resolve via search first.
- **`get_market_overview` is not param-free** — it needs a marketId. The only
  truly param-free reads are `get_leaderboard_categories`, `my_overview`,
  `get_open_orders`, `my_positions`.
- **Don't quote a price from `get_market_overview` alone.** Last/summary price
  ≠ a fillable price. Pull `get_market_orderbook` for real bid/ask + depth.
- **`my_*` vs `get_trader_*`.** Use `my_*` for the logged-in user (no address);
  only use `get_trader_*` when you have an explicit 0x address.
- **Read tools never trade.** They cannot place or cancel anything. If the user
  wants to act, route to **fireplace-trading** (and trading must be enabled).
- **Default `isActive`** on positions is open-only; pass `"false"` to see
  settled history.
