---
name: multi-trajectory-analysis
description: Run the same data analysis in several independent trajectories and report what holds across them. Adapted from Robin's analysis agents.
metadata:
  source: builtin
---

# Multi-trajectory analysis (after FutureHouse Robin)

Use when results depend on analytic choices (normalization, filtering, model specification).
1. Write a precise analysis brief: data paths, question, required outputs (named quantities).
2. `dispatch` mode `consensus` with the brief as the single item and 3–5 trajectories. Workers analyse independently.
3. Treat quantities that agree across trajectories as robust; for those that differ, find the analytic choice that causes the divergence and report the range, not the most favourable value.
4. Register robust headline results with `claim_finding`.
