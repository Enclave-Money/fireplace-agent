---
name: fireplace-discover
description: |
  Find Fireplace markets worth betting on. A scaffold for opportunity discovery
  across several angles — mispricing / "fish" (holder-strength imbalance),
  smart-money accumulation, trending / hot movers, catalyst / news-driven,
  structural (bonds, expiring, mispriced sibling legs), and personalized (the
  categories the user demonstrably wins in) — each mapped to the exact
  search_markets sort params. Every candidate is validated for tradeable
  liquidity, live price, resolution risk, and overlap with the user's book
  before it is surfaced, then ranked and handed off to fireplace-research /
  fireplace-thesis. Read-only.
version: 0.1.0
platforms:
  - linux
  - darwin
metadata:
  hermes:
    category: markets
    tags:
      - fireplace
      - discovery
      - screening
      - opportunities
      - read-only
    related_skills:
      - fireplace-api
      - fireplace-research
      - fireplace-thesis
      - fireplace-risk
---

# Fireplace Discover — finding markets worth betting on

## When to use

Use this skill when the user asks "what should I trade?", "find me an edge",
"any mispriced markets?", "what's smart money doing?", or otherwise wants
candidates surfaced rather than one named market analyzed. To deep-dive a single
pick, hand off to **fireplace-research**; to structure it, **fireplace-thesis**;
for the exact tool/param reference, **fireplace-api**.

This is a SCAFFOLD, not a fixed strategy. Traders discover differently; if the
user has their own method, follow theirs and use this only to add rigor. The
invariants below apply to every angle.

## Procedure

1. **Pick the angle(s)** that fit the user's intent. If unstated, briefly name
   the menu and pick a sensible default (mispricing/fish for "find an edge";
   personalized for "what should I trade"). Angles map to `search_markets`
   screens — the exact sort params are in the SOUL "Fireplace vernacular"
   section:
   - **Mispricing / fish**: holder-strength imbalance
     (`search_markets` sortBy=abs_outcome_strength_diff, sortOrder=desc,
     priceMin=0.01, priceMax=0.99). Trade WITH the strong side against the weak
     ("fish") side; confirm who's strong with `get_market_top_positions`.
   - **Smart-money accumulation**: `search_wallets` by total_pnl (top 10-20) →
     `get_wallet_net_flows` over a recent window → markets with the largest net
     buying. Also scan `get_smart_money_trades` / `get_smart_money_wallets`.
   - **Trending / hot movers**: `search_markets` sortBy=combined_volume_30m
     desc, or sortBy=price_change_absolute_1d_1 desc.
   - **Catalyst / news-driven**: `get_news_events` / `get_news` for fresh
     significant items → check whether the market has already repriced (compare
     recent candles / `get_market_recent_trades` to the news timing).
   - **Structural**: bonds (sortBy=apy desc, priceMin=0.95), expiring-soon
     (sortBy=expiration asc + volumeMin), or sibling legs within one event that
     don't sum to ~1 (`get_event_by_id`).
   - **Personalized edge**: `my_recent_trades` + `my_positions` → the categories
     where the user demonstrably wins → screen new/trending markets in those
     categories (compose with **fireplace-portfolio**).

2. **Validate every candidate before surfacing it** — this is where most
   discovery goes wrong:
   - **Tradeable liquidity**: `get_market_orderbook`. Is there depth to enter at
     a sensible size? DROP edges you cannot actually trade — a great-looking
     price with no book is not an opportunity.
   - **Live price** from the tool's metrics (current_yes_price /
     current_no_price via `get_market_overview` / the orderbook mid), never a
     stale summary field.
   - **Exclude** markets the user already holds (`my_positions`) and
     resolved/closed/untradeable ones.
   - **Resolution risk**: flag near-resolution markets and check
     `get_dispute_stats` before recommending.

3. **Rank the survivors** by edge × confidence × tradeable-liquidity ×
   time-to-resolution. Keep the shortlist tight (3-7), never a dump.

4. **Output** per pick: market + outcome/side, current price (c and implied
   prob), the edge thesis in one line, the catalyst / why-now, the key risk, and
   a suggested entry. State what you filtered out and why (e.g. "dropped 4 for
   thin books").

Hand off: **fireplace-research** to deep-dive a pick, **fireplace-thesis** to
structure it. Sizing is manual Kelly (see SOUL "Position sizing").

## Pitfalls

- **Surfacing an untradeable edge.** A mispriced market with no book is not an
  opportunity; validate liquidity with `get_market_orderbook` first.
- **Dumping a screen.** A raw sorted list is not discovery. Validate, rank, and
  keep the shortlist tight with a one-line thesis each.
- **Recommending what the user already holds** — always cross-check
  `my_positions`.
- **Ignoring resolution/dispute risk** on near-resolution or contested markets.
