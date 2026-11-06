import AppKit
import SieveSciCore
import SwiftUI
import UniformTypeIdentifiers

struct PromptInput: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var attachments: [URL] = []
    @State private var selection = 0
    @State private var lastEscape = Date.distantPast
    @FocusState private var focused: Bool
    /// The editor holds input-method text that is not committed yet (pinyin, kana …).
    @State private var composing = false

    var suggestions: [SlashCommandInfo] {
        guard text.hasPrefix("/"), !text.contains(" ") else { return [] }
        let q = text.dropFirst().lowercased()
        return model.commandCatalog.filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) || $0.name.lowercased().contains(q) }.prefix(12).map { $0 }
    }

    var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    var interrupts: Bool { model.running && text.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, c in
                        HStack(spacing: Theme.Space.s) {
                            Text("/\(c.name)").font(Theme.monoSmall).foregroundStyle(i == selection ? Theme.accent : .primary)
                            if !c.args.isEmpty { Text(c.args).font(Theme.monoTiny).foregroundStyle(.tertiary) }
                            Spacer(minLength: Theme.Space.m)
                            Text(L(c.summary)).font(Theme.meta).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, Theme.Space.s + 2).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).fill(i == selection ? Theme.accentSoft : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { complete(c) }
                    }
                }
                .padding(Theme.Space.xs)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.separator))
                .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.xs + 2) {
                            ForEach(attachments, id: \.self) { url in
                                HStack(spacing: Theme.Space.xs) {
                                    Image(systemName: icon(for: url)).foregroundStyle(.secondary)
                                    Text(url.lastPathComponent).lineLimit(1)
                                    Button { attachments.removeAll { $0 == url } } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain).foregroundStyle(.tertiary).font(.system(size: 9, weight: .bold))
                                }
                                .font(Theme.meta)
                                .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).fill(Theme.surface))
                            }
                        }
                    }
                }
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        // Text being composed in an input method (pinyin, kana …) is not in `text` yet, so
                        // the placeholder checks the editor for marked text while the field is focused.
                        // Marked text changes the editor's selection, so the selection notification says
                        // when composing starts and stops (polling 10× a second re-laid-out the window).
                        if !(focused && composing) {
                            Text(model.running ? L("Queue a message, or press Esc to interrupt…") : L("Ask a research question, paste a GitHub link, or type / for commands"))
                                .font(Theme.prose).foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    TextEditor(text: $text)
                        .font(Theme.prose)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 22, maxHeight: 180)
                        .fixedSize(horizontal: false, vertical: true)
                        .focused($focused)
                        .onKeyPress(.return, phases: .down) { press in
                            // Return while composing confirms the input method's candidate; it must not send.
                            if press.modifiers.contains(.shift) || Self.composing() { return .ignored }
                            if let c = suggestions[safe: selection], text != "/" + c.name { complete(c); return .handled }
                            send()
                            return .handled
                        }
                        .onKeyPress(.tab) {
                            if let c = suggestions[safe: selection] { complete(c); return .handled }
                            return .ignored
                        }
                        .onKeyPress(.upArrow) { if suggestions.isEmpty || Self.composing() { return .ignored }; selection = max(0, selection - 1); return .handled }
                        .onKeyPress(.downArrow) { if suggestions.isEmpty || Self.composing() { return .ignored }; selection = min(suggestions.count - 1, selection + 1); return .handled }
                        .onKeyPress(.escape) {
                            if Self.composing() { return .ignored }   // Esc cancels the composition
                            if model.running { model.interrupt(); return .handled }
                            if Date().timeIntervalSince(lastEscape) < 0.6 { model.submit("/rewind", attachments: []) }
                            lastEscape = Date()
                            return .handled
                        }
                        .onChange(of: text) { _, _ in selection = 0 }
                }
                HStack(spacing: Theme.Space.s) {
                    Menu {
                        Button(L("Attach files…")) { pickFiles() }
                        Button(L("Add a read-only folder…")) { pickReadOnlyFolder() }
                            .disabled(model.workspace == nil)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                            .frame(width: Theme.Control.icon, height: Theme.Control.icon)
                            .overlay(Rectangle().strokeBorder(Theme.rule))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help(L("Attach files, images, PDFs or data"))
                    .accessibilityLabel(L("Attach files, images, PDFs or data"))
                    SandboxMenu()
                    Spacer()
                    EffortMenu()
                    ModelMenu()
                    Button { if interrupts { model.interrupt() } else { send() } } label: {
                        Image(systemName: interrupts ? "stop.fill" : "arrow.up")
                            .font(.system(size: interrupts ? 10 : 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: Theme.Control.icon, height: Theme.Control.icon)
                            .background(Rectangle().fill(canSend || interrupts ? Theme.accent : Theme.accent.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend && !interrupts)
                    .help(interrupts ? L("Interrupt (Esc)") : L("Send (Enter)"))
                    .accessibilityLabel(interrupts ? L("Interrupt (Esc)") : L("Send (Enter)"))
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.m + 2)
            .padding(.bottom, Theme.Space.s + 2)
            .background(Rectangle().fill(Theme.raised))
            .overlay(Rectangle().strokeBorder(focused ? Theme.accent : Theme.ink, lineWidth: 1.5))
            .hardShadow(offset: 4, color: focused ? Theme.accent : Theme.ink)
            // Focus draws a heavier rule along the top edge, like a field on a form being filled in.
            .overlay(alignment: .top) { Rectangle().fill(Theme.accent).frame(height: focused ? 2 : 0) }
            .animation(Theme.Motion.hover, value: focused)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { attachments.append(url) } }
                    }
                }
                return true
            }
            .onPasteCommand(of: [.fileURL, .png, .tiff]) { providers in paste(providers) }
        }
        .onAppear {
            focused = true
            // Text typed before leaving (e.g. to Settings) comes back.
            if !model.draft.isEmpty { text = model.draft; model.draft = "" }
        }
        .onDisappear { if !text.isEmpty { model.draft = text } }
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { _ in
            let c = Self.composing()
            if c != composing { composing = c }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { _ in
            let c = Self.composing()
            if c != composing { composing = c }
        }
        .onChange(of: model.draft) { _, d in
            if !d.isEmpty { text = d; model.draft = ""; focused = true }
        }
    }

    /// The focused text view has input-method text that is not committed yet.
    static func composing() -> Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "tiff", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "csv", "tsv", "xlsx": return "tablecells"
        case "fasta", "fa", "fastq", "gb", "pdb", "cif", "sdf": return "atom"
        default: return "doc"
        }
    }

    func complete(_ c: SlashCommandInfo) {
        text = "/" + c.name + (c.args.isEmpty ? "" : " ")
        if c.args.isEmpty { send() }
    }

    func send() {
        let t = text
        let a = attachments
        text = ""
        attachments = []
        model.submit(t, attachments: a)
    }

    /// Lets agents read a folder outside the workspace (never write to it); the blind verifier cannot see it.
    func pickReadOnlyFolder() {
        guard let ws = model.workspace else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = L("Agents can read these folders but never change them.")
        guard panel.runModal() == .OK else { return }
        for u in panel.urls { try? ReadOnlyFolders.add(u, workspace: ws) }
        model.handle(.notice(L10n.f("Read-only folders: %@", ReadOnlyFolders.load(workspace: ws).map(\.lastPathComponent).joined(separator: ", "))))
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { attachments += panel.urls }
    }

    /// Pasted screenshots are saved into the workspace inputs/ folder and attached.
    func paste(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { attachments.append(url) } } }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { return }
                    let dir = (model.workspace ?? FileManager.default.temporaryDirectory).appendingPathComponent("inputs")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let url = dir.appendingPathComponent("pasted-\(Int(Date().timeIntervalSince1970)).png")
                    try? png.write(to: url)
                    DispatchQueue.main.async { attachments.append(url) }
                }
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Status bar: permission mode · model picker with context ring · quota

