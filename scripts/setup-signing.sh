#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [[ -f .tools/env.sh ]]; then
  source .tools/env.sh
fi
if [[ -n "${JAVA_HOME:-}" ]]; then
  export PATH="$JAVA_HOME/bin:$PATH"
fi
mkdir -p .tools
umask 077
if [[ -f .tools/signing.env ]]; then
  source .tools/signing.env
elif [[ -e .tools/personal.jks ]]; then
  echo 'Existing keystore has no signing.env. Restore its credentials; refusing to replace it.' >&2
  exit 1
else
  export ANDROID_KEYSTORE_PATH="$root/.tools/personal.jks"
  export ANDROID_KEY_ALIAS=personal
  export ANDROID_KEYSTORE_PASSWORD
  export ANDROID_KEY_PASSWORD
  ANDROID_KEYSTORE_PASSWORD=$(openssl rand -hex 32)
  ANDROID_KEY_PASSWORD=$ANDROID_KEYSTORE_PASSWORD
  keytool -genkeypair -keystore "$ANDROID_KEYSTORE_PATH" -storetype JKS \
    -alias "$ANDROID_KEY_ALIAS" -keyalg RSA -keysize 3072 -validity 10000 \
    -storepass:env ANDROID_KEYSTORE_PASSWORD -keypass:env ANDROID_KEY_PASSWORD \
    -dname 'CN=asbjaare personal Dondurma' -noprompt
  {
    printf 'export ANDROID_KEYSTORE_PATH=%q\n' "$ANDROID_KEYSTORE_PATH"
    printf 'export ANDROID_KEY_ALIAS=%q\n' "$ANDROID_KEY_ALIAS"
    printf 'export ANDROID_KEYSTORE_PASSWORD=%q\n' "$ANDROID_KEYSTORE_PASSWORD"
    printf 'export ANDROID_KEY_PASSWORD=%q\n' "$ANDROID_KEY_PASSWORD"
  } > .tools/signing.env
fi
keytool -list -keystore "$ANDROID_KEYSTORE_PATH" -alias "$ANDROID_KEY_ALIAS" \
  -storepass:env ANDROID_KEYSTORE_PASSWORD > /dev/null
echo 'Personal signing key ready. Back up .tools/personal.jks and .tools/signing.env privately.'
