//
//  APIUsageTracker.swift
//  Stratify
//
//  Created by Andrew Benson on 10/16/25.
//
//  Tracks API usage for limiting non-subscribers
//

import Foundation
import Combine
import OSLog

final class APIUsageTracker: ObservableObject {
    static let shared = APIUsageTracker()
    private static let logger = Logger(subsystem: "APIUsageTracker", category: "APIUsageTracker")
    
    private let userDefaults = UserDefaults.standard
    private let calendar = Calendar.current
    
    private let firstLaunchDateKey = "first_app_launch_date"
    
    private init() {}
    
    /// Get the current date as a string key for UserDefaults
    private var todayKey: String {
        let formatter = DateFormatter()
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return "api_usage_\(formatter.string(from: Date()))"
    }
    
    /// Get the number of API calls made today
    var todayUsage: Int {
        userDefaults.integer(forKey: todayKey)
    }
    
    /// Get the first launch date
    var firstLaunchDate: Date? {
        userDefaults.object(forKey: firstLaunchDateKey) as? Date
    }
    
    /// Record the first launch date if not already recorded
    func recordFirstLaunchIfNeeded() {
        if firstLaunchDate == nil {
            userDefaults.set(Date(), forKey: firstLaunchDateKey)
            Self.logger.info("Recorded first launch date: \(Date())")
        }
    }
    
    /// Get the number of days since first launch
    var daysSinceFirstLaunch: Int {
        guard let firstLaunch = firstLaunchDate else {
            // If no first launch recorded, record it now and return 0
            recordFirstLaunchIfNeeded()
            return 0
        }
        
        let components = calendar.dateComponents([.day], from: firstLaunch, to: Date())
        return components.day ?? 0
    }
    
    /// Check if user can do the key action of the app, such as convert a photo,
    /// record a reverse audio, etc
    func canPerformKeyAction(serviceEntitlement: ServiceEntitlement) -> (allowed: Bool, message: String?) {
        // Paid users have no limits
        guard serviceEntitlement == .notEntitled else {
            return (true, nil)
        }
        
        let daysElapsed = daysSinceFirstLaunch
        let usageToday = todayUsage
        
        Self.logger.info("Days since first launch: \(daysElapsed), usage today: \(usageToday)")
        
        switch daysElapsed {
        case 0:
            // First day - the day the app was first run
            if usageToday >= 5 {
                return (false, "You've reached your limit of 5 free icon layer exports for today. Upgrade for unlimited exports!")
            }
            return (true, nil)

        case 1, 2:
            // Days 2 and 3
            if usageToday >= 2 {
                return (false, "You've reached your limit of 2 free icon layer exports for today. Upgrade for unlimited exports!")
            }
            return (true, nil)

        default:
            // Day 3+: No free identifications
            return (false, "Your free trial has ended. Upgrade for unlimited icon layer exports!")
        }
    }

    /// Increment today's API usage count
    func incrementUsage() {
        let currentUsage = todayUsage
        userDefaults.set(currentUsage + 1, forKey: todayKey)
        Self.logger.info("Incremented usage to \(currentUsage + 1) for today")
    }

#if DEBUG || TESTFLIGHT
    /// Reset today's usage (for testing purposes)
    func resetTodayUsage() {
        userDefaults.removeObject(forKey: todayKey)
    }
    
    /// Reset first launch date (for testing purposes)
    func resetFirstLaunchDate() {
        userDefaults.removeObject(forKey: firstLaunchDateKey)
    }
#endif
}
