//
//  AppDelegate.swift
//  PhotoCal
//
//  Created by Andrew Benson on 5/25/25.
//

import Foundation
import OSLog

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
public final class AppDelegate: NSObject, UIApplicationDelegate {
    let logger = Logger(subsystem: "AppDelegate", category: "AppDelegate")
    
    /// Populated by `PhotoCalApp`
    public weak var analyticsManager: AnalyticsManager?

    public func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let analyticsManager {
            // Put analyticsManager into the session's userInfo dict
            if connectingSceneSession.userInfo != nil {
                connectingSceneSession.userInfo?["analyticsManager"] = analyticsManager
            } else {
                connectingSceneSession.userInfo = [
                    "analyticsManager": analyticsManager
                ]
            }
        }
        let configuration = UISceneConfiguration(name: "FunVoice", sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = SceneDelegate.self
        }
        return configuration
    }

    public func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        assert(analyticsManager != nil)
        let signposter = OSSignposter(subsystem: "AppDelegate", category: "Init")
        let signpostID = signposter.makeSignpostID()
        let name: StaticString = "didFinishLaunchingWithOptions()"
        let state = signposter.beginInterval(name, id: signpostID)
        defer {
            signposter.endInterval(name, state)
        }
        analyticsManager?.send(.appDidFinishLaunching)
        return true
    }

    public func applicationWillTerminate(_ application: UIApplication) {
        logger.log("**** \(#function)")
        analyticsManager?.send(.appWillTerminate)
        analyticsManager?.logNonFatalError(AppWillTerminateError())
    }

    struct AppWillTerminateError: Swift.Error, LocalizedError {
        public var errorDescription: String? { "Application will terminate" }
    }

    struct MemoryWarningError: Swift.Error, LocalizedError {
        public var errorDescription: String? { "Application did receive memory warning" }
    }

    struct AppAliveTenSecondsAfterMemoryWarningError: Swift.Error, LocalizedError {
        public var errorDescription: String? { "App is still alive ten seconds after memory warning" }
    }

    public func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        logger.log("**** \(#function)")
        analyticsManager?.send(.appMemoryWarning)
        analyticsManager?.logNonFatalError(MemoryWarningError())

        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.analyticsManager?.send(.appAliveTenSecondsAfterMemoryWarning)
            self?.analyticsManager?.logNonFatalError(AppAliveTenSecondsAfterMemoryWarningError())
        }
    }

    public func applicationDidEnterBackground(_ application: UIApplication) {
        /* WILL NOT BE CALLED BECAUSE WE HAVE A SCENE DELEGATE */
    }

    public func applicationWillEnterForeground(_ application: UIApplication) {
        /* WILL NOT BE CALLED BECAUSE WE HAVE A SCENE DELEGATE */
    }

}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Called if app is in foreground when notification arrives.
    /// The method will be called on the delegate only if the application is in the foreground. If the method is not implemented or
    /// the handler is not called in a timely manner then the notification will not be presented. The application can choose to have
    /// the notification presented as a sound, badge, alert and/or in the notification list. This decision should be based on whether
    /// the information in the notification is otherwise visible to the user.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Don't present the notification at all if the app is in the foreground
        analyticsManager?.send(.notificationReceivedWhileRunning)
        return []
    }

    /// The method will be called on the delegate when the user responded to the notification by opening the application, dismissing the
    /// notification or choosing a `UNNotificationAction`. The delegate must be set before the application returns from
    /// `application:didFinishLaunchingWithOptions:`.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        logger.log("**** didReceive response \(response)")

        if let analyticsManager {
            let result: String
            switch response.actionIdentifier {
            case UNNotificationDismissActionIdentifier:
                result = "dismissed"
            case UNNotificationDefaultActionIdentifier:
                result = "appOpened"
            default:
                result = response.actionIdentifier
            }
            analyticsManager.send(.notificationResponse, properties: [
                "response": result
            ])
        }

    }

    /// The method will be called on the delegate when the application is launched in response to the user's request to view in-app notification settings.
    /// Add `UNAuthorizationOptionProvidesAppNotificationSettings` as an option in `requestAuthorizationWithOptions:completionHandler:`
    /// to add a button to inline notification settings view and the notification settings view in Settings. The notification will be nil when opened from Settings.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        // not implemented
    }
}

#endif

