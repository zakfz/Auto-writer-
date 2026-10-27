#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="Auto Writer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/ModuleCache
xcrun swiftc -O -parse-as-library -module-cache-path build/ModuleCache \
  Sources/WriterCore.swift Sources/SynonymEngine.swift Sources/AutoWriter.swift \
  -o "$APP/Contents/MacOS/AutoWriter" \
  -framework AppKit -framework SwiftUI -framework ApplicationServices -framework Carbon
cp Resources/Info.plist "$APP/Contents/Info.plist"
xcrun swiftc -module-cache-path build/ModuleCache Tools/MakeIcon.swift -o build/make-icon
build/make-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.filipzak.autowriter "$APP"
printf 'Built: %s/Auto Writer.app\n' "$PWD"
