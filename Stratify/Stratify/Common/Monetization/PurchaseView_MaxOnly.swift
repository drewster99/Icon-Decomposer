// PurchaseView SwiftUI
// Created by Adam Lyttle on 7/18/2024

// Make cool stuff and share your build with me:

//  --> x.com/adamlyttleapps
//  --> github.com/adamlyttleapps

// Special thanks:

//  --> Mario (https://x.com/marioapps_com) for recommending changes to fix
//      an issue Apple had rejecting the paywall due to excessive use of
//      the word "FREE"

import Foundation
import OSLog
import SwiftUI
import StoreKit
import AVKit
import Combine

public struct PurchaseViewConfiguration {
    public let appBrandTint: Color
    public let appBackgroundPrimary: Color
    public let appForegroundPrimary: Color
    public let paywallSavingsHighlightBackground: Color
    public let onboardingTitleColor: Color
    
    public static var `default`: PurchaseViewConfiguration {
        PurchaseViewConfiguration(
            appBrandTint: .blue,
            appBackgroundPrimary: .white,
            appForegroundPrimary: .black,
            paywallSavingsHighlightBackground: .yellow,
            onboardingTitleColor: .blue
        )
    }
}

struct PurchaseView_MaxOnly: View {
    public init(configuration: PurchaseViewConfiguration,
                isPresented: Binding<Bool>,
                delayBeforeShowingMaybeLaterButton: TimeInterval,
                onMaybeLaterButtonTapped: (() -> Void)? = nil,
                onSubscriptionStarted: (() -> Void)? = nil) {
        self.configuration = configuration
        self._isPresented = isPresented
        self.delayBeforeShowingMaybeLaterButton = delayBeforeShowingMaybeLaterButton
        self.onMaybeLaterButtonTapped = onMaybeLaterButtonTapped
        self.onSubscriptionStarted = onSubscriptionStarted
    }
    let configuration: PurchaseViewConfiguration
    
    var logger = Logger(subsystem: "Monetization", category: "PurchaseView_MaxOnly")

    @StateObject var purchaseModel: PurchaseModel = PurchaseModel()
    @EnvironmentObject var appStoreMonitor: AppStoreMonitor
    @EnvironmentObject var analyticsManager: AnalyticsManager

    @Binding public var isPresented: Bool
    public let delayBeforeShowingMaybeLaterButton: TimeInterval
    @State private var freeTrial: Bool = false
    @State private var selectedProductId: String = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasing: Bool = false

    @State private var isShowingAlert: Bool = false
    @State private var errorMessage: String = ""

