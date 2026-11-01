---
name: figure-review
description: Review scientific figures for correctness and clarity. Adapted from AI Scientist v2's VLM reviewer.
metadata:
  source: builtin
---

# Figure review (after AI Scientist v2)

For each figure (open it with `read_file`):
- Axes labelled with quantity and unit; ticks readable; log scales marked.
- Sample sizes (n) stated; error bars defined (SD, SEM or CI) in the caption; statistics named with p or q values.
- The plotted values match the numbers in the text and their receipts.
- No truncated axes that exaggerate effects; consistent colours across panels; colour-blind-safe palette.
- Caption self-contained: what was measured, in what, how many, which test.
Report problems per figure and regenerate the figure from its script after fixing.
