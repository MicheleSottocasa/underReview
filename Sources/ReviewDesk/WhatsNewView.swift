import ReviewDeskCore
import SwiftUI

/// What the "What's New" sheet shows.
enum WhatsNew: Identifiable {
    /// Before updating: the changes from the installed version up to this release, from GitHub, with install and Later.
    case update(AppRelease)
    /// This build's own changes, from the CHANGELOG.md in its bundle: after an update, or from Help.
    case installed([VersionNotes])

    var id: String {
        switch self {
        case .update(let release): "update-\(release.version)"
        case .installed: "installed"
        }
    }
}

/// "What's New in X": the changes of every version in the range, newest first.
struct WhatsNewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let content: WhatsNew
    /// Nil while loading.
    @ViewState private var notes: [VersionNotes]?
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's New in ReviewDesk \(release?.version ?? model.currentVersion)")
                .font(.title2.bold())
                .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error {
                        Label("Couldn't load the changes: \(error)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let notes {
                        if notes.isEmpty, error == nil {
                            Text("No notes were published for these versions.").foregroundStyle(.secondary)
                        }
                        ForEach(notes) { version in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(version.version).font(.title3.bold())
                                    if let date = version.date {
                                        Text(date, format: .dateTime.day().month().year()).foregroundStyle(.secondary)
                                    }
                                }
                                MarkdownText(version.notes)
                            }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if release != nil {
                        Text("You have \(model.currentVersion)").font(.headline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            Divider()
            HStack {
                Spacer()
                if let release {
                    Button("Later") {
                        model.dismissedUpdate = release.version
                        dismiss()
                    }
                    .help("Hide the update until a newer version comes out")
                    Button(model.canInstallUpdates ? "Install and Relaunch" : "Download") {
                        dismiss()
                        model.installUpdate(release)
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 560, height: 600)
        .task {
            guard let release else {
                if case .installed(let installed) = content { notes = installed }
                return
            }
            do {
                notes = try await model.github.releaseNotes(repo: AppVersion.repository, after: model.currentVersion, through: release.version)
            } catch {
                self.error = error.userMessage
                notes = []
            }
        }
    }

    private var release: AppRelease? {
        if case .update(let release) = content { release } else { nil }
    }
}
