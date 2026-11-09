import Foundation
import Testing
@testable import MacVisorTPM

/// libtpms keeps one TPM per process, so these run one at a time.
@Suite(.serialized)
struct TPMEngineTests {
    /// TPM2_Startup(SU_CLEAR).
    static let startup = Data([0x80, 0x01, 0, 0, 0, 0x0c, 0, 0, 0x01, 0x44, 0, 0])
    /// TPM2_GetRandom(16).
    static let getRandom = Data([0x80, 0x01, 0, 0, 0, 0x0c, 0, 0, 0x01, 0x7b, 0, 0x10])
    /// TPM2_GetCapability(TPM_CAP_TPM_PROPERTIES, TPM_PT_FAMILY_INDICATOR, 1).
    static let family = Data([0x80, 0x01, 0, 0, 0, 0x16, 0, 0, 0x01, 0x7a, 0, 0, 0, 0x06, 0, 0, 0x01, 0, 0, 0, 0, 0x01])

    static func rc(_ response: Data) -> UInt32 { response.dropFirst(6).prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }

    final class Box: @unchecked Sendable { var state: Data?; var writes = 0 }

    @Test func aNewTPMStartsAndAnswers() throws {
        let box = Box()
        let tpm = TPMEngine.shared
        try tpm.start(permanentState: nil) { box.state = $0; box.writes += 1 }
        defer { tpm.stop() }
        #expect(Self.rc(try tpm.process(Self.startup)) == 0)
        let random = try tpm.process(Self.getRandom)
        #expect(Self.rc(random) == 0)
        #expect(random.count == 10 + 2 + 16)
        let family = try tpm.process(Self.family)
        #expect(Self.rc(family) == 0)
        #expect(family.suffix(4) == Data("2.0\0".utf8), "TPM_PT_FAMILY_INDICATOR is \"2.0\"")
        #expect(box.state != nil && box.writes > 0, "A new TPM's permanent state was handed out to keep.")
    }

    /// TPM2_CreatePrimary in the owner hierarchy, an ECC P-256 storage key with a fixed template: derived
    /// from the TPM's seed, so the same TPM always makes the same key and another TPM a different one.
    static let createPrimary = Data([
        0x80, 0x02, 0x00, 0x00, 0x00, 0x43, 0x00, 0x00, 0x01, 0x31,   // TPM_ST_SESSIONS, size 67, CreatePrimary
        0x40, 0x00, 0x00, 0x01,                                        // TPM_RH_OWNER
        0x00, 0x00, 0x00, 0x09, 0x40, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00,   // empty password session
        0x00, 0x04, 0x00, 0x00, 0x00, 0x00,                            // inSensitive: no auth, no data
        0x00, 0x1a, 0x00, 0x23, 0x00, 0x0b, 0x00, 0x03, 0x04, 0x72, 0x00, 0x00,   // ECC, SHA-256, storage attributes
        0x00, 0x06, 0x00, 0x80, 0x00, 0x43, 0x00, 0x10, 0x00, 0x03, 0x00, 0x10,   // AES-128-CFB, no scheme, P-256, no KDF
        0x00, 0x00, 0x00, 0x00,                                        // unique: empty x, y
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,                            // outsideInfo, no PCRs
    ])

    @Test func thePermanentStateIsTheSameTPMNextTime() throws {
        let tpm = TPMEngine.shared
        try tpm.start(permanentState: nil) { _ in }
        _ = try tpm.process(Self.startup)
        let key = try tpm.process(Self.createPrimary)
        #expect(Self.rc(key) == 0)
        let state = try #require(tpm.permanentState)
        tpm.stop()

        try tpm.start(permanentState: state) { _ in }
        _ = try tpm.process(Self.startup)
        #expect(try tpm.process(Self.createPrimary) == key, "Started from its state: the same seed, the same key.")
        tpm.stop()

        try tpm.start(permanentState: nil) { _ in }
        defer { tpm.stop() }
        _ = try tpm.process(Self.startup)
        let other = try tpm.process(Self.createPrimary)
        #expect(Self.rc(other) == 0)
        #expect(other != key, "A new TPM has a seed of its own.")
    }

    @Test func aRunningTPMsVolatileStateResumesIt() throws {
        let tpm = TPMEngine.shared
        try tpm.start(permanentState: nil) { _ in }
        _ = try tpm.process(Self.startup)
        let permanent = try #require(tpm.permanentState)
        let volatile = try tpm.volatileState()
        #expect(!volatile.isEmpty)
        tpm.stop()
        try tpm.start(permanentState: permanent, volatileState: volatile) { _ in }
        defer { tpm.stop() }
        // Resumed: it is started already, so a second Startup is refused as TPM_RC_INITIALIZE (0x100).
        #expect(Self.rc(try tpm.process(Self.startup)) == 0x100)
        #expect(Self.rc(try tpm.process(Self.getRandom)) == 0)
    }

    @Test func aStoppedTPMRefusesCommands() {
        TPMEngine.shared.stop()
        #expect(throws: TPMEngine.Failure.notRunning) { try TPMEngine.shared.process(Self.getRandom) }
    }
}
