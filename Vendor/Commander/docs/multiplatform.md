---
summary: 'Commander multiplatform support log'
read_when:
  - enabling Commander on additional OS targets
  - modifying Commander CI coverage
---

# Commander Multiplatform Tracking

## Current Status (November 11, 2025)
- **Supported platforms:** macOS 14+, iOS 17+, tvOS 17+, watchOS 10+, visionOS 1.0+ via `Package.swift` declarations; Linux remains unrestricted because SwiftPM only constrains Apple-family targets explicitly. Windows and Android are intentionally unsupported.
- **Portability audit:** Commander exclusively depends on `Foundation` and concurrency features already available in Swift 6, so no conditional compilation was required.
- **Testing coverage:** `CommanderTests` run natively on macOS and Linux. Apple simulator builds validate the iOS/tvOS/watchOS triples. Windows and Android are not part of our CI story.

> ¹ See [Swift Package Manager Platform Support](https://developer.apple.com/documentation/swift_packages/supportedplatform), which documents that only Apple OS minimums are declared in `Package.swift` and other platforms remain unconstrained.

## Implementation Checklist

| Item | Status | Notes |
| --- | --- | --- |
| Declare Apple platform minimums in `Package.swift` | ✅ | Uses `.macOS(.v14)`, `.iOS(.v17)`, `.tvOS(.v17)`, `.watchOS(.v10)`, `.visionOS(.v1)`
| Verify Linux portability of sources/tests | ✅ | Host-only APIs avoided; runs via `swift test --package-path Commander` on Linux
| Validate Apple simulator builds | ✅ | `swift build --build-tests` with `-Xswiftc -sdk …`/`-Xswiftc -target …` for iOS/tvOS/watchOS as described [on Swift Forums](https://forums.swift.org/t/how-to-build-ios-apps-on-linux-with-swift-package/66601/3)
| Standalone Commander workflow | ✅ | `.github/workflows/commander-multiplatform.yml` fan-out matrix covers macOS, Apple simulators, and Linux

## CI Design Highlights
- **macOS host tests:** Run `swift test` directly on `macos-latest` (currently the macOS 15 Sonoma image announced [here](https://github.blog/changelog/2025-04-10-github-actions-macos-15-and-windows-2025-images-are-now-generally-available/)).
- **Apple simulator builds:** Each matrix entry resolves the proper SDK via `xcrun --sdk <name> --show-sdk-path` and then runs `xcrun --sdk <name> swift build --build-tests --triple <target> --sdk <path>` so both Swift and Clang honor the simulator sysroot.
- **Linux:** We use `SwiftyLab/setup-swift@v1` with Ubuntu 24.04 targeting Swift 6.2. Windows coverage was dropped, so no WinGet/compnerd steps remain.
## Follow-Ups
1. Expand visionOS coverage beyond compiler smoke tests once Peekaboo formally adopts it in app targets.
2. Expand the test suite with parser edge cases so non-macOS runs provide more value.
3. Publish a reusable GitHub Actions composite to share these steps with Tachikoma/PeekabooCore once Commander graduates to its own repository.
