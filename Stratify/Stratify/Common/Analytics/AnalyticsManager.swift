//
//  AnalyticsManager.swift
//  Stratify
//
//   Created by Andrew Benson on 3/1/24.
//

import Foundation
import OSLog
import SwiftUI
import StoreKit
import AVFoundation
import Combine

#if canImport(TelemetryClient)
import TelemetryClient
#endif
#if canImport(FirebaseAnalytics)
import Firebase
import FirebaseCore
import FirebaseAnalytics
#endif
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif

private let logger = Logger(subsystem: "Analytics", category: "AnalyticsManager")
public final class AnalyticsManager: ObservableObject, AnalyticsManagerInterfacing {
    private let logger = Logger(subsystem: "Analytics", category: "AnalyticsManager")

    /// Unique identifier for the current user
    @Published var userIdentifier: String = ""

    let sendEventsForDebugBuilds: Bool = false
    private var isDebugBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    /// Event parameters which will be automatically merged with the parameters of every analytics event
    private var defaultEventParameters: [String: Any] = [:]

    private var isFirstAppLaunch: Bool {
        get {
            let alreadyDidFirstLaunch = UserDefaults.standard.bool(forKey: "analyticsManager_firstAppLaunchWasRecorded")
            return !alreadyDidFirstLaunch
        }
        set {
            _ = newValue
            // Intentionally empty - read-only computed property
        }
    }

    private let isActivatedSemaphore = DispatchSemaphore(value: 1)
    private var _isActivated = false
    private var isActivated: Bool {
        get {
            isActivatedSemaphore.wait()
            let result = self._isActivated
            isActivatedSemaphore.signal()
            return result
        }
        set {
            isActivatedSemaphore.wait()
            self._isActivated = newValue
            isActivatedSemaphore.signal()
        }
    }

    private let queueLengthSemaphore = DispatchSemaphore(value: 1)
    private var _queueLength = 0
    private var queueLength: Int {
        get {
            queueLengthSemaphore.wait()
            let result = self._queueLength
            queueLengthSemaphore.signal()
            return result
        }
        set {
            queueLengthSemaphore.wait()
            self._queueLength = newValue
            queueLengthSemaphore.signal()
        }
    }
    private func incrementQueueLength() {
        queueLengthSemaphore.wait()
        _queueLength += 1
        queueLengthSemaphore.signal()
    }
    @discardableResult
    private func decrementQueueLength() -> Int {
        queueLengthSemaphore.wait()
        let newLength = _queueLength - 1
        _queueLength = newLength
        queueLengthSemaphore.signal()
        return newLength
    }

    public func activate() {
        logger.log("*** ACTIVATE() CALLED -- RUNNING DEFERRED ACTIONS ****")
        isActivated = true
        deferredActivationQueue.resume()
    }
    private let deferredActivationQueue: DispatchQueue
    private func runOrDefer(_ title: String, _ action: @escaping () -> Void) {
        queueLengthSemaphore.wait()
        let shouldDefer = _queueLength > 0 || !isActivated

        if shouldDefer {
            _queueLength += 1
        }
        let savedQueueLength = _queueLength
        queueLengthSemaphore.signal()

        if shouldDefer {
            logger.log("**** DEFERRING: \(title) (queue length is \(savedQueueLength))")
            deferredActivationQueue.async { [self] in
                self.logger.log("**** START RUNNING DEFERRED: \(title)")
                action()
                let newQueueLength = self.decrementQueueLength()
                self.logger.log("**** DONE RUNNING DEFERRED: \(title) (queuelength is \(newQueueLength))")
            }
        } else {
            logger.log("**** RUN IMMEDIATE: \(title) (queue length is \(savedQueueLength))")
            action()
        }
    }

    /// appID is a telemetry deck app ID
    /// user is just a user identifier
    public init(telemetryDeckAppID appID: String, onInitDone: @escaping () -> Void) {
        logger.log("*** init AnalyticsManager")

        let queue = DispatchQueue(label: "AnalyticsManagerDeferredActivation", qos: .default, target: .main)
        deferredActivationQueue = queue

        if !isActivated {
            deferredActivationQueue.suspend()
            logger.log("Analytics processing will be deferred until `activate()` is called")
        }

        runOrDefer("Analytics initialization") { [self] in
            self.logger.log("Initializing with TelemtryDeck appID \(appID)")

#if canImport(TelemetryClient)
            logger.log("**** Initialize TelemetryDeck")
            var configuration = TelemetryManagerConfiguration(appID: appID)
            TelemetryDeck.initialize(config: configuration)
#endif

#if canImport(FirebaseAnalytics)
            self.logger.log("**** Initialize Firebase")
            FirebaseApp.configure()
#endif
            let firstLaunchAlreadyRecordedKey = "analyticsManager_firstAppLaunchWasRecorded"
            let alreadyDidFirstLaunch = UserDefaults.standard.bool(forKey: firstLaunchAlreadyRecordedKey)
            if !alreadyDidFirstLaunch {
                self.send(.firstAppLaunch)
                UserDefaults.standard.setValue(true, forKey: firstLaunchAlreadyRecordedKey)
            }

            onInitDone()
        }
    }

