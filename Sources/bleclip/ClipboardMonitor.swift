import AppKit

class ClipboardMonitor {
    private var lastChangeCount: Int
    private var lastContent: String?
    private var suppressNextChange: Bool = false

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        lastContent = NSPasteboard.general.string(forType: .string)
    }

    /// Returns the new clipboard text if it changed, nil otherwise.
    func checkForChange() -> String? {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return nil }
        lastChangeCount = currentCount

        if suppressNextChange {
            suppressNextChange = false
            return nil
        }

        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        guard text != lastContent else { return nil }
        lastContent = text
        return text
    }

    /// Sets the local clipboard content. Suppresses the next change detection to prevent echo.
    func setClipboard(_ text: String) {
        suppressNextChange = true
        lastContent = text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount
        Logger.debug("Local clipboard set: \(text.prefix(80))...")
    }
}
