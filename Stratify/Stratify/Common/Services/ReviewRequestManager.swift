//
//  ReviewRequestManager.swift
//  FunVoice
//
//  Manages app store review requests with rate limiting
//

import Foundation
import StoreKit
import OSLog
#if os(iOS)
import UIKit
#endif

final class ReviewRequestManager {
    static let shared = ReviewRequestManager()
    private static let logger = Logger(subsystem: "FunVoice", category: "ReviewRequestManager")

    private let lastReviewRequestDateKey = "lastReviewRequestDate"
    private let hasLaunchedMainViewKey = "hasLaunchedMainView"
    private let minimumDaysBetweenRequests: TimeInterval = 3 // 3 days minimum between requests

    private init() {}

    /// Date the last review was requested
    private var lastReviewRequestDate: Date {
        get {
            UserDefaults.standard.object(forKey: lastReviewRequestDateKey) as? Date ?? Date.distantPast
        }
        set {
            UserDefaults.standard.set(newValue, forKey: lastReviewRequestDateKey)
        }
    }

    /// Check if the main view has been launched before
    private var hasLaunchedMainView: Bool {
        get {
            UserDefaults.standard.bool(forKey: hasLaunchedMainViewKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hasLaunchedMainViewKey)
        }
    }

    /// Mark that the main view has been launched
    func markMainViewLaunched() {
        hasLaunchedMainView = true
    }

    /// Check if we should request a review
    private func shouldRequestReview() -> Bool {
        // Check if enough time has passed since last request
        let daysSinceLastRequest = Date().timeIntervalSince(lastReviewRequestDate) / 86400
        guard daysSinceLastRequest >= minimumDaysBetweenRequests else {
            Self.logger.info("Not requesting review - only \(daysSinceLastRequest) days since last request")
            return false
        }

        return true
    }

    /// Actually perform the review request
    /// - Parameters:
    ///   - analyticsManager: Analytics manager to log the event
    ///   - updateLastRequestDate: Whether to update the last request date
    ///   - properties: Additional analytics properties to track trigger source
    private func performReviewRequest(analyticsManager: AnalyticsManager?, updateLastRequestDate: Bool, properties: [String: Any] = [:]) {
        #if os(iOS)
        Task { @MainActor in
            if let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                Self.logger.info("Requesting app store review with properties: \(properties)")
                analyticsManager?.send(.requestAppStoreReview, properties: properties)

                // Post notification for any listeners
                NotificationCenter.default.post(
                    name: Notification.Name("RequestingAppStoreReview"),
                    object: nil,
                    userInfo: [:]
                )

                // Use the modern AppStore API
                AppStore.requestReview(in: windowScene)

                if updateLastRequestDate {
                    self.lastReviewRequestDate = Date()
                }
            }
        }
        #else
        Task { @MainActor in
            Self.logger.info("Requesting app store review with properties: \(properties)")
            analyticsManager?.send(.requestAppStoreReview, properties: properties)

            NotificationCenter.default.post(
                name: Notification.Name("RequestingAppStoreReview"),
                object: nil,
                userInfo: [:]
            )

            #if os(iOS)
            AppStore.requestReview()
            #elseif os(macOS)
            // TODO: This won't really work - fix it
            #warning("Request review needs fixing")
            AppStore.requestReview(in: NSViewController())
            #endif

            if updateLastRequestDate {
                self.lastReviewRequestDate = Date()
            }
        }
        #endif
    }

    /// Request a review if appropriate conditions are met
    /// - Parameters:
    ///   - delay: Delay in seconds before showing the request
    ///   - analyticsManager: Analytics manager to log the event
    func requestReviewIfAppropriate(delay: TimeInterval = 9.0, analyticsManager: AnalyticsManager?) {
        guard shouldRequestReview() else {
            Self.logger.info("Skipping review request - cooldown period active")
            return
        }

        Self.logger.info("Scheduling review request after \(delay) seconds (generic trigger)")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.performReviewRequest(
                analyticsManager: analyticsManager,
                updateLastRequestDate: true,
                properties: ["trigger": "generic", "delay_seconds": delay]
            )
        }
    }

    /// Request a review on first launch if appropriate
    /// - Parameters:
    ///   - analyticsManager: Analytics manager to log the event
    func requestReviewOnFirstLaunch(analyticsManager: AnalyticsManager?) {
        // Only request on first launch
        guard !hasLaunchedMainView else {
            Self.logger.info("Skipping review request on launch - not first launch")
            return
        }

        // Mark as launched now so we don't request again
        markMainViewLaunched()
        Self.logger.info("First launch detected, marking main view as launched")

        // Check 3-day cooldown
        guard shouldRequestReview() else {
            Self.logger.info("Skipping review request on first launch - cooldown period active")
            return
        }

        Self.logger.info("Scheduling review request after 45 seconds (first launch trigger)")

        // Request after 45 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 45.0) {
            self.performReviewRequest(
                analyticsManager: analyticsManager,
                updateLastRequestDate: true,
                properties: ["trigger": "first_launch", "delay_seconds": 45]
            )
        }
    }

    /// Request a review after successful share
    /// - Parameters:
    ///   - analyticsManager: Analytics manager to log the event
    func requestReviewAfterShare(analyticsManager: AnalyticsManager?) {
        // Check 3-day cooldown
        guard shouldRequestReview() else {
            Self.logger.info("Skipping review request after share - cooldown period active")
            return
        }

        Self.logger.info("Scheduling review request after 5 seconds (share completion trigger)")

        // Request after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.performReviewRequest(
                analyticsManager: analyticsManager,
                updateLastRequestDate: true,
                properties: ["trigger": "share_completed", "delay_seconds": 5]
            )
        }
    }
}
