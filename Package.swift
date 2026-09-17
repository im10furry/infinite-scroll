// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InfiniteScroll",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 1.14.0 is the first release that wires Terminal.userScrolling into
        // scrollTo, so scrolling back while output streams no longer snaps to
        // the bottom (upstream issue #559).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.14.0"),
    ],
    targets: [
        .target(
            name: "InfiniteScrollProtocol",
            path: "Sources/InfiniteScrollProtocol"
        ),
        .executableTarget(
            name: "InfiniteScroll",
            dependencies: ["SwiftTerm", "InfiniteScrollProtocol"],
            path: "Sources/InfiniteScroll"
        ),
        .executableTarget(
            name: "infinite-scroll",
            dependencies: ["InfiniteScrollProtocol"],
            path: "Sources/InfiniteScrollCLI"
        ),
    ]
)
