import AppKit
import SieveSciCore
import SwiftUI

@main
struct SieveSciApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("SieveSci") {
            RootView()
                .environmentObject(model)
                .environment(\.modelLink, model.link)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(model.config.appearance == .light ? .light : model.config.appearance == .dark ? .dark : nil)
                .id(model.language)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("About SieveSci")) { Credits.showAboutPanel() }
                Button(L("Check for Updates…")) { Task { await Updater.shared.check(manual: true) } }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L("Settings") + "…") { model.showSettingsPage = true }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button(L("New Task")) { model.startSession() }.keyboardShortcut("n")
                Button(L("Open Workspace…")) { pickWorkspace() }.keyboardShortcut("o")
            }
            CommandMenu(L("Agent")) {
                Button(L("Interrupt")) { model.interrupt() }.keyboardShortcut(".", modifiers: .command)
                Button(L("Cycle Permission Mode")) { model.cyclePermissionMode() }.keyboardShortcut(.tab, modifiers: .shift)
                Button(L("Fork Task")) { model.fork() }
                Button(L("Review Now")) { model.submit("/review", attachments: []) }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button(L("Export Report…")) { model.submit("/report", attachments: []) }
                Button(L("Refresh Catalogs & Leaderboards")) { model.submit("/refresh", attachments: []) }
            }
            CommandMenu(L("View")) {
                Button(L("Toggle Research Panel")) { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                ForEach(Array(MainTab.all.enumerated()), id: \.offset) { i, t in
                    Button(t.title) { model.showSettingsPage = false; model.mainTab = t }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
                Divider()
                ForEach(Array(InspectorTab.side.enumerated()), id: \.offset) { i, t in
                    Button(t.title) { model.show(t) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.command, .option])
                }
            }
        }
    }

    func pickWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Open Workspace")
        if panel.runModal() == .OK, let url = panel.url { model.open(workspace: url) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) { Signals.ignoreBrokenPipes() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM executables start as background processes; make this a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = Brand.appIcon
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Updater.shared.installOnQuit() }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AccentTheme.storageKey) private var accent = AccentTheme.blue.rawValue
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    var body: some View {
        Group {
            if model.showSettingsPage {
                SettingsPage()
            } else {
                HStack(spacing: 0) {
                    if sidebarVisible {
                        SidebarView(collapse: { withAnimation(.easeOut(duration: 0.18)) { sidebarVisible = false } })
                            .frame(width: 248)
                            .transition(.move(edge: .leading))
                        Rectangle().fill(Theme.hairline).frame(width: 1)
                    }
                    if model.workspace == nil {
                        WelcomeView(sidebarVisible: $sidebarVisible)
                    } else {
                        MainArea(sidebarVisible: $sidebarVisible)
                            .frame(minWidth: 400, maxWidth: .infinity)
                            .inspector(isPresented: $model.showInspector) {
                                InspectorView()
                                    .inspectorColumnWidth(min: 280, ideal: 340, max: 600)
                            }
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.canvas)
        .tint(Theme.accent)
        .environment(\.locale, Locale(identifier: L10n.resolved))
        .id(accent)
    }
}

/// App mark: the aurora ghost, then the name.
struct AppMark: View {
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            BrandLogo(size: 32)
            Text("SieveSci").font(.system(size: 18, weight: .semibold))
        }
    }
}

