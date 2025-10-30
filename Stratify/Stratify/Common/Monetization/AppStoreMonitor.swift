//
//  AppStoreMonitor.swift
//  Stratify
//
//  Created by Andrew Benson on 2/16/25.
//  Copyright © 2025 Nuclear Cyborg. All rights reserved.
//

import Foundation
import SwiftUI
import StoreKit
import Combine
import OSLog

#if canImport(RevenueCat)
import RevenueCat
#endif

extension ServiceEntitlement {
    public var uiSettingsDescription: String {
        switch self {
        case .notEntitled: "Free limited access to basic features.\n"
        case .basic: "Basic features with some limits."
        case .pro:  "All the Basic features plus Pro"
        case .max:  "Full access to everything"
        }
    }
}

public struct AppStoreConfiguration {
    // MARK: - START PER APP CONFIGURATION
    
    /// IDs for products that will be shown to the user on the paywall screen.
    /// These are the only product IDs that should be used for new purchases.
    /// Each of these must be present in one of `basicProductIDs`, `proProductIDs`
    /// or `maxProductIDs`
    public static let activeProductIDs = [
        "funvoice_max_1y",
        "funvoice_max_1m",
        "funvoice_max_1w"
    ]
    
    /// Subscription product IDs provide ServiceEntitlement level `.basic`
    public static let basicProductIDs: [String] = []
    
    /// Subscription product IDs provide ServiceEntitlement level `.pro`
    public static let proProductIDs: [String] = [] 
    
    /// Subscription product IDs provide ServiceEntitlement level `.max`
    public static let maxProductIDs = [
        "funvoice_max_1y",
        "funvoice_max_1m",
        "funvoice_max_1w"
    ]
    
    /// All product IDs ever used. Never delete anything from this list
    public static var productIDs: [String] {
        basicProductIDs + proProductIDs + maxProductIDs
    }
    
    /// If present, this is the RevenueCat API key - STRATIFY APP
    public static let revenueCatAPIKey: String = "appl_teapMlIuXiPvXPKhTfsEpnAnvMV"
    // MARK: - END OF PER APP CONFIGURATION
}

final class AppStoreMonitor: ObservableObject {
    private static let logger = Logger(subsystem: "Monetization", category: "AppStoreMonitor")
    
    typealias Transaction = StoreKit.Transaction
    typealias RenewalInfo = StoreKit.Product.SubscriptionInfo.RenewalInfo
    typealias RenewalState = StoreKit.Product.SubscriptionInfo.RenewalState
    
    /// Products - returned by StoreKit based on our `productIDs` list
    @Published var products: [Product] = []
    
    /// Subset of `products`, above, which are auto renewable subscriptions
    @Published var subscriptions: [Product] = []
    
    /// Subset of `subscriptions` which are currently purchased/active
    @Published var purchasedSubscriptions: [Product] = []
    
    /// The current `ServiceEntitlement` for this user
    @Published public private(set) var serviceEntitlement: ServiceEntitlement {
        didSet {
            UserDefaults.standard.set(serviceEntitlement.rawValue, forKey: AppStoreMonitor.lastServiceEntitlementLevelKey)
        }
    }
    static let lastServiceEntitlementLevelKey: String = "lastServiceLevelEntitlementKey"
    
    /// A set of transaction IDs already sent to analytics. We store this in `UserDefaults` between
    /// runs to avoid sending duplicates
    private var transactionIdsAlreadySentToAnalytics: Set<UInt64> {
        get {
            let array: [UInt64] = UserDefaults.standard.array(forKey: "transactionIdsAlreadySentToAnalytics") as? [UInt64] ?? []
            var newSet: Set<UInt64> = []
            array.forEach { newSet.insert($0) }
            return newSet
        }
        set {
            let array = [UInt64](newValue)
            UserDefaults.standard.set(array, forKey: "transactionIdsAlreadySentToAnalytics")
        }
    }
    
