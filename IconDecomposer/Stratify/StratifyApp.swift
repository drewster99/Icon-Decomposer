//
//  StratifyApp.swift
//  Stratify
//
//  Created by Andrew Benson on 9/28/25.
//

import SwiftUI

@main
struct StratifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Document-based scene
        DocumentGroup(newDocument: StratifyDocument.init) { file in
            DocumentView(document: file.document)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Project...") {
                    NSDocumentController.shared.newDocument(nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            CommandGroup(replacing: .help) {
                Button("\(AppInfo.appName) Help") {
                    // TODO: Open help
                }
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var welcomeWindowController: NSWindowController?
    private var hasFinishedLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Prevent any automatic document opening during launch
        // This must be set early to prevent the open panel from appearing
        UserDefaults.standard.set(false, forKey: "NSShowAppCentricOpenPanelInsteadOfUntitledFile")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Close any automatically opened documents
        DispatchQueue.main.async {
            for document in NSDocumentController.shared.documents {
                document.close()
            }

            // Show welcome window only if it's been more than 60 days since last launch
            if self.shouldShowWelcomeWindow() {
                self.showWelcomeWindow()
            }

            // Update last launch date
            UserDefaults.standard.set(Date(), forKey: "LastLaunchDate")

            // Mark launch as complete to allow normal document opening
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.hasFinishedLaunching = true
            }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Allow opening files when double-clicked
        return hasFinishedLaunching
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Only process file opens after launch completes
        guard hasFinishedLaunching else { return }

        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    func applicationShouldAutomaticallyLocalizeKeyEquivalents(_ application: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showWelcomeWindow()
        }
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // Never automatically create untitled documents
        return false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // Prevent automatic open panel during launch
        if !hasFinishedLaunching {
            return false
        }
        return false
    }

    private func shouldShowWelcomeWindow() -> Bool {
        guard let lastLaunchDate = UserDefaults.standard.object(forKey: "LastLaunchDate") as? Date else {
            // First launch, show welcome window
            return true
        }

        let daysSinceLastLaunch = Calendar.current.dateComponents([.day], from: lastLaunchDate, to: Date()).day ?? 0
        return daysSinceLastLaunch > 60
    }

    private func showWelcomeWindow() {
        // Close any existing welcome window
        welcomeWindowController?.close()

        // Create and show new welcome window
        let welcomeView = WelcomeWindow()
        let hostingController = NSHostingController(rootView: welcomeView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Stratify"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false

        welcomeWindowController = NSWindowController(window: window)
        welcomeWindowController?.showWindow(nil)
        window.center()  // Center after showing to ensure proper positioning
        window.makeKeyAndOrderFront(nil)
    }
}
