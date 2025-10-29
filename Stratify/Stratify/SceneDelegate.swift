//
//  SceneDelegate.swift
//  PhotoCalorieCam
//
//  Created by Andrew Benson on 5/25/25.
//

#if os(iOS)
import Foundation
import SwiftUI
import Combine
import OSLog

final class SceneDelegate: NSObject, ObservableObject, UIWindowSceneDelegate {
    private let logger = Logger(subsystem: "FunVoice", category: "SceneDelegate")

    var window: UIWindow?

    public weak var analyticsManager: AnalyticsManager?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        logger.log("***** scene willConnectTo session options \(connectionOptions)")

        // set analyticsManager from userInfo dictionary
        if let analyticsManager = session.userInfo?["analyticsManager"] as? AnalyticsManager {
            self.analyticsManager = analyticsManager
        }

        self.window = (scene as? UIWindowScene)?.keyWindow

        if connectionOptions.notificationResponse != nil {
            analyticsManager?.send(.appLaunchedFromNotification)
        } else {
            analyticsManager?.send(.appLaunchedFromHomeScreen)
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        logger.log("**** \(#function)")
        analyticsManager?.setApplicationState(.background)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        logger.log("**** \(#function)")
        analyticsManager?.setApplicationState(.foreground)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        logger.log("**** \(#function)")
        analyticsManager?.setSceneState(.inactive)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        logger.log("**** \(#function)")
        analyticsManager?.setSceneState(.active)
    }
}
#endif
