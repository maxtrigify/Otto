// swift-tools-version: 5.9

// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Otto's copy of microsoft/onnxruntime-swift-package-manager 1.24.2 (see README.md here).
// The upstream repository and its binary download both went away in November 2026, so the
// bindings and the macOS binary are kept in this repository.

import PackageDescription

let package = Package(
  name: "onnxruntime",
  platforms: [.iOS(.v15), .macOS(.v14)],
  products: [
    .library(name: "onnxruntime", type: .static, targets: ["OnnxRuntimeBindings"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "OnnxRuntimeBindings",
      dependencies: ["onnxruntime"],
      path: "objectivec",
      cxxSettings: [.define("SPM_BUILD")]),
    .binaryTarget(name: "onnxruntime", path: "onnxruntime.xcframework.zip"),
  ],
  cxxLanguageStandard: .cxx17
)
