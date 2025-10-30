// PurchaseModel SwiftUI
// Created by Adam Lyttle on 7/18/2024

// Make cool stuff and share your build with me:

//  --> x.com/adamlyttleapps
//  --> github.com/adamlyttleapps

import Foundation
import StoreKit
import Combine
import OSLog

final class PurchaseModel: ObservableObject {
    
    @Published var productIds: [String]
    @Published var productDetails: [PurchaseProductDetails] = []
    
    @Published var isPurchasing: Bool = false
    @Published var isFetchingProducts: Bool = false
    @Published var error: String?

    private var logger = Logger(subsystem: "Monetization", category: "PurchaseModel")

    public weak var appStoreMonitor: AppStoreMonitor?

    /// You must set `appStoreMonitor` prior to starting a purchase
    public init(appStoreMonitor: AppStoreMonitor? = nil) {
        self.appStoreMonitor = appStoreMonitor

        // initialise your productids and product details
        self.productIds = AppStoreConfiguration.activeProductIDs
        self.productDetails = [ ]
        
        Task { @MainActor in await fetchProducts() }
    }
    
    private var maximumAnnualCost: Double {
        productDetails.reduce(0) { max($0, $1.annualCost) }
    }
    public func percentageSavings(_ productDetails: PurchaseProductDetails) -> Double {
        guard maximumAnnualCost > 0 else { return 0 }
        let savings = maximumAnnualCost - productDetails.annualCost
        guard savings > 1.00 else { return 0 }
        let savingsPercentage = savings * 100.0 / maximumAnnualCost
        let rounded = savingsPercentage.rounded(.down)
        return rounded
    }
    
    fileprivate func populateSubscriptionDetails(_ product: Product, _ duration: inout String, _ durationPlanName: inout String, _ annualCost: inout Double) {
        if let sub = product.subscription {
            switch sub.subscriptionPeriod {
            case .monthly:
                duration = sub.subscriptionPeriod.value == 1 ? "Month" : "\(sub.subscriptionPeriod.value) Months"
                durationPlanName = sub.subscriptionPeriod.value == 1 ? "Monthly" : "\(sub.subscriptionPeriod.value) Months"
                annualCost = (product.price as NSDecimalNumber).doubleValue * 12 / Double(sub.subscriptionPeriod.value)
            case .yearly:
                duration = sub.subscriptionPeriod.value == 1 ? "Year" : "\(sub.subscriptionPeriod.value) Years"
                durationPlanName = sub.subscriptionPeriod.value == 1 ? "Yearly" : "\(sub.subscriptionPeriod.value) Years"
                annualCost = (product.price as NSDecimalNumber).doubleValue / Double(sub.subscriptionPeriod.value)
            case .weekly:
                duration = sub.subscriptionPeriod.value == 1 ? "Week" : "\(sub.subscriptionPeriod.value) Weeks"
                durationPlanName = sub.subscriptionPeriod.value == 1 ? "Weekly" : "\(sub.subscriptionPeriod.value) Weeks"
                annualCost = (product.price as NSDecimalNumber).doubleValue * 52 / Double(sub.subscriptionPeriod.value)
                
            default: 
                switch sub.subscriptionPeriod.unit {
                case .day:
                    if sub.subscriptionPeriod.value == 7 {
                        duration = "Week"
                        durationPlanName = "Weekly"
                        annualCost =  (product.price as NSDecimalNumber).doubleValue * 52.0
                    } else {
                        duration = "\(sub.subscriptionPeriod.value) Days"
                        durationPlanName = "\(duration)"
                        annualCost =  (product.price as NSDecimalNumber).doubleValue * 365.0 /  Double(sub.subscriptionPeriod.value)
                    }
                case .month:
                    duration = "\(sub.subscriptionPeriod.value) Month(s)"
                    durationPlanName = "\(duration)"
                    annualCost =  (product.price as NSDecimalNumber).doubleValue * 12.0 /  Double(sub.subscriptionPeriod.value)
                case .week:
                    duration = "\(sub.subscriptionPeriod.value) Week(s)"
                    durationPlanName = "\(duration)"
                    annualCost =  (product.price as NSDecimalNumber).doubleValue * 52.0 /  Double(sub.subscriptionPeriod.value)
                case .year:
                    duration = "\(sub.subscriptionPeriod.value) Year(s)"
                    durationPlanName = "\(duration)"
                    annualCost =  (product.price as NSDecimalNumber).doubleValue  /  Double(sub.subscriptionPeriod.value)
                @unknown default:
                    let descr = sub.subscriptionPeriod.unit.debugDescription
#if DEBUG
                    fatalError("Unknown subscription period unit: \(descr)")
#else
                    logger.fault("Unknown subscription period unit encountered: \(descr)")
                    duration = "Unknown Period"
                    durationPlanName = "Unknown Period"
                    annualCost = (product.price as NSDecimalNumber).doubleValue
#endif
                }
            }
        } else {
            duration = "Unknown"
            durationPlanName = "Unknown"
#if DEBUG
            fatalError("This should not happen!")
#endif
        }
    }
    
