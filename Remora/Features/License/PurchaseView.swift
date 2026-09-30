#if MAS_BUILD
import StoreKit
import SwiftUI

/// Mac App Store variant of the unlock window: an In-App Purchase
/// replaces the direct channel's license-key entry.
struct PurchaseView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        PurchaseContent(store: appState.storeService)
    }
}

private struct PurchaseContent: View {
    @Environment(AppState.self) private var appState
    @ObservedObject var store: StoreService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header

                if store.isUnlocked {
                    successCard
                } else {
                    purchaseCard
                }
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var header: some View {
        if store.isUnlocked {
            PageHeader(title: "You're all set.")
        } else if appState.isTrialExhausted {
            PageHeader(
                title: "Your \(AppState.trialNoteLimit)-note free trial is complete.",
                subtitle: "Your existing notes stay fully available. Unlocking is a one-time purchase — no subscription."
            )
        } else {
            PageHeader(
                title: "Unlock unlimited notes.",
                subtitle: "You're on the free trial (\(appState.trialNotesUsed) of \(AppState.trialNoteLimit) notes used). Unlocking is a one-time purchase — no subscription."
            )
        }
    }

    private var successCard: some View {
        LicenseSuccessCard(
            title: "Unlimited Notes Unlocked",
            message: "Thank you for supporting Remora. Use \(appState.hotkeys.hotKeyDisplayString) to keep taking notes."
        ) {
            appState.dismissLicenseWindow()
        }
    }

    private var purchaseCard: some View {
        TitledCard(title: "Unlimited Notes", systemImage: "infinity") {
            Text("Everything in the trial, without the five-note limit. One purchase, yours forever, across all your Macs signed into the same Apple Account.")
                .font(.subheadline)
                .foregroundStyle(RemoraTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage = store.lastErrorMessage {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage)
                }
                .font(.subheadline)
                .foregroundStyle(RemoraTheme.danger)
            }

            HStack(spacing: Spacing.md) {
                Button {
                    Task { await store.purchaseUnlimited() }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if store.isWorking {
                            ProgressView().controlSize(.small)
                        }
                        Text(purchaseButtonTitle)
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(store.isWorking)

                Button("Restore Purchases") {
                    Task { await store.restorePurchases() }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                .disabled(store.isWorking)
            }
        }
    }

    private var purchaseButtonTitle: String {
        if let product = store.unlimitedProduct {
            return "Unlock Unlimited Notes — \(product.displayPrice)"
        }
        return "Unlock Unlimited Notes"
    }
}
#endif
