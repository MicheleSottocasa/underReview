import AppKit
import ReviewDeskCore
import SwiftUI

@main
struct ReviewDeskApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        Window("ReviewDesk", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 600)
                .task {
                    if let folder = Screenshots.folder {
                        await Screenshots.capture(model, to: folder)
                    } else {
                        model.start()
                    }
                }
        }
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.checkForUpdatesFromMenu() }
            }
            CommandGroup(replacing: .help) {
                Button("Show Tour") { model.startTour() }
                Button("What's New") { model.showCurrentNotes() }
            }
            CommandGroup(after: .newItem) {
                Button("Refresh") { model.refreshNow() }.keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView().environment(model)
        }

        // Closing the window leaves monitoring running here; Quit stops it.
        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` launches a bare executable; make it a regular app with a Dock icon and windows.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Without this, App Nap throttles the background poll timer once the window is closed.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Monitoring pull requests")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.recentEvents.isEmpty ? "arrow.triangle.pull" : "bell.badge")
            .onAppear {
                model.openMainWindow = { openWindow(id: "main") }
                // Window restoration keeps a window closed if it was closed at quit; a launch should always show it.
                openWindow(id: "main")
                model.start()
            }
    }
}

/// The notifications posted since launch, newest first, muted pull requests included.
struct NotificationsButton: View {
    @Environment(AppModel.self) private var model
    @ViewState private var showing = false

    var body: some View {
        Button {
            showing.toggle()
            model.unseenEvents = 0
        } label: {
            Label("Notifications", systemImage: model.unseenEvents > 0 ? "bell.badge" : "bell")
        }
        .help(model.unseenEvents > 0 ? "\(model.unseenEvents) new notification\(model.unseenEvents == 1 ? "" : "s")" : "Notifications")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Notifications").font(.headline)
                    Spacer()
                    if !model.recentEvents.isEmpty {
                        Button("Clear") { model.recentEvents.removeAll() }.buttonStyle(.link)
                    }
                }
                .padding(10)
                Divider()
                if model.recentEvents.isEmpty {
                    Text("No notifications since ReviewDesk opened.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                } else {
                    List(model.recentEvents) { event in
                        Button {
                            model.open(prID: event.pr.id)
                            showing = false
                        } label: { row(event) }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(width: 380, height: model.recentEvents.isEmpty ? nil : 420)
        }
    }

    private func row(_ event: RecentEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(verbatim: "\(event.pr.repo)#\(event.pr.number)").font(.caption).foregroundStyle(.secondary)
                if model.org.muted.contains(event.pr.itemKey) {
                    Image(systemName: "bell.slash").font(.caption).foregroundStyle(.secondary)
                        .help("Notifications are off for this pull request, so macOS didn't show this one")
                }
                Spacer()
                Text(event.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            }
            Text(event.pr.title).lineLimit(1)
            Text(event.kinds.map(\.text).joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.recentEvents.isEmpty {
            Text("No new activity")
        }
        ForEach(model.recentEvents.prefix(10)) { event in
            Button(String("\(event.pr.repo)#\(event.pr.number): \(event.kinds.map(\.text).joined(separator: ", "))")) {
                model.open(prID: event.pr.id)
            }
        }
        if !model.recentEvents.isEmpty {
            Button("Clear") { model.recentEvents.removeAll() }
        }
        Divider()
        Button("Open ReviewDesk") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh Now") { model.refreshNow() }
        Divider()
        Button("Quit ReviewDesk") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
        .sheet(item: Bindable(model).whatsNew) { WhatsNewView(content: $0) }
        .task {
            // First launch: tour the app on demo data before any real pull request shows up.
            guard model.shouldStartTour, model.tourStep == nil, !Screenshots.isRequested else { return }
            try? await Task.sleep(for: .seconds(1))
            model.startTour()
        }
    }

    @ViewBuilder
    private var content: some View {
        // The tour runs on its demo data, so it works before `gh` is set up.
        if let error = model.setupError, model.tourStep == nil {
            SetupView(error: error)
        } else {
            @Bindable var model = model
            NavigationSplitView(columnVisibility: $model.columns) {
                SidebarView().navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 460)
            } detail: {
                if let pr = model.selectedPR {
                    DetailView(pr: pr).id(pr.id)
                } else {
                    ContentUnavailableView("Select a pull request", systemImage: "arrow.triangle.pull")
                }
            }
            .toolbar {
                ToolbarItem { NotificationsButton() }
                ToolbarItem {
                    if model.isLoading {
                        ProgressView().controlSize(.small).help("Loading pull requests…")
                    } else {
                        Button { model.refreshNow() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = model.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.85))
                        .onTapGesture { model.lastError = nil }
                }
            }
        }
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var model
    let error: String

    var body: some View {
        ContentUnavailableView {
            Label("Connect GitHub", systemImage: "person.badge.key")
        } description: {
            Text("ReviewDesk uses the GitHub CLI for every request. Install `gh` and run `gh auth login` in Terminal, then retry.")
            Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } actions: {
            Button("Retry") { model.retrySetup() }
        }
    }
}

// ponytail: the macOS 27 SDK turns `@State` into a macro whose plugin ships only with Xcode.
// The underlying property wrapper behaves the same; switch back to `@State` once Xcode is required.
typealias ViewState<Value> = SwiftUI.State<Value>

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
            PromptSettings().tabItem { Label("Prompts", systemImage: "text.bubble") }
            CloneSettings().tabItem { Label("Repositories", systemImage: "folder") }
            ToolSettings().tabItem { Label("Tools", systemImage: "terminal") }
        }
        .frame(width: 640)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var whatsNew: WhatsNew?
    @AppStorage("checkForUpdates") private var checkForUpdates = true
    @ViewState private var checking = false
    @AppStorage("pollForeground") private var foreground = Updates.defaultForeground
    @AppStorage("pollBackground") private var background = Updates.defaultBackground
    @AppStorage("diffMode") private var diffMode = DiffMode.split
    @AppStorage("wrapLines") private var wrap = false
    @AppStorage(AppModel.autoMarkViewedKey) private var autoMarkViewed = false
    @AppStorage(AppModel.archiveAfterDaysKey) private var archiveAfterDays = AppModel.defaultArchiveAfterDays

    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    HStack(spacing: 6) {
                        Text(model.currentBuild.isEmpty ? model.currentVersion : "\(model.currentVersion) (\(model.currentBuild))")
                        Badge(text: "BETA PREVIEW", color: .orange)
                    }
                }
                Toggle("Check for new versions automatically", isOn: $checkForUpdates)
                HStack {
                    Group {
                        if let progress = model.updateProgress {
                            Text(progress).foregroundStyle(.secondary)
                        } else if let update = model.availableUpdate {
                            Button(model.canInstallUpdates ? "Install \(update.version) and Relaunch" : "\(update.version) is available: Download") {
                                model.installUpdate(update)
                            }
                            .buttonStyle(.link)
                            Button("What's New") { whatsNew = .update(update) }.buttonStyle(.link)
                        } else if let error = model.updateCheckError {
                            Text("Last check failed: \(error)").foregroundStyle(.orange).lineLimit(2)
                        } else if let checked = model.lastUpdateCheck {
                            Text("Up to date · checked \(checked.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                        } else {
                            Text("Not checked yet").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    Spacer()
                    Button(checking ? "Checking…" : "Check Now") {
                        checking = true
                        Task {
                            await model.checkForUpdates()
                            checking = false
                        }
                    }
                    .disabled(checking)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(AppModel.betaNotice)
            }
            Section {
                seconds("While ReviewDesk is in front", $foreground)
                seconds("In the background", $background)
            } header: {
                Text("Refresh")
            } footer: {
                Text("Never more often than every \(Updates.minimumInterval) s, to stay inside GitHub's hourly API limit. Failures back off up to 30 min.")
            }
            Section {
                Picker("Move merged and closed pull requests", selection: $archiveAfterDays) {
                    Text("Never").tag(0)
                    ForEach([1, 2, 3, 7, 14, 30], id: \.self) { days in
                        Text(days == 1 ? "After 1 day" : "After \(days) days").tag(days)
                    }
                }
            } header: {
                Text("Archive")
            } footer: {
                Text("They go to the Archive group at the bottom of To Review, My PRs or their folder, collapsed until you open it. A stack waits for its last open pull request. Archived pull requests are still monitored.")
            }
            Section("Diff") {
                Picker("Layout", selection: $diffMode) {
                    Text("Side by side").tag(DiffMode.split)
                    Text("Unified").tag(DiffMode.unified)
                }
                Toggle("Wrap long lines", isOn: $wrap)
            }
            Section {
                Toggle("Mark a file as Viewed on GitHub when all its key areas are read", isOn: $autoMarkViewed)
            } header: {
                Text("Focus")
            } footer: {
                Text("Off by default: it checks the file's Viewed box on GitHub for you, without a click. Marking an area unread again leaves the box as it is.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $whatsNew) { WhatsNewView(content: $0) }
    }

    private func seconds(_ title: String, _ value: Binding<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                Text("s").foregroundStyle(.secondary)
            }
        }
    }
}

struct AISettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("aiEngine") private var engine = "claude"
    @AppStorage("claudeModel") private var claudeModel = ""
    @AppStorage("reviewEffort") private var effort = "high"
    @AppStorage("codexModel") private var codexModel = ""
    @AppStorage("codexEffort") private var codexEffort = ""
    @AppStorage("ollamaThink") private var ollamaThink = ""
    @AppStorage(AppModel.codeReviewFilesKey) private var codeReviewFiles = "clone"
    @AppStorage("ollamaModel") private var ollamaModel = "qwen2.5-coder"
    @AppStorage("aiBudget") private var budget = 150_000
    @AppStorage("stackParallelAgents") private var parallelAgents = 3

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $engine) {
                    Text("Claude Code · beta").tag("claude")
                    Text("Codex · alpha").tag("codex")
                    Text("Ollama (local) · alpha").tag("ollama")
                    if engine == "linked" { Text("Linked Claude session · beta").tag("linked") }
                }
            } footer: {
                Text("Also used by Explain on comments. The AI tab changes the same setting. Claude Code support is in beta; Codex and Ollama are alpha, so expect rough edges with them.")
            }
            Section {
                ModelPicker(choices: AIOptions.models(for: .claudeCode), selection: $claudeModel, defaultLabel: "CLI default")
                EffortPicker(engine: .claudeCode, selection: $effort)
                Picker("Pull request files", selection: $codeReviewFiles) {
                    Text("Worktree of the linked clone").tag("clone")
                    Text("Download from GitHub").tag("download")
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("The model is used by every Claude Code action; the effort is /code-review's level. Each review reads the pull request's files at its head commit, in a folder of its own that is removed afterwards. A worktree is quick and leaves the clone's branch alone, but needs a clone linked in Repositories; a download needs nothing, but fetches the whole repository every time. Without either, /code-review reads only the diff.")
            }
            Section {
                ModelPicker(choices: AIOptions.models(for: .codex), selection: $codexModel, defaultLabel: "CLI default")
                EffortPicker(engine: .codex, selection: $codexEffort)
            } header: {
                Text("Codex")
            } footer: {
                Text("Used by every Codex action. Your config.toml is ignored, so these choices are the only ones applied; Default keeps the CLI's own model and reasoning effort.")
            }
            Section {
                ModelPicker(choices: model.ollamaModels.map { ModelChoice($0, $0) }, selection: $ollamaModel, defaultLabel: nil)
                if model.ollamaThinks[ollamaModel] == true {
                    EffortPicker(engine: .ollama(model: ollamaModel), selection: $ollamaThink)
                }
            } header: {
                Text("Ollama")
            } footer: {
                Text(model.ollamaModels.isEmpty
                     ? "No pulled models found: start Ollama, or pick Other… and type a model's name."
                     : "The models you have pulled. Other… takes a name that isn't pulled yet. Thinking shows for models that support it.")
            }
            Section {
                Stepper("Agents at once in a stack review: \(parallelAgents)", value: $parallelAgents, in: 1...8)
            } footer: {
                Text("Review Stack gives every pull request its own agent. More at once is faster but uses more of your plan at the same time; Ollama always runs one at a time.")
            }
            Section {
                LabeledContent("Token budget") {
                    TextField("", value: $budget, format: .number).frame(width: 100).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Codex and Ollama")
            } footer: {
                Text("These engines get the diff and files you approve in Prepare Context; nothing is truncated to fit the budget.")
            }
        }
        .formStyle(.grouped)
        .task { await model.loadOllamaModels() }
        .task(id: ollamaModel) { await model.loadOllamaThinks(ollamaModel) }
    }
}

/// Each AI instruction, editable. An empty or default text means the built-in prompt.
struct PromptSettings: View {
    @AppStorage(Prompts.codeReviewKey) private var codeReview = ""
    @AppStorage(Prompts.structureKey) private var structure = ""
    @AppStorage(Prompts.reviewKey) private var review = ""
    @AppStorage(Prompts.explainKey) private var explain = ""
    @AppStorage(Prompts.followUpKey) private var followUp = ""
    @AppStorage(Prompts.fixKey) private var fix = ""
    @AppStorage(Prompts.selectionKey) private var selection = ""

    var body: some View {
        Form {
            editor("Claude Code /code-review", note: "Added to Claude Code's system prompt when it runs /code-review. The review itself follows the command's own instructions.",
                   text: $codeReview, fallback: AIContext.defaultCodeReviewInstructions)
            editor("Findings and key areas from /code-review", note: "Turns the /code-review report into findings and picks the key areas. The JSON schema, the report and the PR's diffs are always appended.",
                   text: $structure, fallback: AIContext.defaultStructureInstructions)
            editor("Codex and Ollama review", note: "Starts the review prompt. The JSON schema, PR description and files are always appended.",
                   text: $review, fallback: AIContext.defaultReviewInstructions)
            editor("Follow-up check", note: "Asks whether the changes and replies since your review handle each of your comments. The result format, your threads and the changes are always appended.",
                   text: $followUp, fallback: FollowUp.defaultInstructions)
            editor("Explain a comment", note: "Starts the prompt. The PR description, the diff and the conversation are always appended.",
                   text: $explain, fallback: AIContext.defaultExplainInstructions)
            editor("Suggest a fix", note: "Asks for a fix to a finding or a comment as a GitHub suggested change. The result format, the PR description, the file's diff with line numbers and the problem are always appended.",
                   text: $fix, fallback: AIContext.defaultFixInstructions)
            editor("Explain selected lines", note: "Starts the prompt. The PR description, the file's diff and the selected lines are always appended.",
                   text: $selection, fallback: AIContext.defaultSelectionInstructions)
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
    }

    private func editor(_ title: String, note: String, text: Binding<String>, fallback: String) -> some View {
        let shown = Binding(
            get: { text.wrappedValue.isEmpty ? fallback : text.wrappedValue },
            set: { text.wrappedValue = $0 == fallback ? "" : $0 }
        )
        return Section {
            TextEditor(text: shown)
                .font(.callout.monospaced())
                .frame(minHeight: 110)
        } header: {
            HStack {
                Text(title)
                if !text.wrappedValue.isEmpty { Badge(text: "Custom", color: .accentColor) }
                Spacer()
                Button("Reset to Default") { text.wrappedValue = "" }
                    .controlSize(.small)
                    .disabled(text.wrappedValue.isEmpty)
            }
        } footer: {
            Text(note)
        }
    }
}

struct ToolSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(AppModel.tools, id: \.self) { tool in
                    TextField(tool, text: path(tool), prompt: Text(model.toolPaths[tool] ?? "not found"))
                }
            } header: {
                Text("Command-line tools")
            } footer: {
                Text("Leave empty to use the path found by your login shell. Changes apply after restarting ReviewDesk.")
            }
        }
        .formStyle(.grouped)
    }

    private func path(_ tool: String) -> Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: "path.\(tool)") ?? "" },
            set: { UserDefaults.standard.set($0.isEmpty ? nil : $0, forKey: "path.\(tool)") }
        )
    }
}
