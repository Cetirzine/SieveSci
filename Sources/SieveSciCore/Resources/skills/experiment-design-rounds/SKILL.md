---
name: experiment-design-rounds
description: Design experiments iteratively in rounds (e.g. which genes to perturb next), updating on each round's results. Adapted from BioDiscoveryAgent.
metadata:
  source: builtin
---

# Iterative experiment design (after BioDiscoveryAgent)

1. Define the objective and the budget per round (e.g. 32 genes per CRISPR screen round) and the readout.
2. Round 1: choose candidates from prior knowledge — pathways, literature, databases (`bio_tool_search` helps), with a reason per candidate; record them in the plan.
3. After each round: analyse the results in code, update which hypotheses are supported, and choose the next batch balancing exploitation (neighbours of hits) and exploration (untested pathways). Never re-select a tested candidate without a reason.
4. Keep a per-round table (candidate, reason, result) in a file; it is the audit trail of the design decisions.
5. Use `/goal` for multi-round campaigns so rounds continue automatically.
