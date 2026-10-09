#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
repo=asbjaare/dondurma-rss-reader
[[ "$(git branch --show-current)" == main ]] || { echo 'Switch to main before publishing.' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit your changes before publishing.' >&2; exit 1; }
git ls-files --error-unmatch .github/workflows/personal-apk.yml > /dev/null
gh api "repos/$repo" --jq .full_name
bash scripts/setup-signing.sh
source .tools/signing.env
# Feed credentials through stdin so they never appear in command arguments.
base64 < "$ANDROID_KEYSTORE_PATH" | tr -d '\n' | gh secret set PERSONAL_KEYSTORE_BASE64 --repo "$repo"
printf '%s' "$ANDROID_KEYSTORE_PASSWORD" | gh secret set PERSONAL_KEYSTORE_PASSWORD --repo "$repo"
printf '%s' "$ANDROID_KEY_PASSWORD" | gh secret set PERSONAL_KEY_PASSWORD --repo "$repo"
printf '%s' "$ANDROID_KEY_ALIAS" | gh secret set PERSONAL_KEY_ALIAS --repo "$repo"
git push origin main
gh workflow run personal-apk.yml --repo "$repo" --ref main
echo "Build started: https://github.com/$repo/actions/workflows/personal-apk.yml"
echo "APK will appear at: https://github.com/$repo/releases"
