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
    @AppStorage("ShouldShowWelcome") private var shouldShowWelcome = true

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

            CommandGroup(replacing: .appInfo) {
                Button("About \(AppInfo.appName)") {
                    appDelegate.showAboutWindow()
                }
            }

            CommandGroup(replacing: .help) {
                Button("\(AppInfo.appName) Help") {
                    if let url = URL(string: "https://github.com/ajb/icon-decomposer") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // Welcome window (shown conditionally via AppDelegate)
        WindowGroup("Welcome", id: "welcome") {
            WelcomeWindow(onGetStarted: {
                // Close welcome window
                if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "welcome" }) {
                    window.close()
                }
                // Create new document
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSDocumentController.shared.newDocument(nil)
                }
            })
        }
        .handlesExternalEvents(matching: ["welcome"])
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var aboutWindowController: NSWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Prevent automatic document creation
        UserDefaults.standard.set(false, forKey: "NSShowAppCentricOpenPanelInsteadOfUntitledFile")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Close any auto-created documents
        for document in NSDocumentController.shared.documents {
            document.close()
        }

        // Check if we should show welcome window (first launch or 60+ days)
        if shouldShowWelcomeWindow(), let welcomeURL = URL(string: "stratify://welcome") {
            // Open the welcome window
            NSWorkspace.shared.open(welcomeURL)
        }

        // Update last launch date
        UserDefaults.standard.set(Date(), forKey: "LastLaunchDate")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "stratify" && url.host == "welcome" {
                // Welcome window will be shown automatically
                continue
            }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // Don't automatically create untitled documents
        return false
    }

    func applicationShouldAutomaticallyLocalizeKeyEquivalents(_ application: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when last window closes
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

    func showAboutWindow() {
        // If window already exists, just bring it to front
        if let existingWindow = aboutWindowController?.window {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        // Create and show new about window
        let aboutView = AboutView()
        let hostingController = NSHostingController(rootView: aboutView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "About \(AppInfo.appName)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false

        aboutWindowController = NSWindowController(window: window)
        aboutWindowController?.showWindow(nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
