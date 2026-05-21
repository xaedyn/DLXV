import AppKit

/// Tracks the current display's Extended Dynamic Range headroom — the factor
/// by which HDR highlights may exceed SDR white. Re-queries when the screen
/// configuration changes or the system wakes, since macOS can briefly report
/// a stale headroom of 1.0 after waking.
@MainActor
final class EDRMonitor {
    private(set) var headroom: Float = 1.0
    private weak var window: NSWindow?

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// Binds monitoring to the screen the given window is on.
    func attach(to window: NSWindow?) {
        self.window = window
        refresh()
    }

    @objc private func refresh() {
        let screen = window?.screen ?? NSScreen.main
        let value = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        headroom = max(1.0, Float(value))
    }
}