/// Icon, label and tint for each permission mode (title-bar menu).
enum PermissionModeChip {
    static func style(_ mode: PermissionMode) -> (icon: String, text: String, tint: Color) {
        switch mode {
        case .ask: return ("hand.raised", L("ask before edits & code"), .secondary)
        case .acceptEdits: return ("pencil", L("accept edits on"), Theme.accent)
        case .auto: return ("bolt", Seatbelt.available ? L("auto mode on · sandboxed") : L("auto mode on"), Theme.warn)
        case .plan: return ("pause.circle", L("plan mode on"), Theme.info)
        case .yolo: return ("exclamationmark.triangle", L("YOLO mode on · no sandbox"), Theme.bad)
        }
    }
}

/// Where agent commands may write: the sandbox, as a borderless menu in the composer.
struct SandboxMenu: View {
    @EnvironmentObject var model: AppModel

    static func label(_ m: SandboxMode) -> String {
        switch m {
        case .workspaceWrite: return L("Workspace write")
        case .workspaceWriteOffline: return L("Workspace write · offline")
        case .off: return L("No sandbox")
        }
    }

    var body: some View {
        Menu {
            Picker(L("Commands the agents run"), selection: model.sandboxSelection) {
                Text(L("Write workspace only, network on")).tag(SandboxMode.workspaceWrite)
                Text(L("Write workspace only, offline")).tag(SandboxMode.workspaceWriteOffline)
                Text(L("No sandbox")).tag(SandboxMode.off)
            }
            .pickerStyle(.inline)
        } label: {
            Label(Self.label(model.effectiveSandbox), systemImage: model.effectiveSandbox == .off ? "exclamationmark.shield" : "checkmark.shield")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(Theme.meta)
        .tint(model.effectiveSandbox == .off ? Theme.warn : .secondary)
        .help(L("Commands the agents run"))
    }
}

/// Model picker with the context ring; switching asks first (the prompt cache goes cold).
struct ModelMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var showUsage = false
    @State private var pendingSwitch: ModelRef?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Menu {
                ForEach(model.usableProviders, id: \.id) { p in
                    Section(p.displayName) {
                        ForEach(p.models, id: \.self) { m in
                            Button(m) { pendingSwitch = ModelRef(providerId: p.id, model: m) }
                        }
                    }
                }
                Divider()
                Button(L("Providers…")) { model.openSettings(.providers) }
            } label: {
                Text(model.meter.model.isEmpty ? L("no model") : model.meter.model)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(Theme.meta)
            .tint(.secondary)
            Button { showUsage.toggle() } label: { ContextRing(fill: model.meter.fill) }
                .buttonStyle(.plain)
                .popover(isPresented: $showUsage, arrowEdge: .top) { UsagePopover().environmentObject(model) }
        }
        .alert(L("Switch model?"), isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } })) {
            Button(L("Switch")) { if let r = pendingSwitch { model.switchMainModel(r) }; pendingSwitch = nil }
            Button(L("Cancel"), role: .cancel) { pendingSwitch = nil }
        } message: {
            Text(L("The conversation is kept, but the new model starts with a cold prompt cache: the next request pays full price for the whole context. Switch at a natural break."))
        }
    }
}

