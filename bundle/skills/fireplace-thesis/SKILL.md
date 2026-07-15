---
name: fireplace-thesis
description: |
  Turn Fireplace research into a structured, falsifiable trade thesis before
  proposing anything. Forces the full spec, in numbers not "likely/probably":
  market + direction, live price, a numeric fair value + EV/edge, concrete
  entry / exit-target / invalidation levels read off the book, the causal
  mechanism tied to the resolution criteria, the 2-3 strongest points for and
  the single strongest against, an explicit falsifier, catalysts & timeline,
  risks (resolution/dispute, liquidity, decay), a manual-Kelly size, and an
  honest correlation check for multi-leg ideas. No edge → no trade. Read-only;
  actual placement stays gated behind fireplace-trading + explicit confirmation.
version: 0.1.0
platforms:
  - linux
  - darwin
metadata:
  hermes:
    category: trading
    tags:
      - fireplace
      - thesis
      - trade-plan
      - fair-value
      - falsifiable
    related_skills:
      - fireplace-research
      - fireplace-risk
      - fireplace-trading
      - fireplace-premortem
---

# Fireplace Thesis — a structured, falsifiable trade plan

## When to use

Use this skill after **fireplace-research** (or the user's own analysis) to turn
a read into a committed, checkable trade plan — before proposing any order.
State everything explicitly, with NUMBERS. Sizing detail lives in
**fireplace-risk** and the SOUL "Position sizing" section; placement is gated by
**fireplace-trading**; red-team the result with **fireplace-premortem**.

## The thesis spec

- **MARKET + DIRECTION**: outcome and side (BUY YES / BUY NO) and the LIVE price
  (c + implied prob) from the order book mid (`get_market_orderbook`) — not a
  stale quoted price.
- **FAIR VALUE + EV**: your estimated true probability as a NUMBER (0-1) and
  confidence. Edge = fair value − market price. State rough EV / carry (e.g.
  "fair ~0.5% vs 1.9% paid → negative carry; only the pump-sell scalp is +EV").
  If it's part of a series, anchor fair value on the base rate.
- **LEVELS**: concrete entry, exit-target, and invalidation prices read off the
  book (e.g. "rest bids 0.80-0.82, sell into 0.90-0.92, invalidate < 0.78") —
  never a purely qualitative read.
- **MECHANISM**: WHY it resolves your way — the causal story, tied to the EXACT
  resolution criteria (from the market description).
- **EVIDENCE**: the 2-3 strongest points FOR (price / flow / holders / news /
  smart money) and the single strongest point AGAINST. Holder positioning is
  evidence: cite sized smart-money on your side, or its absence on the other.
- **FALSIFIER**: the observation that would make you exit or flip. If you can't
  name one, the thesis is too vague — keep researching.
- **CATALYSTS & TIMELINE**: what moves it and when (key dates, resolution date).
- **RISKS**: resolution / dispute risk (`get_dispute_stats`), liquidity, time
  decay.
- **SIZE**: manual Kelly off your fair value (see SOUL "Position sizing") —
  compute and show the arithmetic, never invent a dollar figure.
- **MULTI-LEG**: if the idea pairs two markets as a "hedge"/"straddle", check
  correlation honestly — if both legs realistically lose together (e.g. both need
  an extreme outcome), it's a sentiment scalp, not a convex hedge. Say so and
  quantify the combined carry.

Be opinionated; flag uncertainty honestly. **No edge (fair value ≤ price) → no
trade**; say what price WOULD give an edge.

## Pitfalls

- **A thesis with no number.** Fair value, edge, levels, and size are all
  numeric — "likely" is not a thesis.
- **No falsifier.** If nothing would change your mind, you haven't finished
  researching.
- **Overselling a "hedge".** Two legs that lose together are a scalp; check
  correlation and quantify carry.
- **Skipping to placement.** A thesis is a plan; any order still goes through
  **fireplace-trading**'s propose-and-confirm gate and requires trading enabled.
