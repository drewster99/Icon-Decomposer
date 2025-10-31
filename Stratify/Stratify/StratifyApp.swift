//
//  StratifyApp.swift
//  Stratify
//
//  Created by Andrew Benson on 9/28/25.
//

import Foundation
import SwiftUI
import OSLog
import StoreKit
import NCCOpenAppleSearchAdsInstallAttribution

@main
struct StratifyApp: App {
    static private let logger = Logger(subsystem: "StratifyApp", category: "App")
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("ShouldShowWelcome") private var shouldShowWelcome = true
    
    @StateObject private var appStoreMonitor: AppStoreMonitor
    @StateObject private var userAccountProperties: UserAccountProperties
    @StateObject private var analyticsManager: AnalyticsManager
    @StateObject private var adAttributionManager: NCCOpenAppleSearchAdsInstallAttribution
    @State private var serviceEntitlement: ServiceEntitlement
    @State private var isShowingPaywall: Bool = false
    
    init() {
        // MARK: - FIREBASE - ANALYTICS (AND `FirebaseApp.configure()`)
        let analyticsManager = AnalyticsManager(telemetryDeckAppID: "", onInitDone: {
            //            Task.detached(priority: .userInitiated) {
            //                appAPI.doFirebaseUserLogin()
            //            }
        })
        self._analyticsManager = StateObject(wrappedValue: analyticsManager)
        
        //        // Wire up analytics manager to AppAPI
        //        appAPI.analyticsManager = analyticsManager
        
        // Start analytics
        analyticsManager.activate()
        
#if DEBUG || TESTFLIGHT
        // Record first launch date for API usage tracking
        if CommandLine.arguments.contains("--resetUsageTrackingData") {
            APIUsageTracker.shared.resetTodayUsage()
            APIUsageTracker.shared.resetFirstLaunchDate()
        }
#endif
        
        APIUsageTracker.shared.recordFirstLaunchIfNeeded()
        
        let appStoreMonitor = AppStoreMonitor(analyticsManager: analyticsManager)
        self._appStoreMonitor = StateObject(wrappedValue: appStoreMonitor)
        self._serviceEntitlement = State(initialValue: appStoreMonitor.serviceEntitlement)
        
        let userAccountProperties = UserAccountProperties()
        self._userAccountProperties = StateObject(wrappedValue: userAccountProperties)
        
        Task.detached {
            let logger = Logger(subsystem: "StratifyApp", category: "AppTransaction")
            do {
                let t = try await AppTransaction.shared
                let signed = t.signedDate
                logger.log("  signedDate: \(signed)")
                let v = try t.payloadValue
                let appID = v.appID.map { "\($0)" } ?? "<nil>"
                logger.log("  appID: \(appID)")
                logger.log("  appTransactionID: \(v.appTransactionID)")
                logger.log("  appVersion: \(v.appVersion)")
                let appVersionID = v.appVersionID.map { "\($0)" } ?? "<nil>"
                logger.log("  appVersionID: \(appVersionID)")
                logger.log("  bundleID: \(v.bundleID)")
                logger.log("  originalAppVersion: \(v.originalAppVersion)")
                
                if #available(iOS 18.4, *) {
                    logger.log("  originalPlatform.rawValue: \(v.originalPlatform.rawValue)")
                } else {
                    // Fallback on earlier versions
                }
                logger.log("  originalPurchaseDate: \(v.originalPurchaseDate)")
                let preorderDate = v.preorderDate.map { "\($0)" } ?? "<nil>"
                logger.log("  preorderDate: \(preorderDate)")
                logger.log("  signedDate: \(v.signedDate)")
                logger.log("  environment: \(v.environment.rawValue)")
                // Running from Xcode, I didn't get an error, but the response had
                //      appID == nil
                //      originalPurchaseDate 2013-08-01 07:00:00 +0000 -- why??
                //
                // From Xcode, AppTransaction.shared.payloadValue.environment == .sandbox
                
            } catch {
                logger.error("Could not get AppTransaction: \(error)")
                // on Simulator we get 'StoreKit.StoreKitError.unknown'
            }
        }
        
