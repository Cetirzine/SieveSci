#if DEBUG
import AppKit
import Foundation
import SieveSciCore

/// Sample research session for UI work and screenshots (`SIEVESCI_UI_DEMO=1`, debug builds only).
/// Content is fixture data, not interface copy, so it is not localized.
extension AppModel {
    func loadDemo() {
        let env = ProcessInfo.processInfo.environment
        if let a = env["SIEVESCI_UI_APPEARANCE"].flatMap(AppConfig.Appearance.init(rawValue:)) { config.appearance = a }
        if let e = env["SIEVESCI_UI_EFFORT"].flatMap(Effort.init(rawValue:)) { config.effort = e }
        config.permissionMode = .acceptEdits
        config.recentWorkspaces = ["/Users/demo/Research/kinase-screen", "/Users/demo/Research/metabolomics-2026"]

        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("crispr-offtarget")
        let fm = FileManager.default
        for d in ["data/emx1", "analysis", "figures", "notes"] { try? fm.createDirectory(at: ws.appendingPathComponent(d), withIntermediateDirectories: true) }
        for f in ["data/emx1/wt_rep1.csv", "data/emx1/wt_rep2.csv", "data/emx1/hf1_rep1.csv", "data/emx1/hf1_rep2.csv", "analysis/count_indels.py", "notes/plan.md"] {
            let u = ws.appendingPathComponent(f)
            if !fm.fileExists(atPath: u.path) { try? "sample\n".write(to: u, atomically: true, encoding: .utf8) }
        }
        let fig = ws.appendingPathComponent("figures/offtarget_rates.png")
        Self.drawDemoChart(to: fig)
        workspace = ws
        taskId = "emx1-hf1-offtarget"
        tasks = [("emx1-hf1-offtarget", Date().addingTimeInterval(-40)),
                 ("guide-design-vegfa", Date().addingTimeInterval(-26 * 3600)),
                 ("amplicon-qc", Date().addingTimeInterval(-3 * 86400))]
        taskTitles = ["emx1-hf1-offtarget": "Does SpCas9-HF1 reduce off-target editing at EMX1?",
                      "guide-design-vegfa": "Design guides for VEGFA exon 1", "amplicon-qc": "QC the amplicon run from March"]
        meter = ContextMeter(model: "deepseek-v4-pro", contextWindow: 128_000, lastPromptTokens: 41_300,
                             session: Self.decode(Usage.self, #"{"input":5200,"cacheRead":118000,"cacheWrite":9400,"output":6100,"reasoning":0}"#) ?? Usage())
        figures = [fig]
        changedFiles = ["analysis/count_indels.py", "figures/offtarget_rates.png"]

        let empty = (try? JSONCodec.parse("{}"))!
        let now = Date()
        func t(_ s: Double) -> Date { now.addingTimeInterval(-s) }
        func tool(_ id: String, _ name: String, _ summary: String, output: String = "", error: Bool = false, receipt: String? = nil,
                  start: Double, dur: Double?, live: [String] = [], diff: FileDiff? = nil) -> TranscriptItem {
            TranscriptItem(id: id, kind: .tool(ToolCallView(id: id, name: name, summary: summary, input: empty, output: output, isError: error,
                                                             receipt: receipt, started: t(start), ended: dur.map { t(start - $0) }, live: live, diff: diff)))
        }

        let oldPy = "import pandas as pd\n\ndef rate(df):\n    return df['indels'] / df['reads']\n"
        let newPy = "import pandas as pd\n\ndef rate(df):\n    reads = df['read_count']\n    return df['indel_reads'] / reads.where(reads > 0)\n"

        streams["checker-a1b2c3"] = [
            tool("c1", "read_file", "analysis/count_indels.py", output: "18 lines", start: 300, dur: 1),
            tool("c2", "verify_citation", "kleinstiver2016", output: "DOI resolves; title and year match", receipt: "R-0012", start: 298, dur: 2),
            TranscriptItem(id: "c3", kind: .assistant("No blocking issues. The off-target sites match the GUIDE-seq list in Kleinstiver et al. (2016).")),
        ]
        streams["verifier-77de01"] = [
            tool("v1", "python", "recompute indel rates from raw amplicon counts", start: 40, dur: nil,
                 live: ["loading data/emx1/hf1_rep1.csv (412,088 reads)", "loading data/emx1/hf1_rep2.csv (398,551 reads)", "site OT1: 0.04% (wt 12.8%)"]),
        ]
        cards = [
            "checker-a1b2c3": AgentCard(id: "checker-a1b2c3", role: .checker, parent: "main", purpose: "Review the analysis plan against the literature",
                                        started: t(302), ended: t(290), result: "Plan passes: hypotheses are falsifiable, controls cover both replicates."),
            "verifier-77de01": AgentCard(id: "verifier-77de01", role: .verifier, parent: "main", purpose: "Blind re-analysis of claim C2 from raw reads",
                                         started: t(42)),
            "worker-5c9e10": AgentCard(id: "worker-5c9e10", role: .worker, parent: "main", purpose: "Align the replicate-2 amplicons to the off-target sites",
                                       started: t(25)),
        ]

        let review = #"{"verdict":"pass","issues":[{"severity":"medium","what":"Replicate 2 has 18% fewer reads at OT3","evidence":"hf1_rep2.csv row 3"}],"required_actions":["Report per-replicate rates alongside the pooled rate"],"reasoning":"Design is sound; the read-depth gap does not change the conclusion."}"#

        streams["main"] = [
            TranscriptItem(id: "u1", kind: .user("Does SpCas9-HF1 reduce off-target editing at the EMX1 site compared with wild-type SpCas9? Use the amplicon data in data/emx1/.", attachments: [])),
            TranscriptItem(id: "th1", kind: .thinking("Search the literature for the GUIDE-seq off-target list first, then compute indel rates per site.", started: t(400), ended: t(394))),
            tool("t1", "literature_search", "SpCas9-HF1 off-target EMX1 GUIDE-seq", output: "6 results\n1. Kleinstiver 2016 Nature\n2. Tsai 2015 Nat Biotechnol", receipt: "R-0007", start: 392, dur: 3),
            TranscriptItem(id: "l1", kind: .literature(action: .added, key: "kleinstiver2016", title: "High-fidelity CRISPR–Cas9 nucleases with no detectable genome-wide off-target effects", detail: "Nature 529")),
            tool("t2", "bash", "ls data/emx1", output: "hf1_rep1.csv\nhf1_rep2.csv\nwt_rep1.csv\nwt_rep2.csv", receipt: "R-0008", start: 385, dur: 1),
            tool("t3", "python", "analysis/count_indels.py", output: "Traceback (most recent call last):\n  File \"analysis/count_indels.py\", line 4, in rate\nKeyError: 'reads'", error: true, start: 380, dur: 2),
            tool("t4", "edit_file", "analysis/count_indels.py", start: 370, dur: 1, diff: FileDiff.make(path: "analysis/count_indels.py", old: oldPy, new: newPy)),
            tool("t5", "python", "analysis/count_indels.py --plot figures/offtarget_rates.png", output: fig.path + "\nrates written for 4 sites", receipt: "R-0010", start: 360, dur: 6),
            TranscriptItem(id: "a1", kind: .assistant("""
            Indel rates at the four GUIDE-seq off-target sites, pooled over two replicates. The rate at a site is $r = n_{\\text{indel}} / N$, and the specificity gain is

            $$\\Delta = \\log_2 \\frac{r_{\\text{WT}}}{r_{\\text{HF1}}} \\approx 8.3 \\quad (p < 10^{-6})$$

            | Site | Wild-type | SpCas9-HF1 |
            |---|---|---|
            | EMX1 on-target | 38.2% | 36.9% |
            | OT1 | 12.8% | 0.04% |
            | OT2 | 3.1% | below detection |

            On-target activity is kept (`-1.3` points) while every off-target site drops below 0.1%. I registered this as claim **C2** and dispatched a blind verifier [@kleinstiver2016].
            """)),
            TranscriptItem(id: "ag1", kind: .agent("checker-a1b2c3")),
            TranscriptItem(id: "r1", kind: .review(kind: "plan", verdict: "pass", body: review)),
            TranscriptItem(id: "d1", kind: .deliberation(thread: "T1", from: "checker-a1b2c3", to: "main", kind: "disagree", text: "OT3 should not be pooled: replicate 2 is under-sequenced. Report it separately or drop it.")),
            TranscriptItem(id: "cm1", kind: .commit(hash: "9f3c2ab41e", subject: "Fix indel rate columns; add off-target figure", files: 3)),
            TranscriptItem(id: "ag2", kind: .agent("verifier-77de01")),
        ]
        running = true
        runStarted = t(42)
        spinnerVerb = "Pipetting"
        demoAsk = PermissionAsk(tool: "bash", summary: "Rscript analysis/stats.R --site EMX1 --test fisher", input: empty, effect: .executes,
                                rememberPattern: "bash(Rscript analysis/stats.R:*)")

        var plan = ResearchPlan(goal: "Test whether SpCas9-HF1 lowers off-target editing at EMX1 without losing on-target activity.")
        plan.stage = .verification
        plan.hypotheses = Self.decode([Hypothesis].self, """
        [{"id":"H1","statement":"HF1 reduces indel rates at GUIDE-seq off-target sites by at least 10-fold.","prediction":"OT1–OT3 < 0.5%","falsification":"Any off-target site with rate ≥ 10% of wild-type.","status":"supported","registeredAt":0},
         {"id":"H2","statement":"On-target activity stays within 5 points of wild-type.","prediction":"|Δ| < 5 points","falsification":"On-target drop > 5 points in either replicate.","status":"open","registeredAt":0}]
        """) ?? []
        plan.steps = Self.decode([PlanStep].self, """
        [{"id":"S1","title":"Collect the GUIDE-seq off-target list","detail":"","status":"done","checkpoint":false,"criteria":"","evidence":["R-0007"],"note":""},
         {"id":"S2","title":"Compute indel rates per site and replicate","detail":"","status":"done","checkpoint":false,"criteria":"","evidence":["R-0010"],"note":""},
         {"id":"S3","title":"Blind verification of the main claim","detail":"","status":"in_progress","checkpoint":true,"criteria":"","evidence":[],"note":""},
         {"id":"S4","title":"Statistics: Fisher's exact test per site","detail":"","status":"pending","checkpoint":false,"criteria":"","evidence":[],"note":""},
         {"id":"S5","title":"Re-sequence OT3 replicate 2","detail":"","status":"skipped","checkpoint":false,"criteria":"","evidence":[],"note":""}]
        """) ?? []
        self.plan = plan
        claims = Self.decode([Claim].self, """
        [{"id":"C1","statement":"On-target editing at EMX1 is 38.2% (WT) vs 36.9% (HF1).","successCriteria":"Recomputed from raw reads within 0.5 points.","evidence":["R-0010"],"dataPaths":["data/emx1"],"status":"verified","verdict":"Recomputed 38.1% / 36.9% from raw counts.","verifierReceipts":["R-0014"],"createdAt":0},
         {"id":"C2","statement":"HF1 lowers OT1 editing from 12.8% to 0.04%.","successCriteria":"Independent recount from the CSVs reproduces both rates.","evidence":["R-0010"],"dataPaths":["data/emx1"],"status":"verifying","verdict":null,"verifierReceipts":[],"createdAt":0}]
        """) ?? []
        contested = [(thread: "T1", kind: "disagree", issue: "OT3 pooled across replicates with unequal depth", reason: "Replicate 2 has 18% fewer reads at OT3.")]
        jobs = ["j1": JobState(id: "j1", label: "Rscript analysis/stats.R", lines: ["Fisher test OT1: p < 1e-12", "Fisher test OT2: p = 3.2e-6", "running OT3…"], running: true, unread: 1)]
        jobOrder = ["j1"]
        mainTab = .chat
        inspectorTab = .files
        showInspector = env["SIEVESCI_UI_INSPECTOR"] == "1"
        if let tab = env["SIEVESCI_UI_TAB"], let t = InspectorTab(rawValue: tab) { mainTab = .panel(t) }
        // SIEVESCI_UI_TRACE=<n>: a long project's trace (n audit events), for checking the Trace tab stays responsive.
        if let n = env["SIEVESCI_UI_TRACE"].flatMap(Int.init) {
            let t0 = Date().addingTimeInterval(-Double(n) * 20)
            trace = (0..<n).map { i -> TraceEvent in
                let review = i % 5 == 0, lit = i % 3 == 0
                let kind = review ? "review" : (lit ? "literature_search" : "bash")
                let text = lit ? "CRISPR base editing off-target \(i)" : "Rscript analysis/stats.R --replicate \(i % 7) [r\(i)]"
                let cat: TraceEvent.Category = review ? .agents : (lit ? .literature : .work)
                return TraceEvent(id: i, at: t0.addingTimeInterval(Double(i) * 20), actor: review ? "checker-1a2b" : "main",
                                  kind: kind, text: text, isError: i % 97 == 0, category: cat)
            }
        }
        if env["SIEVESCI_UI_SETTINGS"] == "1" { showSettingsPage = true }
        if env["SIEVESCI_UI_WELCOME"] == "1" { workspace = nil }
        if env["SIEVESCI_UI_EMPTY"] == "1" {
            streams = ["main": []]; cards = [:]; contested = []; demoAsk = nil; running = false
            meter = ContextMeter(model: "deepseek-v4-pro", contextWindow: 128_000)
        }
        if let path = env["SIEVESCI_UI_SNAPSHOT"] { Self.snapshotWindow(to: path) }
    }

    /// `SIEVESCI_UI_SNAPSHOT=<file.png>`: renders the window into a PNG and quits. The app draws its own
    /// view, so no screen-recording permission is needed for before/after comparisons.
    static func snapshotWindow(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let v = w.contentView?.superview ?? w.contentView {
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
            NSApp.terminate(nil)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// A small bar chart for the figure previews.
    static func drawDemoChart(to url: URL) {
        let size = NSSize(width: 640, height: 400)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        let values: [(CGFloat, CGFloat)] = [(38.2, 36.9), (12.8, 0.04), (3.1, 0.01), (1.9, 0.02)]
        NSColor(white: 0.85, alpha: 1).setFill(); NSRect(x: 60, y: 50, width: 540, height: 1).fill()
        for (i, v) in values.enumerated() {
            let x = 80 + CGFloat(i) * 130
            NSColor(srgbRed: 0.6, green: 0.62, blue: 0.68, alpha: 1).setFill()
            NSRect(x: x, y: 51, width: 44, height: v.0 * 8).fill()
            NSColor(srgbRed: 0.30, green: 0.42, blue: 1.0, alpha: 1).setFill()
            NSRect(x: x + 50, y: 51, width: 44, height: max(2, v.1 * 8)).fill()
        }
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}
#endif
