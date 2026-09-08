#!/usr/bin/env bash
#
# Baut den macOS-Client lokal — dieselben Schritte wie der CI-Job
# .github/workflows/lux-macos.yml, nur auf diesem Rechner.
#
# Der Sinn gegenüber CI: Zertifikat und Notarisierungsschlüssel bleiben im
# Schlüsselbund und wandern nicht als Secret zu GitHub.
#
#   ./.github/lux/build-local.sh                    signiert, wenn eine
#                                                   Developer-ID gefunden wird
#   ./.github/lux/build-local.sh --no-sign          unsigniertes DMG
#   ./.github/lux/build-local.sh --notarize <profil>  zusätzlich notarisieren
#   ./.github/lux/build-local.sh --skip-deps        Werkzeuge nicht neu prüfen
#
# Alles Heruntergeladene liegt in .lux-build/ im Repo (Flutter-SDK, vcpkg) und
# kann danach gelöscht werden. Die Systeminstallation von Flutter wird nicht
# angefasst — der CI-Job patcht das SDK, und das soll dir hier nicht passieren.
#
# Änderungen am Arbeitsverzeichnis (Serverkonfiguration, Deployment-Target,
# pubspec) werden am Ende automatisch zurückgenommen.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BUILD_HOME="$ROOT/.lux-build"
FLUTTER_VERSION="3.24.5"
MAC_RUST_VERSION="1.81"
FLUTTER_RUST_BRIDGE_VERSION="1.80.1"
CARGO_EXPAND_VERSION="1.0.95"
VCPKG_COMMIT_ID="120deac3062162151622ca4860575a33844ba10b"
VERSION="1.4.9"

export LUX_RENDEZVOUS_SERVER="${LUX_RENDEZVOUS_SERVER:-rd.lux.io}"
export LUX_RS_PUB_KEY="${LUX_RS_PUB_KEY:-IizurzL8I8eHrbgyIcEdyYvSvXwLwbsut4y9l12+sWQ=}"

WILL_SIGN=auto
NOTARIZE_PROFILE=""
SKIP_DEPS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-sign)   WILL_SIGN=no; shift ;;
    --notarize)  NOTARIZE_PROFILE="${2:?--notarize braucht den Namen eines notarytool-Profils}"; shift 2 ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    -h|--help)   sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

phase() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()   { printf '\033[31mFehler:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Voraussetzungen ---------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "läuft nur auf macOS"
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools fehlen: xcode-select --install"

case "$(uname -m)" in
  arm64)  TARGET=aarch64-apple-darwin; ARCH=aarch64; EXTRA_BUILD_ARGS="--screencapturekit" ;;
  x86_64) TARGET=x86_64-apple-darwin;  ARCH=x86_64;  EXTRA_BUILD_ARGS="" ;;
  *) die "unbekannte Architektur $(uname -m)" ;;
esac
echo "Ziel: $TARGET"

# Der Build ändert verfolgte Dateien. Nur mit sauberem Stand starten, sonst
# lässt sich am Ende nicht sagen, was zurückzunehmen ist.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  die "Arbeitsverzeichnis ist nicht sauber — bitte committen oder stashen"
fi

