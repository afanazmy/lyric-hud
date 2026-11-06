import AppKit
import Combine
import SwiftUI

/// Panel tanpa border yang tidak mencuri fokus dari app lain.
final class HUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Kalau tidak muncul di atas app fullscreen, coba naikkan level ini.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Supaya klik pertama pada tombol langsung bekerja walau panel tidak aktif.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Mendeteksi kursor masuk/keluar panel, walau app sedang tidak aktif.
final class HoverTrackingView: NSView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let newArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newArea)
        area = newArea
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor
final class NotchPanelController {
    private let model: PlayerModel
    private let panel = HUDPanel()
    private var cancellables = Set<AnyCancellable>()
    private var collapseTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?

    init(model: PlayerModel) {
        self.model = model

        let host = FirstMouseHostingView(rootView: HUDRootView(model: model))
        if #available(macOS 13.0, *) {
            host.sizingOptions = []
        }

        let tracker = HoverTrackingView()
        tracker.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        host.frame = tracker.bounds
        host.autoresizingMask = [.width, .height]
        tracker.addSubview(host)
        panel.contentView = tracker

        // Window dibesarkan SEBELUM animasi expand, dan dikecilkan SESUDAH animasi collapse.
        model.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in self?.expandedWillChange(expanded) }
            .store(in: &cancellables)

        // Panel hanya tampil selama ada lagu dari browser.
        model.$isActive
            .removeDuplicates()
            .sink { [weak self] active in self?.activeChanged(active) }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
    }

    /// Menaruh panel di posisinya. Tampil atau tidaknya diatur oleh `model.isActive`.
    func show() {
        reposition()
    }

    private func activeChanged(_ active: Bool) {
        if active {
            reposition()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Hover

    private func hoverChanged(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            model.isExpanded = true
        } else {
            // Delay kecil supaya tidak berkedip kalau kursor lewat sekilas.
            collapseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                self?.model.isExpanded = false
            }
        }
    }

    // MARK: - Frame

    private func expandedWillChange(_ expanded: Bool) {
        shrinkTask?.cancel()
        if expanded {
            panel.setFrame(frame(expanded: true), display: true)
        } else {
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, !self.model.isExpanded else { return }
                self.panel.setFrame(self.frame(expanded: false), display: true)
            }
        }
    }

    private func reposition() {
        panel.setFrame(frame(expanded: model.isExpanded), display: true)
    }

    /// Layar dengan notch kalau ada, kalau tidak layar utama.
    private func targetScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func frame(expanded: Bool) -> NSRect {
        let screen = targetScreen()
        let content = expanded ? Metrics.expanded : Metrics.compact
        let size = CGSize(
            width: content.width + Metrics.pad * 2,
            height: content.height + Metrics.pad * 2
        )
        // Tepi atas pill: tepat di bawah menu bar (atau di bawah notch kalau menu bar disembunyikan).
        let topEdge = min(
            screen.visibleFrame.maxY,
            screen.frame.maxY - screen.safeAreaInsets.top
        ) - Metrics.gapBelowMenuBar
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: topEdge + Metrics.pad - size.height,
            width: size.width,
            height: size.height
        )
    }
}