    /// Weak `AnalyticsManager` reference
    public weak var analyticsManager: AnalyticsManager?
    private var updateListenerTask: Task<Void, Error>?
    private var purchaseIntentTask: Task<Void, Error>?
    public init(analyticsManager: AnalyticsManager?) {
        Self.logger.log("AppStoreMonitor.init()")
        self.analyticsManager = analyticsManager
        
        // Get saved serviceEntitlement value
        let lastServiceEntitlement: ServiceEntitlement = {
            let rawValue = UserDefaults.standard.integer(forKey: Self.lastServiceEntitlementLevelKey)
            if let serviceEntitlement = ServiceEntitlement(rawValue: rawValue) {
                Self.logger.log("init: Restored saved ServiceEntitlement: \(serviceEntitlement.analyticsName, privacy: .public) (\(serviceEntitlement.rawValue, privacy: .public))")
                return serviceEntitlement
            } else {
                Self.logger.log("init: No saved ServiceEntitlement. Starting with .notEntitled")
                return .notEntitled
            }
        }()
        analyticsManager?.addUserProperty(String(lastServiceEntitlement.analyticsName), key: "serviceEntitlement")
        analyticsManager?.addUserProperty(String(lastServiceEntitlement.rawValue), key: "serviceEntitlementLevel")
        self._serviceEntitlement = .init(initialValue: lastServiceEntitlement)
        
        let signposter = OSSignposter(subsystem: "AppStoreMonitor", category: "init")
        let signpostID = signposter.makeSignpostID()
        let name: StaticString = "init()"
        let state = signposter.beginInterval(name, id: signpostID)
        defer {
            signposter.endInterval(name, state)
        }
        
#if canImport(RevenueCat)
        // RevenueCat integration
        Self.logger.log("init: Configuring RevenueCat")
        Purchases.logLevel = .debug
        Purchases.configure(
            with: .init(withAPIKey: AppStoreConfiguration.revenueCatAPIKey)
                .with(purchasesAreCompletedBy: .myApp, storeKitVersion: .storeKit2)
        )
        Purchases.shared.attribution.enableAdServicesAttributionTokenCollection()
        Self.logger.log("init: RevenueCat configuration complete")
#endif
        
        // Start a transaction listener as close to app launch as possible so you don't miss any transactions.
        updateListenerTask = listenForTransactions()
        
        Task {
            // During store initialization, request products from the App Store.
            Self.logger.log("init: requesting products")
            await updateProducts()
            
            if products.isEmpty {
                Self.logger.log("init: products array empty - requesting user login")
                Task { await requestUserLogin() }
            }
        }
        
        // Start a purchase intent listener
        purchaseIntentTask = listenForPurchaseIntents()
    }
    
    deinit {
        updateListenerTask?.cancel()
    }
    
