import AppKit
import SwiftUI

/// First run, on one page: allow Accessibility, then take a note. Each
/// step shows a green check when it's done and the next one opens by
/// itself; there is nothing to navigate.
///
/// Accessibility is the only permission asked for here because it is the
/// only one needed to start: it reads the page in every supported browser
/// and the context inside Slack, Figma and code editors. Everything else
/// (dictation, Finder and Xcode, a browser's Automation) is asked for when
/// the user first reaches for it, and lives in Setup afterwards.
struct FirstRunView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didPressHotkey = false
    @State private var didRequestAccessibility = false

    private enum Step: Int, CaseIterable {
        case accessibility
        case firstNote
    }

    private func isComplete(_ step: Step) -> Bool {
        switch step {
        case .accessibility: return appState.isAccessibilityTrusted
        case .firstNote: return didPressHotkey
        }
    }

    /// The first step still to do; nil once everything is done.
    private var currentStep: Step? {
        Step.allCases.first { !isComplete($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                PageHeader(
                    title: "Two steps to your first note",
                    subtitle: "Notes that stay attached to the app, page, or file you're in."
                )

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    accessibilityStep
                    firstNoteStep
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: currentStep)

                if !appState.isLicensed {
                    Label {
                        Text("Your first \(AppState.trialNoteLimit) notes are free. Everything you write stays yours; a license unlocks unlimited new notes.")
                            .font(.footnote)
                            .foregroundStyle(RemoraTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "hourglass")
                            .foregroundStyle(RemoraTheme.secondaryText)
                    }
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Divider()

            footer
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.md)
        }
        // Fixed, so the window never resizes as steps open and close. The
        // height includes the (transparent) title bar strip.
        .frame(width: 580, height: 600)
        .onChange(of: appState.quickNoteHotkeyPressCount) { _, _ in
            didPressHotkey = true
        }
        .onChange(of: currentStep) { _, step in
            announce(step)
        }
    }

    // MARK: - Step 1: Accessibility

    private var accessibilityStep: some View {
        stepCard(
            .accessibility,
            title: "Allow Accessibility",
            detail: appState.isAccessibilityTrusted
                ? "Remora can see the app, page, or file you're in."
                : "Lets Remora see the app, page, or file you're in, so each note attaches to the right place."
        ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    if didRequestAccessibility {
                        PendingLabel(text: "Waiting for macOS…")
                        Button("Open Settings Again", action: requestAccessibility)
                            .buttonStyle(.glass)
                    } else {
                        Button("Allow Accessibility", action: requestAccessibility)
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            .accessibilityIdentifier("firstRunAllowAccessibility")
                    }
                }

                Text("macOS opens System Settings. Switch Remora on there (add it with ＋ if it isn't listed) and this page moves on by itself.")
                    .font(.footnote)
                    .foregroundStyle(RemoraTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func requestAccessibility() {
        didRequestAccessibility = true
        appState.openAccessibilitySettings()
    }

    // MARK: - Step 2: the first note

    private var firstNoteStep: some View {
        stepCard(
            .firstNote,
            title: "Take your first note",
            detail: didPressHotkey
                ? "That's the drawer. Press the shortcut again, or Escape, to close it."
                : "Press your shortcut in any app and the note drawer slides in, attached to whatever you're in."
        ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.md) {
                    Text(appState.hotkeys.hotKeyDisplayString)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xs)
                        .cardSurface(cornerRadius: CornerRadius.control + 2, fill: RemoraTheme.glassCardFill)
                        .accessibilityLabel("Quick note shortcut \(appState.hotkeys.hotKeyDisplayString)")

                    Text("Press it now. This page will notice.")
                        .font(.subheadline)
                        .foregroundStyle(RemoraTheme.secondaryText)
                }

                Divider()

                HStack(spacing: Spacing.sm) {
                    Text("Prefer a different shortcut?")
                        .font(.subheadline)
                    Spacer()
                    ShortcutRecorderView(displayText: appState.hotkeys.hotKeyDisplayString) { shortcut in
                        appState.hotkeys.setHotKeyShortcut(shortcut)
                    }
                    .frame(width: 150)
                }

                if appState.hotkeys.hotKeyShortcut == .default {
                    Label {
                        Text("\(appState.hotkeys.hotKeyDisplayString) is also “New Private Window” in Safari and Chrome. While Remora runs, it wins; change it here if you use that shortcut.")
                            .font(.caption)
                            .foregroundStyle(RemoraTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(RemoraTheme.warning)
                    }
                }
            }
        }
    }

    // MARK: - Shared pieces

    /// One step: a numbered badge that becomes a green check, a title and
    /// one line of detail, and the step's controls while it is the one to
    /// do. Steps still ahead are dimmed.
    private func stepCard<Controls: View>(
        _ step: Step,
        title: String,
        detail: String,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        let isDone = isComplete(step)
        let isCurrent = currentStep == step

        return HStack(alignment: .top, spacing: Spacing.sm) {
            stepBadge(step, isDone: isDone)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(RemoraTheme.primaryText)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(RemoraTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isCurrent {
                    controls()
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(
            fill: RemoraTheme.glassCardFill,
            strokeColor: isDone ? RemoraTheme.success.opacity(0.5) : nil
        )
        .opacity(isDone || isCurrent ? 1 : 0.55)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count): \(title), \(isDone ? "done" : isCurrent ? "to do now" : "next")")
        .accessibilityIdentifier("firstRunStep\(step.rawValue + 1)")
    }

    private func stepBadge(_ step: Step, isDone: Bool) -> some View {
        Group {
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(RemoraTheme.success)
            } else {
                Text("\(step.rawValue + 1)")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(RemoraTheme.accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(RemoraTheme.accent.opacity(0.12)))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(spacing: Spacing.md) {
            if currentStep != nil {
                Button("Skip for now") {
                    appState.completeOnboarding()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(RemoraTheme.secondaryText)
            }

            Spacer()

            Button("Start Taking Notes") {
                appState.completeOnboarding()
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(currentStep != nil)
        }
    }

    private func announce(_ step: Step?) {
        let message: String
        switch step {
        case .accessibility: return
        case .firstNote: message = "Accessibility allowed. Next: take your first note."
        case nil: message = "Setup complete."
        }
        AccessibilityNotification.Announcement(message).post()
    }
}
