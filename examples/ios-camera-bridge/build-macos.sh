#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode is required" >&2; exit 1; }

xcodegen generate
xcodebuild -project CameraBridgeDemo.xcodeproj -scheme CameraBridgeDemo \
  -configuration Release -sdk iphoneos -arch arm64 \
  -derivedDataPath "$project_dir/build" CODE_SIGNING_ALLOWED=NO build

mkdir -p "$project_dir/out/Payload"
ditto "$project_dir/build/Build/Products/Release-iphoneos/CameraBridgeDemo.app" \
  "$project_dir/out/Payload/CameraBridgeDemo.app"
cd "$project_dir/out"
ditto -c -k --sequesterRsrc --keepParent Payload CameraBridgeDemo.ipa

sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -dynamiclib -fobjc-arc \
  -miphoneos-version-min=14.0 -isysroot "$sdk_path" \
  -I "$project_dir/CameraBridge" \
  -framework Foundation -framework UIKit -framework AVFoundation \
  -framework CoreMedia -framework CoreVideo -framework CoreImage -framework QuartzCore \
  -Wl,-install_name,@rpath/CameraBridge.dylib \
  "$project_dir/CameraBridge/CameraBridge.m" -o "$project_dir/out/CameraBridge.dylib"
codesign --force --sign - "$project_dir/out/CameraBridge.dylib"

echo "Built: $project_dir/out/CameraBridgeDemo.ipa"
echo "Built: $project_dir/out/CameraBridge.dylib"