// MARK: - Sidebar: new task · workspaces with their tasks · settings

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    var collapse: () -> Void

    var others: [String] { model.config.recentWorkspaces.filter { $0 != model.workspace?.path } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                AppMark()
                Spacer()
                Button(action: collapse) { Image(systemName: "sidebar.left") }
                    .buttonStyle(QuietIconButtonStyle())
                    .help(L("Hide sidebar"))
                    .accessibilityLabel(L("Hide sidebar"))
            }
            .padding(.top, 44)
            .padding(.horizontal, Theme.Space.l)

            Button { model.showSettingsPage = false; model.mainTab = .chat; model.startSession() } label: {
                Label(L("New task"), systemImage: "plus")
            }
            .buttonStyle(.action)
            .environment(\.actionButtonFills, true)
            .disabled(model.workspace == nil)
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.l)

            if !model.needsYou.isEmpty { NeedsYouList().padding(.top, Theme.Space.l) }

            HStack(spacing: Theme.Space.xs) {
                SectionLabel(L("Workspace"))
                Spacer()
                Button { pickWorkspace() } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(QuietIconButtonStyle())
                    .help(L("Open Workspace…"))
                    .accessibilityLabel(L("Open Workspace…"))
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xs)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let ws = model.workspace {
                        HStack(spacing: 0) {
                            row(icon: "folder.fill", title: ws.lastPathComponent, tint: Theme.accent).help(ws.path)
                            disclosure(ws.path)
                            newTaskButton { model.showSettingsPage = false; model.mainTab = .chat; model.startSession() }
                        }
                        if model.isFolderOpen(ws.path) {
                            if model.tasks.isEmpty { noTasks }
                            ForEach(model.tasks, id: \.id) { t in
                                TaskRow(id: t.id, modified: t.modified)
                            }
                        }
                    }
                    ForEach(others, id: \.self) { path in
                        HStack(spacing: 0) {
                            Button { model.open(workspace: URL(fileURLWithPath: path)) } label: {
                                HStack(spacing: 0) {
                                    row(icon: "folder", title: (path as NSString).lastPathComponent, tint: .secondary)
                                    // A conversation here is still working in the background.
                                    if model.backgroundWorkspaces.values.contains(URL(fileURLWithPath: path).standardizedFileURL.path) {
                                        RoleGhostBadge(role: .main, working: true, size: 18).padding(.trailing, Theme.Space.xs)
                                    }
                                }
                            }
                            .buttonStyle(HoverRowStyle(radius: Theme.Radius.s + 2))
                            .help(path)
                            disclosure(path)
                            newTaskButton { model.showSettingsPage = false; model.mainTab = .chat; model.open(workspace: URL(fileURLWithPath: path), newTask: true) }
                        }
                        if model.isFolderOpen(path) {
                            let list = model.folderTasks[path] ?? []
                            if list.isEmpty { noTasks }
                            ForEach(list, id: \.id) { t in
                                TaskRow(id: t.id, modified: t.modified, folder: path)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.s)
            }
            // Folders left expanded list their conversations again after a switch or a background run.
            .task(id: model.workspace?.path) { model.refreshOpenFolders() }
            .onChange(of: model.backgroundTasks) { _, _ in model.refreshOpenFolders() }

            UpdateBanner().padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.s)

            Button { model.showSettingsPage = true } label: {
                Label(L("Settings"), systemImage: "gearshape")
                    .font(Theme.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(height: Theme.Control.row)
            }
            .buttonStyle(HoverRowStyle(radius: Theme.Radius.s + 2))
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.m)
        }
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.separator).frame(width: 1) }
    }

    var noTasks: some View {
        Text(L("No tasks yet")).font(Theme.meta).foregroundStyle(.tertiary)
            .padding(.leading, 38).padding(.vertical, Theme.Space.xs)
    }

    /// "−" / "+" beside each folder row: shows or hides its conversations, without switching to it.
    func disclosure(_ path: String) -> some View {
        let open = model.isFolderOpen(path)
        let label = open ? L("Collapse folder") : L("Expand folder")
        return Button { withAnimation(Theme.Motion.hover) { model.setFolder(path, open: !open) } } label: {
            Image(systemName: open ? "minus" : "plus")
                .font(.system(size: 7, weight: .heavy))
                .frame(width: 13, height: 13)
                .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: 1))
        }
        .buttonStyle(QuietIconButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    /// "New conversation in this folder", beside each folder row.
    func newTaskButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "square.and.pencil") }
            .buttonStyle(QuietIconButtonStyle())
            .help(L("New conversation in this folder"))
            .accessibilityLabel(L("New conversation in this folder"))
            .padding(.trailing, Theme.Space.xs)
    }

    func row(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: Theme.Space.s + 2) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint).frame(width: 18)
            Text(title).font(Theme.body).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Control.row)
        .contentShape(Rectangle())
    }

    func pickWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Open Workspace")
        if panel.runModal() == .OK, let url = panel.url { model.open(workspace: url) }
    }
}

