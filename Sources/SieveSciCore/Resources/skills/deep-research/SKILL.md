---
name: deep-research
description: Multi-source deep research on a question: plan sub-questions, research them in parallel, then synthesize a cited report. Adapted from GPT Researcher.
metadata:
  source: builtin
---

# Deep research (after GPT Researcher, Apache-2.0)

1. **Plan.** Restate the question. Write 4–8 sub-questions that together answer it (mechanism, evidence, methods, counter-evidence, open problems). Record them with `update_plan`.
2. **Research in parallel.** `dispatch` mode `map`, one item per sub-question. Instructions for each worker: run `web_search` and `literature_search`, `paper_fetch` the 2–4 most relevant primary sources, read the relevant passages (`paper_read`), and return findings as bullet points, each with a [@key] or URL and the exact numbers quoted.
3. **Fill gaps.** Read the batch results. For contradictions or thin evidence, run `library_search` across the whole library and targeted searches.
4. **Verify.** `verify_citation` for every source you will cite (existence, retraction, support).
5. **Synthesize.** Answer the question first, then evidence by sub-question, then disagreements and limitations. Every claim carries [@key]; every number appears in a fetched source. Distinguish established findings from single studies.
