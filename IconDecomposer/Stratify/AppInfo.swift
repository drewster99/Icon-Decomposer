//
//  AppInfo.swift
//  Stratify
//
//  Created by Andrew Benson on 10/26/25.
//

import Foundation
import AppKit

struct AppInfo {
    /// Official name for the app
    static let appName: String = "Stratify"

    /// This app's "Apple ID" on the app store
    static let appStoreAppID = "XXXXX" // actual app ID - URLs won't work until app is live

    /// App store URL for this app
    static var appStoreURL: URL {
        guard let url = URL(string: "https://apps.apple.com/app/id\(Self.appStoreAppID)") else {
            fatalError("AppInfo: Can't create appStoreURL")
        }
        return url
    }
    
    /// App store URL to leave a review for the app
    static var appStoreRequestReviewURL: URL {
        guard let url = URL(string: "https://apps.apple.com/app/id\(Self.appStoreAppID)?action=write-review") else {
            fatalError("AppInfo: Can't create appStoreRequestReviewURL")
        }
        return url
    }
    
//    /// API login URL for this app
//    static let appAPILoginURL: URL = {
//        guard let url = URL(string: "https://us-central1-photocaloriecam.cloudfunctions.net/login") else {
//            fatalError("Invalid API login URL")
//        }
//        return url
//    }()

    /// API app version header - name of header (value will use `appVersionString`, below
    static let appAPIAppVersionHeaderName: String = "X-NCC-APP-Version"

    public static var userAgentString: String {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "UnknownApp"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
#if os(macOS)
        let os = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let device = {
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var model = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            return String(cString: model)
        }() ?? "Unknown"
#else
        let os = "iOS \(UIDevice.current.systemVersion)"
        let device = UIDevice.current.model
#endif
        return "\(appName)/\(appVersion) (\(device); \(os); build \(buildNumber))"
    }

    public static var appVersionString: String {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(appVersion)(\(buildNumber))"
    }

    struct UserDefaultsKey {
        static let wasEverATestFlightUser: String = "wasEverATestFlightUserUser"
        
        #if TESTFLIGHT
        static let isOnboardingComplete: String = "tf_isOnboardingComplete"
        static let productionIsOnboardingComplete: String = "isOnboardingComplete"
        #else
        static let isOnboardingComplete: String = "isOnboardingComplete"
        #endif
    }
}
