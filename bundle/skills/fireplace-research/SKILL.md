---
name: fireplace-research
description: |
  Deep-dive a single Fireplace market or event into a thesis. The full research
  method, run on EVERY market analyzed: resolution first (map exactly what
  qualifies as outcome 1 vs 2, from the market description) → price & flow off
  the live order book → holder structure BOTH sides with directional-vs-
  market-maker classification → news & catalysts → term structure / series base
  rate → synthesize a numeric fair value, edge vs price, and EV. Encodes the
  invariants that keep real signal from being left on the table (never skip
  holders, never quote a stale price, never defer the deciding question).
  Read-only; hands off to fireplace-thesis and fireplace-risk before any order.
version: 0.1.0
platforms:
  - linux
  - darwin
metadata:
  hermes:
    category: markets
    tags:
      - fireplace
      - research
      - analysis
      - fair-value
      - read-only
    related_skills:
      - fireplace-api
      - fireplace-discover
      - fireplace-news
      - fireplace-thesis
---

# Fireplace Research — deep-diving one market into a thesis

## When to use

Use this skill whenever the user names a market or event and wants it analyzed
("what do you think of X?", "is this mispriced?", "analyze this market"). Run
EVERY step on EVERY market — do not skip holders or term-structure on some and
not others; that inconsistency is how real signal gets left on the table. For
the tool/param reference see **fireplace-api**; for the news-vs-resolution read
in step 4 see **fireplace-news**; to structure the result see **fireplace-thesis**.

## Procedure

1. **RESOLUTION FIRST (the backbone).** `get_market_by_id` / `get_market_overview`
   — read the EXACT resolution criteria and end date from the market description
   and MAP precisely what qualifies as outcome 1 vs outcome 2 (and by when). Most
   bad trades are misread criteria. This OUT1-vs-OUT2 mapping is what you judge
   price, news, and holders against for the rest of the analysis. If the
   valuation hinges on a resolution detail (does the window count an event from
   before creation? what specific act resolves YES?), SETTLE IT NOW from the
   description — never defer the deciding question, especially on the most
   fundable idea.
2. **PRICE & FLOW.** Take the price from the LIVE order book (mid / best bid-ask
   via `get_market_orderbook`), not a single quoted/last price — quoted prices on
   thin markets are often stale, so reconcile before you quote a level. Read
   spread, depth, and bid/ask imbalance / walls; `get_market_recent_trades` for
   order-flow direction. `get_market_latest_candles` for recent price action.
3. **HOLDERS (mandatory, BOTH sides).** Call `get_market_top_positions`
   SEPARATELY for each outcome (once for Yes, once for No) and present a
   side-by-side comparison — for each side give the top 3-5 holders by wallet
   (`trader_address`) with sizes (shares / position_value), avg entry, and PnL,
   plus whether that side has smart-money backing (cross-reference
   `get_smart_money_wallets`). Read BOTH directions: sized smart-money on one
   side is direct evidence it resolves that way; thin retail or NO smart-money on
   a side is itself a signal. For notable holders, pull their actual track record
   (`get_trader_overview` / `get_trader_historical_pnl`) and report CONCRETE
   numbers — realized PnL, win rate, position size, and especially their
   category-specific record (how they perform in THIS market's category) — never
   a vague "good/bad trader" label; check category stats by default. CLASSIFY
   each notable holder: a **directional trader** (one-sided, sized,
   conviction-held — real signal) vs a **market-maker / LP / reward-farmer**
   (two-sided / balanced exposure, churny, parked near the reward spread —
   discount as inventory, NOT a directional bet). Weight the directional ones.
   NAME the actual wallets and dollar sizes; reporting only one side is never
   acceptable. Never skip holders.
4. **NEWS & CATALYSTS.** `get_news` (market_id) for what is moving it, plus
   `web_search` for breaking external coverage — use BOTH. Note time-to-
   resolution and any key dates. For the deeper "does this actually move the
   resolution?" read, load **fireplace-news**.
5. **TERM STRUCTURE / SERIES.** If this is one leg of a date ladder (event-by-
   June / -July / -Dec) or a recurring series (monthly repeats), pull the sibling
   legs / prior instances (`get_event_by_id`) and compare. Express the thesis on
   the leg with room to run, not a near-dead one. Cite the series BASE RATE — how
   prior instances resolved (a monthly series 0-for-6 is the strongest "won't hit
   YES" argument). Make any redirect actionable: pull the siblings' prices.
6. **SYNTHESIZE.** State a fair-value probability (a NUMBER, with a confidence
   band), the price-vs-fair gap = the edge, and rough EV / carry — prefer numbers
   to "likely/probably". Give the 2-3 load-bearing reasons and what would change
   your mind.

Cost reminder: trading is gasless; the only real cost is spread + slippage from
the book — reason from depth, never gas. Hand off to **fireplace-thesis** and
**fireplace-risk** before proposing anything.

## Pitfalls

- **Skipping holders or reading one side only.** Both outcomes, every time, with
  named wallets and sizes.
- **Quoting a stale price.** Reconcile the summary against the live
  `get_market_orderbook` before quoting a level.
- **Misreading resolution.** The single most common failure — pin the OUT1-vs-
  OUT2 mapping from the description before anything else.
- **Deferring the deciding question.** Settle the one detail the valuation turns
  on now, not "later".
- **Relaying the price instead of forming a fair value.** Always output your own
  number and the edge.
- **Reading maker/farmer inventory as a directional bet.** Classify holders;
  weight only the directional ones.
