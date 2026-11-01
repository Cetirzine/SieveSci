---
name: virtual-lab-meeting
description: Run a research "team meeting" of specialist agents led by a PI, with a scientific critic, to decide an approach before committing to it. After Stanford's Virtual Lab (Swanson et al.).
metadata:
  source: builtin
---

# Virtual lab meeting (after the Virtual Lab of Swanson, Zou et al., Stanford / CZ Biohub)

Use when a decision needs several kinds of expertise before work starts: which modality or method,
which data, which model system, how to validate. Not for questions one search answers.

1. **Agenda.** Write the decision to be made as one question, the constraints (time, data, budget,
   equipment) and what a good answer must contain. Ground it first: background searches with
   [@key] citations, as for any plan.
2. **Team.** You are the PI. Choose 3–4 specialists the agenda needs (for example: structural
   biologist, computational biologist, immunologist, statistician). For each, one line: expertise,
   what they should look for, what they should challenge.
3. **Round 1 — positions.** `dispatch` mode `map`, one item per specialist ("role: …; expertise: …").
   Instructions: "As this specialist, answer the agenda question. Give a recommendation, the evidence
   for it with citations or receipts, the main risk, and one thing you would want another specialist
   to check." Each works from the shared brief only.
4. **Round 2 — cross-examination.** `dispatch` mode `map` again, each specialist now given the other
   positions: "Agree or disagree with each other position, with new evidence only. Revise yours if
   warranted." At most two rounds in total; repeated arguments are not new evidence.
5. **Critic.** Ask the checker (`/review` or the end-of-turn review) to act as scientific critic of the
   PI's draft decision: unsupported claims, missing controls, feasibility, simpler alternatives.
6. **Decision.** As PI, write the meeting record into the plan: the decision, the reasons, the
   dissent that remained (mark it *contested*, never hide it), the experiments or analyses it implies,
   and what result would change the decision. Ask the user to approve before execution.

The meeting produces a plan, not a finding: nothing decided here is a result until it is run and verified.
