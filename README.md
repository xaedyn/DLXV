# DLXV

**Deluxe video. For Mac.**

A native macOS video player for Apple Silicon — accurate HDR rendering,
media-library support, and on-device subtitle generation. Currently in early
development.

## Status

**Phase 0 — validation.** Building the HDR rendering proof-of-concept.

## Requirements

- macOS Tahoe 26 or later
- Apple Silicon (M-series)
- Xcode 26 or later

## Building

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate
the Xcode project from `project.yml`, so the `.xcodeproj` is not committed.

```sh
brew install xcodegen   # one time
xcodegen generate       # produces DLXV.xcodeproj
open DLXV.xcodeproj
```

Then build and run from Xcode with ⌘R.

## License

MIT — see [LICENSE](LICENSE).