    /// Sends an arbitrary event to analytics
    ///
    /// Note: Firebase event names can be a maximum of 40 characters and can only contain
    /// uppercase letters, lowercase letters, numbers, and the underscore.  They must start
    /// with an alphabetic letter.
    private func send(eventName: String, properties: [String: Any?]) {
        let nonNilProperties = properties.compactMapValues({ $0 })
        logger.debug("sending event \(eventName) with properties \(nonNilProperties.keyValueDebugText) [\(self.defaultEventParameters.keyValueDebugText)]")

        let defaultKeys = defaultEventParameters.keys
        nonNilProperties.keys.forEach({ key in
            if defaultKeys.contains(key) {
                logger.fault("Key \"\(key)\" for event with name \"\(eventName)\" shadows default parameter.")
            }
        })

        /// All the event  properties, including the default values
        let propertiesToUse = nonNilProperties.merging(defaultEventParameters) { givenPropertyValue, _ in
            givenPropertyValue
        }

        /// `String` representations of the combined property list.  Any non-convertible values are dropped
        let stringConvertedPropertiesToUse = propertiesToUse.compactMapValues { value in
            anyToStringRepresentation(value)
        }
#if canImport(TelemetryClient)
        if isDebugBuild && !sendEventsForDebugBuilds {
            logger.debug("Debug build - not sending event \(eventName) to TelemetryDeck")
        } else {
            // Send to TelemetryDeck
            TelemetryDeck.signal(eventName, parameters: stringConvertedPropertiesToUse)
        }
#endif

#if canImport(FirebaseAnalytics)
        // Firebase allows a maximum of 40 characters in the event name, per:
        // https://developers.google.com/android/reference/com/google/firebase/analytics/FirebaseAnalytics.Event
        if eventName.count > 40 {
            logger.fault("eventName \"\(eventName)\" exceeds maximum length of 40 characters allowed by Firebase")
        }

        // Firebase analytics event names must start with a letter, and can contain only letters, numbers, and
        // the underscore character, per:
        // https://developers.google.com/android/reference/com/google/firebase/analytics/FirebaseAnalytics.Event
        if let regex = try? Regex("[A-Za-z][A-Za-z0-9_]{0,39}"), (try? regex.wholeMatch(in: eventName)) == nil {
            logger.fault("eventName\"\(eventName)\" does not meet Firebase character requirements")
        }

        // convert properties from types Firebase doesn't seemingly understand
        let convertedProperties: [String: Any] = propertiesToUse.mapValues({ value in

            if value is Date, let value = value as? Date {
                return value.formatted(Date.ISO8601FormatStyle())
            }
            if value is UUID, let value = value as? UUID {
                return value.uuidString
            }

            return value
        })

        if isDebugBuild && !sendEventsForDebugBuilds {
            logger.debug("Debug build - not sending event \(eventName) to Firebase Analytics")
        } else {
            // Send to Firebase/Google Analytics
            Analytics.logEvent(eventName, parameters: convertedProperties)
        }
#endif
    }

    /// Sends a pre-defined event to analytics
    public func send(_ event: AnalyticsManager.Event, eventNameExtension: String = "", properties: [String: Any?] = [:]) {
        let fullEventName = event.name + eventNameExtension
        runOrDefer("Send event \(fullEventName)") {
            self.send(eventName: fullEventName, properties: properties)
        }
    }

    public func post(_ event: AnalyticsEvent) {
        runOrDefer("Post event \(event.eventName)") {
            self.send(eventName: event.eventName, properties: event.properties)
        }
    }
    /// Log a screen view
    public func logScreenView(_ screenName: String, screenClassName: String? = nil) {
        runOrDefer("Log \"\(screenName)\" screen view") { [self] in
            let screenClassNameToUse = screenClassName ?? screenName
            self.logger.debug("logScreenView: \(screenName) (\(screenClassNameToUse))")
            self.send(eventName: "screen_view", properties: [
                "screen_name": screenName,
                "screen_class": screenClassNameToUse
            ])
        }
    }

    /// Sets a persistent identifier for the current user
    public func setUserIdentifier(_ userIdentifier: String) {
        runOrDefer("Set user identifier \"\(userIdentifier)\"") { [self] in
            self.logger.debug("setUserIdentifier: \"\(userIdentifier)\"")
            guard !userIdentifier.isEmpty else {
                self.logger.fault("setUserIdentifier called with empty string")
                return
            }
            self.userIdentifier = userIdentifier
            if isDebugBuild && !sendEventsForDebugBuilds {
                logger.debug("Debug build - not sending user identifier to analytics")
            } else {
#if canImport(TelemetryClient)
                TelemetryDeck.updateDefaultUserID(to: userIdentifier)
#endif
#if canImport(FirebaseAnalytics)
                Analytics.setUserID(userIdentifier)
#endif
            }
#if canImport(FirebaseCrashlytics)
            Crashlytics.crashlytics().setUserID(userIdentifier)
#endif
        }
    }

    /// Adds a default event parameter that will be included will all subsequent analytics events
    public func addDefaultParameter(_ value: Any?, key: String) {
        runOrDefer("Add default parameter \"\(key)\"") { [self] in
            let valueText: String
            if let value {
                valueText = anyToPrintableBasicType(value) ?? "<nil>"
            } else {
                valueText = "<nil>"
            }
            logger.debug("addDefaultParameter \"\(key)\" = \(valueText)")
            if let value {
                defaultEventParameters[key] = value
            } else {
                clearDefaultParameter(key)
            }
        }
    }

