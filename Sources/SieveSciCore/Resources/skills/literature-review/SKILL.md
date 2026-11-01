---
name: literature-review
description: Write a multi-perspective literature review with an outline and cited sections. Adapted from Stanford STORM / Co-STORM.
metadata:
  source: builtin
---

# Multi-perspective literature review (after STORM / Co-STORM, MIT)

1. **Discover perspectives.** Search broadly (web + literature) and list 4–6 distinct perspectives on the topic (e.g. molecular mechanism, clinical evidence, methods/measurement, controversies, translational outlook).
2. **Perspective-guided questioning.** For each perspective, write the questions an expert with that perspective would ask; research them (`dispatch` map over perspectives works well). Collect sources into the library.
3. **Outline.** Draft a hierarchical outline from what was found (not from memory). Keep sections the evidence supports.
4. **Write section by section.** Each paragraph cites [@key] sources; quote numbers exactly. Use `library_search` to find supporting passages, then `library_search` with stance `contradicting` and `paper_graph` (citing papers) for contradicting ones, before stating a consensus.
5. **Review.** Check every citation with `verify_citation`; mark open questions explicitly. Export with `/report`.