    @State private var videoDisplayTimer = Timer.publish(every: 1.0/120.0, on: .main, in: .common).autoconnect()
    @State private var videoNormalFraction: CGFloat = 0.0
    @State private var ticks: Int = 0
    @State private var showMaybeLaterButton: Bool = false
    @State private var closeButtonProgress: CGFloat = 0.0
    @State private var isPresentingOfferCodeRedemption = false
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) var verticalSizeClass

    @FocusState private var isFocused: Bool

    public let onMaybeLaterButtonTapped: (() -> Void)?
    public let onSubscriptionStarted: (() -> Void)?

    let color: Color = Color.blue

    private var videoURL: URL? {
        let name = colorScheme == .dark ? "video_hero_dark" : "video_hero_light"
        return Bundle.main.url(forResource: name, withExtension: "mov")
    }

    /// `true` if the currently selected `purchaseModel`'s product has
    /// a free trial available
    private var isFreeTrialAvailable: Bool {
        purchaseModel.productDetails.contains { details in
            details.hasTrial
        }
    }

    /// `true` if the selected `purchaseModel`'s product allows family sharing
    private var isFamilySharingAvailable: Bool {
        purchaseModel.productDetails.contains { details in
            details.allowsFamilySharing
        }
    }
    
    private let appLaunchCountKey = "appLaunchCountKey"
    public var appLaunchCount: Int {
        UserDefaults.standard.integer(forKey: appLaunchCountKey)
    }

    private var daysSinceFirstLaunch: Int {
        let firstAppLaunchDateKey = "firstAppLaunchDateKey"
        guard let data = UserDefaults.standard.data(forKey: firstAppLaunchDateKey) else {
            return .max
        }
        do {
            let firstAppLaunchDate = try JSONDecoder().decode(Date.self, from: data)
            let daysSinceFirstAppLaunch = Int(Date().timeIntervalSince(firstAppLaunchDate)) / 86400
            logger.log("Days since first app launch: \(daysSinceFirstAppLaunch) (first launch date: \(firstAppLaunchDate)))")
            return daysSinceFirstAppLaunch
        } catch {
            return .max
        }
    }

    private var selectedEntitlement: ServiceEntitlement {
        if selectedProductId.isEmpty {
            return .notEntitled
        }

        if let product = purchaseModel.productDetails.first(where: { $0.productId == selectedProductId }) {
            return product.serviceEntitlement
        }

        return .notEntitled
    }

    fileprivate func maybeLaterAndPurchaseButtonsView() -> some View {
        HStack(spacing: 16) {
            if showMaybeLaterButton {
                // Maybe later button - to dismiss and not purchase now
                Button {
                    isPresented = false
                    analyticsManager.send(.maybeLaterButtonTap)
                    onMaybeLaterButtonTapped?()
                } label: {
                    Text("Maybe later")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.bordered)
                .disabled(isPurchasing)
                .padding(.vertical)
            }

            // Purchase button
            Button {
                analyticsManager.send(.purchaseButtonTap)
                if !isPurchasing {
                    purchaseModel.purchaseSubscription(productId: selectedProductId)
                }
            } label: {
                ZStack {
                    Text(freeTrial ? "Start Free Trial" : "Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                    if isPurchasing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .padding()
                    }
                }
                .frame(idealWidth: 300)
            }
            .focused($isFocused)
            .buttonStyle(.borderedProminent)
            .tint(configuration.appBrandTint)
            .disabled(isPurchasing || selectedProductId.isEmpty)
            .padding(.vertical)
        }
        .padding(.horizontal)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    GetStartedWithView(serviceEntitlement: ServiceEntitlement.max,
                                       configuration: configuration)
                        .padding(.bottom, 5)
                    MaxBulletsView(configuration: configuration)
                    MaxChatModeBulletsView(configuration: configuration)

                    // Product selection
                    VStack(alignment: .leading, spacing: 4) {
                        if purchaseModel.productDetails.isEmpty {
                            ProgressView(label: {
                                Text("One moment please...")
                                    .fixedSize(horizontal: true, vertical: false)
                            })

                        } else {
                            PurchaseOptionsView(
                                selectedProductId: $selectedProductId,
                                useFreeTrialEnabled: $freeTrial,
                                configuration: configuration
                            )
                            .environmentObject(purchaseModel)
                            FreeTrialToggleDisplayView(
                                isFreeTrialAvailable: isFreeTrialAvailable,
                                selectedEntitlement: selectedEntitlement,
                                freeTrial: $freeTrial,
                                configuration: configuration
                            )
                            .padding(.top, 1)
                        }
                    }
                    .padding()

                    maybeLaterAndPurchaseButtonsView()

                    FooterLinksView {
                        Task {
                            do {
                                try await purchaseModel.restorePurchases()
                            } catch {
                                Task { @MainActor in
                                    errorMessage = "Error restoring purchases: \(error)"
                                    isShowingAlert = true
                                }
                            }
                        }
                    } onRedeemOfferCode: {
                        isPresentingOfferCodeRedemption = true
                    }
                }
            }
            .scrollIndicators(.hidden)
            .padding(10)

            // Close button with circular reveal animation
            Button(action: {
                isPresented = false
                analyticsManager.send(.maybeLaterButtonTap)
                onMaybeLaterButtonTapped?()
            }, label: {
                Image(systemName: "xmark.square")
                    .font(.title2)
                    .foregroundColor(.primary)
                    .padding(12)
                    .background(
                        Circle()
                            .fill(.regularMaterial)
                            .overlay(
                                Circle()
                                    .fill(Color.secondary.opacity(0.2))
                            )
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .mask(
                        CircularRevealMask(progress: closeButtonProgress)
                    )
            })
            .disabled(isPurchasing)
            .padding(.top, 10)
            .padding(.trailing, 10)
            .opacity(closeButtonProgress == 0 ? 0.0 : 1.0)
        }
        .interactiveDismissDisabled(!showMaybeLaterButton)
        .background(configuration.appBackgroundPrimary)