    /// Deletes a default event parameter
    public func clearDefaultParameter(_ key: String) {
        runOrDefer("Clear default parameter \"\(key)\"") { [self] in
            logger.debug("clearDefaultParamter: key \"\(key)\"")
            defaultEventParameters.removeValue(forKey: key)
        }
    }

    /// Sets a custom key/value pair that persists throughout the analytics session
    /// Firebase Analytics supports a maximum of 25 user properties.
    /// Firebase allows a maximum of 24 characters for a user property, but the dashboard, when creating
    /// a new custom dimension, will give you an error that says it can't exceed 40.
    /// Telemetry Deck does not support user properties
    public func addUserProperty(_ value: String, key: String) {
        runOrDefer("Add user property \"\(key)\"") { [self] in
            self.logger.debug("addUserProperty: key \"\(key)\" = \"\(value)\"")
            guard !key.isEmpty else {
                self.logger.fault("addUserProperty: key parameter is an empty string")
                return
            }
#if canImport(FirebaseAnalytics)
            guard value.count <= 36 else {
                self.logger.fault("addUserProperty: Value \"\(value)\" for key \"\(key)\" exceeds the Firebase Analytics maximum of 36 characters")
                return
            }
            guard key.count <= 24 else {
                self.logger.fault("addUserProperty: Key \"\(key)\" exceeds the Firebase Analytics maximum of 24 characters")
                return
            }
            if isDebugBuild && !sendEventsForDebugBuilds {
                logger.debug("Debug build - not send user property \(key) to Firebase Analytics")
            } else {
                Analytics.setUserProperty(value, forName: key)
            }
#endif
        }
    }

    /// Deletes a user property (see `addUserProperty`)
    public func clearUserProperty(_ key: String) {
        runOrDefer("Clear user property \"\(key)\"") { [self] in
#if canImport(FirebaseAnalytics)
            guard key.count <= 24 else {
                self.logger.fault("clearUserProperty: Key \"\(key)\" exceeds the Firebase Analytics maximum of 24 characters")
                return
            }
            if isDebugBuild && !sendEventsForDebugBuilds {
                logger.debug("Debug build - not clearing user property \(key) to Firebase Analytics")
            } else {
                Analytics.setUserProperty(nil, forName: key)
            }
#endif
        }
    }

    // MARK: - Camera Permission State Tracking

    private let cameraPermissionStateKey = "analytics_lastKnownCameraPermissionState"

    /// Updates the camera permission state user property and logs changes
    public func updateCameraPermissionState(_ status: AVAuthorizationStatus) {
        let stateString: String
        switch status {
        case .notDetermined: stateString = "notDetermined"
        case .restricted: stateString = "restricted"
        case .denied: stateString = "denied"
        case .authorized: stateString = "authorized"
        @unknown default: stateString = "unknown_\(status.rawValue)"
        }

        // Check if state actually changed
        let lastState = UserDefaults.standard.string(forKey: cameraPermissionStateKey)

        if lastState != stateString {
            // State changed - update user property and log event
            addUserProperty(stateString, key: "cameraPermissionState")

            if let lastState = lastState {
                // Log change event only if we had a previous state
                send(.cameraPermissionStateChanged, properties: [
                    "oldState": lastState,
                    "newState": stateString
                ])
            }

            // Save new state
            UserDefaults.standard.set(stateString, forKey: cameraPermissionStateKey)
        }
    }

    // MARK: - Microphone Permission State Tracking

    private let microphonePermissionStateKey = "analytics_lastKnownMicrophonePermissionState"

    /// Updates the microphone permission state user property and logs changes
    /// Pass the string representation: "UNKNOWN", "DENIED", or "GRANTED"
    public func updateMicrophonePermissionState(_ stateString: String) {
        // Check if state actually changed
        let lastState = UserDefaults.standard.string(forKey: microphonePermissionStateKey)

        if lastState != stateString {
            // State changed - update user property and log event
            addUserProperty(stateString, key: "micPermissionState")

            if let lastState = lastState {
                // Log change event only if we had a previous state
                send(.microphonePermissionStateChanged, properties: [
                    "oldState": lastState,
                    "newState": stateString
                ])
            }

            // Save new state
            UserDefaults.standard.set(stateString, forKey: microphonePermissionStateKey)
        }
    }

    // MARK: - In App Purchase Logging

