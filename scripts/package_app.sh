#!/bin/zsh
set -euo pipefail

# Produce the local signed Mac app without executing supplied Windows code.
project_root="${0:A:h:h}"
cd "$project_root"
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
  print -u2 "Usage: scripts/package_app.sh [release|debug]"
  exit 2
fi

# Pin the chosen local identity so a later update cannot silently switch back
# to an ad-hoc signature and invalidate the user's privacy grants.
signing_identity="${MACVIEWER_SIGNING_IDENTITY:-}"
identity_file="$project_root/dist/.macviewer-signing-identity"
if [[ -z "$signing_identity" && -f "$identity_file" ]]; then
  signing_identity="$(cat "$identity_file")"
fi
if [[ -z "$signing_identity" ]]; then
  development_identities=("${(@f)$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/{print $2}')}" )
  if (( ${#development_identities[@]} == 1 )) && [[ "${development_identities[1]}" =~ '^[A-Fa-f0-9]{40}$' ]]; then
    signing_identity="${development_identities[1]}"
  else
    signing_identity="-"
  fi
fi

# CI sets these; local builds keep the current development values.
app_version="${MACVIEWER_VERSION:-0.3.4}"
build_number="${MACVIEWER_BUILD_NUMBER:-5}"
ventura_release="${MACVIEWER_VENTURA_RELEASE:-0}"
build_flags=(--configuration "$configuration")
if [[ "${MACVIEWER_UNIVERSAL:-0}" == "1" ]]; then
  build_flags+=(--arch arm64 --arch x86_64)
fi

swift build "${build_flags[@]}" --product MacViewer
binary_directory="$(swift build "${build_flags[@]}" --show-bin-path)"
app_directory="$project_root/dist/MacViewer.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
# The S3 app icon ships prebuilt (5.0): scripts/MacViewer.icns is a
# byte-identical copy of the settled production set, with
# scripts/AppIcon.appiconset as its canonical PNG source.
# AppIconTests pins the two artifacts together.
cp "$project_root/scripts/MacViewer.icns" "$app_directory/Contents/Resources/MacViewer.icns"
for language in en vi; do
  mkdir -p "$app_directory/Contents/Resources/$language.lproj"
  cp "Sources/MacViewer/Resources/$language.lproj/Localizable.strings" "$app_directory/Contents/Resources/$language.lproj/Localizable.strings"
done
cp -R "$binary_directory/MacViewer_MacViewer.bundle" "$app_directory/Contents/Resources/"
mkdir -p "$app_directory/Contents/Resources/Licenses/Zstandard"
cp ThirdParty/zstd/LICENSE "$app_directory/Contents/Resources/Licenses/Zstandard/LICENSE"
cp ThirdParty/zstd/COPYING "$app_directory/Contents/Resources/Licenses/Zstandard/COPYING"
mkdir -p "$app_directory/Contents/Resources/Licenses/G722"
cp ThirdParty/g722/LICENSE "$app_directory/Contents/Resources/Licenses/G722/LICENSE"
cp ThirdParty/g722/WEBRTC_LICENSE "$app_directory/Contents/Resources/Licenses/G722/WEBRTC_LICENSE"
# Replace the executable atomically so an already-running development app keeps
# its original mapped inode while a newly launched process gets the new build.
cp "$binary_directory/MacViewer" "$app_directory/Contents/MacOS/MacViewer.new"
mv -f "$app_directory/Contents/MacOS/MacViewer.new" "$app_directory/Contents/MacOS/MacViewer"
# Embed every framework the executable links through @rpath (SwiftPM
# binary targets — WebRTC today). SwiftPM keeps such frameworks beside
# the build products, but the packaged bundle must carry its own copy:
# the 5.0 release shipped without Contents/Frameworks and dyld killed
# the app at launch ("Library not loaded: @rpath/WebRTC.framework/
# WebRTC", field report 2026-10-22). If a linked framework cannot be
# found among the build products, abort — never emit a bundle that is
# missing a framework its executable loads.
packaged_executable="$app_directory/Contents/MacOS/MacViewer"
frameworks_directory="$app_directory/Contents/Frameworks"
mkdir -p "$frameworks_directory"
linked_frameworks="$(otool -L "$binary_directory/MacViewer" | grep -o '@rpath/[^/]*\.framework/[^/ ]*' | sed -e 's|^@rpath/||' -e 's|\.framework/.*$||' | sort -u || true)"
if [[ -n "$linked_frameworks" ]]; then
  for framework_name in ${(f)linked_frameworks}; do
    framework_source=""
    for candidate_directory in "$binary_directory" "$binary_directory/PackageFrameworks"; do
      if [[ -d "$candidate_directory/$framework_name.framework" ]]; then
        framework_source="$candidate_directory/$framework_name.framework"
        break
      fi
    done
    if [[ -z "$framework_source" ]]; then
      framework_matches="$(find "$binary_directory" -type d -name "$framework_name.framework")"
      framework_source="${framework_matches%%$'\n'*}"
    fi
    if [[ -z "$framework_source" || ! -d "$framework_source" ]]; then
      print -u2 "package_app.sh: error: the built executable links @rpath/$framework_name.framework/$framework_name but no $framework_name.framework exists under the build products directory:"
      print -u2 "  products: $binary_directory"
      print -u2 "  searched: $binary_directory/$framework_name.framework"
      print -u2 "            $binary_directory/PackageFrameworks/$framework_name.framework"
      print -u2 "            and every directory named $framework_name.framework below the products directory."
      print -u2 "  Refusing to package an app bundle that dyld would kill at launch."
      exit 1
    fi
    print "Embedding $framework_name.framework from $framework_source"
    rm -rf "$frameworks_directory/$framework_name.framework"
    cp -R "$framework_source" "$frameworks_directory/$framework_name.framework"
  done
fi
# dyld resolves @rpath dependencies against the executable's run paths;
# the build records only /usr/lib/swift and @executable_path/../lib, so
# add the embedded-frameworks directory. This must happen before
# signing: editing load commands invalidates the code signature.
executable_load_commands="$(otool -l "$packaged_executable")"
if [[ "$executable_load_commands" != *'@executable_path/../Frameworks'* ]]; then
  print "Adding run path @executable_path/../Frameworks to the packaged executable"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$packaged_executable"
fi
cp Sources/UltraViewerProtocol/Resources/8bit.dat "$app_directory/Contents/Resources/8bit.dat"
cat > "$app_directory/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MacViewer</string>
  <key>CFBundleIdentifier</key><string>dev.macviewer.app</string>
  <key>CFBundleName</key><string>MacViewer Ventura</string>
  <key>CFBundleDisplayName</key><string>MacViewer Ventura</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>MacViewer.icns</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>vi</string></array>
  <key>CFBundleShortVersionString</key><string>$app_version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>MacViewerVenturaRelease</key><integer>$ventura_release</integer>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
# Sign the embedded frameworks explicitly, with the same identity as
# the app: the bundle signing below does not use --deep, so nested code
# would otherwise keep whatever signature it arrived with (or none) and
# fail the --deep verification that follows.
for embedded_framework in "$frameworks_directory"/*.framework(N); do
  codesign --force --deep --sign "$signing_identity" --timestamp=none "$embedded_framework"
done
codesign --force --sign "$signing_identity" --timestamp=none "$app_directory"
codesign --verify --deep --strict "$app_directory"
# Release gate, added after the 5.0 launch crash: every framework the
# packaged executable loads through @rpath must physically exist inside
# the bundle. Unit tests cannot catch a missing embedded framework —
# SwiftPM keeps the framework beside the test products — so the packaged
# app proves itself here, generically, for any current or future binary
# dependency.
packaged_dependencies="$(otool -L "$packaged_executable")"
checked_frameworks=""
verified_framework_count=0
packaging_check_failed=0
while IFS= read -r dependency_line; do
  dependency_path="${dependency_line#"${dependency_line%%[![:space:]]*}"}"
  dependency_path="${dependency_path%% *}"
  [[ "$dependency_path" == @rpath/*.framework/* ]] || continue
  dependency_framework="${dependency_path#@rpath/}"
  dependency_framework="${dependency_framework%%.framework/*}"
  case " $checked_frameworks " in
    *" $dependency_framework "*) continue ;;
  esac
  checked_frameworks="$checked_frameworks $dependency_framework"
  expected_framework_binary="$frameworks_directory/$dependency_framework.framework/$dependency_framework"
  if [[ -f "$expected_framework_binary" ]]; then
    verified_framework_count=$(( verified_framework_count + 1 ))
  else
    print -u2 "package_app.sh: error: packaged executable loads $dependency_path but the bundle lacks $expected_framework_binary"
    packaging_check_failed=1
  fi
done <<< "$packaged_dependencies"
if (( packaging_check_failed )); then
  print -u2 "package_app.sh: error: refusing to emit an app bundle with unresolved @rpath framework dependencies (see above)."
  exit 1
fi
print "Packaging check passed: $verified_framework_count embedded framework(s) cover every @rpath framework dependency of the packaged executable."
# Updating nested resources leaves the bundle directory's timestamp unchanged.
# Finder/Launch Services can then retain the first build's generic app icon.
# Refresh the package metadata after signing; timestamps are not signed content.
touch "$app_directory/Contents" "$app_directory"
registration_tool="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ "${CI:-}" != "true" && -x "$registration_tool" ]]; then
  "$registration_tool" -f "$app_directory"
fi
print -r -- "$signing_identity" > "$identity_file"
print "App ready: $app_directory"
