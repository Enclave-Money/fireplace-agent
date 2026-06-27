---
name: fireplace-risk
description: |
  Risk management for Fireplace trading: position sizing rules, reading
  orderbook depth (spread, walls, bid/ask imbalance) via get_market_orderbook,
  judging concentration/exposure with get_market_open_interest /
  get_event_open_interest / get_market_top_positions, the concept and use of
  stop orders (place_stop_limit / place_stop_market), and the per-trade and
  portfolio risk limits the agent should ask the user for and then enforce on
  every proposed order. This skill defines the guardrails that fireplace-trading
  must respect before any order is proposed.
version: 0.1.0
platforms:
  - linux
  - darwin
metadata:
  hermes:
    category: risk
    tags:
      - fireplace
      - risk
      - sizing
      - liquidity
      - stops
    related_skills:
      - fireplace-trading
      - fireplace-portfolio
      - fireplace-api
---

# Fireplace Risk — sizing, liquidity, and limits

## When to use

Use this skill before and around any trade: to size a position, to judge whether
a market is liquid enough to trade, to measure how concentrated the user's (or a
market's) exposure is, and to set or reason about stop orders. **fireplace-
trading** must consult these rules before proposing any order;
**fireplace-portfolio** hands its exposure figures here to be judged against
limits; raw tool/param details live in **fireplace-api**.

## Risk limits to establish (ask the user, then enforce)

If the user hasn't set them, ask once and remember for the session:

- **Per-trade cap** — max USD (or % of bankroll) on a single order.
- **Per-market / per-event cap** — max aggregate exposure to one market or one
  correlated event.
- **Portfolio cap & cash buffer** — max total deployed; reserve kept uninvested.
- **Max spread / min depth to trade** — refuse or warn below these.
- **Stop discipline** — does the user want a protective stop on entries, and at
  what loss level.

Enforce these on every proposal. If an order would breach a limit, say so and
propose a compliant size instead of silently shrinking or ignoring it.

## Reading liquidity with the orderbook

ALWAYS pull `get_market_orderbook` (numeric marketId) before sizing or pricing.
From the live bids/asks:

- **Spread** = best ask − best bid. Wide spread → poor liquidity → size down or
  use a passive limit rather than crossing.
- **Depth at price** — how many shares rest near your target. Never assume a
  size fills; size to the visible depth, not to the headline.
- **Walls** — large resting orders that act as support/resistance; price just
  inside them and treat them as liquidity that can vanish.
- **Bid/ask imbalance** — heavier bids vs asks signals near-term pressure;
  context, not a guarantee.

For point-in-time history use `get_market_orderbook_snapshots`; for realised
flow use `get_market_recent_trades`.

## Concentration & exposure

- **Market level** — `get_market_open_interest` (marketId) and
  `get_market_top_positions` (market_id; optional `amount`=100|1k|10k,
  `outcome`, `limit`, `offset`) show how crowded and how concentrated a market
  is. A position that is a large share of a thin market is hard to exit.
- **Event level** — `get_event_open_interest` (eventId) aggregates correlated
  markets so the user sees event-wide risk, not just one leg.
- **User level** — combine with **fireplace-portfolio**'s `my_positions` /
  `my_overview` to compute the user's exposure as a % of their book and against
  the per-market / per-event caps above. Flag correlated directional skew (many
  "Yes" across linked events) as a single risk, not many small ones.

## Stop orders (concept)

Stops cap downside by triggering an exit when price crosses a level:

- **`place_stop_market`** — when the stop triggers, exit at the best available
  price. Reliable to fill, but slippage in a thin/fast market is unbounded.
  Prefer when getting out matters more than price.
- **`place_stop_limit`** — triggers into a limit order at a set price; protects
  against bad fills but may **not fill** if price gaps through the limit. Prefer
  when price control matters more than certainty of exit.
- Choose the trigger off real depth (`get_market_orderbook`), not a round
  number, and account for the spread. Placing a stop is still an execution
  action — it goes through **fireplace-trading**'s propose-and-confirm gate and
  requires trading to be enabled.

## Position-sizing procedure

1. Confirm the per-trade and portfolio limits (ask if unknown).
2. Read `get_market_orderbook`; assess spread, depth, walls, imbalance.
3. Compute worst-case loss for the candidate size (for a binary outcome, a BUY's
   max loss ≈ price × shares; a SELL's ≈ (1 − price) × shares).
4. Cap size so worst-case loss ≤ per-trade limit AND post-trade market/event
   exposure ≤ those caps AND the order fits visible depth.
5. Decide stop level/type if the user wants protection.
6. Hand the sized, limit-checked proposal to **fireplace-trading** to itemize
   and confirm. Never place it from here.

## Pitfalls

- **Sizing without the book.** A summary price is not fillable depth — always
  read `get_market_orderbook` first.
- **Ignoring correlation.** Multiple positions on linked events are one big bet;
  use `get_event_open_interest` and portfolio skew, not just per-market caps.
- **Stop-market slippage / stop-limit non-fill.** Pick the stop type for the
  market's liquidity; a stop-limit in a gapping market may never fill.
- **Treating limits as soft.** If a proposal breaches a cap, surface it and
  resize; don't quietly proceed.
- **Forgetting the gate.** Stops and all sizing outputs are still execution
  actions — they require enabled trading and explicit confirmation via
  **fireplace-trading**.
