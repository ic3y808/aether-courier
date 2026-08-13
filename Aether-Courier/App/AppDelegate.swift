import AppKit
import SwiftUI

/// Handles macOS application lifecycle events for background mail fetching
/// and Dock integration when windows are closed.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Observe new window creations to attach window delegate
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.delegate == nil && window.canBecomeMain {
            window.delegate = self
        }
    }

    /// Keep the application running in background when all windows are closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Re-open / unhide the main window when clicking the Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                if window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    return true
                }
            }
            // If no window is visible, unhide the application
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// Intercept standard window close (red 'X') button to hide instead of destroying/closing if it's a main app window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender.canBecomeMain {
            sender.orderOut(nil)
            return false
        }
        return true
    }
}
