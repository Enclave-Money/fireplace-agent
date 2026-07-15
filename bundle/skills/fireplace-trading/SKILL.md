---
name: fireplace-trading
description: |
  How to place, size, and reason about trades on Fireplace prediction markets.
  Covers the disciplined order workflow: pull live state with read tools (ALWAYS
  get_market_orderbook before proposing a price), size the order against the
  user's risk limits, present the exact proposed order (market + side + price +
  size) and WAIT for an explicit, itemized in-turn confirmation, and only then
  route through the gated execution tool. Documents the parameters and order
  types for place_limit_order and place_market_order. Trading is OFF by default
  (read-only profile) — the execution tools only exist after the user runs
  'fireplace enable-trading'. Never auto-confirm, never assume liquidity.
version: 0.1.0
platforms:
  - linux
  - darwin
metadata:
  hermes:
    category: trading
    tags:
      - fireplace
      - trading
      - orders
      - execution
      - confirmation-required
    related_skills:
      - fireplace-api
      - fireplace-risk
      - fireplace-portfolio
      - fireplace-thesis
      - fireplace-premortem
---

# Fireplace Trading — placing orders safely

## When to use

Use this skill when the user wants to actually *act* on a market: buy or sell an
outcome, set a limit, work an order, or exit a position. It owns the execution
tools (`place_limit_order`, `place_market_order`, `place_stop_limit`,
`place_stop_market`, `place_iceberg`, `place_sticky_bbo`, `edit_order`,
`cancel_order`, `cancel_all_orders`, `redeem_positions`, `merge_positions`,
`split_position`). For pure reads (prices, books, positions) use
**fireplace-api**; for sizing math and limits use **fireplace-risk**; for
reviewing the resulting book use **fireplace-portfolio**.

## Hard rules (non-negotiable)

1. **Trading is opt-in.** The default Fireplace profile is read-only; the 14
   execution tools are not advertised to the model and cannot fire. If the user
   wants to trade and the tools aren't available, tell them to run
   `fireplace enable-trading` (and `fireplace disable-trading` to lock back to
   read-only). Server-side key scoping is the real guarantee.
2. **Never place, edit, cancel, redeem, merge, or split without an explicit,
   itemized, in-turn user confirmation** that names market + side + size +
   price. A general "go ahead" from earlier in the conversation does not count.
3. **Never assume liquidity.** ALWAYS call `get_market_orderbook` immediately
   before proposing or placing any price-bearing order. Quote prices off real
   depth, never off a summary or a guess.
4. **Stay in scope.** Only markets/trading. Decline off-topic requests briefly.

## Procedure

1. **Resolve the market.** From the user's intent get the right ids:
   `search_markets` → numeric `marketId` for reads; you will need the **string
   condition-id `marketId`** for the actual `place_*` call. Confirm the outcome
   label ("Yes"/"No" or the named outcome) explicitly.
2. **Read live state.** Call `get_market_orderbook` (numeric marketId) for the
   live bids/asks, best bid/ask, spread, and visible walls. Optionally
   `get_market_overview` for volume/OI and `my_positions` to see existing
   exposure. Hand the depth read to **fireplace-risk** for spread/imbalance
   judgement.
3. **Size against risk limits.** Apply the per-trade and portfolio caps from
   **fireplace-risk** (ask the user for them if unknown). Translate the user's
   intent into concrete numbers: outcome, side, price, size/amount.
4. **Propose, then STOP.** Present the exact order back to the user as an
   itemized line — e.g. "BUY 50 shares of `Yes` on <market> @ 0.55 (limit, GTC),
   ~$27.50 max" — including order type and worst-case cost/proceeds. Then WAIT.
   Do not call any execution tool yet.
5. **On explicit confirmation only**, route through the single appropriate
   execution tool with the validated params. If the user changes anything,
   re-propose and wait again.
6. **Confirm the result.** Report the fill/working state; verify with
   `get_order_status` / `get_open_orders` / `my_positions`.

## Choosing the order type (do NOT default to a plain limit)

