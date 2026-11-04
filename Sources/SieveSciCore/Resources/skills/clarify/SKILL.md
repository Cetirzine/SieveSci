---
name: clarify
description: When a request is too vague to plan, search first, brainstorm a few candidate directions, then ask the user to choose with a structured card (single / multiple choice, fill-in, always "Other").
metadata:
  source: builtin
---

# Clarify a vague request (search → brainstorm → ask)

Use when the request leaves open what decides the work — the question, the organism or system, the data,
the outcome that matters — and different readings would lead to different plans. Not when one sensible
reading exists (take it and state it), and not for what a search or the workspace can answer.

1. **Search a little** (3–6 calls): `web_search` and `literature_search` on the request as given, plus
   a look at the workspace (`glob`, `read_file` on data and notes). Note what the field already knows and
   what data exist.
2. **Brainstorm directions** (no need for brainstorming mode): 6–10 concrete readings of the request —
   each a question that could actually be answered, with the evidence it rests on and the data it
   needs. Drop near-duplicates and the ones the available data cannot support.
3. **Ask once** with `ask_user`:
   - one question, kind `single` (or `multi` if several directions can run together), reason
     `direction`, 2–4 options — your recommendation first, each with a one-line `description` (what
     it would answer, what it needs) and `evidence` ([@key], receipt ids);
   - fill-in questions (kind `text`, reason `missing_value`) for values only the user has — organism,
     sample size, data location, deadline — with a `placeholder` example;
   - at most 4 questions in all; "Other" is added automatically.
4. **Act on the answer**: restate the chosen question in one sentence, cite the answer's receipt in the
   plan's rationale, and plan. If the user dismissed the card, reply briefly and wait. If nobody could
   answer (headless run), proceed on the most defensible reading and say which decision is missing.
