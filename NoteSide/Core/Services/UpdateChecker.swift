import AppKit
import Combine
import Foundation
import Security

// The self-updater downloads and swaps the app bundle — sandbox-
// incompatible and disallowed on the App Store (updates ship through
// the store itself), so the entire type is compiled out of MAS builds.
#if !MAS_BUILD
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

            // Never install what we can't authenticate: require an intact
            // code signature from the same team, for the same bundle
            // identifier, as the running app. Without this the updater
            // would install — and de-quarantine — whatever the download
            // URL happened to serve.
            try Self.verifyUpdateSignature(of: stagedAppURL)

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

    // MARK: Signature verification

    struct SigningInfo {
        let teamIdentifier: String?
        let identifier: String?
    }

    /// Requires the staged update to have an intact code signature whose
    /// Team ID and bundle identifier match the running app's.
    nonisolated static func verifyUpdateSignature(of stagedAppURL: URL) throws {
        var staticCodeRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(stagedAppURL as CFURL, [], &staticCodeRef) == errSecSuccess,
              let stagedCode = staticCodeRef else {
            throw UpdateError.message("Couldn't read the update's code signature — install aborted.")
        }

        let validationFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(stagedCode, validationFlags, nil) == errSecSuccess else {
            throw UpdateError.message("The downloaded update's code signature is invalid — install aborted.")
        }

        guard let stagedInfo = signingInfo(of: stagedCode), let stagedTeam = stagedInfo.teamIdentifier else {
            throw UpdateError.message("The downloaded update has no Team ID — install aborted.")
        }

        guard let runningInfo = runningAppSigningInfo(), let runningTeam = runningInfo.teamIdentifier else {
            throw UpdateError.message("Couldn't determine this app's own Team ID — install aborted.")
        }

        guard stagedTeam == runningTeam else {
            throw UpdateError.message("The update is signed by a different developer (\(stagedTeam)) — install aborted.")
        }

        if let stagedIdentifier = stagedInfo.identifier,
           let runningIdentifier = runningInfo.identifier,
           stagedIdentifier != runningIdentifier {
            throw UpdateError.message("The update is a different app (\(stagedIdentifier)) — install aborted.")
        }
    }

    nonisolated static func signingInfo(of code: SecStaticCode) -> SigningInfo? {
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else {
            return nil
        }
        return SigningInfo(
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            identifier: info[kSecCodeInfoIdentifier as String] as? String
        )
    }

    nonisolated private static func runningAppSigningInfo() -> SigningInfo? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess, let staticCode = staticRef else { return nil }
        return signingInfo(of: staticCode)
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
#endif
