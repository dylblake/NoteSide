//
//  BrowserPermissionsState.swift
//  NoteSide
//
//  Created by Dylan Evans on 5/12/26.
//

import AppKit
import Foundation
import Observation

enum BrowserPermissionState: String {
    case notInstalled
    /// Installed, but NoteSide has never attempted Automation access, so
    /// macOS hasn't shown its consent prompt yet. Never persisted.
    case undetermined
    case notGranted
    case granted
}

/// A non-browser app NoteSide sends Apple Events to for context detection.
/// Each is its own macOS Automation (TCC) entry, granted separately.
struct AppAutomationTarget: Hashable {
    let title: String
    let bundleIdentifier: String
    let purpose: String
    /// Benign script whose only job is to trigger/verify the Automation
    /// permission for this target.
    let probeScript: String
}

@MainActor
@Observable
final class BrowserPermissionsState {
    private(set) var browserPermissionStates: [String: BrowserPermissionState] = [:]
    private(set) var appAutomationStates: [String: BrowserPermissionState] = [:]
    var browserAutomationMessage = "Grant access per browser below — macOS asks once per browser."
    private var pendingAutomationRequests: Set<String> = []

    private static let browserPermissionDefaultsPrefix = "browserPermissionState."
    private static let appAutomationDefaultsPrefix = "appAutomationState."
    private static let browserPermissionMigrationKey = "browserPermissionStatesMigratedV2"
    static let supportedBrowsers = BrowserURLProvider.supportedBrowsers

    static let appAutomationTargets: [AppAutomationTarget] = [
        AppAutomationTarget(
            title: "Finder",
            bundleIdentifier: "com.apple.finder",
            purpose: "Lets notes attach to the folder or file you're viewing in Finder.",
            probeScript: #"tell application id "com.apple.finder" to return name"#
        ),
        AppAutomationTarget(
            title: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            purpose: "Lets notes attach to the file you have open in Xcode.",
            probeScript: #"tell application id "com.apple.dt.Xcode" to return name"#
        )
    ]

    @ObservationIgnored let browserURLProvider: BrowserURLProvider
    @ObservationIgnored private var onEditorError: (String?) -> Void
    @ObservationIgnored private var onOpenApplication: (String) -> Void

    init(browserURLProvider: BrowserURLProvider) {
        self.browserURLProvider = browserURLProvider
        self.onEditorError = { _ in }
        self.onOpenApplication = { _ in }
        Self.migrateBrowserPermissionStatesIfNeeded()
    }

    /// Must be called once after init to wire closures back to AppState.
    func configure(
        onEditorError: @escaping (String?) -> Void,
        onOpenApplication: @escaping (String) -> Void
    ) {
        self.onEditorError = onEditorError
        self.onOpenApplication = onOpenApplication
    }

    // MARK: - Public Methods

    func requestAutomationAccess(for bundleIdentifier: String) {
        let name = browserName(for: bundleIdentifier)
        browserAutomationMessage = "Requesting Automation access for \(name)..."
        queueAutomationRequest(for: bundleIdentifier, activatesBrowser: true)
    }

    func openAutomationSettings() {
        openSettingsPane(candidates: [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security"
        ])
    }

    func refreshBrowserPermissionStates() {
        #if MAS_BUILD
        // Browser rows aren't shown in the App Store build (Accessibility
        // covers browsers), and the sandbox would fail every probe anyway.
        return
        #else
        var browsersToProbe: [String] = []

        for browser in Self.supportedBrowsers {
            let bundleIdentifier = browser.bundleIdentifier

            guard isBrowserInstalled(bundleIdentifier) else {
                browserPermissionStates[bundleIdentifier] = .notInstalled
                continue
            }

            // Nothing stored decodes as .notInstalled — for an installed
            // browser that sentinel means "never attempted", i.e. macOS has
            // never shown its Automation prompt for this browser.
            let storedState = storedBrowserPermissionState(for: bundleIdentifier)
            let knownState: BrowserPermissionState? = storedState == .notInstalled ? nil : storedState

            guard let knownState else {
                // Don't probe here: an Apple Event to a never-attempted
                // browser would fire the macOS consent prompt for every
                // running browser the moment this refresh runs. Mark it
                // undetermined so onboarding lists it with a Request
                // Access button instead.
                browserPermissionStates[bundleIdentifier] = .undetermined
                continue
            }

            browserPermissionStates[bundleIdentifier] = knownState
            if browserURLProvider.isRunning(bundleIdentifier: bundleIdentifier) {
                browsersToProbe.append(bundleIdentifier)
            }
        }

        guard !browsersToProbe.isEmpty else { return }

        // Re-verify running browsers off the main thread — each probe is a
        // full Apple Event round-trip, and a busy browser would otherwise
        // stall the UI for its duration.
        let provider = browserURLProvider
        Task { [weak self] in
            for bundleIdentifier in browsersToProbe {
                let attempt = await Task.detached(priority: .userInitiated) {
                    provider.accessAttempt(bundleIdentifier: bundleIdentifier, activatesBrowser: false)
                }.value

                guard let self else { return }
                switch attempt.result {
                case .success:
                    self.setBrowserPermissionState(.granted, for: bundleIdentifier)
                case .automationDenied, .unavailable, .notBrowser:
                    self.setBrowserPermissionState(.notGranted, for: bundleIdentifier)
                case .noTab:
                    // Inconclusive — keep the stored state already applied.
                    break
                }
            }
        }
        #endif
    }

