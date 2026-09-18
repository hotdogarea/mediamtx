#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode is required" >&2; exit 1; }

xcodegen generate
for app in CameraBridgeDemo CameraBridgeCleanHost; do
  case "$app" in
    CameraBridgeDemo) output_name="boleme-demo" ;;
    CameraBridgeCleanHost) output_name="boleme-clean-host" ;;
  esac
  xcodebuild -project CameraBridgeDemo.xcodeproj -scheme "$app" \
    -configuration Release -sdk iphoneos -arch arm64 \
    -derivedDataPath "$project_dir/build" CODE_SIGNING_ALLOWED=NO build
  mkdir -p "$project_dir/out/$app/Payload"
  ditto "$project_dir/build/Build/Products/Release-iphoneos/$app.app" \
    "$project_dir/out/$app/Payload/$app.app"
  cd "$project_dir/out/$app"
  ditto -c -k --sequesterRsrc --keepParent Payload "../$output_name.ipa"
  cd "$project_dir"
done

sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -dynamiclib -fobjc-arc \
  -miphoneos-version-min=14.0 -isysroot "$sdk_path" \
  -I "$project_dir/CameraBridge" \
  -framework Foundation -framework UIKit -framework AVFoundation \
  -framework CoreMedia -framework CoreVideo -framework CoreImage -framework CoreGraphics -framework QuartzCore \
  -Wl,-install_name,@rpath/boleme.dylib \
  "$project_dir/CameraBridge/CameraBridge.m" \
  "$project_dir/CameraBridge/BridgeControls.m" -o "$project_dir/out/boleme.dylib"
codesign --force --sign - "$project_dir/out/boleme.dylib"

echo "Built: $project_dir/out/boleme-demo.ipa"
echo "Built: $project_dir/out/boleme-clean-host.ipa"
echo "Built: $project_dir/out/boleme.dylib"
