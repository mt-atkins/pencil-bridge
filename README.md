# Pencil Bridge

Use an Apple Pencil-compatible iPad as a cursor input surface for a Mac. Two native Swift apps send Pencil input over an encrypted local connection.

**Experimental prototype.** Installation and pairing have been tested on physical hardware. The first version had noticeable lag; the current version includes performance fixes and round-trip diagnostics, but those improvements still need hardware retesting. Contributions and device reports are welcome.

The Pencil touches the **iPad screen**. Mac trackpads and Magic Trackpads cannot detect its tip. USB currently installs the app; it does **not** carry the input connection.

## Features

- **Draw / Drag:** Pencil contact presses the left mouse button, movement drags, and lifting releases it.
- **Pointer:** Pencil movement moves the cursor; a tap clicks on lift. Strokes moving more than 1.2% of the canvas do not click.
- Absolute mapping of the iPad canvas to a selected Mac display.
- Finger contacts on the input canvas are ignored.
- Bonjour discovery and pairing with a fresh 12-character code.
- TLS 1.2 with a pre-shared key and AES-GCM. The pairing code itself is not transmitted.
- Mouse-button release on cancelled strokes, disconnects, app backgrounding, Mac sleep, stopping sharing, and normal app exit. A silent connection loss is detected within approximately 5.5 seconds.
- Stale queued movement is replaced with the latest position while press, release, and cancellation ordering is preserved.
- Both apps display application-level connection round-trip time. This is not an end-to-end Pencil latency measurement.

Pressure is captured and transported, but the Mac currently posts ordinary mouse events. Pressure-sensitive tablet input, right-click, scrolling, screen mirroring, and direct USB input are not implemented.

## Requirements

- macOS 14 or later.
- iPadOS 16 or later and an Apple Pencil compatible with the iPad.
- Both devices on the same local network.
- Xcode 16.4 or later to build; an Apple development signing account to install on an iPad.

The initial hardware setup used a 9.7-inch iPad Pro running iPadOS 16.7.16. The apps have no third-party package dependencies.

## Build and install

```sh
git clone https://github.com/mt-atkins/pencil-bridge.git
cd pencil-bridge
open PencilBridge.xcodeproj
```

1. Sign in through **Xcode → Settings → Accounts**. For both targets, choose your team in **Signing & Capabilities**. Change the bundle identifiers if necessary for your account.
2. Connect the iPad by USB, unlock it, and trust the Mac. Enable **Settings → Privacy & Security → Developer Mode**, restart, and confirm.
3. Select the **PencilBridgeiPad** scheme and your physical iPad, then Run. Xcode may need to register the iPad and update the development provisioning profile.
4. Select **PencilBridgeMac** and **My Mac**, then Run.

The checked-in project has no development team configured. It can also be regenerated using Python's standard library:

```sh
python3 scripts/generate-project.py
```

Regeneration replaces the project settings, including changes made in Xcode. To include your signing team when regenerating:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID python3 scripts/generate-project.py
```

### Command-line builds

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project PencilBridge.xcodeproj -scheme PencilBridgeMac \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PencilBridge.xcodeproj -scheme PencilBridgeiPad \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

These commands verify compilation without a signing account. An unsigned device build cannot be installed on an iPad. For a signed device build, use your team and allow provisioning updates:

```sh
xcodebuild -project PencilBridge.xcodeproj -scheme PencilBridgeiPad \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates build
```

### iPadOS 16 installation fallback

If Xcode scripting does not expose an older iPad, the app can be provisioned and installed with `ios-deploy`:

```sh
brew install ios-deploy
DEVELOPMENT_TEAM=YOUR_TEAM_ID zsh scripts/install-ipad-ios16.sh YOUR_IPAD_UDID
```

Tap the app's icon on the iPad to launch it. Automatic debugger launch can fail on older devices when debug symbols are missing, even after a successful installation. This helper installs without launching. Use Xcode or Apple's `devicectl` tools for newer devices.

## Connect and use

1. On the Mac, click **Open Accessibility Settings** and enable Pencil Bridge in **Privacy & Security → Accessibility**.
2. Click **Start Sharing**. Allow Local Network access and incoming connections if macOS asks.
3. Open the iPad app, tap **Find Mac**, and allow Local Network access.
4. Enter the code shown by the Mac, then tap the Mac's name.
5. Choose **Pointer / Tap to Click** or **Draw / Drag**. Canvas position maps directly to the selected Mac display.
6. Use **Disconnect** on the iPad or **Stop Sharing** in the Mac menu bar to end the session.

Reconnect after backgrounding the iPad. Restarting sharing creates a new pairing code.

If no Mac appears, verify sharing is started, Local Network access is allowed for both apps, and the network permits devices to communicate with each other. A wrong pairing code times out. If connected input does not move the cursor, check Mac Accessibility access; rebuilding may require toggling or re-adding that permission.

## Verification

```sh
zsh scripts/check.sh
```

The 36 checks cover packet fragmentation and batching, invalid input, coordinate validation, click/drag state, cancellation and disconnect release, bounded movement coalescing, preserved stroke boundaries, connection round-trip measurement over encrypted loopback, and rejection of a wrong pairing key. They do not post real mouse events.

Use `--unit-only` to skip loopback networking. A restricted sandbox may require permission to listen on localhost.

Hardware verification is separate: test clicking, dragging, release when lifting the Pencil, release after backgrounding the iPad, reconnecting, and stopping sharing. Include device models, OS versions, perceived delay, and the displayed connection round-trip reading in reports.

## Source layout

| Path | Purpose |
| --- | --- |
| `Shared/Protocol.swift` | Validated packets, TCP framing, movement queue, cursor state |
| `Shared/Transport.swift` | Encrypted connections, heartbeats, timeouts, round-trip diagnostics |
| `Mac/MacApp.swift` | Sharing, pairing, display selection, Accessibility, Core Graphics input |
| `iPad/iPadApp.swift` | Discovery, connection UI, UIKit Pencil capture inside SwiftUI |
| `Tests/main.swift` | Input and networking checks |
| `scripts/` | Project generation, checks, device installation helpers |

The transport follows Apple's [TLS-PSK Network.framework example](https://developer.apple.com/forums/thread/711114). Input uses [UIKit Pencil touches](https://developer.apple.com/documentation/uikit/handling-input-from-apple-pencil), and discovery uses [NWBrowser](https://developer.apple.com/documentation/network/nwbrowser).

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md). Released under the [MIT license](LICENSE).
