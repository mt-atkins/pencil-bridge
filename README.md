# Pencil Bridge

Use an Apple Pencil-compatible iPad as a cursor input surface for a Mac. Two native Swift apps send Pencil input over an encrypted local connection.

**Experimental prototype (0.4).** The earlier version was installed and paired on physical hardware. The apps include a tablet workspace, finger trackpad controls, four-digit codes and QR pairing. Version 0.4 adds a selected-window ghost preview and app input lock alongside Distyll’s Toolpath branding. Automated checks cover the new input and pairing formats; camera scanning, pressure support in individual drawing apps, and gesture feel still need hardware testing. Contributions and device reports are welcome. Update both apps together: version 0.4 uses input protocol 3 and requires both apps to be updated.

The Pencil touches the **iPad screen**. Mac trackpads and Magic Trackpads cannot detect its tip. USB currently installs the app; it does **not** carry the input connection.

## Distyll branding

Graphite surfaces, restrained orange actions, Space Grotesk headings, Inter text and IBM Plex Mono readouts follow Distyll’s Toolpath system. Both apps bundle their fonts and use an original pen-and-tablet icon. See [BRANDING.md](BRANDING.md) for tokens and asset generation, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for font licences.

## Pen tablet workspace

- **Pen:** contact draws or drags; lifting releases the tip. Precise positions, normalized pressure, and tilt are sent as macOS tablet-point events, with a stable device identity and contact proximity events.
- **Pointer:** Pencil contact moves the cursor, and tapping clicks on lift.
- **Pan:** Pencil contact holds Space and drags; lifting, cancellation or disconnect releases both the mouse button and Space.
- The active area matches the selected Mac display’s proportions, so circles remain circular. Display changes are communicated to the iPad. Proportional mapping can be disabled in Tablet Settings.
- Light, Natural and Firm pressure response curves, plus a local pen test pad that never sends input to the Mac.
- A shortcut rail for undo/redo, brush/eraser, brush size, zoom, fit, and display switching. Move it to either side using the handedness setting.
- Per-app keyboard bindings: activate the desired Mac app, then use **Edit Shortcuts** in the companion to customize its keys and modifiers. Profiles are saved locally and selected automatically as the active Mac app changes.
- Up to 16 delivered pen samples are batched together for stroke fidelity. Movement waiting behind a slow connection is bounded, while press, release and cancellation ordering is retained.

Drawing apps differ in how they accept synthetic tablet events. **Send tablet pressure and tilt** can be disabled in the Mac app for ordinary mouse compatibility. Encoding and AppKit conversion are tested; pressure/tilt support has not yet been verified across third-party drawing apps. First-generation Apple Pencil has no hover sensing or double-tap button. A low-frame-rate window ghost is available; full desktop mirroring and direct USB input are not implemented.

## Window ghost and app lock

Choose **App window** in the Mac companion, or **Selected window** in iPad Tablet Settings. The Pencil maps to that window’s rectangle instead of the entire display. Choose Whole display to return to display mapping. The picker shows up to twelve visible windows, plus the current selection.

Enable **Show window ghost** for a faint, live image behind the iPad drawing surface. Allow Pencil Bridge in macOS **Privacy & Security → Screen Recording** (called Screen & System Audio Recording on newer macOS releases); macOS may require restarting the app. Ghost opacity is adjustable on the iPad. Capture includes only the selected window, without the cursor, at up to four frames per second and 960 pixels on the longest side. Minimized/closed windows have no live preview. This is a positioning aid; the local Pencil trail remains immediate.

Frames use a separate encrypted connection with a fresh 256-bit session secret supplied over the authenticated input connection. Frames are bounded, dropped when the preview connection is busy, and decoded off the iPad input thread. Images are not recorded or saved. Screen Recording permission is only requested when ghost preview is enabled.

**Lock input to selected app** pauses Pencil, finger and shortcut input when the selected app/window is not active. Locked events are addressed to the selected process; finger motion is confined to the selected window and clicks are blocked through overlapping windows. Changing targets, losing focus or moving the window releases held input. A closed/minimized locked target stays locked and paused until it returns or you unlock it. Switch to the chosen window on the Mac to resume. App lock does not activate apps automatically or prevent use of your physical keyboard/mouse.

## Mac drawing demo

Choose **Open drawing demo** in the Mac companion or menu bar. Pair the iPad, select Pen, enable tablet pressure and tilt, then draw in the light canvas. The demo uses ordinary AppKit input events, showing whether it receives tablet or mouse input plus live pressure and tilt. Pressure changes brush width; ordinary mouse input uses fixed width. It includes brush/eraser, size, undo/redo, Clear and Save PNG. Keyboard controls: B, E, [ and ], Cmd Z, Shift Cmd Z and Cmd S. Drawings stay in memory until exported; closing the demo discards them.

## Audio feedback

The iPad plays optional, short speaker clicks for Pencil contact, finger clicks, drag starts and tool controls. Tablet Settings provides a Click sounds toggle, volume slider and Test sound button. Cues are generated locally and prepared off the input thread; there is no continuous stroke sound or extra network traffic. They use the iPad’s media volume and mix with other audio. **Play when iPad is muted** is enabled by default; turn it off to respect Silent mode. The output label and route picker show whether the iPad is using its own speakers, headphones or AirPlay. No feedback audio is generated on the Mac. Use the iPad speakers for the most direct feel; Bluetooth audio may add delay. These are audible cues, not physical haptics.

