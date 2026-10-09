#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
[[ "$(uname -s)" == Darwin ]] || { echo 'This setup script supports macOS.' >&2; exit 1; }
command -v brew >/dev/null
mkdir -p .tools
flutter_version=3.47.4
if [[ ! -d .tools/flutter ]]; then
  git clone --depth 1 --branch "$flutter_version" https://github.com/flutter/flutter.git .tools/flutter
fi
[[ "$(git -C .tools/flutter describe --tags --exact-match HEAD)" == "$flutter_version" ]] || {
  echo "Expected Flutter $flutter_version in .tools/flutter." >&2
  exit 1
}
java_home=${JAVA_HOME:-}
if [[ -z "$java_home" ]] || ! "$java_home/bin/java" -version 2>&1 | head -1 | grep -Eq 'version "(17|21)\.'; then
  java_home="$HOME/.local/share/mise/installs/java/temurin-21"
fi
if [[ ! -x "$java_home/bin/java" ]]; then
  brew install openjdk@17
  java_home="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
fi
if [[ ! -x "$(brew --prefix)/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager" ]]; then
  brew install --cask android-commandlinetools
fi
sdkmanager="$(brew --prefix)/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager"
export JAVA_HOME="$java_home"
export ANDROID_HOME="$root/.tools/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$root/.tools/flutter/bin:$ANDROID_HOME/platform-tools:$PATH"
export PUB_CACHE="$root/.tools/pub-cache"
export GRADLE_USER_HOME="$root/.tools/gradle"
export DONDURMA_APPLICATION_ID=io.github.asbjaare.dondurma
mkdir -p "$ANDROID_HOME"
umask 077
{
  printf 'export JAVA_HOME=%q\n' "$JAVA_HOME"
  printf 'export ANDROID_HOME=%q\n' "$ANDROID_HOME"
  printf 'export ANDROID_SDK_ROOT=%q\n' "$ANDROID_HOME"
  printf 'export PUB_CACHE=%q\n' "$PUB_CACHE"
  printf 'export GRADLE_USER_HOME=%q\n' "$GRADLE_USER_HOME"
  printf 'export DONDURMA_APPLICATION_ID=%q\n' "$DONDURMA_APPLICATION_ID"
  printf 'export PATH=%q:"$PATH"\n' "$JAVA_HOME/bin:$root/.tools/flutter/bin:$ANDROID_HOME/platform-tools"
} > .tools/env.sh
"$sdkmanager" --sdk_root="$ANDROID_HOME" --licenses
"$sdkmanager" --sdk_root="$ANDROID_HOME" 'cmdline-tools;latest' 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0'
flutter config --android-sdk "$ANDROID_HOME" --jdk-dir "$JAVA_HOME"
flutter precache --android
bash scripts/setup-signing.sh
source .tools/signing.env
flutter pub get --enforce-lockfile
flutter analyze
flutter test
# A large icon set includes dynamically selected icons.
flutter build apk --release --no-tree-shake-icons
flutter doctor -v
echo 'Ready. Run: bash scripts/flutter.sh run'
echo 'APK: build/app/outputs/flutter-apk/app-release.apk'
