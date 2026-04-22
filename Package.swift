// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NocturneServer",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    dependencies: [
        // Server Framework
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.15.0"),
        
        // Database
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.8.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-fluent.git", from: "2.0.0"),
        
        // HTTP Client for Jellyfin API
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        
        // WebSocket client
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.6.0"),

        // Logging
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),

        // Cross‑platform CryptoKit for Linux
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.9.0"),
        
        // (Anthropic via HTTP API; no SDK dependency)
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "NocturneServer",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                
                // Database
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "HummingbirdFluent", package: "hummingbird-fluent"),
                
                // HTTP Client
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
                
                
                // Utilities
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/NocturneServer"
        ),
    ]
)
