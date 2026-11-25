# ONNX Runtime (Otto's copy)

Otto's wake-word detector (`Vendor/livekit-wakeword`) runs its models with ONNX Runtime.

On 17 November 2026 `github.com/microsoft/onnxruntime-swift-package-manager` and
`github.com/microsoft/onnxruntime` stopped resolving (404), and
`download.onnxruntime.ai` began serving a certificate for a different host. A clean checkout
of Otto could no longer fetch the package or its binary, so both are kept here.

## What is here

| Path | From |
| --- | --- |
| `objectivec/` | `microsoft/onnxruntime-swift-package-manager` at `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2` (1.24.2), unmodified. Training sources, tests and docs are left out. |
| `onnxruntime.xcframework.zip` | The macOS slice of Microsoft's `pod-archive-onnxruntime-c-1.24.2.zip`. |
| `LICENSE` | MIT, Microsoft Corporation. |

## Checking the binary

Microsoft's archive has SHA-256
`f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54`, the checksum in the
upstream `Package.swift` at 1.24.2. This copy drops the iOS slices to keep the repository
small; nothing else is changed. The library inside is byte-identical to the one in
Microsoft's archive:

```
unzip -p onnxruntime.xcframework.zip \
  onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/onnxruntime \
  | shasum -a 256
# 1e57e861aae21b03780d796a5725288e16d68510a2916c26b3b479fa35c91b92
```

## If upstream comes back

Point `Package.swift` at the upstream packages again and delete `Vendor/`.
