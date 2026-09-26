#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"
export GOTOOLCHAIN=go1.25.5
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/.build/dependencies"
TS_REV=59d4bb82744915815178e0f0776d60026a397ee7
SMB_REV=66eafaa6d17e034e8036dee4b3ebc1b52cb53919
mkdir -p "$DEPS"
checkout() {
    if [ ! -d "$DEPS/$1/.git" ]; then git clone "$2" "$DEPS/$1"; fi
    if [ "$(git -C "$DEPS/$1" rev-parse HEAD)" != "$3" ]; then
        git -C "$DEPS/$1" fetch origin "$3"
        git -C "$DEPS/$1" checkout --detach "$3"
    fi
}
checkout libtailscale https://github.com/tailscale/libtailscale.git "$TS_REV"
checkout SMBClient https://github.com/kishikawakatsumi/SMBClient.git "$SMB_REV"
python3 "$ROOT/scripts/patch_tailnet_logging.py" "$DEPS/libtailscale"
python3 "$ROOT/scripts/patch_smb_transport.py" "$DEPS/SMBClient"
FRAMEWORK="$DEPS/libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework"
STAMP="$DEPS/libtailscale/.asteros-framework-stamp"
FINGERPRINT="$TS_REV-$(shasum -a 256 "$ROOT/scripts/patch_tailnet_logging.py" | cut -d ' ' -f1)-$(xcodebuild -version | tr '\n' '-')"
if [ ! -d "$FRAMEWORK" ] || [ "$(cat "$STAMP" 2>/dev/null || true)" != "$FINGERPRINT" ]; then
    rm -f "$DEPS/libtailscale"/libtailscale_ios*.a
    rm -rf "$FRAMEWORK"
    (cd "$DEPS/libtailscale/swift" && make ios-fat)
    printf '%s' "$FINGERPRINT" > "$STAMP"
fi
mkdir -p "$ROOT/.build/frameworks"
rsync -a --delete "$FRAMEWORK/" "$ROOT/.build/frameworks/TailscaleKit.xcframework/"
printf '%s\n' 'Embedded Tailscale dependencies ready.'