    // MARK: - App Automation (Finder, Xcode)

    func refreshAppAutomationStates() {
        var targetsToProbe: [AppAutomationTarget] = []

        for target in Self.appAutomationTargets {
            let bundleIdentifier = target.bundleIdentifier

            guard isBrowserInstalled(bundleIdentifier) else {
                appAutomationStates[bundleIdentifier] = .notInstalled
                continue
            }

            let storedState = storedState(prefix: Self.appAutomationDefaultsPrefix, bundleIdentifier: bundleIdentifier)
            let knownState: BrowserPermissionState? = storedState == .notInstalled ? nil : storedState

            guard let knownState else {
                // Same rule as browsers: never probe an app macOS hasn't
                // asked about yet, or opening this window would fire the
                // consent prompt unprompted.
                appAutomationStates[bundleIdentifier] = .undetermined
                continue
            }

            appAutomationStates[bundleIdentifier] = knownState
            if browserURLProvider.isRunning(bundleIdentifier: bundleIdentifier) {
                targetsToProbe.append(target)
            }
        }

        guard !targetsToProbe.isEmpty else { return }

        Task { [weak self] in
            for target in targetsToProbe {
                let (_, error) = await AppleScriptExecutor.shared.execute(
                    key: "automation-probe:\(target.bundleIdentifier)",
                    source: target.probeScript
                )
                guard let self else { return }
                self.applyAppAutomationProbeResult(error: error, for: target.bundleIdentifier, conclusiveOnly: true)
            }
        }
    }

    func requestAppAutomationAccess(for target: AppAutomationTarget) {
        guard pendingAutomationRequests.insert(target.bundleIdentifier).inserted else { return }

        // Targeting an app with an Apple Event launches it if needed, which
        // is what we want here — the whole point is to surface the prompt.
        Task { [weak self] in
            var retriesRemaining = 3
            while true {
                let (_, error) = await AppleScriptExecutor.shared.execute(
                    key: "automation-probe:\(target.bundleIdentifier)",
                    source: target.probeScript
                )
                guard let self else { return }

                let conclusive = self.applyAppAutomationProbeResult(
                    error: error,
                    for: target.bundleIdentifier,
                    conclusiveOnly: false
                )
                retriesRemaining -= 1
                if conclusive || retriesRemaining <= 0 {
                    self.pendingAutomationRequests.remove(target.bundleIdentifier)
                    return
                }
                try? await Task.sleep(for: .seconds(0.7))
            }
        }
    }

    /// Applies a probe outcome. Returns true when the outcome was
    /// conclusive (granted or denied); launch races and other transient
    /// errors leave the state untouched.
    @discardableResult
    private func applyAppAutomationProbeResult(
        error: NSDictionary?,
        for bundleIdentifier: String,
        conclusiveOnly: Bool
    ) -> Bool {
        if error == nil {
            setAppAutomationState(.granted, for: bundleIdentifier)
            return true
        }
        if (error?[NSAppleScript.errorNumber] as? Int) == -1743 {
            setAppAutomationState(.notGranted, for: bundleIdentifier)
            return true
        }
        return false
    }

