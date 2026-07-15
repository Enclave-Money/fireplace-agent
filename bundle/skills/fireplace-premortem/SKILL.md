---
name: fireplace-premortem
description: |
  Red-team your own conclusion before committing to a non-trivial or
  money-moving Fireplace recommendation. Assume the trade has already LOST and
  write the most likely story for why: fair value anchored on weak/old/single-
  source evidence, misread resolution criteria (the most common failure), an
  "edge" that is really illiquidity or a stale price, overfitting to one
  smart-money wallet or one news item, or a known unknown (timing, dispute,
  off-market event) that flips it. If a real hole surfaces, lower the Kelly
  fraction, tighten the entry, or pass — and always present the strongest
  counter-case alongside the recommendation. Read-only.
version: 0.1.0
platforms:
  - linux
  - darwin
metadata:
  hermes:
    category: risk
    tags:
      - fireplace
      - pre-mortem
      - red-team
      - risk
      - discipline
    related_skills:
      - fireplace-thesis
      - fireplace-risk
      - fireplace-research
---

# Fireplace Pre-mortem — red-team your own conclusion

## When to use

Run this on any non-trivial or money-moving recommendation, immediately before
proposing it — after **fireplace-thesis**, before **fireplace-trading**. It is a
discipline step, not a data step: you are attacking your own conclusion, not
gathering more.

## Procedure

Assume the trade has already LOST. Write the most likely story for why:

- Was the fair value anchored on weak, old, or single-source evidence?
- Did you misread the resolution criteria? (the most common failure — re-read the
  market description and re-check the OUT1-vs-OUT2 mapping)
- Is the "edge" actually just illiquidity or a stale price? Re-check the book
  (`get_market_orderbook`) and live metrics.
- Are you overfitting to one smart-money wallet or one news item?
- What known unknown — timing, a dispute (`get_dispute_stats`), an off-market
  real-world event — could flip it?

If the pre-mortem surfaces a real hole: lower the Kelly fraction, tighten the
entry, or pass. **Always present the strongest counter-case to the user
alongside the recommendation — never only the bull case.**

## Pitfalls

- **Skipping it on your best idea.** The most fundable, most confident trade is
  exactly where a blind spot costs the most — pre-mortem it hardest.
- **Turning it into more research.** It is a red-team of the existing thesis;
  re-check the load-bearing facts, don't start over.
- **Presenting only the bull case.** The counter-case ships with the
  recommendation, every time.
