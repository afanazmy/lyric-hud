import AppKit
import SwiftUI

@main
struct LyricHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Satu-satunya UI "biasa": ikon kecil di menu bar untuk keluar dari app.
        MenuBarExtra("Lyric HUD", systemImage: "music.note.list") {
            Button("Keluar") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchPanelController?
    private var bridge: BridgeServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tanpa ikon Dock, tidak mencuri fokus dari app lain.
        NSApp.setActivationPolicy(.accessory)

        let model = PlayerModel.shared

        let controller = NotchPanelController(model: model)
        controller.show()
        self.controller = controller

        let bridge = BridgeServer(model: model)
        model.onCommand = { [weak bridge] command in bridge?.sendCommand(command) }
        bridge.start()
        self.bridge = bridge
    }
}