    private func listenForPurchaseIntents() -> Task<Void, Error> {
        Task.detached { [self] in
            await Self.logger.log("listenForPurchaseIntents Listening for purchase intents")
            for await purchaseIntent in PurchaseIntent.intents {
                await Self.logger.log("listenForPurchaseIntents: Received a purchase intent for \(purchaseIntent.product.id, privacy: .public)")
                var properties = await purchaseIntent.product.getAnalyticsDictionary()
                properties["purchaseIntentID"] = purchaseIntent.id
                for (key, value) in await purchaseIntent.offer?.analyticsDictionary ?? [:] {
                    properties[key] = value
                }
                await analyticsManager?.send(.purchaseIntentReceived, properties: properties)
                do {
                    _ = try await purchase(purchaseIntent.product)
                } catch {
                    await Self.logger.error("listenForPurchaseIntents: purchase of product \(purchaseIntent.product.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
    
    private func processUnfinishedTransactions() async {
        Self.logger.log("processUnfinishedTransactions()")
        for await result in Transaction.unfinished {
            Self.logger.log("processUnfinishedTransactions: Processing unfinished transaction: \(result.debugDescription, privacy: .public)")
            switch result {
            case .verified(let transaction):
                Self.logger.log("   Unfinished transaction VERIFIED for product ID \(transaction.productID, privacy: .public) - finishing it")
                Self.logger.log("         transaction ID \(transaction.id, privacy: .public)")
                Self.logger.log("       purchase date: \(transaction.purchaseDate, privacy: .public)")
                
                // This never came back, it seems.  wtf is up with that?
                //                if let stat = await verifiedTransaction.subscriptionStatus {
                //                    Self.logger.log("         status.state: \(stat.state.rawValue, privacy: .public)")
                //                }
                if let expirationDate = transaction.expirationDate {
                    Self.logger.log("       expiration: \(expirationDate, privacy: .public)")
                }
                if let revocationDate = transaction.revocationDate {
                    Self.logger.log("       revocation: \(revocationDate, privacy: .public)")
                    if let r = transaction.revocationReason {
                        Self.logger.log("       revocation reason: \(r.rawValue, privacy: .public)")
                    }
                }
                await transaction.finish()
                Self.logger.log("         Verified transaction FINISHED")
            case .unverified(let transaction, let error):
                Self.logger.log("   Unfinished transaction NOT verified for ID \(transaction.productID, privacy: .public), error: \(error.localizedDescription, privacy: .public) - finishing it")
                await transaction.finish()
                Self.logger.log("         UNVERIFIED transaction FINISHED")
            }
        }
    }
    
    /// Returns a `Task` that listens for StoreKit transaction updates
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            await Self.logger.log("listenForTransactions: Watching for transaction updates...")
            // Iterate through any transactions that don't come from a direct call to `purchase()`.
            for await result in Transaction.updates {
                do {
                    await Self.logger.log("listenForTransactions: Received transaction update from StoreKit \(result.debugDescription, privacy: .public)")
                    let transaction = try await self.verifyTransaction(result)
                    
                    // Deliver products to the user.
                    await Self.logger.log("listenForTransactions: Updating customer product status from listenForTransactions handler")
                    _ = await self.updateCustomerProductStatus()
                    
                    // Always finish a transaction.
                    await transaction.finish()
                } catch {
                    // StoreKit has a transaction that fails verification. Don't deliver content to the user.
                    await Self.logger.error("listenForTransactions: Transaction failed verification.")
                }
            }
        }
    }
    
    /// Request app store products
    @MainActor
    func requestProducts() async {
        Self.logger.log("requestProducts: \(AppStoreConfiguration.productIDs.joined(separator: ", "), privacy: .public)")
        let signposter = OSSignposter(subsystem: "AppStoreMonitor", category: "Request Products")
        let signpostID = signposter.makeSignpostID()
        let name: StaticString = "Request Products"
        let state = signposter.beginInterval(name, id: signpostID)
        defer {
            signposter.endInterval(name, state)
        }
        
        do {
            // Request products from the App Store using the identifiers that the `Products.plist` file defines.
            let storeProducts = try await Product.products(for: AppStoreConfiguration.productIDs)
            Self.logger.log("requestProducts: Received \(storeProducts.count, privacy: .public) products: \(storeProducts.map({$0.id}).joined(separator: ", "), privacy: .public)")
            self.products = storeProducts
            
            // Filter the products into categories based on their type.
            var newSubscriptions: [Product] = []
            for product in storeProducts {
                switch product.type {
                    //                case .consumable:
                    //                    newFuel.append(product)
                    //                case .nonConsumable:
                    //                    newCars.append(product)
                case .autoRenewable:
                    newSubscriptions.append(product)
                    //                case .nonRenewable:
                    //                    newNonRenewables.append(product)
                default:
                    // Ignore this product.
                    Self.logger.warning("requestProducts: Unknown product id=\(product.id, privacy: .public), description=\(product.description, privacy: .public)")
                }
            }
            
            // Sort each product category by price, highest to lowest, to update the store.
            subscriptions = sortByPrice(newSubscriptions)
            Self.logger.log("requestProducts: \(newSubscriptions.count, privacy: .public) subscriptions loaded.")
        } catch {
            Self.logger.error("requestProducts: Failed product request from the App Store server. \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func requestUserLogin() async {
        do {
            Self.logger.log("requestUserLogin: Attempting AppStore.sync() to force login.")
            try await AppStore.sync()
            Self.logger.log("requestUserLogin: AppStore.sync() finished")
        } catch {
            Self.logger.error("requestUserLogin: AppStore.sync() failed: \(error.localizedDescription, privacy: .public)")
        }
        
        await updateProducts()
    }
    
    public func updateProducts() async {
        guard products.isEmpty || subscriptions.isEmpty else {
            Self.logger.log("Not doing updateProducts, because we already have some")
            return
        }
        Self.logger.log("update_products()")
        // During store initialization, request products from the App Store.
        await requestProducts()
        
        await processUnfinishedTransactions()
        
        // Deliver products that the customer purchases.
        Self.logger.log("update_products: Updating customer product status")
        await updateCustomerProductStatus()
    }
    
    private enum PurchaseResult {
        case success(_ transaction: Transaction)
        case userCancelled
        case pending
        case unknownResult
    }
    
    private func logPurchaseToAnalyticsIfNeeded(_ product: Product, result: PurchaseResult) async {
        var dict: [String: Any] = await product.getAnalyticsDictionary()
        var alreadySentToAnalytics = false
        
        if case PurchaseResult.success(let transaction) = result {
            let transactionID = transaction.id
            if self.transactionIdsAlreadySentToAnalytics.contains(transactionID) {
                alreadySentToAnalytics = true
            }
            
            transaction.analyticsParams.forEach { key, value in
                dict[key] = value
            }
        }
        
        switch result {
        case .userCancelled:
            analyticsManager?.send(.purchaseUserCancel, properties: dict)
            analyticsManager?.send(.purchaseUserCancel, eventNameExtension: "_\(product.id)", properties: dict)
            if let period = dict["subscriptionPeriod"] as? String {
                let renamedPeriodForFirebase = period.replacingOccurrences(of: "-", with: "_")
                analyticsManager?.send(.purchaseUserCancel, eventNameExtension: "_\(renamedPeriodForFirebase)", properties: dict)
            }
            
        case .pending:
            analyticsManager?.send(.purchasePending, properties: dict)
            analyticsManager?.send(.purchasePending, eventNameExtension: "_\(product.id)", properties: dict)
            if let period = dict["subscriptionPeriod"] as? String {
                let renamedPeriodForFirebase = period.replacingOccurrences(of: "-", with: "_")
                analyticsManager?.send(.purchasePending, eventNameExtension: "_\(renamedPeriodForFirebase)", properties: dict)
            }
            
        case .unknownResult:
            analyticsManager?.send(.purchaseUnknownResult, properties: dict)
            analyticsManager?.send(.purchaseUnknownResult, eventNameExtension: "_\(product.id)", properties: dict)
            if let period = dict["subscriptionPeriod"]  as? String {
                let renamedPeriodForFirebase = period.replacingOccurrences(of: "-", with: "_")
                analyticsManager?.send(.purchaseUnknownResult, eventNameExtension: "_\(renamedPeriodForFirebase)", properties: dict)
            }
            
        case .success(let transaction):
            guard alreadySentToAnalytics == false else { return }
            
            analyticsManager?.send(.purchaseSuccess, properties: dict)
            analyticsManager?.send(.purchaseSuccess, eventNameExtension: "_\(product.id)", properties: dict)
            if let period = dict["subscriptionPeriod"] as? String {
                let renamedPeriodForFirebase = period.replacingOccurrences(of: "-", with: "_")
                analyticsManager?.send(.purchaseSuccess, eventNameExtension: "_\(renamedPeriodForFirebase)", properties: dict)
            }
            
            analyticsManager?.logStoreKit2Transaction(transaction)
            self.transactionIdsAlreadySentToAnalytics.insert(transaction.id)
        }
    }
    
    /// The main purchaise entry point
    public func purchase(_ product: Product) async throws -> Transaction? {
        // Begin purchasing the `Product` the user selects.
        Self.logger.log("**************** purchase() - Begin purchase of product \(product.id, privacy: .public)")
        let analyticsDictionary = await product.getAnalyticsDictionary()
        analyticsManager?.send(.purchaseBegan, properties: analyticsDictionary)
        analyticsManager?.send(.purchaseBegan, eventNameExtension: "_\(product.id)", properties: analyticsDictionary)
        if let period = analyticsDictionary["subscriptionPeriod"] as? String {
            let renamedPeriodForFirebase = period.replacingOccurrences(of: "-", with: "_")
            analyticsManager?.send(.purchaseBegan, eventNameExtension: "_\(renamedPeriodForFirebase)", properties: analyticsDictionary)
        }
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            Self.logger.log("purchase('\(product.id, privacy: .public)'): purchase SUCCESS - we should ALSO see this from Transaction.updates")
            // Check whether the transaction is verified. If it isn't,
            // this function rethrows the verification error.
            let transaction = try await verifyTransaction(verification)
            
            // The transaction is verified. Deliver content to the user.
            //
            // NOTE: This will happen anyway when the `Transaction.updates` listener fires, but,
            // at least in server-based sandbox testing, this can take up to a couple of minutes.
            // Therefore, we process it here now.  The duplicate that comes in later shouldn't
            // affect anything.
            await updateCustomerProductStatus()
            
            // Always finish a transaction.
            await transaction.finish()
            return transaction
            
        case .userCancelled:
            Self.logger.log("purchase('\(product.id, privacy: .public)'): purchase CANCELLED")
            await logPurchaseToAnalyticsIfNeeded(product, result: .userCancelled)
            return nil
            
        case .pending:
            Self.logger.log("purchase('\(product.id, privacy: .public)'): purchase PENDING")
            await logPurchaseToAnalyticsIfNeeded(product, result: .pending)
            return nil
            
        default:
            Self.logger.log("purchase('\(product.id, privacy: .public)'): purchase - UNKNOWN RESULT - ignoring")
            await logPurchaseToAnalyticsIfNeeded(product, result: .unknownResult)
            return nil
        }
    }
    
    private func verifyTransaction<T>(_ result: StoreKit.VerificationResult<T>) async throws -> T {
        // Check whether the JWS passes StoreKit verification.
        Self.logger.log("verifyTransaction()")
        switch result {
        case .unverified(let unverifiedTransaction, let verificationError):
            // StoreKit parses the JWS, but it fails verification.
            Self.logger.error("verifyTransaction(): Couldn't verify transaction: \(verificationError.localizedDescription, privacy: .public)")
            // attempt to finish this unverified transaction
            if let transaction = unverifiedTransaction as? Transaction {
                //                Task {
                Self.logger.log("verifyTransaction(): Finishing unverified transaction")
                await transaction.finish()
                Self.logger.log("verifyTransaction(): Finished unverified transaction")
                //                }
            }
            throw AppStoreError.failedVerification
        case .verified(let safe):
            // The result is verified. Return the unwrapped value.
            Self.logger.log("verifyTransaction(): Verified OK")
            return safe
        }
    }
    
    @MainActor
    private func updateCustomerProductStatus() async {
        await gate.wait()
        Self.logger.log("updateCustomerProductStatus() START")
        await _updateCustomerProductStatus()
        Self.logger.log("updateCustomerProductStatus() END")
        await gate.signal()
    }
    
    @MainActor
    private func _updateCustomerProductStatus() async {
        //        var purchasedNonConsumables: [Product] = []
        var purchasedSubscriptions: [Product] = []
        //        var purchasedNonRenewableSubscriptions: [Product] = []
        
        // Iterate through all of the user's purchased products.
        Self.logger.log("_updateCustomerProductStatus() - Checking Transaction.currentEntitlements")
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let verifiedTransaction):
                // Process the verified transaction, e.g., grant access to features
                Self.logger.log("    Verified entitlement: \(verifiedTransaction.productID, privacy: .public)")
                Self.logger.log("         transaction ID \(verifiedTransaction.id, privacy: .public)")
                Self.logger.log("       purchase date: \(verifiedTransaction.purchaseDate, privacy: .public)")
                
                if let stat = await verifiedTransaction.subscriptionStatus {
                    Self.logger.log("         status.state: \(stat.state.rawValue, privacy: .public)")
                }
                if let expirationDate = verifiedTransaction.expirationDate {
                    Self.logger.log("       expiration: \(expirationDate, privacy: .public)")
                }
                if let revocationDate = verifiedTransaction.revocationDate {
                    Self.logger.log("       revocation: \(revocationDate, privacy: .public)")
                    if let r = verifiedTransaction.revocationReason {
                        Self.logger.log("       revocation reason: \(r.rawValue, privacy: .public)")
                    }
                }
                if let product = subscriptions.first(where: { $0.id == verifiedTransaction.productID }) {
                    purchasedSubscriptions.append(product)
                } else {
                    Self.logger.error("      Unable to find product for verified entitlement for product ID \(verifiedTransaction.productID, privacy: .public)")
                }
            case .unverified(let unverifiedTransaction, let error):
                // Handle unverified transactions (less common with currentEntitlements)
                Self.logger.error("    Unverified entitlement: \(unverifiedTransaction.productID, privacy: .public), Error: \(error, privacy: .public)")
            }
        }
        
        // Update the store information with auto-renewable subscription products.
        self.purchasedSubscriptions = purchasedSubscriptions
        
#if TESTFLIGHT
#warning("TESTFLIGHT BUILD - USING MAX ENTITLEMENT")
        let serviceEntitlement: ServiceEntitlement = .max
#else
        #if DEBUG
        let serviceEntitlement: ServiceEntitlement
        if CommandLine.arguments.contains("--fully-unlocked") {
            serviceEntitlement = .max
        } else {
            serviceEntitlement = purchasedSubscriptions.isEmpty ? .notEntitled : .max
        }
        #else
        let serviceEntitlement: ServiceEntitlement = purchasedSubscriptions.isEmpty ? .notEntitled : .max
        #endif
        
        analyticsManager?.addUserProperty(String(serviceEntitlement.analyticsName), key: "serviceEntitlement")
        analyticsManager?.addUserProperty(String(serviceEntitlement.rawValue), key: "serviceEntitlementLevel")
#endif
        Self.logger.log("_updateCustomerProductStatus(): Updating customer product status from service entitlement change = \(serviceEntitlement.analyticsName, privacy: .public)")
        self.serviceEntitlement = serviceEntitlement
    }
    
    private func sortByPrice(_ products: [Product]) -> [Product] {
        products.sorted(by: { return $0.price > $1.price })
    }
    
    public enum AppStoreError: Error {
        case failedVerification
    }
}

// Define the app's subscription entitlements by level of service, with the highest level of service first.
// The numerical-level value matches the subscription's level that you configure in
// the StoreKit configuration file or App Store Connect.
public enum ServiceEntitlement: Int, Comparable, Equatable, CustomStringConvertible, Identifiable {
    case notEntitled = 0
    
