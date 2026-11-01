---
name: biomni-tools
description: Use Biomni's biomedical tool library and data lake from the Python kernel.
metadata:
  source: builtin
---

# Biomni tools (snap-stanford/Biomni, Apache-2.0)

1. `bio_tool_search` with what you need; it returns `module.function(params)` and matching data-lake datasets.
2. If biomni is not installed: `pip install biomni` (ask before installing). Data lake path: `$BIOMNI_DATA_PATH`.
3. Call from `python`: `from biomni.tool.genetics import liftover_coordinates; r = liftover_coordinates(...); print(r)`. Always print the result — Biomni functions return research logs as strings.
4. Treat Biomni outputs like any other tool output: cite the receipt, check numbers, and verify claims.