    /*
     Firebase things not yet implemented:

     Definitely these

     Analytics.handleOpen(<#T##url: URL##URL#>)
     Analytics.handleUserActivity(<#T##userActivity: Any##Any#>)
     Analytics.handleEvents(forBackgroundURLSession: <#T##String#>, completionHandler: <#T##(() -> Void)?##(() -> Void)?##() -> Void#>)

     Possibly these

     Analytics.initiateOnDeviceConversionMeasurement(phoneNumber: <#T##String#>)
     Analytics.initiateOnDeviceConversionMeasurement(emailAddress: <#T##String#>)
     Analytics.initiateOnDeviceConversionMeasurement(hashedPhoneNumber: <#T##Data#>)
     Analytics.initiateOnDeviceConversionMeasurement(hashedEmailAddress: <#T##Data#>)

     Analytics.resetAnalyticsData()

     Analytics.setConsent(<#T##consentSettings: [ConsentType : ConsentStatus]##[ConsentType : ConsentStatus]#>)
     Analytics.sessionID(completion: <#T##(Int64, (any Error)?) -> Void#>)
     Analytics.setSessionTimeoutInterval(<#T##sessionTimeoutInterval: TimeInterval##TimeInterval#>)
     Analytics.setAnalyticsCollectionEnabled(<#T##analyticsCollectionEnabled: Bool##Bool#>)
     Analytics.appInstanceID()
     */

#if canImport(FirebaseAnalytics)
    private var loggedStoreKit2TransactionIDs: [String] {
        get {
            guard let jsonData = UserDefaults.standard.data(forKey: "loggedStoreKit2TransactionIDs") else {
                return []
            }
            let decoder = JSONDecoder()
            do {
                let results = try decoder.decode([String].self, from: jsonData)
                return results
            } catch {
                logger.fault("Unable to decode unintelligible loggedStoreKit2TransactionIDs JSON data: error: \(error)")
                self.logNonFatalError(error)
                return []
            }
        }
        set {
            let encoder = JSONEncoder()
            do {
                let data = try encoder.encode(newValue)
                UserDefaults.standard.setValue(data, forKey: "loggedStoreKit2TransactionIDs")
            } catch {
                logger.fault("Unable to encode loggedStoreKit2TransactionIDs to JSON for storage: error: \(error)")
                self.logNonFatalError(error)
            }

        }
    }
#endif

    /// Log StoreKit2 transactions
    public func logStoreKit2Transaction(_ transaction: StoreKit.Transaction) {
        runOrDefer("Log StoreKit2 transaction for product ID \"\(transaction.productID)\"") { [self] in
#if canImport(FirebaseAnalytics)

            if isDebugBuild {
                logger.debug("Debug build - not logging StoreKit2 transaction to Firebase Analytics")
                return
            }

            let transactionID = "\(transaction.id)"

            if loggedStoreKit2TransactionIDs.isEmpty == false {
                logger.debug("StoreKit2 transaction IDs previously logged:")
                for id in loggedStoreKit2TransactionIDs {
                    logger.debug("  StoreKit2 transaction ID: \(id)")
                }
            }

            let props = transaction.analyticsParams
            if loggedStoreKit2TransactionIDs.contains(transactionID) {
                logger.log("already logged transaction ID \(transactionID)")
                DispatchQueue.main.async {
                    self.send(.gaIAPEventAlreadyLogged, properties: props)
                }
            } else {
                logger.log("logging new transaction with ID \(transactionID)")
                loggedStoreKit2TransactionIDs.append(transactionID)
                Analytics.logTransaction(transaction)
                DispatchQueue.main.async {
                    self.send(.gaIAPEventLogged, properties: props)
                }
            }
#endif
        }
    }
    /// Set a custom key/value pair that will be included to provide context to crashes
    /// and non-fatal errors.  Firebase allows a maximum of 64 key/value pairs, per:
    /// https://firebase.google.com/docs/crashlytics/customize-crash-reports?platform=ios
    public func addToCrashContext(_ value: Any, key: String) {
        runOrDefer("Add to crash context \"\(key)\"") { [self] in
            var valueAsText: String
            if let boolValue = value as? Bool {
                valueAsText = "\(boolValue)"
            } else if let doubleValue = value as? Double {
                valueAsText = "\(doubleValue)"
            } else if let stringValue = value as? String {
                valueAsText = "\"\(stringValue)\""
            } else if let stringConvertibleValue = value as? CustomStringConvertible {
                valueAsText = stringConvertibleValue.description
            } else if let debugStringConvertibleValue = value as? CustomDebugStringConvertible {
                valueAsText = debugStringConvertibleValue.debugDescription
            } else {
                valueAsText = "<not nil>"
            }
            self.logger.debug("addToCrashContext: key \"\(key)\" = \(valueAsText)")
#if canImport(FirebaseCrashlytics)
            Crashlytics.crashlytics().setCustomValue(value, forKey: key)
#endif
        }
    }

    /// Removes a custom key value pair from crash and non-fatal error context
    public func removeFromCrashContext(_ key: String) {
        runOrDefer("Remove key \"\(key)\" from crash context") { [self] in
            self.logger.debug("removeFromCrashContext: key \"\(key)\"")
#if canImport(FirebaseCrashlytics)
            Crashlytics.crashlytics().setCustomValue(nil, forKey: key)
#endif
        }
    }

    /// Log a non-fatal error
    public func logNonFatalError(_ error: Error) {
        runOrDefer("Log non-fatal error \"\(error.localizedDescription)\"") { [self] in
            self.logger.debug("logNonFatalError: \(error)")
#if canImport(FirebaseCrashlytics)
            Crashlytics.crashlytics().record(error: error)
#endif
        }
    }

    /// Log a message that may give context if there is a crash or non-fatal error
    /// Firebase limits total breadcrumb message storage to 64 KB.  If that limit
    /// is exceeded, older messages are discarded.
    public func logHighImportanceBreadcrumbMessage(_ message: String) {
        runOrDefer("Log high importance breadcrumb message \"\(message)\"") { [self] in
            self.logger.debug("logHighImportanceBreadcrumbMessage: \"\(message)\"")
#if canImport(FirebaseCrashlytics)
            Crashlytics.crashlytics().log(message)
#endif
        }
    }