/// One quiet line under the composer: turns · steps | cache | tokens | jobs.
struct StatsLine: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let turns = model.items.filter { if case .user = $0.kind { return true }; return false }.count
        let steps = model.streams.values.joined().filter { if case .tool = $0.kind { return true }; return false }.count
        let m = model.meter
        let running = model.jobs.values.filter(\.running).count
        HStack(spacing: Theme.Space.s) {
            Text(L10n.f("%d turns", turns) + " · " + L10n.f("%d steps", steps))
            if m.session.promptTotal > 0 {
                divider
                Text(L10n.f("cache %d%%", Int(m.cacheHitRate * 100)))
                    .foregroundStyle(m.cacheHitRate > 0.7 ? Theme.ok : .secondary)
                    .help(L("Share of prompt tokens served from the provider's prefix cache this session"))
                divider
                Text(L10n.f("%@ in · %@ out", (m.session.promptTotal).formatted(.number.notation(.compactName)), m.session.output.formatted(.number.notation(.compactName))))
            }
            if running > 0 {
                divider
                Button { model.show(.jobs) } label: { Label(L10n.f("%d jobs", running), systemImage: "waveform") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .help(L("Background jobs stream live; the agent is notified when they finish or report errors"))
            }
        }
        .font(Theme.monoTiny)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
    }

    var divider: some View { Rectangle().fill(Theme.separator).frame(width: 1, height: 10) }
}