/// One conversation in the sidebar. Hover shows × (delete); right-click has the rest.
struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let modified: Date
    /// The folder of a conversation outside the open workspace; nil for the open one's.
    var folder: String? = nil
    @State private var hovering = false

    var selected: Bool { folder == nil && id == model.taskId }

    func openIt() {
        model.showSettingsPage = false
        if let folder {
            model.mainTab = .chat
            model.open(workspace: URL(fileURLWithPath: folder), task: id)
        } else if !selected {
            model.startSession(task: id)
        }
    }

    var body: some View {
        Button(action: openIt) { label }
        .buttonStyle(HoverRowStyle(radius: 0))
        .overlay(alignment: .trailing) {
            if hovering, folder == nil {
                Button { model.deleteTask(id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(QuietIconButtonStyle())
                    .help(L("Delete conversation…"))
                    .accessibilityLabel(L("Delete conversation…"))
                    .padding(.trailing, 2)
                    .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(Theme.Motion.hover) { hovering = h } }
        .help(model.taskTitles[id] == nil ? id : model.title(of: id) + "\n" + id)
        .contextMenu {
            if let folder {
                // Everything else acts on the open workspace: open the folder first.
                Button(L("Copy conversation ID")) { model.copyToPasteboard(id) }
                Button(L("Show in Finder")) { model.revealTask(id, in: folder) }
            } else {
                Button(L("Rename…")) { model.renameTask(id) }
                Button(L("Copy conversation ID")) { model.copyToPasteboard(id) }
                Button(L("Copy as Markdown")) { model.copyToPasteboard(model.taskMarkdown(id)) }
                Button(L("Export Markdown…")) { model.exportTaskMarkdown(id) }
                Divider()
                if !selected { Button(L("Reference in the open conversation")) { model.referenceTask(id) } }
                Button(L("Fork conversation")) { model.forkTask(id) }
                Button(L("Show in Finder")) { model.revealTask(id) }
                Divider()
                Button(L("Delete conversation…"), role: .destructive) { model.deleteTask(id) }
            }
        }
    }

    var label: some View {
        HStack(spacing: Theme.Space.s) {
            Text(model.title(of: id)).font(Theme.body).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Theme.Space.xs)
            if hovering, folder == nil {
                Color.clear.frame(width: Theme.Control.icon - 6, height: 1)   // room for ×
            } else if let stage = model.attention[id]?.stage, stage.showsChip {
                StageChip(stage: stage)
            } else if (selected && model.running) || model.backgroundTasks.contains(id) {
                RoleGhostBadge(role: .main, working: true, size: 20)
            } else {
                Text(modified.formatted(.relative(presentation: .named, unitsStyle: .narrow).locale(Locale(identifier: L10n.resolved))))
                    .font(Theme.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 38).padding(.trailing, Theme.Space.s)
        .frame(height: Theme.Control.row)
        .background(Rectangle().fill(selected ? Theme.selection : .clear))
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.accent).frame(width: 2).padding(.leading, 26) }
        }
        .animation(Theme.Motion.hover, value: model.taskId)
    }
}

/// A task's stage as a small label: whom it waits for and what it needs.
struct StageChip: View {
    let stage: TaskStage

    var tint: Color {
        switch stage {
        case .answer, .review: return Theme.warn
        case .blocked: return Theme.bad
        default: return Theme.info
        }
    }

    var body: some View {
        Chip(text: stage.label, tint: tint)
            .lineLimit(1)
            .help(stage.detail)
            .transition(.scale(scale: 0.9, anchor: .trailing).combined(with: .opacity))
    }
}

