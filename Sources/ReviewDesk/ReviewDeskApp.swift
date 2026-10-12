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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` launches a bare executable; make it a regular app with a Dock icon and windows.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
