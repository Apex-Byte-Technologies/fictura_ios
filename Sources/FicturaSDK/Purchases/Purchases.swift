import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// A product a paywall can sell, with its price for this user's storefront.
/// The same fields the React Native SDK hands the page (`window.__FICTURA__.packages`).
public struct FicturaPackage: Codable, Equatable {
    /// The package id the page buys with: the product id for StoreKit, `$rc_monthly` for RevenueCat.
    public var id: String
    public var product_id: String
    public var price_string: String
    public var price_micros: Int
    public var currency: String
    /// weekly, monthly, annual, lifetime or other.
    public var period: String
    public var trial_days: Int?
    public var period_months: Int?
    public var one_time: Bool?
    public var title: String?
    public var trial_eligible: Bool?

    public init(id: String, productId: String, priceString: String, priceMicros: Int, currency: String, period: String,
                trialDays: Int? = nil, periodMonths: Int? = nil, oneTime: Bool? = nil, title: String? = nil, trialEligible: Bool? = nil) {
        self.id = id
        product_id = productId
        price_string = priceString
        price_micros = priceMicros
        self.currency = currency
        self.period = period
        trial_days = trialDays
        period_months = periodMonths
        one_time = oneTime
        self.title = title
        trial_eligible = trialEligible
    }
}

/// Where a purchase came from, for attribution in Fictura and RevenueCat.
public struct FicturaPurchaseContext: Equatable {
    public var placement: String
    public var paywallId: String
    public var campaignId: String?
    public var audienceId: String?
    public var experimentId: String?
    public var variantId: String?
}

public enum FicturaPurchaseResult: Equatable {
    case purchased(transactionId: String?, periodType: String?, environment: String?)
    case cancelled
    case pending
    case failed(String)
}

/// How paywalls buy. The SDK uses StoreKit 2 when the app sets none. An app on
/// RevenueCat implements this with three calls (see the README), so RevenueCat
/// records the purchase and its webhook brings revenue into Fictura.
public protocol FicturaPurchaseController: AnyObject {
    /// Packages for these store product ids, priced for this user.
    func packages(for productIds: [String]) async -> [FicturaPackage]
    func purchase(_ package: FicturaPackage, context: FicturaPurchaseContext) async -> FicturaPurchaseResult
    /// True when an active purchase was restored.
    func restore() async throws -> Bool
    /// True when the user has an active subscription (placements skip subscribers by default).
    func isSubscribed() async -> Bool
}

public extension FicturaPurchaseController {
    func isSubscribed() async -> Bool { false }
}

#if canImport(StoreKit)
/// The default: StoreKit 2. `appAccountToken` is set from the Fictura account id
/// when it is a UUID, so a server can match the purchase to the user.
@available(iOS 15, macOS 12, *)
public final class StoreKitPurchaseController: FicturaPurchaseController {
    private var products: [String: Product] = [:]
    private let accountToken: () -> UUID?

    public init(accountToken: @escaping () -> UUID? = { nil }) {
        self.accountToken = accountToken
    }

    static func period(_ unit: Product.SubscriptionPeriod.Unit, _ value: Int) -> (String, Int?) {
        switch unit {
        case .day: return value == 7 ? ("weekly", nil) : ("other", nil)
        case .week: return value == 1 ? ("weekly", nil) : ("other", nil)
        case .month: return value == 1 ? ("monthly", 1) : (value == 12 ? "annual" : "other", value)
        case .year: return value == 1 ? ("annual", 12) : ("other", 12 * value)
        @unknown default: return ("other", nil)
        }
    }

    static func days(_ p: Product.SubscriptionPeriod) -> Int {
        switch p.unit {
        case .day: return p.value
        case .week: return 7 * p.value
        case .month: return 30 * p.value
        case .year: return 365 * p.value
        @unknown default: return p.value
        }
    }

    public func packages(for productIds: [String]) async -> [FicturaPackage] {
        guard !productIds.isEmpty, let found = try? await Product.products(for: Set(productIds)) else { return [] }
        var out: [FicturaPackage] = []
        for p in found {
            products[p.id] = p
            let micros = NSDecimalNumber(decimal: p.price * 1_000_000).intValue
            let currency: String
            if #available(iOS 16, macOS 13, *) { currency = p.priceFormatStyle.currencyCode } else { currency = "USD" }
            var period = "lifetime"
            var months: Int?
            var trialDays: Int?
            var eligible: Bool?
            if let sub = p.subscription {
                (period, months) = Self.period(sub.subscriptionPeriod.unit, sub.subscriptionPeriod.value)
                if let intro = sub.introductoryOffer, intro.paymentMode == .freeTrial {
                    trialDays = Self.days(intro.period)
                    eligible = await sub.isEligibleForIntroOffer
                }
            }
            out.append(FicturaPackage(id: p.id, productId: p.id, priceString: p.displayPrice, priceMicros: micros, currency: currency,
                                      period: period, trialDays: trialDays, periodMonths: months,
                                      oneTime: p.type == .nonConsumable || p.type == .consumable ? true : nil,
                                      title: p.displayName, trialEligible: eligible))
        }
        return productIds.compactMap { id in out.first { $0.product_id == id } }
    }

    public func purchase(_ package: FicturaPackage, context: FicturaPurchaseContext) async -> FicturaPurchaseResult {
        var product = products[package.product_id]
        if product == nil { product = try? await Product.products(for: [package.product_id]).first }
        guard let product else { return .failed("product_not_found") }
        var options: Set<Product.PurchaseOption> = []
        if let token = accountToken() { options.insert(.appAccountToken(token)) }
        do {
            switch try await product.purchase(options: options) {
            case .success(let verification):
                guard case .verified(let tx) = verification else { return .failed("unverified_transaction") }
                await tx.finish()
                var env: String?
                if #available(iOS 16, macOS 13, *) { env = tx.environment == .production ? "PRODUCTION" : "SANDBOX" }
                let trial = tx.offerType == .introductory
                return .purchased(transactionId: String(tx.id), periodType: trial ? "trial" : "normal", environment: env)
            case .userCancelled: return .cancelled
            case .pending: return .pending
            @unknown default: return .failed("unknown")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func restore() async throws -> Bool {
        try await AppStore.sync()
        return await isSubscribed()
    }

    public func isSubscribed() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result, tx.revocationDate == nil,
               tx.productType == .autoRenewable || tx.productType == .nonConsumable {
                return true
            }
        }
        return false
    }
}
#endif