    public func setApplicationState(_ state: ApplicationState) {
        runOrDefer("Set application state \"\(state.rawValue)\"") { [self] in
            logger.log("setApplicationState \(state.rawValue)")
            addDefaultParameter(state.rawValue, key: "appState")
            switch state {
            case .background: send(.appInBackground)
            case .foreground: send(.appInForeground)
            }
        }
    }

    public func setSceneState(_ state: SceneState) {
        runOrDefer("Set scene state \"\(state.rawValue)\"") { [self] in
            logger.log("setSceneState \(state.rawValue)")
            addDefaultParameter(state.rawValue, key: "sceneState")
            switch state {
            case .inactive: send(.sceneInactive)
            case .active: send(.sceneActive)
            }
        }
    }
}

public extension AnalyticsManager {
    enum SceneState: String {
        case active
        case inactive
    }
}

public extension AnalyticsManager {
    enum ApplicationState: String {
        case foreground
        case background
    }
}

public extension AnalyticsManager {
    enum Event: String {
        // app lifecycle

        case firstAppLaunch

        case appLaunch
        case appLaunchedFromHomeScreen
        case appLaunchedFromNotification
//        case appLaunchedFromShortcut
        case appInForeground
        case appInBackground
        case appDidFinishLaunching
        case appWillTerminate
        case appMemoryWarning
        case appAliveTenSecondsAfterMemoryWarning

        case sceneInactive
        case sceneActive

        // request app store review from user
        case requestAppStoreReview
        
//        // verification of app transaction
//
//        case appTransactionVerifyAttempt
//        case appTransactionVerifySuccess
//        case appTransactionVerifyFail
//
//        // trial expired paywall lifecycle
//        case trialExpiredWallAppeared
//        case trialExpiredWallDisappeared
//        case trialExpiredActivateLifetimeTap
//        case trialExpiredRestorePurchases
//
//        // trial expired paywall user actions
//        case trialExpiredTapPrivacyPolicy
//        case trialExpiredTapRestorePurchases
//        case trialExpiredTapTermsOfUse
        case settingsScreenRestorePurchases

//        // whenever a lifetime purchase is started by user clicking purchase / buy / etc
//        case purchaseLifetimeStarted

        // the user taps to open the settings screen
        case settingsButtonTap

        // user actions from the settings screen
//        case settingsTapGetLifetime
//        case settingsTapActivateLifetime
        case settingsTapContactUs
        case settingsTapPrivacyPolicy
        case settingsTapTermsOfUse

        case showInitialPaywall
        case showPaywall

        // AppStoreMonitor
        case serviceEntitlement
        case purchaseBegan
        case purchaseSuccess
        case purchaseUserCancel
        case purchasePending
        case purchaseFail
        case purchaseUnknownResult

        case purchaseIntentReceived

        // When the Settings screen calls OpenURL
        case appSettingsOpenURLSuccess
        case appSettingsOpenURLFail

        // Posted whenever an Apple Search Ads install attribution record is received
        case asaAttributionReceived

        case purchaseButtonTap
        case maybeLaterButtonTap
        case purchaseViewAlertOKTap
        case purchaseViewRestoreTap
        case purchaseViewRedeemTap
        case purchaseViewPrivacyTap
        case purchaseViewTermsTap

        case offerCodeRedeemSuccess
        case offerCodeRedeemError

        case loginOK
        case loginFail
        
        case loginMessageShown
        case loginMessageButtonTap

        // Camera permission events
        case cameraPermissionStateChanged
        case addFoodTapEnableCamera
        case onboardingDidSkipScreen
        case onboardingDidTapMaybeLaterFrom

        case photoListRetryTap
        case photoListShowDetailsTap
        case photoListDeletePhotoTap
        case photoListSharePhotoTap
        case photoListDoneButtonTap
        case photoListSelectButtonTap
        case photoListShareSelectionButtonTap
        case photoListDeleteSelectionButtonTap

        case chatRequestContextExceeded
        case chatRequestStart
        case chatRequestComplete

        // MARK: - TAB NAVIGATION
        case tabShowOverview
        case tabShowHistory
        case tabShowAddFood
        case tabShowFoodLog
        case tabShowSettings

        // MARK: - CAMERA/PHOTO CAPTURE
        case addFoodCameraShutterTap
        case addFoodLibraryButtonTap
        case addFoodManualTap

        // MARK: - MANUAL FOOD ENTRY
        case manualEntryCancelTap
        case manualEntrySaveTap
        case manualEntryAutofillTap
        case manualEntrySaveAnywayTap
        case manualEntryZeroMacrosCancelTap
        case manualEntryErrorOKTap

        // MARK: - FOOD ENTRY INTERACTIONS
        case foodLogLongPressed
        case foodLogDeleteMenuTap
        case foodLogDeleteConfirmTap
        case foodLogDeleteCancelTap
        case foodLogEntryRowTap
        case foodEditButtonTap
        case foodEditDoneButtonTap
        case foodPhotoThumbnailTap
        case foodPhotoDoneTap
        case foodGoToDayTap
        case foodSeeEverythingTodayTap
        case foodDateInfoOKTap
        case foodLogShowImagesToggleTap

