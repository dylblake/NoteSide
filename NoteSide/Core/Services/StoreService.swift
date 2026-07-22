#if MAS_BUILD
import Combine
import Foundation
import StoreKit

/// App Store purchase state for the Mac App Store channel. One
/// non-consumable — "Unlimited Notes" — plays the role license keys play
/// in the direct-download channel (selling external keys in-app violates
/// App Review Guideline 3.1.1, so none of that code ships in MAS builds).
@MainActor
final class StoreService: ObservableObject {
    static let unlimitedProductID = "com.dylblake.noteside.unlimited"

    @Published private(set) var isUnlocked = false
    @Published private(set) var unlimitedProduct: Product?
    @Published private(set) var isWorking = false
    @Published private(set) var lastErrorMessage: String?

    private var transactionUpdatesTask: Task<Void, Never>?

    /// Begins observing transaction updates and loads current state.
    /// Call once at app start.
    func start() {
        transactionUpdatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { [weak self] in
            await self?.refreshEntitlements()
            await self?.loadProductIfNeeded()
        }
    }

    func purchaseUnlimited() async {
        lastErrorMessage = nil
        await loadProductIfNeeded()

        guard let product = unlimitedProduct else {
            lastErrorMessage = "The App Store product isn't available right now — check your connection and try again."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification)
            case .userCancelled:
                break
            case .pending:
                lastErrorMessage = "Purchase is awaiting approval (Ask to Buy). It unlocks automatically once approved."
            @unknown default:
                break
            }
        } catch {
            lastErrorMessage = "Purchase failed: \(error.localizedDescription)"
        }
    }

    func restorePurchases() async {
        lastErrorMessage = nil
        isWorking = true
        defer { isWorking = false }

        do {
            try await AppStore.sync()
        } catch {
            lastErrorMessage = "Restore failed: \(error.localizedDescription)"
            return
        }

        await refreshEntitlements()
        if !isUnlocked {
            lastErrorMessage = "No previous purchase found for this Apple Account."
        }
    }

    func refreshEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.unlimitedProductID,
               transaction.revocationDate == nil {
                unlocked = true
            }
        }
        isUnlocked = unlocked
    }

    private func loadProductIfNeeded() async {
        guard unlimitedProduct == nil else { return }
        unlimitedProduct = try? await Product.products(for: [Self.unlimitedProductID]).first
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }

        if transaction.productID == Self.unlimitedProductID {
            if transaction.revocationDate == nil {
                isUnlocked = true
            } else {
                await refreshEntitlements()
            }
        }
        await transaction.finish()
    }
}
#endif
