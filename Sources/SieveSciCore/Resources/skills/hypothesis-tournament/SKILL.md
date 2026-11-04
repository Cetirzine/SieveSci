---
name: hypothesis-tournament
description: Generate literature-grounded hypotheses or candidates, rank them by pairwise comparison, then review, evolve and re-rank the best. Adapted from FutureHouse Robin and Google AI co-scientist.
metadata:
  source: builtin
---

# Hypothesis / candidate tournament (after FutureHouse Robin, Apache-2.0)

The tournament runs as a brainstorm (`brainstorm` start … end, stages in order), so the user can watch
it and the host's rules apply: no plan and no workers until it ends. Do the comparisons and reviews
yourself; parallel workers are for the plan that follows.

1. **Ground.** Search the literature on the disease/mechanism; build a short evidence brief with [@key] citations.
2. **Generate** 10–20 candidate hypotheses (or therapeutic candidates / assays). Each: statement, mechanism, key supporting evidence [@key], what would falsify it, and the experiment that tests it. Use several operators (facet recombination, cross-domain analogy, inverted assumptions, `ideation_seeds`; see the `brainstorm` skill) — one prompt repeated yields duplicates. Record them with `idea` add (it merges near-duplicates) in the diverge stage.
3. **Rank** (stage `rank`). Compare the candidates pairwise yourself, ~3 comparisons per candidate, on a criterion such as: "Which is better supported by the evidence, more mechanistically specific, more testable with available assays, and more likely to translate?" Record the order with `idea` rank.
4. **Reflect** (stage `novelty`, after Google's AI co-scientist). For the top third, a review per candidate: novelty against the literature, internal consistency, testability, the strongest objection. Record each novelty verdict with `idea` novelty (it needs ≥3 searches run after the idea was written). Drop candidates the review shows to be known or untestable.
5. **Evolve.** Improve the survivors: combine compatible ones, sharpen vague mechanisms, simplify, or transfer an idea from an analogous system — each change justified by evidence [@key]. Add the evolved versions to the pool (stage `evolve`) and go back to `rank` for one more round over the pool (the originals stay in it, so evolution has to earn its place).
6. **Meta-review.** Note the patterns across the reviews (recurring weaknesses, missing evidence types) and state them as guidance for the next round or for the plan. Stop after two evolution rounds or when the top three stop changing.
7. **Report** the top candidates with the comparison reasons, the evidence, and the proposed experiments. Mark which evidence is direct vs. indirect and which candidates are evolved versions. The ranking is a prioritization, not a finding. Let the user choose with `ask_user`, then `brainstorm` end; register the chosen ones with `idea` promote (independent review) and only then plan the experiments with `update_plan`.