//        .foregroundStyle(configuration.appForegroundPrimary)
        .preferredColorScheme(.light)
        .onAppear(perform: doOnAppear)
        .onChange(of: appStoreMonitor.serviceEntitlement, initial: true) { _, _ in
            Task { @MainActor in
                if appStoreMonitor.serviceEntitlement != .notEntitled {
                    isPresented = false
                    #if DEBUG
                    if onSubscriptionStarted == nil {
                        fatalError("onSubscriptionStarted is unexpectedly nil!")
                    }
                    #else
                    onSubscriptionStarted?()
                    #endif
                }
            }
        }
        .onChange(of: isFreeTrialAvailable) { _, _ in
            Task { @MainActor in
                if !isFreeTrialAvailable {
                    freeTrial = false
                }
            }
        }
        .onReceive(purchaseModel.$productDetails) { details in
            Task { @MainActor in
                if let product = details.first(where: { $0.productId == selectedProductId }) {
                    freeTrial = product.hasTrial
                }
            }
        }
        .onReceive(purchaseModel.$error) { error in
            guard let newErrorMessage: String = error else {
                Task { @MainActor in
                    self.errorMessage = ""
                    self.isShowingAlert = false
                }
                return
            }

            Task { @MainActor in
                self.errorMessage = "Error: \(newErrorMessage)"
                self.isShowingAlert = true
            }
        }
        .onChange(of: freeTrial) { _, newValue in
            Task { @MainActor in

                if let product = purchaseModel.productDetails.first(where: { $0.productId == selectedProductId }) {
                    // Check if the currently selected product already agrees with the flag
                    if product.hasTrial == newValue { return }
                }

                if let product = purchaseModel.productDetails.first(where: { $0.hasTrial == newValue }) {
                    selectedProductId = product.productId
                }
            }
        }
        .onReceive(purchaseModel.$isPurchasing) { isPurchasing in
            Task { @MainActor in
                self.isPurchasing = isPurchasing
            }
        }
        .onReceive(videoDisplayTimer) { _ in
            Task { @MainActor in
                // 120 ticks per second
                ticks += 1

                // Show 'maybe later' button and close button after delay
                let tickTarget = Int((120.0 * delayBeforeShowingMaybeLaterButton).rounded())
                if ticks >= tickTarget {
                    if !showMaybeLaterButton {
                        withAnimation {
                            showMaybeLaterButton = true
                        }
                    }

                    // Animate close button circular reveal
                    let animationDuration: CGFloat = 60.0 // Half a second at 120 ticks per second
                    let progress: CGFloat = min(CGFloat(ticks - tickTarget) / animationDuration, 1.0)
                    withAnimation(.linear(duration: 1.0/120.0)) {
                        closeButtonProgress = progress
                        var frac: CGFloat = videoNormalFraction
                        frac += 0.0025
                        if frac > 0.20 {
                            frac += 0.01
                        }
                        if frac > 0.50 {
                            frac += 0.015
                        }
                        if frac > 1.0 {
                            frac = 1.0
                        }
                        videoNormalFraction = frac
                    }
                }
            }
        }
        .alert(errorMessage, isPresented: $isShowingAlert) {
            Button("OK", role: .cancel) {
                analyticsManager.send(.purchaseViewAlertOKTap)
            }
            .onAppear {
                analyticsManager.logScreenView("PurchaseViewMaxErrorAlert")
            }
        }
        .offerCodeRedemption(isPresented: $isPresentingOfferCodeRedemption) { result in
            switch result {
            case .success:
                print("All is well")
                analyticsManager.send(.offerCodeRedeemSuccess)
            case .failure(let error):
                print("Super big error trying to redeem offer code: \(error)")
                analyticsManager.send(.offerCodeRedeemError, properties: [
                    "error": error.localizedDescription
                ])
                analyticsManager.logNonFatalError(error)
                Task { @MainActor in
                    self.errorMessage = "Error redeeming offer code: \(error)"
                    self.isShowingAlert = true
                }
            }
            isPresentingOfferCodeRedemption = false
        }
    }

    private func doOnAppear() {
        purchaseModel.appStoreMonitor = self.appStoreMonitor

        Task { await appStoreMonitor.updateProducts() }

        selectedProductId = purchaseModel.productDetails.first?.productId ?? purchaseModel.productIds.first ?? ""
        if let product = purchaseModel.productDetails.first(where: { $0.productId == selectedProductId }) {
            freeTrial = product.hasTrial
        }

        isFocused = true
    }
}

