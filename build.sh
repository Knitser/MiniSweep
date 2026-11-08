#!/bin/zsh
set -euo pipefail
project="${0:A:h}"
destination="${1:-$project/dist}"
build="$project/build"
app="$destination/MiniSweep.app"
release_version="${MINISWEEP_VERSION:-1.1.0}"
build_number="${MINISWEEP_BUILD_NUMBER:-3}"
signing_identity="${MINISWEEP_SIGNING_IDENTITY:-}"
if [[ ! "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' || ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "Use a numeric release version (for example, 1.0.1) and positive build number."
    exit 2
fi
if [[ -n "$signing_identity" && "$signing_identity" != 'Developer ID Application:'* ]]; then
    print -u2 "Release signing requires a Developer ID Application identity from Keychain."
    exit 2
fi
mkdir -p "$build/ModuleCache" "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun clang -O2 -mmacosx-version-min=14.0 -ffile-prefix-map="$project"=. -fdebug-prefix-map="$project"=. -c "$project/Sources/Engine.c" -o "$build/Engine.o"
xcrun swiftc -swift-version 5 -O -whole-module-optimization -target arm64-apple-macosx14.0 \
    -module-name MiniSweep -file-prefix-map "$project"=. -debug-prefix-map "$project"=. \
    -module-cache-path "$build/ModuleCache" -import-objc-header "$project/Sources/Engine.h" \
    "$project/Sources/Services.swift" "$project/Sources/App.swift" "$project/Sources/Details.swift" "$project/Sources/Tests.swift" \
    "$build/Engine.o" -framework SwiftUI -framework AppKit -o "$app/Contents/MacOS/MiniSweep"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MiniSweep</string>
<key>CFBundleIdentifier</key><string>local.minisweep.mac</string>
<key>CFBundleName</key><string>MiniSweep</string>
<key>CFBundleDisplayName</key><string>MiniSweep</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 knitser</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSDocumentsFolderUsageDescription</key><string>MiniSweep reads file names and sizes to show storage usage in folders you scan.</string>
<key>NSDownloadsFolderUsageDescription</key><string>MiniSweep shows large downloads for your review. Files move to Trash only after you confirm.</string>
<key>NSDesktopFolderUsageDescription</key><string>MiniSweep reads file names and sizes when you choose to scan Desktop.</string>
<key>NSRemovableVolumesUsageDescription</key><string>MiniSweep maps storage on volumes you choose.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $release_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
if [[ -f "$project/AppIcon.icns" ]]; then cp "$project/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"; fi
if [[ -n "$signing_identity" ]]; then
    codesign --force --sign "$signing_identity" --options runtime --timestamp "$app"
else
    codesign --force --sign - --options runtime --timestamp=none "$app"
fi
codesign --verify --deep --strict "$app"
print "Built $app"