        // MARK: - EDIT FOOD ENTRY
        case editFoodCancelTap
        case editFoodSaveTap
        case editFoodRecalculateTap
        case editFoodErrorOKTap

        // MARK: - DAY DETAIL VIEW
        case dayDetailDoneTap
        case dayDetailAddFoodTap
        case dayDetailEditTargetTap

        // MARK: - OVERVIEW SCREEN
        case overviewSeeDetailsTap
        case overviewAddFoodTap
        case overviewCaloriesTap
        case overviewTargetTap
        case overviewMacrosTap
        case overviewPreviousDayTap
        case overviewNextDayTap

        // MARK: - BULK IMPORT
        case bulkImportCancelTap
        case bulkImportDoneTap
        case bulkImportPhotoThumbnailTap
        case bulkImportRetryTap
        case bulkImportViewOriginalTap
        case bulkImportAddAnywayTap
        case bulkImportEntryTap

        // MARK: - DUPLICATE PHOTO SHEET
        case duplicatePicEditTap
        case duplicatePicAddAnywayTap
        case duplicatePicCancelTap

        // MARK: - LOGIN/ERROR RECOVERY
        case loginFailedTryAgainButtonTap

        // MARK: - HISTORY/SUMMARY VIEW
        case historyTimeFrameButtonTap
        case historyShowPhotoToggleTap
        case historyFoodRowTap

        // MARK: - SETTINGS
        case settingsEditTargetTap
        case settingsTargetHistoryTap
        case settingsExportAllDataTap
        case settingsImportAllDataTap
        case settingsReviewAppTap
        case settingsContactTap
        case settingsContactUsTap
        case settingsTermsLinkTap
        case settingsPrivacyLinkTap
        case settingsShareAppTap
        case settingsManageSubTap
        case settingsUnlockFeaturesTap
        case settingsSubscriptionTap
        case settingsExportSuccessOKTap
        case settingsToggleFoodLogImages
        case settingsToggleWeeklyImages
        case settingsToggleMonthlyImages
        case settingsExportErrorOKTap
        case settingsImportConfirmTap
        case settingsImportCancelTap
        case settingsImportSuccessOKTap
        case settingsImportErrorOKTap
        case settingsCopyEmailOKTap

        // MARK: - EDIT TARGET VIEW
        case editTargetCancelTap
        case editTargetSaveTap

        // MARK: - TARGET HISTORY VIEW
        case targetHistoryDoneTap

        // MARK: - HISTORY/SUMMARY VIEW
        case historyTimeFrameAllTap
        case historyTimeFrameThisWeekTap
        case historyTimeFrameLastWeekTap
        case historyTimeFrameThisMonthTap
        case historyTimeFrameLastMonthTap
        case historyEditTargetTap
        case historyShowPhotosToggleTap
        case historyDayEntriesDoneTap

        // MARK: - CAMERA PERMISSION
        case requestCameraResultApproved
        case requestCameraResultDeclined
        case noCameraOpenSettingsTap

        // MARK: - DISCLAIMER VIEW
        case disclaimerTermsLinkTap
        case disclaimerPrivacyLinkTap
        case disclaimerContinueTap

        // MARK: - LOGIN/ERROR RECOVERY
        case loginFailedTryAgainTap
        case dataErrorCloseTap
        case dataErrorReportTap
        
        // MARK: - VISUAL TIMER -- START
        case appSettingsAppear
        case appSettingsDisappear
//
//        case notificationPopupShowAlert
//        case notificationPopupChooseEnable
//        case notificationPopupChooseNotNow
//        case notificationAuthChooseAuthorize
//        case notificationAuthChooseDeny
//        case notificationScheduled
//        case notificationCleared
        case notificationReceivedWhileRunning
//
        case notificationResponse
//
//        case buttonTapSettings
//        case buttonTapStart
//        case buttonTapStop
//        case buttonTapTimerPreset
//        case buttonTapCustomPreset
//        case buttonTapManageSubscriptions
//        case buttonTapContactUs
//        case buttonTapTermsOfUse
//        case buttonTapPrivacyPolicy
//        case buttonTapSeeSubscriptionOptions
//
//        case timerPresetSelected
//        case timerCustomPresetSelected
//        case timerCompletedViewShown
//        case timerCompletedViewDismissed
//        case timerStarted
//        case timerExpired
//        case timerStopped
//
//        case timerStateCleared
//        case timerStateSaved
//        case timerStateRestored
//        case timerStateNothingToRestore
//
//        case timerScreenShowOptionsSelected
//
//        case applicationIdleTimerDisabled
//        case applicationIdleTimerEnabled
//
//        case soundPlayed
//
//        case paywallShowFromTimerPresetSelect
//        case paywallShowFromSettings
//        case paywallShowFromTimerStart
//        case paywallAppeared
//
//        case specialAccessGestureRecognized
//
        case subscriptionChanged
//        case subscriptionManagerOpened
//        case subscriptionManagerClosed
//        // MARK - VISUAL TIMER -- END

