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
            VStack(alignment: .leading, spacing: 24) {
                header

                if store.isUnlocked {
                    successCard
                } else {
                    purchaseCard
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }

    private var background: some View {
        ZStack {
            Rectangle().fill(NoteSideTheme.windowBackground)
            Rectangle().fill(.regularMaterial)
            LinearGradient(
                colors: [
                    NoteSideTheme.accent.opacity(0.06),
                    Color.clear,
                    NoteSideTheme.warning.opacity(0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NoteSide")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(NoteSideTheme.primaryText)

            if store.isUnlocked {
                Text("You're all set.")
                    .font(.title3)
                    .foregroundStyle(NoteSideTheme.secondaryText)
            } else if appState.isTrialExhausted {
                Text("Your \(AppState.trialNoteLimit)-note free trial is complete.")
                    .font(.title3)
                    .foregroundStyle(NoteSideTheme.secondaryText)

                Text("Your existing notes stay fully available. Unlocking is a one-time purchase — no subscription.")
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.tertiaryText)
            } else {
                Text("Unlock unlimited notes.")
                    .font(.title3)
                    .foregroundStyle(NoteSideTheme.secondaryText)

                Text("You're on the free trial (\(appState.trialNotesUsed) of \(AppState.trialNoteLimit) notes used). Unlocking is a one-time purchase — no subscription.")
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.tertiaryText)
            }
        }
    }

    private var successCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(NoteSideTheme.success)

            Text("Unlimited Notes Unlocked")
                .font(.title2.weight(.semibold))
                .foregroundStyle(NoteSideTheme.primaryText)

            Text("Thank you for supporting NoteSide. Use \(appState.hotkeys.hotKeyDisplayString) to keep taking notes.")
                .font(.subheadline)
                .foregroundStyle(NoteSideTheme.secondaryText)
                .multilineTextAlignment(.center)

            Button {
                appState.dismissLicenseWindow()
            } label: {
                Text("Get Started")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Capsule(style: .continuous).fill(NoteSideTheme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(card)
    }

    private var purchaseCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Unlimited Notes", systemImage: "infinity")
                .font(.headline)
                .foregroundStyle(NoteSideTheme.primaryText)

            Text("Everything in the trial, without the five-note limit. One purchase, yours forever, across all your Macs signed into the same Apple Account.")
                .font(.subheadline)
                .foregroundStyle(NoteSideTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage = store.lastErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage)
                }
                .font(.subheadline)
                .foregroundStyle(NoteSideTheme.danger)
            }

            HStack(spacing: 14) {
                Button {
                    Task { await store.purchaseUnlimited() }
                } label: {
                    HStack(spacing: 8) {
                        if store.isWorking {
                            ProgressView().controlSize(.small)
                        }
                        Text(purchaseButtonTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule(style: .continuous).fill(NoteSideTheme.accent))
                }
                .buttonStyle(.plain)
                .disabled(store.isWorking)

                Button("Restore Purchases") {
                    Task { await store.restorePurchases() }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                .disabled(store.isWorking)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private var purchaseButtonTitle: String {
        if let product = store.unlimitedProduct {
            return "Unlock Unlimited Notes — \(product.displayPrice)"
        }
        return "Unlock Unlimited Notes"
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(NoteSideTheme.contentBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(NoteSideTheme.border.opacity(0.8), lineWidth: 1)
            )
    }
}
#endif
