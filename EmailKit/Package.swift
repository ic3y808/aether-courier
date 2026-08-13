// swift-tools-version:6.2
import PackageDescription

// EmailKit — the self-contained mail engine for Aether-Courier.
//
// Mirrors the role AetherKit plays for Aether-Terra: a UI-free Swift package
// that owns all networking (IMAP/SMTP over Network.framework), the Codable
// DTOs, MIME handling, and the pure OAuth-PKCE helpers. It has NO dependency
// on the Aether backend — the backend is used ONLY for AI copilot tasks, and
// that client lives in the app target, not here.
//
// Zero external dependencies: the IMAP and SMTP clients are implemented on
// Apple's Network.framework so the package stays pure and deterministically
// testable (protocol logic runs against an in-memory scripted transport).
let package = Package(
    name: "EmailKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(name: "EmailKit", targets: ["EmailKit"])
    ],
    targets: [
        .target(
            name: "EmailKit",
            path: "Sources/EmailKit"
        ),
        .testTarget(
            name: "EmailKitTests",
            dependencies: ["EmailKit"],
            path: "Tests/EmailKitTests"
        )
    ]
)
