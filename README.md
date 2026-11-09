# macvisor-tpm

A TPM 2.0 for virtual machines on macOS, as a Swift package: [libtpms](https://github.com/stefanberger/libtpms)
and OpenSSL's libcrypto, built static from their release tarballs, behind a small Swift API. MacVisor uses it
to give Windows 11 and Linux guests a virtual TPM under Apple's Virtualization.framework.

```swift
import MacVisorTPM

let tpm = TPMEngine.shared                      // one TPM per process (libtpms keeps global state)
try tpm.start(permanentState: saved) { state in // nil makes a new TPM
    persist(state)                              // called after every command that changes it
}
let response = try tpm.process(command)         // a TPM 2.0 command buffer in, its response out
let session = try tpm.volatileState()           // for a saved VM session; start(volatileState:) resumes it
tpm.stop()                                      // power off; start again for the next boot
```

A new TPM is made with libtpms' `default-v1` profile, pinned so that a newer libtpms never changes the commands
and algorithms an existing TPM has. The caller sends `TPM2_Startup` after each start, as platform firmware
does, and keeps the state blobs (MacVisor encrypts them under a key held by the Mac's Secure Enclave).

## Building the library

`Artifacts/CTPM.xcframework` is built by `scripts/build-ctpm.sh` from pinned versions, checked against their
SHA-256s (`Artifacts/BUILD-INFO.txt` says which): OpenSSL 3.5 (an LTS line) and libtpms 0.10, TPM 2.0 only,
arm64, macOS 15 or later. It needs Xcode's command line tools, autoconf, automake, libtool and pkg-config.

## Licence

MIT for this package's own code (LICENSE). The library it builds contains libtpms (BSD-3-Clause, BSD-2-Clause
and the TCG's licence) and OpenSSL (Apache-2.0): see THIRD-PARTY-NOTICES.md.
