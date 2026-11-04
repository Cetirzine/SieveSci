---
name: brainstorm
description: Brainstorm new research ideas in a mode the user watches live — ground, diverge with several operators, deduplicate, rank, novelty-check, review, evolve, report — keeping every idea as speculation until it is checked. A closed phase before planning; the host enforces the stage order. After Google AI co-scientist, Stanford Virtual Lab, Scideator and Si et al.
metadata:
  source: builtin
---

# Brainstorm (watched live, checked before it counts)

The user sees each stage, every idea you record and your thinking, and can stop you or ask you to wrap
up. Announce each stage with `brainstorm` stage (one-line `note`), so what they see is what you do.

## The flow is fixed

```
brainstorm start
  → ground → diverge → dedupe → rank → novelty → [review → evolve] → report
  → ask_user (the user chooses)
  → brainstorm end
  → idea promote (the chosen ideas)
  → update_plan → the work (workers only from here)
```

The host enforces it:

- Stages run in order. A skipped stage is refused, and so is leaving a stage whose work is not done
  (no grounding searches, fewer than 6 live ideas, no ranking, top ideas not novelty-checked). Review and
  evolve are optional. The only way back is evolve → dedupe or rank, at most twice.
- `idea` add works in diverge and evolve, `idea` rank in rank, `idea` novelty from novelty on, and
  `idea` promote only after `brainstorm` end.
- While the brainstorm is live there is **no planning, no workers and no execution**: `update_plan`,
  `task`, `dispatch`, `claim_finding`, Python, scripts and file writes are refused. You do every stage
  yourself, in your own context. Reading, searching, `paper_fetch` and read-only shell stay open.
- When an idea would need an experiment or an analysis, write that into its `test`. It becomes a plan
  step after the user chose the idea.

## Stages

1. **Start.** `brainstorm` start with the topic and why new ideas are needed now. If it is refused
   (the user turned autonomous brainstorming off), continue without it and mention `/brainstorm`.
2. **Ground** (stage `ground`). Search before generating: `web_search` and `literature_search`, fetch
   the 5–10 papers that matter, and write a short evidence brief with [@key] citations. Ideas that
   ignore the brief are wasted.
3. **Diverge** (stage `diverge`). Generate 12–24 ideas yourself, with several operators, never one:
   - `facet` — split the key papers into purpose · mechanism · evaluation and recombine across papers;
   - `analogy` — restate the problem without its field's words, then look for the same structure in a
     distant field (`ideation_seeds` sources far_papers, cross_domain), and search that field;
   - `invert` — list 3–5 assumptions the field takes for granted, negate each, and ask what would be
     observable if the negation held (no direct evidence that this works; use it sparingly);
   - `seed` — draw seeds with `ideation_seeds` and force an association with each;
   - `verbalized` — ask yourself for several ideas with how likely each is, and keep the unlikely tail.
   Work one operator at a time and record each batch with `idea` add as it comes, so the user watches the
   pool grow. Every idea: statement, mechanism, test, falsifier, operator, evidence.
4. **Dedupe** (stage `dedupe`). `idea` add merges near-duplicates automatically; also merge ideas that
   say the same thing in other words (`idea` discard with "duplicate of In"). If most new ideas were
   duplicates, say which operator ran dry.
5. **Rank** (stage `rank`). Compare the live ideas pairwise yourself on "better grounded in the
   evidence, more mechanistically specific, testable with available means", and record the order with
   `idea` rank.
6. **Novelty** (stage `novelty`). For the top third (at least the top 3): 5–10 searches each (synonyms,
   the mechanism, the method, the organism; preprints and patents via `web_search`), read the closest
   papers, then `idea` novelty with the verdict and the receipts. A verdict is "not found in these
   searches", never "novel". Known ideas are discarded.
7. **Review and evolve** (stages `review`, `evolve`; optional). Note the recurring weaknesses, then
   improve the survivors — combine compatible ones, sharpen mechanisms, simplify the test, transfer from
   an analogous system — and add the evolved versions as new ideas (operator `evolve:<id>`), so they
   compete with the originals. For another round go back to `rank`; stop when the top three stop changing.
8. **Report** (stage `report`). Present the top ideas as speculation with: what each builds on, how it
   was checked (queries, closest prior work), and what is unchecked. Then `ask_user` (kind multi, reason
   direction, one option per idea with `idea` and `evidence`) so the user picks what to pursue.
9. **End.** After the answer, `brainstorm` end with a two-line summary. If the user dismissed the
   question, end and wait.

## After the brainstorm

Only now does the work become a project:

1. `idea` promote each idea the user chose (with its prediction); an independent checker reviews the
   novelty check, then it is registered as a hypothesis.
2. `update_plan` around those hypotheses: steps that test them, with success criteria, `parallel: true`
   on steps that need no other step's results, and a checkpoint on the deliverable.
3. Do the work. Workers run the plan's independent steps; results go through `claim_finding` as always.

If the user asks you to wrap up, stop generating at once, finish only the novelty checks already
running, and go straight to report (the host allows that jump after a wrap-up).
