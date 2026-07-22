import Foundation
import Testing
@testable import NoteSide

struct UpdateCheckerSignatureTests {

    /// The test host is the signed NoteSide.app itself — it trivially
    /// matches its own team and bundle identifier, so verification must
    /// accept it.
    @Test func acceptsAppSignedBySameTeamWithSameIdentifier() throws {
        try UpdateChecker.verifyUpdateSignature(of: Bundle.main.bundleURL)
    }

    /// A system app is validly signed but by a different (or absent)
    /// team — the updater must refuse to install it.
    @Test func rejectsValidlySignedAppFromAnotherTeam() {
        #expect(throws: (any Error).self) {
            try UpdateChecker.verifyUpdateSignature(
                of: URL(fileURLWithPath: "/System/Applications/Calculator.app")
            )
        }
    }

    /// An unsigned bundle (what an attacker-controlled download would
    /// look like at minimum) must be refused outright.
    @Test func rejectsUnsignedBundle() throws {
        let fakeApp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeUpdate-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(
            at: fakeApp.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fakeApp) }

        #expect(throws: (any Error).self) {
            try UpdateChecker.verifyUpdateSignature(of: fakeApp)
        }
    }
}
