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
    case notGranted
    case granted
}

@MainActor
@Observable
final class BrowserPermissionsState {
    private(set) var browserPermissionStates: [String: BrowserPermissionState] = [:]
    var browserAutomationMessage = "Put Safari, Chrome, or Arc in front, then test browser access."
    var isBrowserAutomationGranted = false
    private var pendingAutomationRequests: Set<String> = []

    private static let browserPermissionDefaultsPrefix = "browserPermissionState."
    private static let browserPermissionMigrationKey = "browserPermissionStatesMigratedV2"
    static let supportedBrowsers = BrowserURLProvider.supportedBrowsers

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

    func probeBrowserAutomation() {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let attempt = browserURLProvider.probeFrontmostBrowserAttempt(frontmostBundleIdentifier: frontmostBundleIdentifier)
        applyBrowserAutomationAttempt(attempt)
    }

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
        for browser in Self.supportedBrowsers {
            let storedState = storedBrowserPermissionState(for: browser.bundleIdentifier)

            if !isBrowserInstalled(browser.bundleIdentifier) {
                if storedState != .notInstalled {
                    browserPermissionStates[browser.bundleIdentifier] = .notInstalled
                }
                continue
            }

            guard storedState != .notInstalled else {
                continue
            }

            if browserURLProvider.isRunning(bundleIdentifier: browser.bundleIdentifier) {
                let attempt = browserURLProvider.accessAttempt(
                    bundleIdentifier: browser.bundleIdentifier,
                    activatesBrowser: false
                )

                switch attempt.result {
                case .success:
                    browserPermissionStates[browser.bundleIdentifier] = .granted
                    setBrowserPermissionState(.granted, for: browser.bundleIdentifier)
                case .automationDenied, .unavailable:
                    browserPermissionStates[browser.bundleIdentifier] = .notGranted
                    setBrowserPermissionState(.notGranted, for: browser.bundleIdentifier)
                case .noTab:
                    browserPermissionStates[browser.bundleIdentifier] = storedState
                case .notBrowser:
                    browserPermissionStates[browser.bundleIdentifier] = .notGranted
                }
            } else {
                browserPermissionStates[browser.bundleIdentifier] = storedState
            }
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
        case .notInstalled?, nil:
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
        guard let sourceBundleIdentifier, browserURLProvider.supports(bundleIdentifier: sourceBundleIdentifier) else {
            return
        }

        if browserPermissionStates[sourceBundleIdentifier] != .granted {
            let name = browserName(for: sourceBundleIdentifier)
            browserAutomationMessage = "Browser access is not enabled for \(name) yet. Use Permissions & Setup to request it."
        }
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
            isBrowserAutomationGranted = true
            onEditorError(nil)
            setBrowserPermissionState(.granted, for: bundleIdentifier(for: browserName))
        case .automationDenied(let browserName), .unavailable(let browserName):
            isBrowserAutomationGranted = false
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
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            let attempt = self.browserURLProvider.accessAttempt(
                bundleIdentifier: bundleIdentifier,
                activatesBrowser: activatesBrowser
            )
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
        let defaultsKey = Self.browserPermissionDefaultsPrefix + bundleIdentifier
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey) else {
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
