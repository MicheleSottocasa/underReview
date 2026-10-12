import AppKit
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
                .task { model.start() }
        }
        .commands {
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
                model.start()
            }
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
        if let error = model.setupError {
            SetupView(error: error)
        } else {
            NavigationSplitView {
                SidebarView()
            } content: {
                ItemListView()
            } detail: {
                if let pr = model.selectedPR {
                    DetailView(pr: pr).id(pr.id)
                } else {
                    ContentUnavailableView("Select a pull request", systemImage: "arrow.triangle.pull")
                }
            }
            .toolbar {
                ToolbarItem {
                    Button { model.refreshNow() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(model.isRefreshing)
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
        .frame(width: 480)
    }

    private func path(_ tool: String) -> Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: "path.\(tool)") ?? "" },
            set: { UserDefaults.standard.set($0.isEmpty ? nil : $0, forKey: "path.\(tool)") }
        )
    }
}