PATCHED_FILES=()
restore() {
  local rc=$?
  if [ ${#PATCHED_FILES[@]} -gt 0 ]; then
    printf '\nBaupatches zurücknehmen ...\n'
    git checkout -- "${PATCHED_FILES[@]}" 2>/dev/null || true
    git -C libs/hbb_common checkout -- src/config.rs 2>/dev/null || true
  fi
  exit $rc
}
trap restore EXIT

mkdir -p "$BUILD_HOME"
# Verzeichnis ignoriert sich selbst, damit die .gitignore des Upstream unberührt bleibt.
printf '*\n' > "$BUILD_HOME/.gitignore"

if [ "$SKIP_DEPS" -eq 0 ]; then
  phase "Werkzeuge"

  command -v brew >/dev/null 2>&1 || die "Homebrew fehlt: https://brew.sh"
  for f in llvm create-dmg pkg-config; do
    brew list --formula "$f" >/dev/null 2>&1 || brew install "$f"
  done

  # NASM nur für Intel: dort baut vcpkg x86-Assembler in aom und ffmpeg.
  # Absichtlich nicht `brew install nasm` — das liefert NASM 3.x, dessen CLI
  # inkompatibel ist und an dem aom scheitert.
  if [ "$ARCH" = "x86_64" ] && ! "$BUILD_HOME/bin/nasm" -v >/dev/null 2>&1; then
    mkdir -p "$BUILD_HOME/bin"
    ( cd "$BUILD_HOME" \
      && curl -fsSLO https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/macosx/nasm-2.16.03-macosx.zip \
      && unzip -oq nasm-2.16.03-macosx.zip \
      && cp nasm-2.16.03/nasm bin/nasm )
  fi
  [ -d "$BUILD_HOME/bin" ] && export PATH="$BUILD_HOME/bin:$PATH"

  command -v rustup >/dev/null 2>&1 || die "rustup fehlt: https://rustup.rs"
  rustup toolchain install "$MAC_RUST_VERSION" --component rustfmt --profile minimal
  rustup target add --toolchain "$MAC_RUST_VERSION" "$TARGET"
fi

export RUSTUP_TOOLCHAIN="$MAC_RUST_VERSION"
[ -d "$BUILD_HOME/bin" ] && export PATH="$BUILD_HOME/bin:$PATH"

# --- Eigenes Flutter-SDK -----------------------------------------------------

phase "Flutter $FLUTTER_VERSION"
FLUTTER_HOME="$BUILD_HOME/flutter"
if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  case "$ARCH" in
    aarch64) ZIP="flutter_macos_arm64_${FLUTTER_VERSION}-stable.zip" ;;
    x86_64)  ZIP="flutter_macos_${FLUTTER_VERSION}-stable.zip" ;;
  esac
  echo "lade $ZIP (rund 1,5 GB, passiert nur einmal)"
  curl -fL --progress-bar -o "$BUILD_HOME/$ZIP" \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/$ZIP"
  ( cd "$BUILD_HOME" && rm -rf flutter && unzip -q "$ZIP" && rm -f "$ZIP" )

  # Dieselben zwei Eingriffe wie im CI-Job — hier an unserer eigenen Kopie.
  git -C "$FLUTTER_HOME" apply "$ROOT/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
  # https://github.com/flutter/flutter/issues/133533
  sed -i '' -e 's|_setFramesEnabledState(false);|//_setFramesEnabledState(false);|g' \
    "$FLUTTER_HOME/packages/flutter/lib/src/scheduler/binding.dart"
fi
export PATH="$FLUTTER_HOME/bin:$PATH"
flutter --version | head -1

# --- flutter_rust_bridge -----------------------------------------------------

phase "Bridge erzeugen"
if [ ! -x "$HOME/.cargo/bin/flutter_rust_bridge_codegen" ]; then
  cargo install cargo-expand --version "$CARGO_EXPAND_VERSION" --locked
  cargo install flutter_rust_bridge_codegen --version "$FLUTTER_RUST_BRIDGE_VERSION" --features "uuid" --locked
fi

# extended_text 14 verlangt ein neueres Dart, als Flutter 3.24.5 mitbringt.
sed -i '' -e 's/extended_text: 14.0.0/extended_text: 13.0.0/g' flutter/pubspec.yaml
PATCHED_FILES+=(flutter/pubspec.yaml)
( cd flutter && flutter pub get )

"$HOME/.cargo/bin/flutter_rust_bridge_codegen" \
  --rust-input ./src/flutter_ffi.rs \
  --dart-output ./flutter/lib/generated_bridge.dart \
  --c-output ./flutter/macos/Runner/bridge_generated.h
cp ./flutter/macos/Runner/bridge_generated.h ./flutter/ios/Runner/bridge_generated.h

# --- Serverkonfiguration einbacken -------------------------------------------

phase "Serverkonfiguration einbacken"
python3 .github/lux/patch-server-config.py

# --- vcpkg -------------------------------------------------------------------

phase "vcpkg-Abhängigkeiten"
export VCPKG_ROOT="$BUILD_HOME/vcpkg"
if [ ! -d "$VCPKG_ROOT/.git" ]; then
  git clone -q https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT"
fi
git -C "$VCPKG_ROOT" fetch -q --depth 1 origin "$VCPKG_COMMIT_ID"
git -C "$VCPKG_ROOT" checkout -q "$VCPKG_COMMIT_ID"
[ -x "$VCPKG_ROOT/vcpkg" ] || "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
"$VCPKG_ROOT/vcpkg" install --x-install-root="$VCPKG_ROOT/installed"

# --- Bauen -------------------------------------------------------------------

