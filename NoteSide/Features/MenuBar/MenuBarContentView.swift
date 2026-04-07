import AppKit
import Combine
import ServiceManagement
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var updateChecker = UpdateChecker()
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginNeedsApproval: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NoteSide")
                        .font(.title3.weight(.semibold))
                    Text("Leave notes for the app, page, or file you are in.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    dismiss()
                    appState.showInfoWindow()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(NoteSideTheme.primaryText)
                }
                .buttonStyle(.plain)
            }

            Button {
                dismiss()
                appState.openAllNotes()
            } label: {
                Label("View All Notes", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                dismiss()
                appState.showOnboarding()
            } label: {
                Label("Permissions & Setup", systemImage: "checklist")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Hotkey")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(appState.hotKeyDisplayString)
                    .font(.subheadline.weight(.medium))

                ShortcutRecorderView(displayText: appState.hotKeyDisplayString) { shortcut in
                    appState.setHotKeyShortcut(shortcut)
                }
                .fixedSize()

                Text("Click the box, then press the shortcut you want.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Launch on startup", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                if launchAtLoginNeedsApproval {
                    HStack(spacing: 6) {
                        Text("Enable NoteSide in System Settings to allow launch on startup.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }

            if let errorMessage = appState.editorErrorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if appState.recentNotes.isEmpty {
                Text("No notes yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(appState.recentNotes) { note in
                        Button {
                            dismiss()
                            appState.open(note)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.context.displayName)
                                    .font(.subheadline.weight(.medium))
                                Text(note.body)
                                    .lineLimit(2)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit NoteSide", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            updateRow
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { refreshLaunchAtLoginState() }
    }

    private func refreshLaunchAtLoginState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled)
        launchAtLoginNeedsApproval = (status == .requiresApproval)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status != .notRegistered {
                    try service.unregister()
                }
            }
        } catch {
            // Fall through to status reconciliation below.
        }

        let status = service.status
        let actualEnabled = (status == .enabled)
        if launchAtLogin != actualEnabled {
            launchAtLogin = actualEnabled
        }
        launchAtLoginNeedsApproval = (enabled && status == .requiresApproval)
    }

    @ViewBuilder
    private var updateRow: some View {
        switch updateChecker.state {
        case .idle:
            Button {
                updateChecker.check()
            } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .checking:
            statusRow(
                systemImage: nil,
                tint: nil,
                message: "Checking for updates…",
                showsSpinner: true
            )

        case .upToDate:
            statusRow(
                systemImage: "checkmark.circle.fill",
                tint: NoteSideTheme.success,
                message: "You're up to date (v\(UpdateChecker.currentVersion))",
                showsSpinner: false
            )

        case .updateAvailable(let version, _, let releaseURL):
            VStack(alignment: .leading, spacing: 8) {
                Label("Update Available — v\(version)", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NoteSideTheme.accent)

                Text("You have v\(UpdateChecker.currentVersion). Install the latest version now?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        updateChecker.installUpdate()
                    } label: {
                        Text("Install Update")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        NSWorkspace.shared.open(releaseURL)
                    } label: {
                        Text("Release Notes")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading update…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                        .progressViewStyle(.linear)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .installing:
            statusRow(
                systemImage: nil,
                tint: nil,
                message: "Installing update — the app will restart…",
                showsSpinner: true
            )

        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(NoteSideTheme.warning)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Retry") {
                    updateChecker.check()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(systemImage: String?, tint: Color?, message: String, showsSpinner: Bool) -> some View {
        HStack(spacing: 8) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint ?? NoteSideTheme.secondaryText)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, downloadURL: URL, releaseURL: URL)
        case downloading(received: Int64, total: Int64)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let owner = "dylblake"
    private let repo = "NoteSide"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    // MARK: Check

    func check() {
        switch state {
        case .checking, .downloading, .installing:
            return
        default:
            break
        }
        Task { await performCheck() }
    }

    private func performCheck() async {
        state = .checking

        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            state = .failed("Bad update URL.")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NoteSide/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                state = .failed("Couldn't reach GitHub.")
                return
            }
            guard http.statusCode == 200 else {
                state = .failed("GitHub returned \(http.statusCode).")
                return
            }

            let release = try JSONDecoder().decode(GithubRelease.self, from: data)
            let latestVersion = Self.normalize(release.tagName)
            let currentVersion = Self.normalize(Self.currentVersion)

            guard latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending else {
                state = .upToDate
                return
            }

            let releaseURL = URL(string: release.htmlUrl)
                ?? URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!

            guard let dmgAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
                  let downloadURL = URL(string: dmgAsset.browserDownloadUrl) else {
                state = .failed("No installable asset on the latest release.")
                return
            }

            state = .updateAvailable(version: latestVersion, downloadURL: downloadURL, releaseURL: releaseURL)
        } catch {
            state = .failed("Couldn't check for updates.")
        }
    }

    // MARK: Install

    func installUpdate() {
        guard case let .updateAvailable(_, downloadURL, _) = state else { return }
        Task { await performInstall(from: downloadURL) }
    }

    private func performInstall(from downloadURL: URL) async {
        state = .downloading(received: 0, total: 0)

        do {
            let stagingDir = try Self.makeStagingDirectory()
            let dmgURL = stagingDir.appendingPathComponent("NoteSide.dmg")

            try await downloadDMG(from: downloadURL, to: dmgURL)

            state = .installing

            // Mount the DMG and locate the .app bundle inside it.
            let mountPoint = try Self.mountDMG(at: dmgURL)
            let stagedAppURL: URL
            do {
                guard let appInDMG = try Self.findAppBundle(in: mountPoint) else {
                    Self.detachQuietly(mountPoint)
                    throw UpdateError.message("Update DMG didn't contain an app bundle.")
                }
                stagedAppURL = stagingDir.appendingPathComponent(appInDMG.lastPathComponent)
                try FileManager.default.copyItem(at: appInDMG, to: stagedAppURL)
                Self.detachQuietly(mountPoint)
            } catch {
                Self.detachQuietly(mountPoint)
                throw error
            }

            let currentBundle = Bundle.main.bundleURL
            let parent = currentBundle.deletingLastPathComponent()

            // Sanity-check we can write to the parent of the running bundle
            // before we hand control off to the helper script.
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                throw UpdateError.message(
                    "NoteSide can't write to \(parent.path). Move it to /Applications and try again."
                )
            }

            try Self.spawnReplacementScript(currentBundle: currentBundle, stagedApp: stagedAppURL)

            // Give the helper script a moment to start before we exit.
            try? await Task.sleep(nanoseconds: 250_000_000)
            NSApp.terminate(nil)
        } catch let UpdateError.message(message) {
            state = .failed(message)
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    private func downloadDMG(from url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("NoteSide/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        let total = response.expectedContentLength

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var received: Int64 = 0
        var lastUIUpdate = Date()

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if Date().timeIntervalSince(lastUIUpdate) > 0.1 {
                    state = .downloading(received: received, total: total)
                    lastUIUpdate = Date()
                }
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        state = .downloading(received: received, total: max(total, received))
    }

    // MARK: Helpers

    private static func makeStagingDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteSideUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func mountDMG(at dmgURL: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-noautoopen", "-plist", dmgURL.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.message("Couldn't mount the update DMG.")
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw UpdateError.message("Couldn't read mount point from hdiutil output.")
        }

        return URL(fileURLWithPath: mountPath)
    }

    private static func detachQuietly(_ mountPoint: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-force"]
        try? process.run()
        process.waitUntilExit()
    }

    private static func findAppBundle(in directory: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents.first { $0.pathExtension == "app" }
    }

    private static func spawnReplacementScript(currentBundle: URL, stagedApp: URL) throws {
        // Helper script: wait for our PID to exit, swap the bundle, relaunch.
        // Logs go to a file under /tmp so failures can be inspected later.
        let pid = ProcessInfo.processInfo.processIdentifier
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noteside-update-\(pid).log")

        let script = """
        #!/bin/bash
        set -e
        TARGET=\(Self.shellEscape(currentBundle.path))
        NEW=\(Self.shellEscape(stagedApp.path))
        STAGE=\(Self.shellEscape(stagedApp.deletingLastPathComponent().path))
        PID=\(pid)
        LOG=\(Self.shellEscape(logURL.path))

        exec >>"$LOG" 2>&1
        echo "[$(date)] update helper starting"

        # Wait up to 30s for the parent app to fully exit.
        for i in $(seq 1 60); do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 0.5
        done
        sleep 1

        if [ ! -d "$NEW" ]; then
            echo "staged app missing at $NEW"
            exit 1
        fi

        echo "removing $TARGET"
        rm -rf "$TARGET"

        echo "installing $NEW -> $TARGET"
        cp -R "$NEW" "$TARGET"

        # Strip the quarantine attribute Gatekeeper added when we downloaded
        # the DMG, otherwise the user gets the "downloaded from internet"
        # prompt on launch.
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

        echo "cleaning up $STAGE"
        rm -rf "$STAGE"

        echo "relaunching"
        open "$TARGET"
        echo "[$(date)] update helper done"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noteside-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", scriptURL.path]
        try chmod.run()
        chmod.waitUntilExit()

        // Launch /bin/bash detached so it survives our termination.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
    }

    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Strip a leading "v" so "v1.0.2" and "1.0.2" compare equal.
    private static func normalize(_ version: String) -> String {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    private enum UpdateError: Error {
        case message(String)
    }

    private struct GithubRelease: Decodable {
        let tagName: String
        let htmlUrl: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadUrl = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case assets
        }
    }
}
