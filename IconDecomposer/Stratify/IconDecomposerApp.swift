//
//  IconDecomposerApp.swift
//  IconDecomposer
//
//  Created by Andrew Benson on 9/28/25.
//

import SwiftUI

@main
struct IconDecomposerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Document-based scene
        DocumentGroup(newDocument: IconDecomposerDocument.init) { file in
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
                Button("Icon Decomposer Help") {
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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Close any automatically opened documents
        DispatchQueue.main.async {
            for document in NSDocumentController.shared.documents {
                document.close()
            }

            // Show welcome window
            self.showWelcomeWindow()

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

    private func showWelcomeWindow() {
        // Close any existing welcome window
        welcomeWindowController?.close()

        // Create and show new welcome window
        let welcomeView = WelcomeWindow()
        let hostingController = NSHostingController(rootView: welcomeView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Icon Decomposer"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("WelcomeWindow")

        welcomeWindowController = NSWindowController(window: window)
        welcomeWindowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