    var products: [Product] = [] {
        didSet {
            Task { @MainActor in
                productDetails = products.map { product in
                    var duration: String = ""
                    var durationPlanName: String = ""
                    var hasFreeTrial: Bool = false
                    let allowsFamilySharing: Bool = product.isFamilyShareable
                    var trialDurationDescription: String?
                    var annualCost: Double = 0.0
                    let serviceEntitlement = ServiceEntitlement(for: product.id) ?? .notEntitled
                    let currencySymbol = product.priceFormatStyle.locale.currencySymbol ?? ""
                    populateSubscriptionDetails(product, &duration, &durationPlanName, &annualCost)

                    // Lazy work here - only supporting into offer if it's 3 days free
                    if let sub = product.subscription {
                        let dg = DispatchGroup()
                        dg.enter()
                        let updateMe = { result in
                            hasFreeTrial = result
                            trialDurationDescription = "3 Days Free"
                        }
                        Task.detached(priority: .userInitiated) {
                            if await sub.isEligibleForIntroOffer, let intro = sub.introductoryOffer {
                                if intro.period.value == 3 && intro.period.unit == .day {
                                    updateMe(true)
                                }
                            }
                            dg.leave()
                        }
                        dg.wait()
                    }
                    return  PurchaseProductDetails(price: product.displayPrice,
                                                   productId: product.id,
                                                   duration: duration,
                                                   durationPlanName: durationPlanName,
                                                   hasTrial: hasFreeTrial,
                                                   allowsFamilySharing: allowsFamilySharing,
                                                   trialDurationDescription: trialDurationDescription,
                                                   annualCost: annualCost,
                                                   serviceEntitlement: serviceEntitlement,
                                                   currencySymbol: currencySymbol)
                }
                .sorted { $0.annualCost < $1.annualCost }
            }
        }
    }
    private var loadedProductsSuccessfully = false
    private func fetchProducts() async {
        Task { @MainActor in
            error = nil
            isFetchingProducts = true
            do {
                let products = try await Product.products(for: productIds)
                self.products = products
                print("PurchaseModel: fetched \(products.count) products")
            } catch {
                self.error = "Error loading products: \(error)"
            }
            isFetchingProducts = false
        }
    }
    
    private func productForId(_ productId: String) -> Product? {
        products.first(where: { $0.id == productId })
    }
    
    func purchaseSubscription(productId: String) {
        // trigger purchase process
        logger.log("Trying to purchase product ID: \(productId)")
        isPurchasing = true
        if let product = productForId(productId) {
            guard let appStoreMonitor else {
                logger.error("Internal error - appStoreMonitor is nil when purchasing product ID: \(productId)")
                self.error = "Internal error - appStoreMonitor is nil"
                isPurchasing = false
                return
            }
            Task {
                do {
                    _ = try await appStoreMonitor.purchase(product)
                } catch {
                    Task { @MainActor in
                        logger.error("Purchase failed for product ID: \(productId): \(error)")
                        self.error = "Purchase failed: \(error)"
                    }
                }
                Task { @MainActor in
                    self.isPurchasing = false
                }
            }
        } else {
            logger.error("Product not found with ID: \(productId)")
            error = "Internal error - product not found for ID \(productId)"
            isPurchasing = false
        }
    }
    
    func restorePurchases() async throws {
        // trigger restore purchases
        try await AppStore.sync()
    }
    
}

final class PurchaseProductDetails: ObservableObject, Identifiable {
    typealias ID = UUID
    let id: ID

    @Published var price: String
    @Published var productId: String
    @Published var duration: String
    @Published var durationPlanName: String
    @Published var hasTrial: Bool
    @Published var allowsFamilySharing: Bool
    @Published var trialDurationDescription: String?
    @Published var annualCost: Double
    @Published var serviceEntitlement: ServiceEntitlement
    @Published var currencySymbol: String

    public var weeklyCost: Double {
        (100.0 * annualCost / 52.0).rounded() / 100.0
    }

    public var weeklyCostText: String {
        String(format: "\(currencySymbol)%.2f", weeklyCost)
    }

    init(
        price: String = "",
        productId: String = "",
        duration: String = "",
        durationPlanName: String = "",
        hasTrial: Bool = false,
        allowsFamilySharing: Bool = false,
        trialDurationDescription: String?,
        annualCost: Double,
        serviceEntitlement: ServiceEntitlement,
        currencySymbol: String
    ) {
        self.id = ID()
        self.price = price
        self.productId = productId
        self.duration = duration
        self.durationPlanName = durationPlanName
        self.hasTrial = hasTrial
        self.allowsFamilySharing = allowsFamilySharing
        self.trialDurationDescription = trialDurationDescription
        self.annualCost = annualCost
        self.serviceEntitlement = serviceEntitlement
        self.currencySymbol = currencySymbol
    }
}
