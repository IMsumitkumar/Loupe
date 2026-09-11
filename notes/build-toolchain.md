Xcode 26.6 is installed but the active developer directory is the Command Line Tools; the Makefile sets `DEVELOPER_DIR` instead of changing the system setting.

The app is built with SwiftPM (`swift build`) and the bundle assembled by the Makefile rather than a hand-written
`.xcodeproj`; the spec's 9.1 layout names an xcodeproj but fixes only the outcome (one `make` to a signed DMG).
Both Rust targets are installed so the staticlib is lipo'd universal. The keychain holds two "Apple Development"
identities and no "Developer ID Application", so `make` signs with Apple Development by default and notarization
(`make notarize`) needs a Developer ID certificate plus a `notarytool` keychain profile in `NOTARY_PROFILE`.
