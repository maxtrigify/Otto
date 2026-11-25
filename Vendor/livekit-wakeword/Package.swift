// swift-tools-version:5.9
//
// Otto's copy of livekit/livekit-wakeword's Swift package at
// 95448a7559c453fcd87645bd67b247ffb45f85b0 (Apache-2.0, see LICENSE). The sources are
// unmodified; only this manifest differs, pointing at Otto's copy of ONNX Runtime because the
// upstream microsoft/onnxruntime-swift-package-manager repository no longer resolves.
import PackageDescription

let package = Package(
  name: "LiveKitWakeWord",
  platforms: [.iOS(.v16), .macOS(.v14)],
  products: [
    .library(name: "LiveKitWakeWord", targets: ["LiveKitWakeWord"])
  ],
  dependencies: [
    .package(path: "../onnxruntime-swift-package-manager")
  ],
  targets: [
    .target(
      name: "LiveKitWakeWord",
      dependencies: [
        .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
      ],
      path: "Sources/LiveKitWakeWord",
      resources: [
        .copy("Resources/melspectrogram.onnx"),
        .copy("Resources/embedding_model.onnx"),
      ]
    )
  ]
)
