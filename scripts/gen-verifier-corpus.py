"""Generates Resources/eval/verifier-corpus.json: claims over small datasets with known truth.
Standard library only; every label is checked here with an exact or numerically integrated test."""
import json, math, random, statistics as st, sys

def t_pvalue(a, b):
    """Welch two-sided p-value, t distribution integrated numerically."""
    ma, mb, va, vb = st.mean(a), st.mean(b), st.variance(a), st.variance(b)
    na, nb = len(a), len(b)
    se = math.sqrt(va / na + vb / nb)
    if se == 0: return 1.0
    t = abs(ma - mb) / se
    df = (va / na + vb / nb) ** 2 / ((va / na) ** 2 / (na - 1) + (vb / nb) ** 2 / (nb - 1))
    c = math.exp(math.lgamma((df + 1) / 2) - math.lgamma(df / 2)) / math.sqrt(df * math.pi)
    f = lambda x: c * (1 + x * x / df) ** (-(df + 1) / 2)
    n, hi = 20000, t + 60
    h = (hi - t) / n
    tail = (f(t) + f(hi) + sum((4 if i % 2 else 2) * f(t + i * h) for i in range(1, n))) * h / 3
    return min(1.0, 2 * tail)

def bh(ps):
    m = len(ps); order = sorted(range(m), key=lambda i: ps[i]); q = [0.0] * m; prev = 1.0
    for rank, i in reversed(list(enumerate(order, 1))):
        prev = min(prev, ps[i] * m / rank); q[i] = prev
    return q

def pearson(x, y):
    mx, my = st.mean(x), st.mean(y)
    return sum((a - mx) * (b - my) for a, b in zip(x, y)) / math.sqrt(sum((a - mx) ** 2 for a in x) * sum((b - my) ** 2 for b in y))

def ranks(v):
    o = sorted(range(len(v)), key=lambda i: v[i]); r = [0.0] * len(v)
    for k, i in enumerate(o): r[i] = k + 1
    return r

def fisher_two_sided(a, b, c, d):
    n1, n2, k = a + b, c + d, a + c
    p = lambda x: math.comb(n1, x) * math.comb(n2, k - x) / math.comb(n1 + n2, k)
    p0 = p(a)
    return sum(p(x) for x in range(max(0, k - n2), min(k, n1) + 1) if p(x) <= p0 * (1 + 1e-9))

def csv(header, rows):
    return ",".join(header) + "\n" + "\n".join(",".join(f"{v:.4g}" if isinstance(v, float) else str(v) for v in r) for r in rows) + "\n"

R = random.Random(20261016)
C = []
def case(id, truth, statement, criteria, files, check, note=""):
    assert check, id
    C.append({"id": id, "truth": truth, "statement": statement, "criteria": criteria, "files": files, "note": note})

# 1–2: two-group difference, true and null (B is a shuffled copy of A's values)
a = [R.gauss(10, 1) for _ in range(12)]; b = [R.gauss(14, 1) for _ in range(12)]
case("diff-true", "verified", "Expression of the reporter is higher in treated than in control samples.",
     "Welch t-test, two-sided p < 0.05, treated mean > control mean",
     {"data/reporter.csv": csv(["sample", "group", "expression"], [(f"s{i}", g, v) for i, (g, v) in enumerate([("control", x) for x in a] + [("treated", x) for x in b])])},
     t_pvalue(a, b) < 1e-6 and st.mean(b) > st.mean(a))
a = [R.gauss(10, 1) for _ in range(12)]; b = a[:]; R.shuffle(b); b = [x + R.choice([-0.01, 0.01]) for x in b]
case("diff-null", "refuted", "Expression of the reporter is higher in treated than in control samples.",
     "Welch t-test, two-sided p < 0.05, treated mean > control mean",
     {"data/reporter.csv": csv(["sample", "group", "expression"], [(f"s{i}", g, v) for i, (g, v) in enumerate([("control", x) for x in a] + [("treated", x) for x in b])])},
     t_pvalue(a, b) > 0.5)