        // MARK: - ONBOARDING
        case onboardingDidStart
        case onboardingDidShowScreen
        case onboardingDidTapContinueFrom
        case onboardingDidEnterName
        case onboardingAllSetDisplayed
        case onboardingDidComplete
        case onboardingChosenUsage
        case onboardingChosenFeature

        // MARK: - DISCLAIMER
        case disclaimerAccepted
        case onboardingAgreedToTerms

        // MARK: - RECORDING
        case recordButtonStartTap
        case recordButtonStopTap
        case recordingStarted
        case recordingFinished
        case recordingTimeLimitReached
        case playOriginalStartTap
        case playOriginalStopTap
        case playEffectStartTap
        case playEffectStopTap
        case playEffectREVERSE
        case playEffectCHIPMUNK
        case playEffectGIANT

        // MARK: - SHARE FLOW
        case shareButtonTap
        case shareScreenAppear
        case shareScreenVariantSelect_REVERSE
        case shareScreenVariantSelect_CHIPMUNK
        case shareScreenVariantSelect_ORIGINAL
        case shareScreenVariantSelect_GIANT
        case shareScreenShareTap
        case shareRecordingStart
        case shareRecordingOriginalStart
        case shareRecordingReverseStart
        case shareRecordingChipmunkStart
        case shareRecordingGiantStart
        case exportFilePrepared
        case shareSucceeded
        case shareCancelled
        case shareFailedWithError

        // MARK: - SETTINGS SCREEN (FUNVOICE)
        case settingsGearTap
        case settingsRateAppTap
        case settingsOpenSettingsAppTap
        case settingsContactSupportTap
        case settingsEraseAllRecordingsTap
        case settingsTermsOfUseTap
        case settingsPrivacyPolicyTap

        // MARK: - MICROPHONE PERMISSION
        case requestingMicrophoneAccess
        case microphonePermissionGranted
        case microphonePermissionDenied
        case microphonePermissionStateChanged

        // MARK: - AUDIO SESSION INTERRUPTIONS
        case audioSessionInterrupted

        // Google analytics / Firebase notable events
        case gaIAPEventLogged
        case gaIAPEventAlreadyLogged

        /// Remember names should be max 40 characters for Firebase
        public var name: String {
            rawValue
        }
    }
}

extension Dictionary where Key == String, Value == String {
    var keyValueDebugText: String {
        var keyValues: [String] = []
        for key in keys.sorted() {
            if let value = self[key] {
                keyValues.append("\(key)=\(value)")
            }
        }
        return keyValues.joined(separator: ", ")
    }
}

extension Dictionary where Key == String, Value == Any {
    var keyValueDebugText: String {
        var keyValuePairs: [String] = []
        for key in keys.sorted() {
            guard let value = self[key] else { continue }
            guard let valueText = anyToPrintableBasicType(value) else {
                logger.fault("analytics property for key \"\(key)\" with value of type \(type(of: value)) is not a basic type")
                continue
            }
            keyValuePairs.append("\(key)=\(valueText)")
        }
        return keyValuePairs.joined(separator: ", ")
    }
}

public extension Bool {
    var analyticsValue: String {
        self ? "1" : "0"
    }
}

public extension Dictionary where Key == String, Value == String {
    func mergingAnalyticsDict(_ other: [String: String]) -> [String: String] {
        self.merging(other) { _, new in
            new
        }
    }
}

public extension Dictionary where Key == String, Value == String {
    func mergingAnalyticsDict(_ other: [String: Any?]) -> [String: Any?] {
        var result: [String: Any?] = self

        for key in other.keys {
            result[key] = other[key]
        }

        return result
    }
}

// MARK: - ANALYTICS MANAGER INTERFACE
public protocol AnalyticsManagerInterfacing: AnyObject {
    func post(_ event: any AnalyticsEvent)
    func logNonFatalError(_ error: Error)
}

public protocol AnalyticsEvent {
    var eventName: String { get }
    var properties: [String: Any?] { get }
}

public protocol AnalyticsEventLogging: AnyObject {
    var analyticsManagerInterface: AnalyticsManagerInterfacing? { get set }
    func postAnalytics(_ event: Event)
    func logNonFatalError(_ error: Error)

    associatedtype Event: AnalyticsEvent
}

public struct SimpleAnalyticsEvent: AnalyticsEvent {
    public let eventName: String
    public let properties: [String: Any?]

    public init(eventName: String, properties: [String: Any?]) {
        self.eventName = eventName
        self.properties = properties
    }
}

extension AnalyticsEvent where Self == SimpleAnalyticsEvent {
    public static func simple(eventName: String, properties: [String: Any?]) -> SimpleAnalyticsEvent {
        SimpleAnalyticsEvent(eventName: eventName, properties: properties)
    }
}

extension AnalyticsEventLogging {

    func postAnalytics(eventName: String, properties: [String: Any?]) {
        analyticsManagerInterface?.post(SimpleAnalyticsEvent(eventName: eventName, properties: properties))
    }
    func postAnalytics(_ event: Event) {
        guard let analyticsManagerInterface else {
            logger.warning("postAnalytics event with name \(event.eventName): class \(type(of: self)) not registered - analyticsManagerInterface is nil")
            return
        }

        analyticsManagerInterface.post(event)
    }
    public func logNonFatalError(_ error: Error) {
        guard let analyticsManagerInterface else {
            logger.warning("logNonFatalError: class \(type(of: self)) not registered - analyticsManagerInterface is nil")
            return
        }
        analyticsManagerInterface.logNonFatalError(error)
    }
}