extension PurchaseView_MaxOnly {
    struct CircularRevealMask: Shape {
        var progress: CGFloat

        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = max(rect.width, rect.height)

            // Start from top (12 o'clock), which is -90 degrees
            let startAngle = Angle(degrees: -90)
            let endAngle = Angle(degrees: -90 + (360 * Double(progress)))

            path.move(to: center)
            path.addArc(center: center,
                        radius: radius,
                        startAngle: startAngle,
                        endAngle: endAngle,
                        clockwise: false)
            path.closeSubpath()

            return path
        }
    }

    struct CheckMarkBulletTextView: View {
        let configuration: PurchaseViewConfiguration
        let text: String
        
        public init(_ text: String, configuration: PurchaseViewConfiguration) {
            self.text = text
            self.configuration = configuration
        }
        
        var body: some View {
            HStack {
                Image(systemName: "checkmark.square")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.primary, configuration.paywallSavingsHighlightBackground)
                Text("\(text)")
            }
        }
    }
    
    struct MaxBulletsView: View {
        private static let maxBullets: [String] = [
            "Record your voice / singing",
            "Reverse it – and share!",
            "No ads or watermarks"
        ]
        let configuration: PurchaseViewConfiguration
        @State private var bullets: [String] = []
        @State private var hiddenBullets: [String] = []

        var body: some View {
            VStack(alignment: .center, spacing: 8) {
                Text("Full unlock - No Limits!")
                    .font(.title3.lowercaseSmallCaps())
                    .fontWeight(.semibold)
                ZStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(hiddenBullets.indices, id: \.self) { index in
                            let bullet = hiddenBullets[index]
                            CheckMarkBulletTextView(bullet, configuration: configuration)
                        }
                    }
                    .padding(.leading)
                    .opacity(0.0)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(bullets, id: \.self) { bullet in
                            HStack {
                                CheckMarkBulletTextView(bullet, configuration: configuration)
                                Spacer()
                            }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .padding(.leading)
                }
            }
            .onAppear {
                bullets = []
                hiddenBullets = Self.maxBullets
                var index = 0.0
                for bullet in Self.maxBullets {
                    withAnimation(.bouncy(duration: 0.50).delay(0.50 + (0.20 * index))) {
                        bullets.append(bullet)
                    }
                    index += 1.0
                }
            }
        }
    }

    struct MaxChatModeBulletsView: View {
        let configuration: PurchaseViewConfiguration
        let columns = [
            GridItem(.flexible()),
            GridItem(.flexible())
        ]

        @State private var bullets: [String] = []
        @State private var allBullets: [String] = []

        var body: some View {
            VStack(alignment: .center, spacing: 8) {
                Text("Cool voice effects!")
                    .font(.title3.lowercaseSmallCaps())
                    .fontWeight(.semibold)
                    .foregroundColor(.black)

                ZStack(alignment: .topLeading) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(allBullets, id: \.self) { bullet in
                            CheckMarkBulletTextView(bullet, configuration: configuration)
                                .transition(.scale(scale: 1.5).combined(with: .opacity))
                        }
                    }
                    .padding(.leading)
                    .opacity(0.0)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(bullets, id: \.self) { bullet in
                            CheckMarkBulletTextView(bullet, configuration: configuration)
                                .transition(.scale(scale: 1.5).combined(with: .opacity))
                        }
                    }
                    .padding(.leading)
                }
            }
            .onAppear {
                bullets = []

                let all = [
//                    "Alien voice",
                    "Giant",
                    "Chipmunk voice"
//                    "Robot voice"
                ]
                allBullets = all
                var index = 0.0
                for bullet in all {
                    withAnimation(.bouncy(duration: 0.50).delay(1.50 + (0.20 * index))) {
                        bullets.append(bullet)
                    }
                    index += 1.0
                }
            }
        }
    }

    struct FooterLinksView: View {
        @EnvironmentObject var analyticsManager: AnalyticsManager
        let onRestorePurchases: () -> Void
        let onRedeemOfferCode: () -> Void

        var body: some View {
            Group {
                // Footer links
                HStack(spacing: 12) {
                    Button("Restore Purchases") {
                        analyticsManager.send(.purchaseViewRestoreTap)
                        onRestorePurchases()
                    }
                    Spacer()
                    Button("Redeem Offer Code") {
                        analyticsManager.send(.purchaseViewRedeemTap)
                        onRedeemOfferCode()
                    }
                }
                .padding([.top, .horizontal], 6)
                HStack(spacing: 12) {
                    Button("Privacy Policy") {
                        analyticsManager.send(.purchaseViewPrivacyTap)
                        if let url = URL(string: "https://nuclearcyborg.com/privacy") {
#if os(iOS)
                            UIApplication.shared.open(url)
#elseif os(macOS)
                            NSWorkspace.shared.open(url)
#endif
                        }
                    }
                    Spacer()
                    Button("Terms of Use") {
                        analyticsManager.send(.purchaseViewTermsTap)
                        if let url = URL(string: "https://nuclearcyborg.com/terms") {
#if os(iOS)
                            UIApplication.shared.open(url)
#elseif os(macOS)
                            NSWorkspace.shared.open(url)
#endif
                        }
                    }
                }
                .padding([.top, .horizontal], 6)
            }
            .buttonStyle(.plain)
            .font(.footnote)
        }
    }

    struct PurchaseOptionsView: View {
        @EnvironmentObject var purchaseModel: PurchaseModel
        @Binding public var selectedProductId: Product.ID
        @Binding public var useFreeTrialEnabled: Bool
        let configuration: PurchaseViewConfiguration

        var body: some View {

            VStack(spacing: 8) {
                ForEach(purchaseModel.isFetchingProducts ? [] : purchaseModel.productDetails) { product in
                    ProductOptionView(product: product,
                                      isSelected: selectedProductId == product.productId,
                                      accentColor: configuration.appBrandTint,
                                      onSelect: {
                        Task { @MainActor in
                            withAnimation {
                                selectedProductId = product.productId
                                useFreeTrialEnabled = product.hasTrial
                            }
                        }
                    },
                                      savingsPercent: self.purchaseModel.percentageSavings(product)
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    struct FreeTrialToggleDisplayView: View {
        public let isFreeTrialAvailable: Bool
        public let selectedEntitlement: ServiceEntitlement
        @Binding public var freeTrial: Bool
        public let configuration: PurchaseViewConfiguration

        var body: some View {
            if isFreeTrialAvailable {
                // Free trial toggle with improved styling
                HStack {
                    Image(systemName: "gift")
                        .foregroundColor(configuration.appBrandTint)

                    Toggle("Use free trial", isOn: $freeTrial)
                        .toggleStyle(SwitchToggleStyle(tint: configuration.appBrandTint))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .padding(.vertical, 5)
            }
        }
    }

    struct GetStartedWithView: View {
        public let serviceEntitlement: ServiceEntitlement
        let configuration: PurchaseViewConfiguration

        var body: some View {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("FunVoice\nReverse Audio")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 28))
                        .foregroundStyle(configuration.appBrandTint)
                }
                .font(.title)
                .fontWeight(.semibold)
            }
        }
    }
}

#Preview {
    struct PurchaseViewPreviewerView: View {
        @State var isPresented: Bool = true
        var body: some View {
            PurchaseView_MaxOnly(
                configuration: .default,
                isPresented: $isPresented,
                delayBeforeShowingMaybeLaterButton: 4.0
            ) {
                print("bla")
            } onSubscriptionStarted: {
                print("foo")
            }
            .environmentObject(AppStoreMonitor(analyticsManager: nil))
        }
    }
    return PurchaseViewPreviewerView()
}