    case basic = 1
    case pro = 2
    case max = 3
    
    public var id: Int { rawValue }
    
    public var rank: Int { rawValue }
    
    init?(for product: Product) {
        // The product must be a subscription to have service entitlements.
        guard product.subscription != nil else {
            return nil
        }
        
        if AppStoreConfiguration.maxProductIDs.contains(product.id) {
            self = .max
        } else if AppStoreConfiguration.proProductIDs.contains(product.id) {
            self = .pro
        } else if AppStoreConfiguration.basicProductIDs.contains(product.id) {
            self = .basic
        } else {
            self = .notEntitled
        }
    }
    
    init?(for productID: String) {
        if AppStoreConfiguration.maxProductIDs.contains(productID) {
            self = .max
        } else if AppStoreConfiguration.proProductIDs.contains(productID) {
            self = .pro
        } else if AppStoreConfiguration.basicProductIDs.contains(productID) {
            self = .basic
        } else {
            self = .notEntitled
        }
    }
    
    public static func < (lhs: Self, rhs: Self) -> Bool {
        // Subscription-group levels are in descending order.
        return lhs.rawValue > rhs.rawValue
    }
    
    public var description: String {
        switch self {
        case .notEntitled:
            return "Not Entitled"
        case .basic:
            return "Basic"
        case .pro:
            return "Pro"
        case .max:
            return "Max"
        }
    }
    
