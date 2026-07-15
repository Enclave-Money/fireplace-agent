---
name: fireplace-news
description: |
  Judge whether a news item actually moves a Fireplace market, read against its
  EXACT resolution criteria. Combines the Fireplace news layer (get_news /
  get_news_events, market-matched) with web_search (breaking external coverage)
  — never web alone — then reconciles them. Distinguishes "announced / expected
  / coming" from the criteria's actual bar, weights statements by source quality
  (an interested party's claim is positioning, not fact), separates
  resolution-moving news from sentiment/price noise, and states a confidence and
  a falsifier. Read-only.
version: 0.1.0
platforms:
  - linux
  - darwin
metadata:
  hermes:
    category: markets
    tags:
      - fireplace
      - news
      - resolution
      - catalysts
      - read-only
    related_skills:
      - fireplace-api
      - fireplace-research
      - fireplace-thesis
---

# Fireplace News — does this news actually move the market?

## When to use

Use this skill when the question is whether a news item, headline, or narrative
actually changes a market's resolution — "does this news matter for X?", "did
the market already price this in?", "will this resolve YES now?". It is the news
step of **fireplace-research** made rigorous. For the tool/param reference see
**fireplace-api**.

## Use BOTH sources — never web alone

- **Fireplace news layer**: `get_news` with the market_id (and `get_news_events`
  for the event) — it is market-matched and often carries context the open web
  misses. Honor the user's stated timeframe via the `days` param (days=7 for
  "past week", days=30 for "past month"); for a keyword/topic pass `search`, for
  a specific market pass `market_id` — do NOT pass both.
- **`web_search`**: for breaking / external coverage beyond the Fireplace layer.

Pull both, then reconcile them. Never answer a market-news question from
`web_search` alone or from memory.

## Procedure

1. **Restate the EXACT resolution criteria** (`get_market_by_id` /
   `get_market_overview`): what literally makes this resolve YES vs NO, and by
   when.
2. **Weight by SOURCE QUALITY.** A statement by an interested party — a
   politician, head of state, negotiator, government, or partisan/anonymous
   account — is evidence of their POSITIONING, not a confirmed fact; treat it as
   a claim, corroborate with neutral/primary reporting, and flag it as
   unconfirmed ("X said Y") rather than laundering it into fact.
3. **Resolution vs sentiment.** For each material item: does it move the
   RESOLUTION, or only sentiment/price? Distinguish "announced / expected /
   coming" from the criteria's actual bar (e.g. "available for purchase by date
   X"). A story can be real and bullish yet NOT satisfy the resolution — call
   that gap out explicitly.
4. **Direction + magnitude.** Which outcome does it favor, how strongly, and is
   the current price already reflecting it? Check recent price action /
   `get_market_recent_trades` and the live `get_market_orderbook`.
5. **Confidence + falsifier.** How sure are you, and what later news would flip
   the read? Default to "noise, not resolution-moving" when uncertain.

Output: the resolution-relevant takeaways, the likely market direction, and
whether there is an edge at the current price.

## Pitfalls

- **Web-only or memory-only answers.** Always pull the Fireplace news layer too;
  never assert an event from memory.
- **Laundering an interested party's claim into fact.** Flag single-sourced
  claims as unconfirmed.
- **Confusing a real, bullish story with a resolving one.** Read every item
  against the exact criteria, not the vibe.
- **Ignoring that the price already moved.** Check whether the market has already
  repriced the news before calling an edge.
