---
name: systematic-review
description: Run a PRISMA-style systematic review or meta-analysis: protocol, search, screening, extraction, risk of bias, synthesis.
metadata:
  source: builtin
---

# Systematic review / meta-analysis (PRISMA 2020)

1. **Protocol first** (pre-registration via `update_plan`): PICO question, inclusion/exclusion criteria, outcomes, effect measure, databases, search strings, risk-of-bias tool, synthesis model. Do not change criteria after screening without a recorded rationale.
2. **Search** every listed source (`literature_search` per source, with the exact strings); save the raw hit lists to files. Deduplicate by DOI/PMID and record counts at each step (identification → screening → eligibility → included).
3. **Screen** titles/abstracts with `dispatch` map: one item per record, instructions = the criteria, output = include/exclude/unclear + reason. Resolve "unclear" by full-text reading.
4. **Extract** data with `dispatch` map over included papers into a table (study, design, n, effect, CI, covariates). Spot-check a random 20% yourself against the papers.
5. **Risk of bias** per study (RoB 2 / ROBINS-I / NOS as appropriate), justified with quotes.
6. **Synthesize** in code (`statsmodels` / R `metafor`): random-effects model, heterogeneity (I², τ²), sensitivity and subgroup analyses that were pre-specified, funnel plot / Egger's test when ≥10 studies.
7. **Report** the PRISMA flow counts from your saved files, GRADE certainty, and limitations. Register the pooled estimate with `claim_finding` before concluding.