    public var analyticsName: String {
        switch self {
        case .notEntitled: return "FREE"
        case .basic: return "BASIC"
        case .pro: return "PRO"
        case .max: return "MAX"
        }
    }
    public var uiSmallIconTextRepresentation: String {
        switch self {
        case .notEntitled: return "FREE"
        case .basic: return "BASIC"
        case .pro: return "PRO"
        case .max: return "MAX"
        }
    }
    
    public var uiSettingsRepresentation: String {
        switch self {
        case .notEntitled: "Free tier"
        case .basic: "BASIC"
        case .pro: "PRO"
        case .max: "MAX"
        }
    }
    
    public var subscriptionBadgeColor: Color {
        switch self {
        case .notEntitled:
            return .gray
        case .basic:
            return .blue
        case .pro:
            return .red
        case .max:
            return .purple
        }
    }
}

extension Product {
    func getAnalyticsDictionary() async -> [String: Any] {
        let typeText = self.type.analyticsValue
        
        var dict: [String: Any] = [
            "product_id": self.id,
            "iapType": typeText
        ]
        
        if let subscription = self.subscription {
            let subscriptionDict = await subscription.getAnalyticsDictionary()
            subscriptionDict.forEach { dict[$0.key] = $0.value }
        }
        return dict
    }
}

extension Product.ProductType {
    var analyticsValue: String {
        switch self {
        case .autoRenewable: "auto_renewable"
        case .consumable: "consumable"
        case .nonConsumable: "non_consumable"
        case .nonRenewable: "non_renewable"
        default: "other_\(rawValue)"
        }
    }
}
extension Product.SubscriptionInfo {
    func getAnalyticsDictionary() async -> [String: Any] {
        
        var dict: [String: Any] = [
            "subscriptionPeriod": subscriptionPeriod.analyticsValue
        ]
        
        if let introductoryOffer  = introductoryOffer, await isEligibleForIntroOffer {
            introductoryOffer.analyticsDictionary.forEach { dict[$0.key] = $0.value }
        }
        
        return dict
    }
}

extension Product.SubscriptionPeriod {
    var analyticsValue: String {
        let subPeriodText: String = {
            var unitText: String = switch unit {
            case .day:
                "day"
            case .week:
                "week"
            case .month:
                "month"
            case .year:
                "year"
            @unknown default:
#if DEBUG
                fatalError("Unknown subscription period unit \(unit)")
#else
                "unknown"
#endif
            }
            
            var valueToUse = value
            if unit == .day && valueToUse == 7 {
                unitText = "week"
                valueToUse = 1
            }
            
            return "\(valueToUse)-\(unitText)"
        }()
        
        return subPeriodText
    }
}

extension Product.SubscriptionOffer {
    var analyticsDictionary: [String: Any] {
        let periodText = period.analyticsValue
        let offerDescription = "\(periodCount)x\(periodText)"
        return [
            "subscriptionOfferID": id ?? "",
            "subscriptionOfferType": type.rawValue,
            "subscriptionOfferDescription": offerDescription,
            "subscriptionOfferPaymentMode": paymentMode.rawValue
        ]
    }
}

// Minimal semaphore
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ value: Int = 1) { self.value = value }
    
    func wait() async {
        if value > 0 { value -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    
    func signal() {
        if waiters.isEmpty {
            value += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private let gate = AsyncSemaphore(1)

