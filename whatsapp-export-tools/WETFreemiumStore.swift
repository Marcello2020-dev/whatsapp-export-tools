import Foundation
import Combine
import StoreKit

/// Handles freemium usage gating and the one-time Pro unlock purchase.
@MainActor
final class WETFreemiumStore: ObservableObject {
    enum PurchaseOutcome: Equatable {
        case unlocked
        case pending
        case cancelled
    }

    enum PurchaseFailure: LocalizedError {
        case productUnavailable
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .productUnavailable:
                return "Pro unlock product is currently unavailable."
            case .verificationFailed(let reason):
                return "Purchase verification failed: \(reason)"
            }
        }
    }

    static let freeExportLimit: Int = 2
    private static let freeExportCountKey = "wet.freemium.successfulExports"
    private static let debugUnlockOverrideKey = "wet.freemium.debugUnlockOverride"
    private static let defaultProductID = "dev.marcello2020.chat-export-studio.pro.lifetime"

    @Published private(set) var isUnlocked: Bool = false
    @Published private(set) var successfulFreeExports: Int
    @Published private(set) var product: Product?
    @Published private(set) var isLoadingProduct: Bool = false
    @Published private(set) var isPurchasing: Bool = false
    @Published private(set) var isRestoring: Bool = false
    @Published private(set) var debugUnlockOverride: Bool

    private let defaults: UserDefaults
    private var started = false
    private var transactionUpdatesTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.successfulFreeExports = max(0, defaults.integer(forKey: Self.freeExportCountKey))
        self.debugUnlockOverride = defaults.bool(forKey: Self.debugUnlockOverrideKey)
    }

    var isProEnabled: Bool {
#if DEBUG
        isUnlocked || debugUnlockOverride
#else
        isUnlocked
#endif
    }

    var freeExportsRemaining: Int {
        max(0, Self.freeExportLimit - successfulFreeExports)
    }

    var requiresUnlock: Bool {
        !isProEnabled && freeExportsRemaining == 0
    }

    var canRunExport: Bool {
        isProEnabled || freeExportsRemaining > 0
    }

    var displayPrice: String? {
        product?.displayPrice
    }

    var productID: String {
        if let fromPlist = Bundle.main.object(forInfoDictionaryKey: "WETProUnlockProductID") as? String {
            let trimmed = fromPlist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return Self.defaultProductID
    }

    func start() async {
        guard !started else { return }
        started = true

        transactionUpdatesTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            for await update in Transaction.updates {
                await self.handleTransactionUpdate(update)
            }
        }

        await refreshEntitlementState()
        await loadProduct()
    }

    func loadProduct() async {
        if isLoadingProduct { return }
        isLoadingProduct = true
        defer { isLoadingProduct = false }

        do {
            let products = try await Product.products(for: [productID])
            product = products.first
        } catch {
            product = nil
        }
    }

    func purchaseProUnlock() async throws -> PurchaseOutcome {
        if isProEnabled { return .unlocked }
        if isPurchasing { return .pending }
        if product == nil {
            await loadProduct()
        }
        guard let product else {
            throw PurchaseFailure.productUnavailable
        }

        isPurchasing = true
        defer { isPurchasing = false }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                await transaction.finish()
                await refreshEntitlementState()
                return isUnlocked ? .unlocked : .pending
            case .unverified(_, let error):
                throw PurchaseFailure.verificationFailed(error.localizedDescription)
            }
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .pending
        }
    }

    func restorePurchases() async throws {
        if isRestoring { return }
        isRestoring = true
        defer { isRestoring = false }
        try await AppStore.sync()
        await refreshEntitlementState()
    }

    func recordSuccessfulExportIfNeeded() {
        guard !isProEnabled else { return }
        guard successfulFreeExports < Self.freeExportLimit else { return }
        successfulFreeExports += 1
        defaults.set(successfulFreeExports, forKey: Self.freeExportCountKey)
    }

#if DEBUG
    func toggleDebugUnlockOverride() {
        let next = !debugUnlockOverride
        debugUnlockOverride = next
        defaults.set(next, forKey: Self.debugUnlockOverrideKey)
    }
#endif

    private func refreshEntitlementState() async {
        var unlocked = false
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            guard transaction.productID == productID else { continue }
            if transaction.revocationDate == nil {
                unlocked = true
            }
        }
        isUnlocked = unlocked
    }

    private func handleTransactionUpdate(_ update: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = update else { return }
        if transaction.productID == productID {
            await refreshEntitlementState()
        }
        await transaction.finish()
    }
}