## Finger trackpad controls

Finger input is relative to the Mac cursor and can move between displays; the Pencil remains mapped absolutely to the selected display.

| Finger input | Mac behavior |
| --- | --- |
| One-finger movement | Move the cursor |
| One-finger tap | Click; quick successive taps use native double/triple-click counts |
| Two-finger tap | Secondary (right) click |
| Two-finger movement | Horizontal and vertical scrolling |
| Pinch | Zoom using the active app’s configurable zoom shortcuts |
| Three-finger movement | Drag with the left mouse button held |

Tablet Settings provides Trackpad, Gestures only and Off options, plus pointer speed. Finger recognizers are disabled during Pencil contact and briefly after lifting to reduce interference from resting fingers. The local test pad ignores finger gestures.

This is a subset of Magic Trackpad behavior. It does not emulate Force Touch, momentum, system-wide Mission Control/swipe gestures or native trackpad magnification events. iPadOS may reserve some gestures at the screen edges.

## Pairing and connection

- A fresh **four-digit join code**, including leading zeros, is shown whenever Mac sharing starts. The manual path limits connection attempts to five per minute; successful pairing resets that limit.
- **Scan QR Code** on the iPad uses the camera to pair automatically. QR pairing has a separate, randomly generated 256-bit secret and does not use the short manual code.
- Both paths use TLS 1.2 with ECDHE-PSK and ChaCha20-Poly1305. Prefer QR pairing on shared networks; four-digit codes are intended for trusted local networks and provide much less authentication entropy than the QR secret.
- Button/key release on cancelled input, disconnects, app backgrounding, Mac sleep, stopping sharing and normal app exit. A silent connection loss is detected within approximately 5.5 seconds.
- Both apps display application-level connection round-trip time, not end-to-end Pencil latency.

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
3. Open the iPad app and allow Local Network access. Tap **Scan QR Code**, allow Camera access, and point at the Mac’s QR code; pairing proceeds automatically.
4. Alternatively, enter the Mac’s four-digit code, tap **Find Mac** if needed, and select the Mac’s name.
5. Activate your drawing app on the Mac. Choose **Pen**, **Pointer**, or **Pan** on the iPad. Open Tablet Settings for tip feel, handedness, finger input and the local pen test.
6. Use **Disconnect** on the iPad or **Stop Sharing** in the Mac menu bar to end the session.

Reconnect after backgrounding the iPad. Restarting sharing creates a new pairing code.

If no Mac appears, verify sharing is started, Local Network access is allowed for both apps, and the network permits devices to communicate with each other. A wrong pairing code times out. If connected input does not move the cursor, check Mac Accessibility access; rebuilding may require toggling or re-adding that permission.

## Verification

```sh
zsh scripts/check.sh
```

The automated checks cover packet fragmentation and batching, invalid coordinates/tilt, pen and finger drag state, cancellation/release, proportional mapping, pressure curves, native AppKit pressure/tilt conversion, button/click fields, per-app binding serialization, relative-distance coalescing, four-digit validation/throttling, QR URL validation and actual QR image decoding, and encrypted connections with both manual and QR credentials. They verify the negotiated cipher and reject a wrong key. They do not post real mouse or keyboard input.

Use `--unit-only` to skip loopback networking. A restricted sandbox may require permission to listen on localhost.

Hardware verification is separate: test window selection, ghost alignment after moving/resizing a window, capture permission denied/re-enabled, app lock while changing apps/windows or minimizing/closing the target, audio routes/mute, and then test manual and QR pairing (including Camera denied/cancelled), Pencil pressure and tilt in your drawing app, relative finger pointing, secondary/double click, two-finger scrolling, pinch zoom, three-finger drag, and release after lifting, cancellation, backgrounding or stopping sharing. Test switching Mac displays and apps, screen rotation, left-handed controls and finger input disabled. Include device models, OS versions, perceived delay, and connection round-trip readings in reports.

## Source layout

| Path | Purpose |
| --- | --- |
| `Shared/Protocol.swift` | Validated packets, TCP framing, movement queue, cursor state |
| `Shared/Transport.swift` | Encrypted connections, heartbeats, timeouts, round-trip diagnostics |
| `Shared/Pairing.swift` | Short-code validation, attempt limiter and QR ticket format |
| `Shared/Tablet.swift` | Mapping, pressure response, finger state and shortcut types |
| `Mac/` | Sharing, QR display, tablet/mouse events and per-app shortcut editor |
| `iPad/` | Connection model, camera scanner, tablet workspace and pen/finger capture |
| `Tests/main.swift` | Input and networking checks |
| `scripts/` | Project generation, checks, device installation helpers |

The transport follows Apple's [TLS-PSK Network.framework example](https://developer.apple.com/forums/thread/711114). Input uses [UIKit Pencil touches](https://developer.apple.com/documentation/uikit/handling-input-from-apple-pencil), and discovery uses [NWBrowser](https://developer.apple.com/documentation/network/nwbrowser).

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md). Original code and product icons are released under the [MIT license](LICENSE). Bundled fonts retain their [SIL Open Font Licences](THIRD_PARTY_NOTICES.md).