/// dsh-superagent's first question, "does anything need me now?": tasks waiting for the user across
/// workspaces. Absent when nothing does.
struct NeedsYouList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel(L("Needs you") + " · \(model.needsYou.count)")
                .padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.xs)
            ForEach(model.needsYou, id: \.id) { item in
                Button { model.openAttention(item.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Space.s) {
                            Text(model.title(of: item.id)).font(Theme.body).lineLimit(1)
                            Spacer(minLength: Theme.Space.xs)
                            StageChip(stage: item.attention.stage)
                        }
                        if !item.attention.stage.detail.isEmpty {
                            Text(item.attention.stage.detail).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if item.attention.workspace != model.workspace?.standardizedFileURL.path {
                            Text((item.attention.workspace as NSString).lastPathComponent).font(Theme.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs + 2)
                    .overlay(FrameStroke(provisional: true, color: Theme.warn.opacity(0.55)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle(radius: 0))
                .padding(.bottom, Theme.Space.xs)
                .appearPop()
            }
        }
        .padding(.horizontal, Theme.Space.s)
    }
}

// MARK: - Main area: title bar · tabs · content

struct MainArea: View {
    @EnvironmentObject var model: AppModel
    @Binding var sidebarVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            TopBar(sidebarVisible: $sidebarVisible)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            switch model.mainTab {
            case .chat:
                ChatView()
            case .panel(let t):
                ScrollView {
                    Group {
                        switch t {
                        case .activity: ActivityPanel()
                        case .plan: PlanPanel()
                        case .claims: ClaimsPanel()
                        case .library: LibraryPanel()
                        default: NotebookPanel()
                        }
                    }
                    .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.xl)
                    .frame(maxWidth: .infinity)
                }
                .background(Theme.canvas)
                .task { model.refreshSidePanels() }
            }
        }
        .background(Theme.canvas)
    }
}

struct TopBar: View {
    @Namespace private var tabs
    @EnvironmentObject var model: AppModel
    @Binding var sidebarVisible: Bool
    @State private var width: CGFloat = 1000

    /// The same title as the sidebar row: the user's name for it, the generated title, or (until one
    /// arrives) the first question.
    var title: String {
        if let t = model.taskTitles[model.taskId] { return t }
        for it in model.items { if case .user(let t, _) = it.kind { return String(t.prefix(60)) } }
        return L("New task")
    }

