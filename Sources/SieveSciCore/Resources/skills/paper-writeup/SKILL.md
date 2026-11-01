---
name: paper-writeup
description: Write up results as a manuscript with figures, methods and citations traced to receipts. Adapted from AI Scientist and Agent Laboratory.
metadata:
  source: builtin
---

# Manuscript write-up (after AI Scientist / Agent Laboratory)

1. Outline: title, abstract, introduction (gap, [@key]), methods (data, software versions from environment.txt, seeds, statistics), results (each number followed by its receipt, e.g. "(r42)"), discussion, limitations.
2. Only verified claims (`claim_finding` status verified) appear as conclusions; others are reported as preliminary or refuted.
3. Figures: produced by saved scripts; apply the figure-review skill to each.
4. Self-review with the checker (`/review`), fix issues, then export with `/report <file>` (provenance footnotes, bibliography, claims table). LaTeX: write sections as .tex and compile with latexmk if installed.
