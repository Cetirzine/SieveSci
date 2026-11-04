---
name: novelty-check
description: Check whether an idea or finding is novel against the literature before calling it new. Adapted from Sakana AI Scientist.
metadata:
  source: builtin
---

# Novelty check (after Sakana AI Scientist, Apache-2.0)

Before describing anything as novel, new, or first:
1. Write 5–10 search queries that would find prior work (synonyms, the mechanism, the method, the organism).
2. Run them with `literature_search` (all sources) and `web_search` (preprints, theses, patents).
3. For the closest 5–10 papers, read the relevant passages and state precisely how the idea differs.
4. Verdict: not found in these searches / incremental / already published, with the closest prior work cited [@key]. Never write "novel" or "first": write what was searched and what was not found. If any paper reports the same finding, it is already published — say so.
5. For an idea in the ledger, record the verdict with `idea` novelty (id, verdict, closest_prior, receipts of the searches above; at least 3, run after the idea was written).