    func badge(_ t: MainTab) -> Int {
        switch t {
        case .panel(.claims): return model.contested.count + model.claims.filter { $0.status == .verifying }.count
        default: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                if !sidebarVisible {
                    Button { withAnimation(.easeOut(duration: 0.18)) { sidebarVisible = true } } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(QuietIconButtonStyle())
                        .help(L("Show sidebar"))
                        .accessibilityLabel(L("Show sidebar"))
                }
                Text(title).font(.system(size: 17, weight: .bold)).tracking(-0.4).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 300, alignment: .leading)
                    .layoutPriority(1)
                // Drop the less important items first when the column is narrow.
                if width > 720 { ModeMenu() }
                if width > 900 { JobsMenu() }
                Spacer(minLength: Theme.Space.m)
                if width > 560 { ResearchStatus().fixedSize() }
                HStack(spacing: Theme.Space.xs) {
                    Button { model.submit("/report", attachments: []) } label: { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(QuietIconButtonStyle())
                        .help(L("Export Report…"))
                        .accessibilityLabel(L("Export Report…"))
                    Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                        .buttonStyle(QuietIconButtonStyle())
                        .help(L("Research panel"))
                        .accessibilityLabel(L("Research panel"))
                }
                .fixedSize()
                .layoutPriority(2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xl) {
                ForEach(MainTab.all, id: \.self) { t in
                    let selected = model.mainTab == t
                    Button { withAnimation(Theme.Motion.allowed ? Theme.Motion.settle : nil) { model.mainTab = t } } label: {
                        HStack(spacing: Theme.Space.xs) {
                            Text(t.title)
                            if badge(t) > 0 {
                                Text("\(badge(t))").font(Theme.label)
                                    .foregroundStyle(Theme.paper)
                                    .padding(.horizontal, 4).frame(height: 15)
                                    .background(Rectangle().fill(Theme.warn))
                                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        }
                        .font(Theme.body.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? Theme.accent : .secondary)
                        .padding(.bottom, Theme.Space.s)
                        // One underline that slides between tabs.
                        .overlay(alignment: .bottom) {
                            if selected { Rectangle().fill(Theme.accent).frame(height: 2).matchedGeometryEffect(id: "tab-underline", in: tabs) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            }
        }
        .padding(.leading, sidebarVisible ? Theme.Space.xl : 80)
        .padding(.trailing, Theme.Space.l)
        .padding(.top, Theme.Space.l)
        .background(Theme.canvas)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { width = g.size.width }
                .onChange(of: g.size.width) { _, w in width = w }
        })
    }
}

/// Permission mode as a borderless menu in the title bar.
struct ModeMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let m = PermissionModeChip.style(model.config.permissionMode)
        Menu {
            ForEach([PermissionMode.ask, .acceptEdits, .auto, .plan], id: \.self) { mode in
                Button { model.config.permissionMode = mode } label: {
                    Label(PermissionModeChip.style(mode).text, systemImage: PermissionModeChip.style(mode).icon)
                }
            }
        } label: {
            Label(m.text, systemImage: m.icon)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .font(Theme.monoTiny)
        .tint(.secondary)
        .foregroundStyle(.secondary)
        .help(L("(⇧⇥ to cycle)"))
    }
}

/// "2 background jobs running ⌄": lists jobs; picking one opens its log.
struct JobsMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let running = model.jobOrder.compactMap { model.jobs[$0] }.filter(\.running)
        if !running.isEmpty {
            Menu {
                ForEach(running) { j in
                    Button(j.id + " · " + j.label) { model.show(.jobs) }
                }
            } label: {
                Text(L10n.f("%d background jobs running", running.count))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(Theme.monoTiny)
            .tint(Theme.accent)
        }
    }
}

/// Research state at a glance: stage, grounding, verified / contested claims.
struct ResearchStatus: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if model.plan.goal.isEmpty == false || model.plan.stage != .scoping {
                Button { model.mainTab = .panel(.plan) } label: {
                    Label(L(model.plan.stage.rawValue), systemImage: "flag")
                }
                .buttonStyle(.plain)
                .help(L("Stage"))
            }
            if let g = model.bench?.services.research.hasGrounding() {
                HStack(spacing: Theme.Space.s) {
                    Label(L("Web"), systemImage: g.web ? "checkmark.circle.fill" : "globe")
                        .foregroundStyle(g.web ? Theme.ok : .secondary)
                    Label(L("Literature"), systemImage: g.literature ? "checkmark.circle.fill" : "books.vertical")
                        .foregroundStyle(g.literature ? Theme.ok : .secondary)
                }
                .labelStyle(.titleAndIcon)
                .help(L("Grounding gate: both searches must succeed before planning, claims and checkpoints"))
                .accessibilityLabel(L("Grounding gate: both searches must succeed before planning, claims and checkpoints"))
            }
            if !model.claims.isEmpty {
                let verified = model.claims.filter { $0.status == .verified }.count
                Button { model.mainTab = .panel(.claims) } label: {
                    Label(L10n.f("%d/%d verified", verified, model.claims.count), systemImage: "checkmark.seal")
                        .foregroundStyle(verified == model.claims.count ? Theme.ok : .secondary)
                }
                .buttonStyle(.plain)
            }
            if !model.contested.isEmpty {
                Button { model.mainTab = .panel(.claims) } label: {
                    Label("\(model.contested.count)", systemImage: "exclamationmark.bubble.fill").foregroundStyle(Theme.warn)
                }
                .buttonStyle(.plain)
                .help(L("Unresolved disagreements between agents — your call"))
            }
        }
        // One framed instrument readout instead of loose labels.
        .font(Theme.monoTiny)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.s + 2)
        .frame(height: 26)
        .overlay(FrameStroke())
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @Binding var sidebarVisible: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(alignment: .bottom, spacing: Theme.Space.m) {
                        DotMatrixText(text: "SieveSci", rows: 18, dot: 4.5, gap: 1.5)
                        LabelTab(text: SieveSci.version).padding(.bottom, 4)
                    }
                    Text(L("Welcome to SieveSci")).font(Theme.display).tracking(-0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("A research agent for biology and chemistry that searches before it speaks, plans with checkpoints, and has every significant claim independently verified."))
                        .font(Theme.prose).foregroundStyle(.secondary).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.xl)
                .overlay(CropMarks(length: 12, inset: 0))
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SectionLabel(L("Get started"))
                    let models = model.modelStatus
                    SetupStep(number: 1, done: models.ready, title: L("Connect a model"), detail: models.text) {
                        Button(models.ready ? L("Change…") : L("Set up…")) { model.openSettings(.providers) }
                            .buttonStyle(.action(models.ready ? .secondary : .primary, width: Theme.Control.buttonWidth))
                    }
                    let search = model.searchStatus
                    SetupStep(number: 2, done: search.ready, title: L("Web search"), detail: search.text, optional: true) {
                        Button(L("Change…")) { model.openSettings(.search) }
                            .buttonStyle(.action(width: Theme.Control.buttonWidth))
                    }
                    SetupStep(number: 3, done: false, title: L("Open a project folder"), detail: L("Your data, code and notes. SieveSci keeps its records in a hidden .sievesci folder inside it.")) {
                        EmptyView()
                    }
                }
                // The main action on the left, the interface language at the far right of the same row.
                HStack(spacing: Theme.Space.m) {
                    Button(L("Open Workspace…")) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { model.open(workspace: url) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.action(.primary))
                    Spacer(minLength: Theme.Space.m)
                    LanguageMenu()
                }
                Text(Credits.line).font(Theme.label).tracking(0.4).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity)
            .appearPop()
        }
        .background(SieveField(fadeMid: 0.25))
        .overlay(alignment: .topLeading) {
            if !sidebarVisible {
                Button { sidebarVisible = true } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(QuietIconButtonStyle())
                    .padding(.leading, 80).padding(.top, Theme.Space.l)
            }
        }
        .background(Theme.canvas)
    }
}

