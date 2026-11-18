import SwiftUI
import UserNotifications

@main
struct HogwatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var m = Monitor.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(m: m)
        } label: {
            Image(nsImage: m.statusImage)
        }
        .menuBarExtraStyle(.window)

        Window("Verlauf", id: "history") {
            HistoryView(m: m)
        }
        .defaultSize(width: 760, height: 560)
        .defaultLaunchBehavior(.suppressed)
    }
}

extension Monitor {
    static let shared = Monitor()
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let args = CommandLine.arguments
        if args.contains("--demo-alert") {
            Task { @MainActor in Monitor.shared.alerts.post("Testmitteilung", "hogwatch darf Mitteilungen senden.") }
        }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            Task { @MainActor in await renderSnapshots(to: URL(fileURLWithPath: args[i + 1])) }
        }
    }

    // Show banners even though a menu bar app counts as frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound, .list])
    }

    /// Development aid: renders every tab, the history window and the menu bar label to PNGs, then quits.
    @MainActor private func renderSnapshots(to dir: URL) async {
        let m = Monitor.shared
        m.setPanelOpen(true)
        try? await Task.sleep(for: .seconds(6))
        func save(_ view: some View, _ name: String) {
            let r = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
            r.scale = 2
            guard let tiff = r.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for tab in Tab.allCases {
            m.tab = tab
            try? await Task.sleep(for: .seconds(tab == .ports || tab == .docker ? 5 : 2))
            save(PanelView(m: m), tab.rawValue)
        }
        save(HistoryView(m: m).frame(width: 760, height: 560), "history")
        save(Image(nsImage: m.statusImage).padding(4), "status")
        NSApp.terminate(nil)
    }
}
