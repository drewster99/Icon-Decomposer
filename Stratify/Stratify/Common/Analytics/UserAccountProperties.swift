//
//  UserAccountProperties.swift
//  Stratify
//
//  Created by Andrew Benson on 5/2/25.
//

import Foundation
import SwiftUI
import Combine
import OSLog

public final class UserAccountProperties: ObservableObject {
    let logger = Logger(subsystem: "User", category: "UserAccountProperties")

    /// A shared instance of `UserAccountProperties`
    public static var shared = UserAccountProperties()

    public let accountCreationDate: Date
    private let accountCreationDateKey = "accountCreationDate"
    private let totalAppLaunchesOnThisDeviceKey = "totalAppLaunchesOnDevice"
    private let chosenUserNameKey = "chosenUserName"
    private let selectedFeaturesKey = "selectedFeatures"
    private let selectedUsagesKey = "selectedUsages"

    private let defaults = UserDefaults.standard

    /// Days since account creation
    public var accountAgeDays: Int {
        let days = Date().calendarDaysSince(startDate: accountCreationDate)
        return days
    }

    // MARK: - User Name

    public var chosenUserName: String {
        get {
            defaults.string(forKey: chosenUserNameKey) ?? ""
        }
        set {
            objectWillChange.send()
            defaults.setValue(newValue, forKey: chosenUserNameKey)
        }
    }

    /// The total number of times the app has been launched on this device
    public var totalAppLaunchesOnThisDevice: Int {
        get {
            defaults.integer(forKey: totalAppLaunchesOnThisDeviceKey)
        }
        set {
            objectWillChange.send()
            defaults.setValue(newValue, forKey: totalAppLaunchesOnThisDeviceKey)
        }
    }

    private var _ubiquitousStore: NSUbiquitousKeyValueStore?
    private var ubiquitousStore: NSUbiquitousKeyValueStore? {
        guard isCloudKitUbiquitiousStoreAvailable else {
            logger.log("NSUbiquitousKeyValueStore not available (CloudKit not available or not logged in)")
            _ubiquitousStore = nil
            return nil
        }

        if _ubiquitousStore == nil {
            let store = NSUbiquitousKeyValueStore.default
            logger.log("Sync NSUKVS started")
            let syncResult = store.synchronize()
            logger.log("Sync NSUKVS complete")
            guard syncResult else {
                logger.error("Could not sync NSUbiquitousKeyValueStore.  Project not built correctly.")
#if DEBUG
                fatalError("Could not sync NSUbiquitousKeyValueStore.  Project not built correctly")
#else
                _ubiquitousStore = store
                return _ubiquitousStore
#endif
            }
            _ubiquitousStore = store
        }

        return _ubiquitousStore
    }

    private var isCloudKitUbiquitiousStoreAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    public init() {
        // See if we have saved info
        let accountCreationDate: Date? = UserDefaults.standard.object(forKey: accountCreationDateKey) as? Date
        self.accountCreationDate = accountCreationDate ?? Date()
        defaults.set(self.accountCreationDate, forKey: accountCreationDateKey)
        totalAppLaunchesOnThisDevice += 1
        logger.log("App launch number: \(self.totalAppLaunchesOnThisDevice)")
        logger.log("Account creation date: \(self.accountCreationDate, privacy: .public) (\(self.accountAgeDays) days ago)")
        logger.log("totalAppLaunchesOnThisDevice: \(self.totalAppLaunchesOnThisDevice, privacy: .public)")
        logger.log("user's name: \(self.chosenUserName)")
    }
}

extension UserAccountProperties {
    public var asAnalyticsDictionary: [String: Any?] {
        [
            "accountCreationDate": "\(accountCreationDate)",
            "appLaunches": "\(totalAppLaunchesOnThisDevice)",
            "accountAgeDays": accountAgeDays
        ]
    }
}

extension Date {

    /// Computes and number of calendar days since the given `startDate`.  Days
    /// are counted like you would on a calendar, meaning that the time of day is ignored.
    /// - Parameters:
    ///   - startDate: The beginning `Date` in the date range.`
    /// - Returns: The number of calendar days since the `startDate`, relative to `self`.

    func calendarDaysSince(startDate: Date) -> Int {
        return Date.calendarDaysBetween(start: startDate, end: self)
    }

    /// Computes the number of calendar days between two dates, the way you would
    /// count them on a calendar.  So, for example, if it's 5:00pm now, anytime today
    /// would be considered 0 days, anytime tomorrow is 1 day.  If the given `end`
    /// `Date` is prior to the given `start` `Date`, a negative number of days
    /// will be returned.
    ///
    /// - Parameters:
    ///   - start: The beginning `Date` in the date range.`
    ///   - end: The ending `Date` in the date range.
    /// - Returns: The number of calendar days between the `start` and `end` dates.
    ///
    static func calendarDaysBetween(start: Date, end: Date) -> Int {
        let calendar = Calendar.current

        // Replace the hour (time) of both dates with 00:00
        let date1 = calendar.startOfDay(for: start)
        let date2 = calendar.startOfDay(for: end)

        let a = calendar.dateComponents([.day], from: date1, to: date2)

        guard let daysDifference = a.value(for: .day) else {
            let logger = Logger(subsystem: "User", category: "UserAccountProperties")
            logger.fault("Calendar day calculation failed, falling back to time-based calculation")
            logger.fault("start: \(date1), end: \(date2)")
            // Fallback: calculate using time interval (less precise but safe)
            let timeInterval = date2.timeIntervalSince(date1)
            let approxDays = Int(timeInterval / 86400) // seconds per day
            return approxDays
        }
        return daysDifference
    }
}
