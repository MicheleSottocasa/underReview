import AppKit
import SwiftUI
import ReviewDeskCore

/// `ReviewDesk --screenshots <folder>`: shows the demo pull request in each tab and saves a PNG of the window,
/// for the README. Never polls GitHub and never saves anything (see `AppModel.save`).
enum Screenshots {
    static var folder: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--screenshots"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1])
    }

    static var isRequested: Bool { folder != nil }

    static let shots: [(name: String, tab: DetailTab, pr: String)] = [
        ("conversation", .conversation, Demo.mainID), ("risk", .risk, Demo.mainID), ("changes", .changes, Demo.mainID),
        ("ai-review", .ai, Demo.mainID), ("follow-up", .followUp, Demo.baseID),
    ]

    @MainActor
    static func capture(_ model: AppModel, to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        model.viewer = Demo.viewer
        model.lastRefresh = .now
        model.org = Organization() // the user's own projects stay out of public screenshots (never saved here)
        model.showDemo()
        if let main = model.prs[Demo.mainID] { model.reveal(main) }
        model.selection = [.pr(Demo.mainID)]
        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return NSApp.terminate(nil) }
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.center()
        for shot in shots {
            model.columns = .all
            model.selection = [.pr(shot.pr)]
            model.detailTab = shot.tab
            try? await Task.sleep(for: .seconds(1.5))
            save(window, to: folder.appendingPathComponent("\(shot.name).png"))
        }
        // `--tour` also saves each tour step and its card (popovers are separate windows), to check the tour.
        if CommandLine.arguments.contains("--tour") {
            model.startTour()
            for step in TourStep.allCases {
                model.showTourStep(step)
                try? await Task.sleep(for: .seconds(1.5))
                save(window, to: folder.appendingPathComponent("tour-\(step.rawValue + 1).png"))
                for (index, card) in NSApp.windows.filter({ $0.isVisible && $0 !== window && $0.className.contains("Popover") }).enumerated() {
                    save(card, to: folder.appendingPathComponent("tour-\(step.rawValue + 1)-card\(index).png"))
                }
            }
        }
        // `--appearance` also saves Settings › Appearance and Import from IDE, then the Changes tab after a theme edit (kept in memory only).
        if CommandLine.arguments.contains("--appearance") {
            let settings = NSWindow(contentViewController: NSHostingController(rootView: AppearanceSettings().frame(width: 640, height: 1100)))
            settings.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1.5))
            save(settings, to: folder.appendingPathComponent("appearance.png"))
            settings.close()
            // The review step of Import from IDE, on a bundled preset (never the user's own IDEs).
            let sheet = NSWindow(contentViewController: NSHostingController(rootView: IDEImportSheet(file: JetBrainsScheme.presets["Darcula"])))
            sheet.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1.5))
            save(sheet, to: folder.appendingPathComponent("import-ide.png"))
            sheet.close()
            ThemeStore.shared.edit {
                $0[.keyword, dark: false] = HexColor(0xD00000)
                $0[.keyword, dark: true] = HexColor(0xFF6060)
                $0[.added, dark: false] = HexColor(0xFFF3B0)
                $0[.added, dark: true] = HexColor(0x4A4220)
            }
            model.detailTab = .changes
            try? await Task.sleep(for: .seconds(1.5))
            save(window, to: folder.appendingPathComponent("changes-themed.png"))
        }
        NSApp.terminate(nil)
    }

    /// The whole window, title bar included.
    @MainActor
    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