/// Converts a value of type `Any` to something printable, for debugging purposes
/// Only simple types (`Double`, `Int`, `Bool`, and `String` are supported).
func anyToPrintableBasicType(_ value: Any) -> String? {
    var result: String

    if value is UInt64, let uInt64Value = value as? UInt64 {
        result = "\(uInt64Value)"
    } else if let doubleValue = value as? Double {
        result = "\(doubleValue)"
    } else if let intValue = value as? Int {
        result = "\(intValue)"
    } else if let boolValue = value as? Bool {
        result = "\(boolValue)"
    } else if let stringValue = value as? String {
        result = "\"\(stringValue)\""
    } else {
        return nil
    }
    return result
}

/// Converts a value of type `Any` to a `String` representation of said value.
/// Used for converting analytics parameter dictionaries of type `[String: Any]`
/// to `[String: String]`, for analytics providers which only support `String` types.
/// Only simple types (`Double`, `Int`, `Bool`, and `String` are supported).
func anyToStringRepresentation(_ value: Any) -> String? {
    var result: String
    if let uuidValue = value as? UUID {
        result = uuidValue.uuidString
    } else if let dateValue = value as? Date {
        result = "\(dateValue)"
    } else if let doubleValue = value as? Double {
        result = "\(doubleValue)"
    } else if let intValue = value as? Int {
        result = "\(intValue)"
    } else if let boolValue = value as? Bool {
        result = "\(boolValue ? "1" : "0")"
    } else if let stringValue = value as? String {
        result = "\(stringValue)"
    } else {
        return nil
    }

    return result
}

extension AnalyticsManager {
    public func registerLoggingObject<T: AnalyticsEventLogging>(_ loggingObject: T) {
        loggingObject.analyticsManagerInterface = self
    }
}

extension StoreKit.Transaction {
    var analyticsParams: [String: Any?] {

        let productTypeParamValue = switch productType {
        case .autoRenewable: "autoRenewable"
        case .nonRenewable: "nonRenewable"
        case .consumable: "consumable"
        case .nonConsumable: "nonConsumable"
        default: "raw_\(productType.rawValue)"
        }

        let environmentParamValue = switch environment {
        case .sandbox: "sandbox"
        case .production: "production"
        case .xcode: "xcode"
        default: "raw_\(environment.rawValue)"
        }

        let reasonValue = switch reason {
        case .purchase: "purchase"
        case .renewal: "renewal"
        default: "raw_\(reason.rawValue)"
        }

        let ownershipTypeValue = switch ownershipType {
        case .familyShared: "familyShared"
        case .purchased: "purchased"
        default: "raw_\(ownershipType.rawValue)"
        }
        let params: [String: Any?] = [
            "transactionID": id,
            "originalID": originalID,
            "productID": productID,
            "purchaseDate": purchaseDate,

            // calling this one IAPOriginalPurchaseDate to clarify that it's
            // for an in app purchase, and not the APP'S original purchase date
            "iapOriginalPurchaseDate": originalPurchaseDate,
            "purchaseQuantity": purchasedQuantity,
            "productType": productTypeParamValue,
            "environment": environmentParamValue,
            "isUpgraded": isUpgraded,
            "reason": reasonValue,
            "storefrontID": storefront.id,
            "storefrontCountryCode": storefront.countryCode,
            "ownershipType": ownershipTypeValue
        ]

        let revocationReasonParamValue: String?
        switch revocationReason {
        case .developerIssue:
            revocationReasonParamValue = "developerIssue"
        case .other:
            revocationReasonParamValue = "other"
        default:
            if let revocationReason {
                revocationReasonParamValue = "raw_\(revocationReason.rawValue)"
            } else {
                revocationReasonParamValue = nil
            }
        }

        let offerTypeValue: String? = switch offer?.type {
        case .code: "code"
        case .introductory: "introductory"
        case .promotional: "promotional"
        case .some(let offerType):
            "raw_\(offerType.rawValue)"
        case .none: nil
        }

        let paymentModeValue: String?
            paymentModeValue = switch offer?.paymentMode {
            case .payUpFront: "payUpFront"
            case .payAsYouGo: "payAsYouGo"
            case .freeTrial: "freeTrial"
            case .some(let mode): "raw_\(mode.rawValue)"
            case .none: nil
            }

        let paramsWithPossibleNilValues: [String: Any?] = [
            "appAccountToken": appAccountToken,
            "revocationDate": revocationDate,
            "revocationReason": revocationReasonParamValue,
            "subscriptionGroupID": subscriptionGroupID,
            "expirationDate": expirationDate,
            "offerID": offer?.id ?? "<nil>",
            "offerType": offerTypeValue,
            "offerPaymentMode": paymentModeValue,
            "price": price as? NSNumber,
            "currency": currency?.identifier
        ]
        let withNilsRemoved = paramsWithPossibleNilValues.filter { element in
            element.value != nil
        }

        let result = params.merging(withNilsRemoved) { a, _ in
#if DEBUG
            fatalError("Duplicate keys")
#else
            a
#endif
        }
        return result
    }
}
