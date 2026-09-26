#!/bin/sh
set -eu
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
command -v go >/dev/null 2>&1 || { echo 'error: Install Go before building AsterOS VPN (brew install go).'; exit 1; }
# Vendored upstream revision and manifest-only compatibility fix are recorded in Vendor/WireGuardKit/UPSTREAM.md.
wg_source="$SRCROOT/Vendor/WireGuardKit/Sources/WireGuardKitGo"
[ -f "$wg_source/Makefile" ] || { echo 'error: Resolve Swift packages before building WireGuard.'; exit 1; }
case "$PLATFORM_NAME" in
    iphoneos) clang_target=miphoneos-version-min ;;
    iphonesimulator) clang_target=mios-simulator-version-min ;;
    *) echo 'error: Unsupported WireGuard build platform.'; exit 1 ;;
esac
exec /usr/bin/make -C "$wg_source" \
    GOOS_iphonesimulator=ios \
    DEPLOYMENT_TARGET_CLANG_FLAG_NAME="$clang_target" \
    DEPLOYMENT_TARGET_CLANG_ENV_NAME=IPHONEOS_DEPLOYMENT_TARGET \
    IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