Match the order type to the trader's use case. Always `get_market_orderbook`
first; the right type depends on size vs visible depth and the trader's intent.
Infer the goal (ask only if genuinely unclear), then choose:

- **MARKET** (`place_market_order`): must fill NOW, size small vs the book,
  willing to pay the spread. Urgent entry/exit on liquid markets.
- **LIMIT** (`place_limit_order`): price-sensitive, willing to wait; rest at/
  inside a level. Maker (no taker fee). Good for a single patient entry — one
  option, not the default.
- **ICEBERG** (`place_iceberg`): size is LARGE vs visible depth. Shows only a
  slice at a time so it doesn't move the book or signal intent; refills as it
  fills. Use when a plain limit would post an obvious wall.
- **STICKY-BBO** (`place_sticky_bbo`): wants to stay at the best bid/ask as the
  book moves — passive accumulation/exit that tracks the market and keeps maker
  priority without manual re-pricing. Use for patient build-ups where staying
  top-of-book matters.
- **STOP-MARKET** (`place_stop_market`): risk management / breakout — fire a
  market order when price crosses a trigger. Caps downside or enters on momentum
  when the trader can't watch; prioritizes certainty of fill.
- **STOP-LIMIT** (`place_stop_limit`): same trigger but caps the fill price
  (avoids slippage on the trigger), at the risk of not filling in a fast move.

Decision shortcuts: urgent + small → market; patient + price set → limit; big
size → iceberg; stay top-of-book over time → sticky-BBO; protect/breakout → stop
(market if fill certainty matters, limit if price control matters). Set limit
prices and stop triggers from the actual book and recent candles, never round
numbers. Always state WHY you chose that type for their use case.

## Order types & parameters

**`place_limit_order`** — GTC, rests on the book until filled or cancelled.
- `marketId` — **condition-id string** (not the numeric id).
- `outcome` — e.g. "Yes" / "No".
- `side` — `BUY` | `SELL`.
- `price` — string in `"0"`–`"1"`, e.g. `"0.55"`.
- `size` — shares, **minimum 5**.
- `tickSize` — optional; auto-fetched if omitted.

**`place_market_order`** — immediate execution at best available price.
- `marketId`, `outcome`, `side` (`BUY`|`SELL`) — as above.
- `amount` — string. For **BUY** = USD to spend; for **SELL** = number of
  shares (must be `>= 1`).
- `orderType` — optional; `FOK` (default, fill-or-kill: all or nothing) or
  `FAK` (fill-and-kill: take what's available, cancel the rest).

**Other execution tools** (use the same propose-and-confirm gate):
- `place_stop_limit` / `place_stop_market` — conditional stop orders; see
  **fireplace-risk** for the stop concept and trigger choice.
- `place_iceberg`, `place_sticky_bbo` — advanced working orders (hidden size /
  follow best-bid-offer); price them off `get_market_orderbook` like any limit.
- `edit_order`, `cancel_order`, `cancel_all_orders` — modify/pull working
  orders; confirm the specific order(s) first.
- `redeem_positions`, `merge_positions`, `split_position` — position lifecycle
  ops; itemize and confirm exactly which positions before calling.

## Pitfalls

- **Auto-confirming.** The single most dangerous failure. Always propose and
  wait for an in-turn, itemized yes.
- **Skipping the orderbook.** A "market is at 0.55" summary can have nothing
  resting at 0.55. Read the book; size to the depth.
- **Wrong marketId form.** Reads take numeric ids; `place_*` take the
  condition-id string. Don't cross them.
- **Sub-minimum size.** Limit orders need `size >= 5` shares; market SELL needs
  `amount >= 1` share.
- **Price out of range.** `price` must be a `"0"`–`"1"` string, not a percent
  and not a number.
- **Trading disabled.** If a `place_*` tool isn't available, it's the read-only
  profile — direct the user to `fireplace enable-trading` rather than retrying.
- **BUY vs SELL `amount` units** in `place_market_order`: USD for BUY, shares
  for SELL. Confusing them mis-sizes the order badly.
