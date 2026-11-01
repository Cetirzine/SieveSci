"""SieveSci persistent Python kernel driver.

Biomni-style "code as action": one long-lived interpreter whose globals persist across calls, so
data loaded in one step is available in the next. Protocol: one JSON request per line on stdin
({"id": ..., "code": ...}); one JSON reply per line on the original stdout. User code's stdout and
stderr are captured; new matplotlib figures are saved under SIEVESCI_FIGURES and reported.
"""
import io, json, os, sys, traceback, contextlib, time

_out = os.fdopen(os.dup(1), "w", buffering=1)
sys.stdout = io.StringIO()
FIG_DIR = os.environ.get("SIEVESCI_FIGURES", "figures")
_ns = {"__name__": "__main__"}
_fig_counter = [0]

try:
    import matplotlib
    matplotlib.use("Agg")
except Exception:
    matplotlib = None


def _save_figures():
    paths = []
    if matplotlib is None:
        return paths
    try:
        import matplotlib.pyplot as plt
    except Exception:
        return paths
    for num in plt.get_fignums():
        fig = plt.figure(num)
        os.makedirs(FIG_DIR, exist_ok=True)
        _fig_counter[0] += 1
        p = os.path.join(FIG_DIR, "fig_%s_%03d.png" % (time.strftime("%Y%m%d_%H%M%S"), _fig_counter[0]))
        fig.savefig(p, dpi=150, bbox_inches="tight")
        paths.append(os.path.abspath(p))
    plt.close("all")
    return paths


# Import name -> pip package, for the hint on a missing module.
_PIP = {"Bio": "biopython", "sklearn": "scikit-learn", "cv2": "opencv-python", "yaml": "pyyaml", "PIL": "pillow",
        "skimage": "scikit-image", "Crypto": "pycryptodome", "umap": "umap-learn", "docx": "python-docx",
        "dateutil": "python-dateutil", "bs4": "beautifulsoup4", "Levenshtein": "python-Levenshtein", "lxml": "lxml"}


def _format(exc):
    """The user's frames only (not this driver's), with an install hint for a missing module."""
    tb = traceback.TracebackException.from_exception(exc)
    tb.stack = traceback.StackSummary.from_list([f for f in tb.stack if not f.filename.endswith("kernel/driver.py")])
    text = "".join(tb.format())
    if isinstance(exc, ModuleNotFoundError) and exc.name:
        top = exc.name.split(".")[0]
        text += ("\nHint: `%s` is not installed for this kernel (%s). Install it with bash: \"%s\" -m pip install %s"
                 "  (or use a skill environment, skill_env)\n" % (top, sys.executable, sys.executable, _PIP.get(top, top)))
    return text


def _run(code):
    out, err = io.StringIO(), io.StringIO()
    # Compile first: an expression is echoed, anything else executed; one traceback, not a chained pair.
    try:
        compiled, is_expr = compile(code, "<cell>", "eval"), True
    except SyntaxError:
        try:
            compiled, is_expr = compile(code, "<cell>", "exec"), False
        except SyntaxError as exc:
            return "", "", "".join(traceback.format_exception_only(type(exc), exc))
    error = None
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            if is_expr:
                value = eval(compiled, _ns)
                if value is not None:
                    print(repr(value))
            else:
                exec(compiled, _ns)
        except BaseException as exc:
            error = _format(exc)
    return out.getvalue(), err.getvalue(), error


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except Exception:
        continue
    if req.get("reset"):
        _ns.clear()
        _ns["__name__"] = "__main__"
        _out.write(json.dumps({"id": req.get("id"), "stdout": "", "stderr": "", "error": None, "figures": []}) + "\n")
        continue
    o, e, err = _run(req.get("code", ""))
    figs = _save_figures()
    _out.write(json.dumps({"id": req.get("id"), "stdout": o, "stderr": e, "error": err, "figures": figs}) + "\n")
