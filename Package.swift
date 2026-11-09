// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macvisor-tpm",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacVisorTPM", targets: ["MacVisorTPM"]),
    ],
    targets: [
        // libtpms (TPM 2.0) and OpenSSL's libcrypto, static, built from their release tarballs by
        // scripts/build-ctpm.sh (pinned versions and SHA-256s in Artifacts/BUILD-INFO.txt).
        .binaryTarget(name: "CTPM", path: "Artifacts/CTPM.xcframework"),
        // A TPM 2.0 for one virtual machine: commands in, responses out, its state as blobs the caller keeps.
        .target(name: "MacVisorTPM", dependencies: ["CTPM"]),
        .testTarget(name: "MacVisorTPMTests", dependencies: ["MacVisorTPM"]),
    ]
)
