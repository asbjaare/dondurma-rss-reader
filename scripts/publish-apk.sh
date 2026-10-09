#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
repo=asbjaare/dondurma-rss-reader
account=asbjaare
[[ "$(git branch --show-current)" == main ]] || { echo 'Switch to main before publishing.' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit your changes before publishing.' >&2; exit 1; }
git ls-files --error-unmatch .github/workflows/personal-apk.yml > /dev/null
# Select the personal account explicitly without changing gh's global account.
# Keep the token out of command arguments and logs.
export GH_TOKEN
GH_TOKEN=$(gh auth token --hostname github.com --user "$account")
actual_account=$(gh api user --jq .login)
[[ "$actual_account" == "$account" ]] || {
  echo "Expected GitHub account $account, got $actual_account." >&2
  exit 1
}
default_branch=$(gh api "repos/$repo" --jq .default_branch)
[[ "$default_branch" == main ]] || {
  echo "The repository default branch is $default_branch. The workflow must be on the default branch before dispatch." >&2
  exit 1
}
# Forks can have Actions disabled even after a workflow has been pushed.
actions_enabled=$(gh api "repos/$repo/actions/permissions" --jq .enabled)
if [[ "$actions_enabled" != true ]]; then
  gh api --method PUT "repos/$repo/actions/permissions" -F enabled=true
fi
bash scripts/setup-signing.sh
source .tools/signing.env
# Feed credentials through stdin so they never appear in command arguments.
base64 < "$ANDROID_KEYSTORE_PATH" | tr -d '\n' | gh secret set PERSONAL_KEYSTORE_BASE64 --repo "$repo"
printf '%s' "$ANDROID_KEYSTORE_PASSWORD" | gh secret set PERSONAL_KEYSTORE_PASSWORD --repo "$repo"
printf '%s' "$ANDROID_KEY_PASSWORD" | gh secret set PERSONAL_KEY_PASSWORD --repo "$repo"
printf '%s' "$ANDROID_KEY_ALIAS" | gh secret set PERSONAL_KEY_ALIAS --repo "$repo"
# Bypass cached Keychain credentials and use the same personal token for Git.
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin main
# Verify that the file reached GitHub, then allow time for workflow registration.
gh api "repos/$repo/contents/.github/workflows/personal-apk.yml?ref=main" --jq .path
workflow_id=
for attempt in {1..15}; do
  if workflow_id=$(gh api "repos/$repo/actions/workflows/personal-apk.yml" --jq .id 2>/dev/null); then
    break
  fi
  echo "Waiting for GitHub to register the APK workflow ($attempt/15)..."
  sleep 2
done
if [[ -z "$workflow_id" ]]; then
  echo "GitHub has the workflow file but has not registered it. Open https://github.com/$repo/actions and enable workflows for this fork, then retry." >&2
  exit 1
fi
workflow_state=$(gh api "repos/$repo/actions/workflows/$workflow_id" --jq .state)
if [[ "$workflow_state" != active ]]; then
  gh api --method PUT "repos/$repo/actions/workflows/$workflow_id/enable"
fi
gh workflow run personal-apk.yml --repo "$repo" --ref main
echo "Build started: https://github.com/$repo/actions/workflows/personal-apk.yml"
echo "APK will appear at: https://github.com/$repo/releases"
