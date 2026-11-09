import CTPM
import Foundation

/// A TPM 2.0 for one virtual machine, on libtpms: commands in, responses out, and its state as blobs the
/// caller keeps (encrypted, beside the VM). libtpms keeps global state, so a process has one TPM: `shared`.
///
/// The permanent state (seeds, NV indices, hierarchy settings) is what makes it this TPM; the volatile
/// state (loaded objects, sessions, PCRs) carries a running TPM across a save and restore of the VM.
public final class TPMEngine: @unchecked Sendable {
    public static let shared = TPMEngine()

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case libtpms(String, UInt32)
        case notRunning

        public var description: String {
            switch self {
            case .libtpms(let call, let rc): "\(call) failed (TPM_RESULT 0x\(String(rc, radix: 16)))"
            case .notRunning: "The TPM isn't running."
            }
        }
    }

    /// The libtpms profile a new TPM is made with. Pinned, so that a newer libtpms never changes the
    /// commands and algorithms an existing VM's TPM has (libtpms keeps a TPM's profile in its state).
    public static let defaultProfile = #"{"Name":"default-v1"}"#

    private let lock = NSLock()
    private var running = false
    fileprivate var permanent: Data?
    fileprivate var onPermanentChange: (@Sendable (Data) -> Void)?

    private init() {}

    /// Starts the TPM: a new one, made with `profile`, when `permanentState` is nil; else the TPM that
    /// state is. `volatileState` (from `volatileState()`) resumes it as it was when the VM was saved.
    /// `onPermanentStateChange` gets the new permanent state after every command that changes it.
    public func start(permanentState: Data?, volatileState: Data? = nil, profile: String = TPMEngine.defaultProfile,
                      onPermanentStateChange: @escaping @Sendable (Data) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if running { TPMLIB_Terminate(); running = false }
        permanent = permanentState
        onPermanentChange = onPermanentStateChange
        try check("TPMLIB_ChooseTPMVersion", TPMLIB_ChooseTPMVersion(TPMLIB_TPM_VERSION_2))
        var callbacks = libtpms_callbacks()
        callbacks.sizeOfStruct = Int32(MemoryLayout<libtpms_callbacks>.size)
        callbacks.tpm_nvram_init = { TPM_RESULT(TPM_SUCCESS) }
        callbacks.tpm_nvram_loaddata = nvramLoad
        callbacks.tpm_nvram_storedata = nvramStore
        callbacks.tpm_nvram_deletename = nvramDelete
        callbacks.tpm_io_init = { TPM_RESULT(TPM_SUCCESS) }
        callbacks.tpm_io_getlocality = { locality, _ in locality?.pointee = 0; return TPM_RESULT(TPM_SUCCESS) }
        callbacks.tpm_io_getphysicalpresence = { presence, _ in presence?.pointee = 0; return TPM_RESULT(TPM_SUCCESS) }
        try check("TPMLIB_RegisterCallbacks", TPMLIB_RegisterCallbacks(&callbacks))
        if let volatileState {
            try volatileState.withUnsafeBytes {
                try check("TPMLIB_SetState(volatile)", TPMLIB_SetState(TPMLIB_STATE_VOLATILE, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)))
            }
        }
        if permanentState == nil {
            try check("TPMLIB_SetProfile", TPMLIB_SetProfile(profile))
        }
        try check("TPMLIB_MainInit", TPMLIB_MainInit())
        running = true
    }

    /// Runs one TPM command (a complete TPM 2.0 command buffer) and returns its response.
    public func process(_ command: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard running else { throw Failure.notRunning }
        var response: UnsafeMutablePointer<UInt8>?
        var responseSize: UInt32 = 0
        var bufferSize: UInt32 = 0
        var input = [UInt8](command)
        let rc = TPMLIB_Process(&response, &responseSize, &bufferSize, &input, UInt32(input.count))
        defer { if let response { TPM_Free(response) } }
        try check("TPMLIB_Process", rc)
        guard let response else { throw Failure.libtpms("TPMLIB_Process returned no response", 0) }
        return Data(bytes: response, count: Int(responseSize))
    }

    /// The running TPM's volatile state, for a saved VM session.
    public func volatileState() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard running else { throw Failure.notRunning }
        var buffer: UnsafeMutablePointer<UInt8>?
        var length: UInt32 = 0
        try check("TPMLIB_GetState(volatile)", TPMLIB_GetState(TPMLIB_STATE_VOLATILE, &buffer, &length))
        defer { free(buffer) }
        guard let buffer else { return Data() }
        return Data(bytes: buffer, count: Int(length))
    }

    /// The permanent state now (also delivered to `onPermanentStateChange` whenever it changes).
    public var permanentState: Data? {
        lock.lock(); defer { lock.unlock() }
        return permanent
    }

    /// Turns the TPM off, as at a VM's power-off or reset. Start it again for the next boot.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if running { TPMLIB_Terminate(); running = false }
    }

    private func check(_ call: String, _ rc: TPM_RESULT) throws {
        guard rc == TPM_RESULT(TPM_SUCCESS) else { throw Failure.libtpms(call, UInt32(rc)) }
    }
}

// MARK: - libtpms storage callbacks (plain C functions: libtpms passes no context)

private func stateName(_ name: UnsafePointer<CChar>?) -> String { name.map { String(cString: $0) } ?? "" }

private let nvramLoad: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<UInt32>?, UInt32, UnsafePointer<CChar>?) -> TPM_RESULT = { data, length, _, name in
    // Only the permanent state is kept here; volatile state comes in through TPMLIB_SetState. TPM_RETRY
    // tells libtpms there is none, and it makes a new TPM.
    guard stateName(name) == TPM_PERMANENT_ALL_NAME, let stored = TPMEngine.shared.permanent, !stored.isEmpty else {
        return TPM_RESULT(TPM_RETRY)
    }
    var buffer: UnsafeMutablePointer<UInt8>?
    let rc = TPM_Malloc(&buffer, UInt32(stored.count))
    guard rc == TPM_RESULT(TPM_SUCCESS), let buffer else { return rc }
    stored.copyBytes(to: buffer, count: stored.count)
    data?.pointee = buffer
    length?.pointee = UInt32(stored.count)
    return TPM_RESULT(TPM_SUCCESS)
}

private let nvramStore: @convention(c) (UnsafePointer<UInt8>?, UInt32, UInt32, UnsafePointer<CChar>?) -> TPM_RESULT = { data, length, _, name in
    guard stateName(name) == TPM_PERMANENT_ALL_NAME, let data else { return TPM_RESULT(TPM_SUCCESS) }
    let state = Data(bytes: data, count: Int(length))
    TPMEngine.shared.permanent = state
    TPMEngine.shared.onPermanentChange?(state)
    return TPM_RESULT(TPM_SUCCESS)
}

private let nvramDelete: @convention(c) (UInt32, UnsafePointer<CChar>?, TPM_BOOL) -> TPM_RESULT = { _, name, _ in
    if stateName(name) == TPM_PERMANENT_ALL_NAME { TPMEngine.shared.permanent = nil }
    return TPM_RESULT(TPM_SUCCESS)
}