    func setAppAutomationState(_ state: BrowserPermissionState, for bundleIdentifier: String) {
        appAutomationStates[bundleIdentifier] = isBrowserInstalled(bundleIdentifier) ? state : .notInstalled

        let defaultsKey = Self.appAutomationDefaultsPrefix + bundleIdentifier
        switch appAutomationStates[bundleIdentifier] {
        case .granted?:
            UserDefaults.standard.set(BrowserPermissionState.granted.rawValue, forKey: defaultsKey)
        case .notGranted?:
            UserDefaults.standard.set(BrowserPermissionState.notGranted.rawValue, forKey: defaultsKey)
        case .undetermined?, .notInstalled?, nil:
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    func setBrowserPermissionState(_ state: BrowserPermissionState, for bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }

        browserPermissionStates[bundleIdentifier] = isBrowserInstalled(bundleIdentifier) ? state : .notInstalled

        let defaultsKey = Self.browserPermissionDefaultsPrefix + bundleIdentifier
        switch browserPermissionStates[bundleIdentifier] {
        case .granted?:
            UserDefaults.standard.set(BrowserPermissionState.granted.rawValue, forKey: defaultsKey)
        case .notGranted?:
            UserDefaults.standard.set(BrowserPermissionState.notGranted.rawValue, forKey: defaultsKey)
        case .undetermined?, .notInstalled?, nil:
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    func isBrowserInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    func bundleIdentifier(for browserName: String) -> String? {
        Self.supportedBrowsers.first(where: { $0.title == browserName })?.bundleIdentifier
    }

    func browserName(for bundleIdentifier: String) -> String {
        browserURLProvider.descriptor(for: bundleIdentifier)?.title ?? "browser"
    }

    func queueQuickNotePermissionRequestIfNeeded(sourceBundleIdentifier: String?) {
        #if MAS_BUILD
        // Accessibility covers browsers in the App Store build; there is
        // no Automation to nudge the user toward.
        return
        #else
        guard let sourceBundleIdentifier, browserURLProvider.supports(bundleIdentifier: sourceBundleIdentifier) else {
            return
        }

        if browserPermissionStates[sourceBundleIdentifier] != .granted {
            let name = browserName(for: sourceBundleIdentifier)
            browserAutomationMessage = "Browser access is not enabled for \(name) yet. Use Permissions & Setup to request it."
        }
        #endif
    }

    // MARK: - Internal Methods

    func applyBrowserAutomationAttempt(_ attempt: BrowserAutomationAttemptResult) {
        print("Browser automation debug: \(attempt.debugDetails)")
        applyBrowserAutomationResult(attempt.result)
    }

    func applyBrowserAutomationResult(_ result: BrowserAutomationProbeResult) {
        browserAutomationMessage = result.message

        switch result {
        case .success(let browserName, _):
            onEditorError(nil)
            setBrowserPermissionState(.granted, for: bundleIdentifier(for: browserName))
        case .automationDenied(let browserName), .unavailable(let browserName):
            onEditorError(result.message)
            setBrowserPermissionState(.notGranted, for: bundleIdentifier(for: browserName))
        case .noTab, .notBrowser:
            break
        }
    }

    // MARK: - Private Methods

    private func queueAutomationRequest(for bundleIdentifier: String, activatesBrowser: Bool) {
        guard pendingAutomationRequests.insert(bundleIdentifier).inserted else { return }

        if activatesBrowser {
            onOpenApplication(bundleIdentifier)
        }

        performAutomationRequest(
            for: bundleIdentifier,
            activatesBrowser: activatesBrowser,
            retriesRemaining: activatesBrowser ? 4 : 2,
            delay: activatesBrowser ? 0.8 : 0.25
        )
    }

    private func performAutomationRequest(
        for bundleIdentifier: String,
        activatesBrowser: Bool,
        retriesRemaining: Int,
        delay: TimeInterval
    ) {
        // The attempt runs off the main thread: the activating script
        // contains an AppleScript `delay` plus an Apple Event round-trip,
        // which would otherwise freeze the UI for each retry.
        let provider = browserURLProvider
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))

            let attempt = await Task.detached(priority: .userInitiated) {
                provider.accessAttempt(
                    bundleIdentifier: bundleIdentifier,
                    activatesBrowser: activatesBrowser
                )
            }.value

            guard let self else { return }
            self.applyBrowserAutomationAttempt(attempt)

            switch attempt.result {
            case .success, .noTab, .automationDenied:
                self.pendingAutomationRequests.remove(bundleIdentifier)
            case .unavailable, .notBrowser:
                guard retriesRemaining > 0 else {
                    self.pendingAutomationRequests.remove(bundleIdentifier)
                    return
                }

                self.performAutomationRequest(
                    for: bundleIdentifier,
                    activatesBrowser: activatesBrowser,
                    retriesRemaining: retriesRemaining - 1,
                    delay: 0.5
                )
            }
        }
    }

    private func storedBrowserPermissionState(for bundleIdentifier: String) -> BrowserPermissionState {
        storedState(prefix: Self.browserPermissionDefaultsPrefix, bundleIdentifier: bundleIdentifier)
    }

    private func storedState(prefix: String, bundleIdentifier: String) -> BrowserPermissionState {
        guard let rawValue = UserDefaults.standard.string(forKey: prefix + bundleIdentifier) else {
            return .notInstalled
        }

        return BrowserPermissionState(rawValue: rawValue) ?? .notInstalled
    }

    static func migrateBrowserPermissionStatesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: browserPermissionMigrationKey) else { return }

        for browser in supportedBrowsers {
            defaults.removeObject(forKey: browserPermissionDefaultsPrefix + browser.bundleIdentifier)
        }
        defaults.set(true, forKey: browserPermissionMigrationKey)
    }

    private func openSettingsPane(candidates: [String]) {
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
