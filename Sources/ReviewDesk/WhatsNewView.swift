import ReviewDeskCore
import SwiftUI

/// "What's New in X": the changes of every version after the installed one up to `release`, newest first,
/// with the banner's install button and Later.
struct WhatsNewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let release: AppRelease
    /// Nil while loading.
    @ViewState private var notes: [VersionNotes]?
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's New in ReviewDesk \(release.version)")
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
                    Text("You have \(model.currentVersion)").font(.headline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            Divider()
            HStack {
                Spacer()
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
            }
            .padding()
        }
        .frame(width: 560, height: 600)
        .task {
            do {
                notes = try await model.github.releaseNotes(repo: AppVersion.repository, after: model.currentVersion, through: release.version)
            } catch {
                self.error = error.userMessage
                notes = []
            }
        }
    }
}
