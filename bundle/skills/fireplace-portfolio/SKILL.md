---
name: fireplace-portfolio
description: |
  How to review the logged-in user's Fireplace portfolio and turn raw account
  reads into a clear picture of exposure, performance, and concentration. Pulls
  my_overview (PnL / volume / win-rate), my_positions (open vs settled, sorted),
  get_open_orders (working orders), get_trader_historical_pnl (PnL curve), and
  the unredeemed-positions and followed-wallet reads, then summarises total and
  per-market exposure, flags concentration, and surfaces unredeemed value and
  stale working orders. Read-only — for sizing/limits use fireplace-risk, to act
  on what you find use fireplace-trading.
version: 0.1.0
platforms:
  - linux
  - darwin
metadata:
  hermes:
    category: portfolio
    tags:
      - fireplace
      - portfolio
      - pnl
      - positions
      - exposure
    related_skills:
      - fireplace-api
      - fireplace-risk
      - fireplace-trading
---

# Fireplace Portfolio — reviewing where the user stands

## When to use

Use this skill when the user asks "how am I doing?", "what's my PnL?", "what
positions do I have?", "what's my exposure?", "do I have open orders?", or
"anything to redeem?". It is read-only and account-scoped to the logged-in user
via the `my_*` and order tools (no 0x address needed). For raw tool/param
reference see **fireplace-api**; for sizing rules and concentration limits see
**fireplace-risk**; to actually rebalance, exit, or redeem see
**fireplace-trading**.

## Procedure

1. **Headline performance.** `my_overview` (param-free) → realised/unrealised
   PnL, volume, win rate, active-position count. Lead the summary with this.
2. **Open positions.** `my_positions` with `isActive: "true"` (default).
   Sort to make the point: `sortBy: "current_holdings"` or `"pnl"` with
   `sortType: "desc"`. Each row gives entry price, current price/holdings, and
   PnL. Use `marketId` to drill into one market.
3. **Settled / historical positions.** `my_positions` with `isActive: "false"`
   for closed exposure when reviewing performance over time.
4. **Working orders.** `get_open_orders` (param-free) → every live limit / stop
   / pending-exit order with market metadata. Flag stale or far-from-market
   resting orders. Drill with `get_order_status` / `get_order_fills`.
5. **PnL trajectory.** `get_trader_historical_pnl` for the curve over time
   (use the user's own address / overview context) to show trend, not just a
   snapshot.
6. **Unredeemed value.** `get_trader_unredeemed_positions` → settled-but-
   unclaimed positions sitting idle. Surface these as redeemable value (acting
   on them = `redeem_positions`, via **fireplace-trading**).
7. **Follow / copy lens.** `my_followed_wallets`,
   `followed_wallets_recent_trades`, `followed_wallets_net_flows` to show what
   tracked wallets are doing relative to the user's book.

## Summarising exposure & concentration

- **Total exposure** = sum of current position values across `my_positions`
  (open). Report alongside PnL so size and result are seen together.
- **Concentration** — rank positions by current value; call out when one
  market/event/outcome is a large share of the book. For market-level context
  use `get_market_top_positions` and `get_market_open_interest` /
  `get_event_open_interest` (see **fireplace-risk** for the limits to compare
  against).
- **Directional skew** — note if the book is heavily one side (lots of "Yes"
  across correlated events) so the user sees correlated risk, not just per-
  market risk.
- **Idle capital** — unredeemed positions and far-from-market working orders are
  capital not working; surface both.

Present as: headline (PnL / win-rate / # positions) → top positions by size with
PnL → concentration/skew flags → working orders → unredeemed value → suggested
follow-ups (never act without going through **fireplace-trading**'s confirm
gate).

## Track record — skill vs luck (the analytical core)

Judge a record by sample size and dispersion, not the headline number.
`get_trader_historical_pnl` / `get_trader_overview` give realized vs unrealized
PnL and whatever ROI / win aggregates the tool returns, by category where
available.

- **HARD RULE: report ONLY numbers the tools return.** Never compute or estimate
  a stat the tools don't already provide; if a metric isn't available, say so
  rather than inventing it. A wrong win-rate is worse than no win-rate.
- Call out when PnL is **concentrated in one or two bets**, or the sample is too
  small to mean anything. Do not crown a great trader off a handful of trades.
- Read **category-specific** performance where the tool exposes it — a strong
  overall record can hide a category the trader consistently loses in.

## Analyzing any trader (not just yourself)

The same method works on any wallet via the `get_trader_*` tools (needs a 0x
`trader_address`); use `my_*` only for the logged-in user.

- **Dead capital** (`get_trader_unredeemed_positions`): settled-but-unclaimed
  winnings plus dust / near-worthless positions. Flag as recoverable cash
  (redeeming is gasless). A winner can read as redeemable until it is actually
  claimed.
- **Style** (`get_trader_recent_trades`): momentum vs contrarian, hold-to-
  resolution vs flip, sizing discipline, category focus, early vs late entries →
  describe an archetype, hedged as inference from public on-chain data.
- For another trader, frame everything as observed/inferred, not certain; for the
  user, end with concrete next steps (e.g. trim X, harvest Y).

## Pitfalls

- **Snapshot ≠ trend.** Pair `my_overview`/`my_positions` with
  `get_trader_historical_pnl` so a good day isn't mistaken for a good strategy.
- **Forgetting settled & unredeemed.** Default `my_positions` is open-only; pull
  `isActive: "false"` and `get_trader_unredeemed_positions` or you'll understate
  the picture and miss claimable value.
- **`my_*` vs `get_trader_*`.** Stay on `my_*` for the logged-in user; only use
  `get_trader_*` (with a 0x address) for someone else.
- **Reporting size without risk context.** Hand concentration figures to
  **fireplace-risk** to judge against limits rather than declaring exposure
  "fine".
- **Acting from review.** Reviewing is read-only; any rebalance/exit/redeem must
  go through **fireplace-trading** with explicit itemized confirmation.