phase "RustDesk bauen"
if [ "$TARGET" = "aarch64-apple-darwin" ]; then
  MIN_MACOS_VERSION="12.3"
  sed -i '' -e "s/MACOSX_DEPLOYMENT_TARGET=[0-9]*\.[0-9]*/MACOSX_DEPLOYMENT_TARGET=${MIN_MACOS_VERSION}/" build.py
  sed -i '' -e "s/platform :osx, '.*'/platform :osx, '${MIN_MACOS_VERSION}'/" flutter/macos/Podfile
  sed -i '' -e "s/osx_minimum_system_version = \"[0-9]*\.[0-9]*\"/osx_minimum_system_version = \"${MIN_MACOS_VERSION}\"/" Cargo.toml
  sed -i '' -e "s/MACOSX_DEPLOYMENT_TARGET = [0-9]*\.[0-9]*;/MACOSX_DEPLOYMENT_TARGET = ${MIN_MACOS_VERSION};/" flutter/macos/Runner.xcodeproj/project.pbxproj
  PATCHED_FILES+=(build.py flutter/macos/Podfile Cargo.toml flutter/macos/Runner.xcodeproj/project.pbxproj)
fi

python3 ./build.py --flutter --hwcodec --unix-file-copy-paste $EXTRA_BUILD_ARGS

APP="./flutter/build/macos/Build/Products/Release/RustDesk.app"
[ -d "$APP" ] || die "$APP wurde nicht erzeugt"

# --- Signieren ---------------------------------------------------------------

IDENTITY=""
if [ "$WILL_SIGN" != "no" ]; then
  IDENTITY="$(security find-identity -v -p codesigning \
              | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  if [ -z "$IDENTITY" ]; then
    echo "Keine Developer-ID im Schlüsselbund gefunden — es wird unsigniert gebaut."
  fi
fi

DMG="rustdesk-lux-${VERSION}-${ARCH}.dmg"
rm -f "$DMG"

# create-dmg braucht auf langsamen Platten mehr Aushängeversuche.
CREATE_DMG="$(readlink -f "$(command -v create-dmg)" 2>/dev/null || command -v create-dmg)"
grep -q 'MAXIMUM_UNMOUNTING_ATTEMPTS=3' "$CREATE_DMG" 2>/dev/null \
  && sed -i '' -e 's/MAXIMUM_UNMOUNTING_ATTEMPTS=3/MAXIMUM_UNMOUNTING_ATTEMPTS=7/' "$CREATE_DMG" || true

if [ -n "$IDENTITY" ]; then
  phase "Signieren mit: $IDENTITY"
  codesign --force --options runtime -s "$IDENTITY" --deep --strict "$APP" -vvv
fi

phase "DMG bauen"
create-dmg --icon "RustDesk.app" 200 190 --hide-extension "RustDesk.app" \
  --window-size 800 400 --app-drop-link 600 185 "$DMG" "$APP"

if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime -s "$IDENTITY" --deep --strict "$DMG" -vvv

  if [ -n "$NOTARIZE_PROFILE" ]; then
    phase "Notarisieren"
    # Profil vorher einmalig anlegen:
    #   xcrun notarytool store-credentials <profil> --apple-id <mail> \
    #     --team-id <team> --password <app-spezifisches-passwort>
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARIZE_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
  fi
fi

# --- Gegenprobe --------------------------------------------------------------

phase "Gegenprobe"
DYLIB="$APP/Contents/Frameworks/liblibrustdesk.dylib"
if strings -a "$DYLIB" | grep -qF "$LUX_RENDEZVOUS_SERVER"; then
  echo "  Serveradresse $LUX_RENDEZVOUS_SERVER steckt im Binary"
else
  die "Serveradresse NICHT im Binary — der Patch hat nicht gegriffen"
fi
if strings -a "$DYLIB" | grep -qF "rs-ny.rustdesk.com"; then
  die "Upstream-Server noch im Binary"
fi
echo "  Upstream-Server ist raus"

if [ -n "$IDENTITY" ]; then
  codesign -dv --verbose=2 "$APP" 2>&1 | sed -n '1,6p'
  spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | head -2 || true
else
  echo "  unsigniert — beim Öffnen Rechtsklick → Öffnen"
fi

printf '\n\033[1mFertig:\033[0m %s (%s)\n' "$DMG" "$(du -h "$DMG" | cut -f1)"
