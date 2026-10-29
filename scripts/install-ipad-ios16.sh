#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
if (( $# != 1 )); then
    print -u2 'Usage: zsh scripts/install-ipad-ios16.sh <iPad-UDID>'
    exit 2
fi
if ! command -v ios-deploy >/dev/null; then
    print -u2 'Install the iPadOS 16 installer first: brew install ios-deploy'
    exit 2
fi
ipad_identifier="$1"
signing_args=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    signing_args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
xcodebuild -project PencilBridge.xcodeproj -scheme PencilBridgeiPad \
    -destination "platform=iOS,id=$ipad_identifier" -destination-timeout 30 \
    -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration "${signing_args[@]}" build
ios-deploy --id "$ipad_identifier" --bundle build/Build/Products/Debug-iphoneos/PencilBridgeiPad.app --no-wifi
print 'Installed. Tap Pencil Bridge on the iPad to launch it.'
