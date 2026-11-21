// swift-tools-version:5.9
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import PackageDescription

let package = Package(
    name: "TouchSpace",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TouchSpace", targets: ["TouchSpace"])],
    targets: [
        // .metal 由 SwiftPM 编进资源包（default.metallib），渲染器用 makeDefaultLibrary(bundle: .module) 取。
        .target(name: "TouchSpace", resources: [.process("TouchShaders.metal")]),
    ]
)
