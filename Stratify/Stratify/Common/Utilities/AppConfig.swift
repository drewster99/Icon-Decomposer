//
//  AppConfig.swift
//  Stratify
//
//  Created by Andrew Benson on 10/14/25.
//

import Foundation

/// Static app configuration
enum AppConfig {
    // MARK: - App Info
    static let appName = "Stratify"
    static let appBundleID = "com.nuclearcyborg.stratify"
    static let appStoreAppID = "6754545505"

    // MARK: - URLs
    // swiftlint:disable force_unwrapping
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id\(Self.appStoreAppID)")!
    static let appStoreReviewURL = URL(string: "https://apps.apple.com/app/id\(Self.appStoreAppID)")!
    static let termsURL = URL(string: "https://nuclearcyborg.com/terms")!
    static let privacyURL = URL(string: "https://nuclearcyborg.com/privacy")!
    static let websiteURL = URL(string: "https://nuclearcyborg.com")!
    // swiftlint:enable force_unwrapping
    
    // MARK: - Contact
    static let supportEmail = "info@nuclearcyborg.com"
    // swiftlint:disable:next force_unwrapping
    static let supportEmailURL = URL(string: "mailto:\(supportEmail)")!

    // MARK: - App Version
    static var appVersion: String {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(appVersion)(\(buildNumber))"
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
 
}