# 3: multiple-testing trap — one of 20 genes is nominally significant, nothing survives BH
while True:
    genes = {}
    for g in range(20):
        ctl = [R.gauss(5, 1) for _ in range(10)]
        trt = [R.gauss(5 + (1.1 if g == 6 else 0), 1) for _ in range(10)]
        genes[f"G{g + 1}"] = (ctl, trt)
    ps = [t_pvalue(*genes[k]) for k in genes]
    if 0.01 < ps[6] < 0.05 and min(bh(ps)) > 0.1 and sorted(ps)[0] == ps[6]: break
rows = [(k, grp, i, v) for k, (ctl, trt) in genes.items() for grp, vals in (("control", ctl), ("treated", trt)) for i, v in enumerate(vals)]
case("multiple-tests-trap", "refuted", "Gene G7 is differentially expressed between treated and control.",
     "Welch t-test per gene across all 20 genes, Benjamini–Hochberg q < 0.05",
     {"data/genes_long.csv": csv(["gene", "group", "replicate", "expression"], rows)}, True,
     note=f"G7 nominal p = {ps[6]:.3f}, smallest BH q = {min(bh(ps)):.2f}")

# 4–5: dose–response correlation, true and flat
dose = [0.5 * i for i in range(1, 31)]
resp = [2 + 0.8 * d + R.gauss(0, 1) for d in dose]
case("corr-true", "verified", "Response increases with dose.", "Pearson r > 0.7",
     {"data/dose_response.csv": csv(["dose", "response"], list(zip(dose, resp)))}, pearson(dose, resp) > 0.9)
while True:
    flat = [R.gauss(10, 2) for _ in dose]
    rho = pearson(ranks(dose), ranks(flat))
    if abs(rho) < 0.15: break
case("corr-flat", "refuted", "Response increases with dose.", "Spearman rho > 0.5",
     {"data/dose_response.csv": csv(["dose", "response"], list(zip(dose, flat)))}, True, note=f"rho = {rho:.2f}")

# 6–7: survival proportions, true and reversed direction
t_alive, c_alive = 35, 20
assert fisher_two_sided(t_alive, 50 - t_alive, c_alive, 50 - c_alive) < 0.01
rows = [(f"p{i}", "treated", int(i < t_alive)) for i in range(50)] + [(f"p{50 + i}", "control", int(i < c_alive)) for i in range(50)]
R.shuffle(rows)
case("survival-true", "verified", "More treated than control patients were alive at 12 months.",
     "Fisher exact test p < 0.05 and a higher proportion alive in the treated arm",
     {"data/survival_12m.csv": csv(["patient", "arm", "alive_12m"], rows)}, True)
case("survival-reversed", "refuted", "Fewer treated than control patients were alive at 12 months.",
     "Fisher exact test p < 0.05 and a lower proportion alive in the treated arm",
     {"data/survival_12m.csv": csv(["patient", "arm", "alive_12m"], rows)}, True, note="direction is the opposite of the data")

# 8: dose–response curve fit (IC50 0.3 µM): a claim of potency below 0.05 µM is false
conc = [0.01 * 3 ** k for k in range(10)]
inh = [(c, rep, 100 / (1 + (0.3 / c) ** 1.0) + R.gauss(0, 2)) for c in conc for rep in range(3)]
case("ic50-overstated", "refuted", "The compound inhibits the enzyme with an IC50 below 0.05 µM.",
     "IC50 from a four-parameter logistic fit to percent inhibition, point estimate < 0.05 µM",
     {"data/inhibition.csv": csv(["conc_uM", "replicate", "inhibition_pct"], inh)}, True, note="simulated IC50 = 0.3 µM")

out = {"about": "Claims over small datasets with known truth, for evaluating SieveSci's blind verifier. "
                "Regenerate with gen_verifier.py; every label is checked there.", "cases": C}
json.dump(out, open(sys.argv[1], "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print(len(C), "cases;", sum(c["truth"] == "verified" for c in C), "true")
