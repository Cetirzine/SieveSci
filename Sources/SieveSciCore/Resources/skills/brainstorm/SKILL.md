---
name: brainstorm
description: Brainstorm new research ideas in a mode the user watches live — ground, diverge with several operators, deduplicate, rank, novelty-check, review, evolve — keeping every idea as speculation until it is checked. After Google AI co-scientist, Stanford Virtual Lab, Scideator and Si et al.
metadata:
  source: builtin
---

# Brainstorm (watched live, checked before it counts)

The user sees each stage, every idea you record and your thinking, and can stop you or ask you to wrap
up. Announce each stage with `brainstorm` stage (one-line `note`), so what they see is what you do.

1. **Start.** `brainstorm` start with the topic and why new ideas are needed now. If it is refused
   (the user turned autonomous brainstorming off), continue without it and mention `/brainstorm`.
2. **Ground** (stage `ground`). Search before generating: `web_search` and `literature_search`, fetch
   the 5–10 papers that matter, and write a short evidence brief with [@key] citations. Ideas that
   ignore the brief are wasted.
3. **Diverge** (stage `diverge`). Generate 12–24 ideas with several operators, never one:
   - `facet` — split the key papers into purpose · mechanism · evaluation and recombine across papers;
   - `analogy` — restate the problem without its field's words, then look for the same structure in a
     distant field (`ideation_seeds` sources far_papers, cross_domain), and search that field;
   - `invert` — list 3–5 assumptions the field takes for granted, negate each, and ask what would be
     observable if the negation held (no direct evidence that this works; use it sparingly);
   - `seed` — draw seeds with `ideation_seeds` and force an association with each;
   - `verbalized` — ask yourself for several ideas with how likely each is, and keep the unlikely tail.
   For breadth, `dispatch` mode `map` with one item per operator or seed set (each worker returns 4–6
   ideas), then merge them yourself, saying which ideas came from which worker (Virtual Lab's
   parallel-then-merge). Every idea: statement, mechanism, test, falsifier, operator, evidence.
   Record them with `idea` add as they come, so the user watches the pool grow.
4. **Dedupe** (stage `dedupe`). `idea` add merges near-duplicates automatically; also merge ideas that
   say the same thing in other words (`idea` discard with "duplicate of In"). If most new ideas are
   duplicates, change operator or seeds — generating more of the same does not help.
5. **Rank** (stage `rank`). `dispatch` mode `rank` over the live ideas with the criterion "better
   grounded in the evidence, more mechanistically specific, testable with available means"; record the
   order with `idea` rank.
6. **Novelty** (stage `novelty`). For the top third: 5–10 searches each (synonyms, the mechanism, the
   method, the organism; preprints and patents via `web_search`), read the closest papers, then `idea`
   novelty with the verdict and the receipts. A verdict is "not found in these searches", never "novel".
   Known ideas are discarded.
7. **Review and evolve** (stages `review`, `evolve`). Note the recurring weaknesses, then improve the
   survivors — combine compatible ones, sharpen mechanisms, simplify the test, transfer from an analogous
   system — and add the evolved versions as new ideas (operator `evolve:<id>`), so they compete with
   the originals. At most two rounds; stop early when the top three stop changing.
8. **Report** (stage `report`). `brainstorm` end with a two-line summary. Present the top ideas as
   speculation with: what each builds on, how it was checked (queries, closest prior work), and what is
   unchecked. Then offer them with `ask_user` (kind multi, reason direction, one option per idea with
   `idea` and `evidence`) so the user picks what to pursue.
9. **Promote** only what the user chose: `idea` promote (with the prediction) runs an independent
   review and registers the hypothesis; results from it go through `claim_finding` as always.

If the user asks you to wrap up, stop generating at once, finish only checks already running, and go to
step 8 with what you have.