        let isSandbox = (Bundle.main.appStoreReceiptURL?.lastPathComponent ?? "") == "sandboxReceipt"
        let distributionType = isSandbox ? "TESTFLIGHT (Sandbox)" : "App Store"
        
        // MARK: - GOOD ANALYTICS PROPERTIES
        //        print("wasEver = \(wasEverATestFlightUser)")
        var analyticsProperties = userAccountProperties.asAnalyticsDictionary
        analyticsProperties["distributionType"] = distributionType
        //        analyticsProperties["wasEverATestFlightUser"] = wasEverATestFlightUser
        analyticsManager.send(.appLaunch, properties: analyticsProperties)
        analyticsManager.addDefaultParameter(userAccountProperties.accountAgeDays, key: "accountAgeDays")
        //        analyticsManager.addUserProperty(wasEverATestFlightUser ? "true" : "false", key: "wasEverATestFlightUser")
        analyticsManager.addUserProperty(AppConfig.appVersion, key: "NCCAppVersion")
        
        // Note: key is 23 characters - Firebase user properties can't exceed 24 characters
        analyticsManager.addUserProperty("\(userAccountProperties.totalAppLaunchesOnThisDevice)", key: "totalLaunchesThisDevice")
        
        // MARK: - AD ATTRIBUTION - IOS AND IPADOS ONLY
        // Ad attribution
        let adAttributionManager = NCCOpenAppleSearchAdsInstallAttribution { payload in
            // Called whenever an attribution payload is loaded - included when loading a saved payload
            
            // Set these as user properties
            analyticsManager.addUserProperty(payload.conversionType, key: "ASAConversionType")
            analyticsManager.addUserProperty(payload.countryOrRegion, key: "ASACountryOrRegion")
            let keywordID = if let keywordID = payload.keywordId {
                "\(keywordID)"
            } else {
                "0"
            }
            analyticsManager.addUserProperty(keywordID, key: "ASAKeywordID")
            
            // Add default parameters for all analytics
            analyticsManager.addDefaultParameter(payload.conversionType, key: "ASAConversionType")
            analyticsManager.addDefaultParameter(payload.countryOrRegion, key: "ASACountryOrRegion")
            analyticsManager.addDefaultParameter(keywordID, key: "ASAKeywordID")
            
        } onNewAttributionPayloadReceived: { payload in
            // Called only when a new ad attribution payload is received
            analyticsManager.send(.asaAttributionReceived, properties: payload.asAnalyticsDictionary)
        }
        self._adAttributionManager = StateObject(wrappedValue: adAttributionManager)
#if TESTFLIGHT
        let shouldShowPaywall = false
#else
        let shouldShowPaywall = appStoreMonitor.serviceEntitlement == .notEntitled
#endif
        self._isShowingPaywall = .init(initialValue: shouldShowPaywall)
        
        appDelegate.analyticsManager = analyticsManager
    }
    
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
                Button("About \(AppConfig.appName)") {
                    appDelegate.showAboutWindow()
                }
            }
            
            CommandGroup(replacing: .help) {
                Button("\(AppConfig.appName) Help") {
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

        // Original icon viewer window
        WindowGroup(id: "original-icon") {
            OriginalIconWindow()
                .environmentObject(OriginalIconStore.shared)
        }
        .defaultSize(width: 512, height: 512)
        .windowResizability(.contentSize)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var aboutWindowController: NSWindowController?
    public weak var analyticsManager: AnalyticsManager?
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Prevent automatic document creation
        UserDefaults.standard.set(false, forKey: "NSShowAppCentricOpenPanelInsteadOfUntitledFile")
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Give macOS a moment to restore windows, then check what we have
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasRestoredDocuments = !NSDocumentController.shared.documents.isEmpty

            // Only show welcome window if no documents were restored
            if !hasRestoredDocuments && self.shouldShowWelcomeWindow(), let welcomeURL = URL(string: "stratify://welcome") {
                // Open the welcome window
                NSWorkspace.shared.open(welcomeURL)
            }

            // Update last launch date
            UserDefaults.standard.set(Date(), forKey: "LastLaunchDate")
        }
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
        window.title = "About \(AppConfig.appName)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        
        aboutWindowController = NSWindowController(window: window)
        aboutWindowController?.showWindow(nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
