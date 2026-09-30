//
//  BrowserPermissionsState.swift
//  Remora
//
//  Created by Dylan Evans on 5/12/26.
//

import AppKit
import Foundation
import Observation

enum BrowserPermissionState: String {
    case notInstalled
    /// Installed, but Remora has never attempted Automation access, so
    /// macOS hasn't shown its consent prompt yet. Never persisted.
    case undetermined
    case notGranted
    case granted
}

/// A non-browser app Remora sends Apple Events to for context detection.
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
    // Timestamped so a stuck/blocked request can't leave a bundle id
    // permanently "pending" and dead-end the button. Observed so the UI's
    // "Connecting…" state appears the instant a request starts.
    private(set) var pendingAutomationRequests: [String: Date] = [:]
    private static let pendingRequestStaleAfter: TimeInterval = 15

    func isRequestPending(for bundleIdentifier: String) -> Bool {
        guard let started = pendingAutomationRequests[bundleIdentifier] else { return false }
        return Date().timeIntervalSince(started) < Self.pendingRequestStaleAfter
    }

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
    /// Fired when a Connect click or a status refresh finds a newly
    /// granted app, so the setup window the prompt buried can come back.
    @ObservationIgnored private var onAutomationGranted: () -> Void
    @ObservationIgnored private var isRefreshingAutomationStatuses = false

    init(browserURLProvider: BrowserURLProvider) {
        self.browserURLProvider = browserURLProvider
        self.onEditorError = { _ in }
        self.onOpenApplication = { _ in }
        self.onAutomationGranted = {}
        Self.migrateBrowserPermissionStatesIfNeeded()
    }

    /// Must be called once after init to wire closures back to AppState.
    func configure(
        onEditorError: @escaping (String?) -> Void,
        onOpenApplication: @escaping (String) -> Void,
        onAutomationGranted: @escaping () -> Void
    ) {
        self.onEditorError = onEditorError
        self.onOpenApplication = onOpenApplication
        self.onAutomationGranted = onAutomationGranted
    }

    // MARK: - Public Methods

    func requestAutomationAccess(for bundleIdentifier: String) {
        let name = browserName(for: bundleIdentifier)
        browserAutomationMessage = "Requesting Automation access for \(name)..."
        queueAutomationRequest(for: bundleIdentifier, activatesBrowser: true)
    }

    func openAutomationSettings() {
        SystemSettingsOpener.openPrivacyPane(.automation)
    }

    func refreshBrowserPermissionStates() {
        #if MAS_BUILD
        // Browser rows aren't shown in the App Store build (Accessibility
        // covers browsers), and the sandbox would fail every probe anyway.
        return
        #else
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

            // The stored record is only the starting point (never
            // attempted shows as undetermined, with a Connect button);
            // the status refresh below corrects it for running browsers
            // without sending an Apple Event, so nothing here can fire a
            // consent prompt.
            browserPermissionStates[bundleIdentifier] = knownState ?? .undetermined
        }

        refreshAutomationStatuses()
        #endif
    }

    /// Re-reads the Automation grant of every running browser and app
    /// target straight from macOS. It sends no Apple Events, so it can't
    /// prompt, launch anything or stall on a busy app, and is cheap
    /// enough for the setup windows' once-a-second poll. An app that
    /// isn't running keeps whatever state it has.
    func refreshAutomationStatuses() {
        guard !isRefreshingAutomationStatuses else { return }

        #if MAS_BUILD
        let browserIdentifiers: [String] = []
        #else
        let browserIdentifiers = Self.supportedBrowsers
            .map(\.bundleIdentifier)
            .filter { browserURLProvider.isRunning(bundleIdentifier: $0) }
        #endif
        let appIdentifiers = Self.appAutomationTargets
            .map(\.bundleIdentifier)
            .filter { browserURLProvider.isRunning(bundleIdentifier: $0) }
        guard !(browserIdentifiers.isEmpty && appIdentifiers.isEmpty) else { return }

        isRefreshingAutomationStatuses = true
        Task { [weak self] in
            let statuses = await AutomationPermission.statuses(
                forBundleIdentifiers: browserIdentifiers + appIdentifiers
            )
            guard let self else { return }
            self.isRefreshingAutomationStatuses = false

            var didGrant = false
            for bundleIdentifier in browserIdentifiers {
                guard let state = Self.permissionState(for: statuses[bundleIdentifier]) else { continue }
                let wasGranted = self.browserPermissionStates[bundleIdentifier] == .granted
                self.setBrowserPermissionState(state, for: bundleIdentifier)
                didGrant = didGrant || (!wasGranted && state == .granted)
            }
            for bundleIdentifier in appIdentifiers {
                guard let state = Self.permissionState(for: statuses[bundleIdentifier]) else { continue }
                let wasGranted = self.appAutomationStates[bundleIdentifier] == .granted
                self.setAppAutomationState(state, for: bundleIdentifier)
                didGrant = didGrant || (!wasGranted && state == .granted)
            }
            if didGrant {
                self.onAutomationGranted()
            }
        }
    }

    private static func permissionState(for status: AutomationPermission.Status?) -> BrowserPermissionState? {
        switch status {
        case .granted: return .granted
        case .denied: return .notGranted
        case .notDetermined: return .undetermined
        case .unknown, nil: return nil
        }
    }

    // MARK: - App Automation (Finder, Xcode)

    func refreshAppAutomationStates() {
        for target in Self.appAutomationTargets {
            let bundleIdentifier = target.bundleIdentifier

            guard isBrowserInstalled(bundleIdentifier) else {
                appAutomationStates[bundleIdentifier] = .notInstalled
                continue
            }

            let storedState = storedState(prefix: Self.appAutomationDefaultsPrefix, bundleIdentifier: bundleIdentifier)
            let knownState: BrowserPermissionState? = storedState == .notInstalled ? nil : storedState

            // Same as browsers: start from the stored record and let the
            // status refresh correct it without sending an Apple Event.
            appAutomationStates[bundleIdentifier] = knownState ?? .undetermined
        }

        refreshAutomationStatuses()
    }

    func requestAppAutomationAccess(for target: AppAutomationTarget) {
        guard !isRequestPending(for: target.bundleIdentifier) else { return }
        pendingAutomationRequests[target.bundleIdentifier] = Date()

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
                    self.pendingAutomationRequests[target.bundleIdentifier] = nil
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
        let newState = isBrowserInstalled(bundleIdentifier) ? state : .notInstalled
        guard appAutomationStates[bundleIdentifier] != newState else { return }
        appAutomationStates[bundleIdentifier] = newState

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

        let newState = isBrowserInstalled(bundleIdentifier) ? state : .notInstalled
        guard browserPermissionStates[bundleIdentifier] != newState else { return }
        browserPermissionStates[bundleIdentifier] = newState

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
            browserAutomationMessage = "Browser access is not enabled for \(name) yet. Open Setup from the menu bar icon to request it."
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
        case .success(let browserName, _), .noTab(let browserName):
            // No tab still means the Apple Event went through: the grant
            // is there, the browser just had no page (Safari's Start
            // Page, a window with no tabs).
            onEditorError(nil)
            let bundleIdentifier = bundleIdentifier(for: browserName)
            let wasGranted = bundleIdentifier.map { browserPermissionStates[$0] == .granted } ?? true
            setBrowserPermissionState(.granted, for: bundleIdentifier)
            if !wasGranted {
                onAutomationGranted()
            }
        case .automationDenied(let browserName):
            onEditorError(result.message)
            setBrowserPermissionState(.notGranted, for: bundleIdentifier(for: browserName))
        case .unavailable, .notBrowser:
            // A timeout or a launch race says nothing about the grant;
            // the status refresh settles it.
            break
        }
    }

    // MARK: - Private Methods

    private func queueAutomationRequest(for bundleIdentifier: String, activatesBrowser: Bool) {
        guard !isRequestPending(for: bundleIdentifier) else { return }
        pendingAutomationRequests[bundleIdentifier] = Date()

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
                self.pendingAutomationRequests[bundleIdentifier] = nil
            case .unavailable, .notBrowser:
                guard retriesRemaining > 0 else {
                    self.pendingAutomationRequests[bundleIdentifier] = nil
                    self.refreshAutomationStatuses()
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

    /// Whether macOS has already granted Remora Automation access to this
    /// browser, from the persisted record rather than the in-memory map,
    /// which is only populated while the Setup window is open. A stale
    /// "granted" (revoked later in System Settings) just fails the script
    /// with -1743; it never re-prompts.
    func isBrowserAutomationKnownGranted(_ bundleIdentifier: String) -> Bool {
        storedBrowserPermissionState(for: bundleIdentifier) == .granted
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

}