/// Interface language as a framed menu the height of a button (globe, native name, chevron), so it sits
/// in a row of action buttons instead of a rounded system pop-up.
struct LanguageMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        Menu {
            Picker(L("Language"), selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                ForEach(L10n.Language.allCases) { Text($0.nativeName).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "globe")
                Text(model.language.nativeName)
            }
            .font(Theme.body.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .tint(.primary)   // ink like a secondary button, not accent
        .fixedSize()
        .padding(.horizontal, Theme.Space.m)
        .frame(minWidth: Theme.Control.buttonWidth, minHeight: Theme.Control.button, maxHeight: Theme.Control.button)
        .background(Rectangle().fill(hovering ? Theme.hairline : Theme.raised))
        .overlay(Rectangle().strokeBorder(hovering ? Theme.ink.opacity(0.55) : Theme.rule, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Theme.Motion.hover) { hovering = h } }
        .help(L("Interface language"))
        .accessibilityLabel(L("Interface language"))
    }
}

/// One line of the welcome checklist: done mark or number, what it is, its current state, an action.
struct SetupStep<Action: View>: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    var optional = false
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Group {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Rectangle().fill(Theme.ok))
                } else {
                    Text(String(format: "%02d", number)).font(Theme.label).foregroundStyle(Theme.accent)
                        .frame(width: 22, height: 22)
                        .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.xs) {
                    Text(title).font(Theme.body.weight(.medium))
                    if optional { Text(L("optional")).font(Theme.caption).foregroundStyle(.tertiary) }
                }
                Text(detail).font(Theme.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            action()
        }
        .padding(.vertical, Theme.Space.s)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? L("done") : L("not done"))
    }
}