/// The small circle next to the model name: how full the context window is.
struct ContextRing: View {
    let fill: Double
    var color: Color { fill > 0.85 ? Theme.bad : (fill > 0.6 ? Theme.warn : Theme.accent) }
    var body: some View {
        ZStack {
            Circle().stroke(Theme.separator, lineWidth: 2)
            Circle().trim(from: 0, to: max(0.02, fill)).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .help(L10n.f("Context %d%% full", Int(fill * 100)))
    }
}

struct UsagePopover: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let m = model.meter
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(L("Context"))
            Text("\(m.lastPromptTokens.formatted()) / \(m.contextWindow.formatted()) " + L("tokens") + " (\(Int(m.fill * 100))%)").font(Theme.monoSmall)
            ProgressView(value: m.fill).tint(m.fill > 0.85 ? Theme.bad : Theme.accent)
            Divider()
            SectionLabel(L("This session"))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow { Text(L("Input (uncached)")); Text(m.session.input.formatted()) }
                GridRow { Text(L("Cache read")); Text(m.session.cacheRead.formatted()) }
                GridRow { Text(L("Cache write")); Text(m.session.cacheWrite.formatted()) }
                GridRow { Text(L("Output")); Text(m.session.output.formatted()) }
                GridRow { Text(L("Cache hit rate")); Text(String(format: "%.1f%%", m.cacheHitRate * 100)).foregroundStyle(m.cacheHitRate > 0.7 ? Theme.ok : .primary) }
            }.font(Theme.monoSmall)
            Divider()
            SectionLabel(L("Plans & balances"))
            ForEach(model.usableProviders, id: \.id) { p in
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.displayName + (model.quotas[p.id]?.plan.map { " · \($0)" } ?? "")).font(.callout.weight(.medium))
                    if let q = model.quotas[p.id] {
                        ForEach(Array(q.meters.enumerated()), id: \.offset) { _, meter in
                            HStack {
                                Text(QuotaText.title(meter)).foregroundStyle(.secondary)
                                Spacer()
                                Text(QuotaText.value(meter)).foregroundStyle(meter.exhausted ? Theme.bad : .primary)
                            }.font(Theme.monoTiny)
                            if let u = meter.usedFraction { ProgressView(value: min(max(u, 0), 1)).tint(u > 0.85 ? Theme.bad : Theme.accent) }
                            if let r = QuotaText.reset(meter) { Text(r).font(.caption2).foregroundStyle(.secondary) }
                        }
                        if let n = q.note { Text(L(n)).font(.caption2).foregroundStyle(.secondary) }
                    } else {
                        Text(L("loading…")).font(.caption2).foregroundStyle(.secondary)
                    }
                    let spend = SpendTracker.shared.spend(providerId: p.id)
                    Text(L10n.f("tracked spend: $%.4f today · $%.2f this month", spend.today, spend.month)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(L("Refresh")) { Task { await model.refreshQuotas() } }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
