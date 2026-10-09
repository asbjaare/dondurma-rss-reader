#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
repo=asbjaare/dondurma-rss-reader
account=asbjaare
[[ "$(git branch --show-current)" == main ]] || { echo 'Switch to main before publishing.' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit your changes before publishing.' >&2; exit 1; }
git ls-files --error-unmatch .github/workflows/personal-apk.yml > /dev/null
# Run the local signing helper before obtaining the personal GitHub token.
# Do not pass an inherited GitHub token to repository helper scripts either.
env -u GH_TOKEN -u GITHUB_TOKEN bash scripts/setup-signing.sh
source .tools/signing.env
# Select the personal account explicitly without changing gh's global account.
# Keep the token out of command arguments and logs.
personal_token=$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token --hostname github.com --user "$account")
gh_personal() { GH_TOKEN="$personal_token" gh "$@"; }
actual_account=$(gh_personal api user --jq .login)
[[ "$actual_account" == "$account" ]] || {
  echo "Expected GitHub account $account, got $actual_account." >&2
  exit 1
}
default_branch=$(gh_personal api "repos/$repo" --jq .default_branch)
[[ "$default_branch" == main ]] || {
  echo "The repository default branch is $default_branch. The workflow must be on the default branch before dispatch." >&2
  exit 1
}
# Forks can have Actions disabled even after a workflow has been pushed.
actions_enabled=$(gh_personal api "repos/$repo/actions/permissions" --jq .enabled)
if [[ "$actions_enabled" != true ]]; then
  gh_personal api --method PUT "repos/$repo/actions/permissions" -F enabled=true
fi
# Feed credentials through stdin so they never appear in command arguments.
base64 < "$ANDROID_KEYSTORE_PATH" | tr -d '\n' | gh_personal secret set PERSONAL_KEYSTORE_BASE64 --repo "$repo"
printf '%s' "$ANDROID_KEYSTORE_PASSWORD" | gh_personal secret set PERSONAL_KEYSTORE_PASSWORD --repo "$repo"
printf '%s' "$ANDROID_KEY_PASSWORD" | gh_personal secret set PERSONAL_KEY_PASSWORD --repo "$repo"
printf '%s' "$ANDROID_KEY_ALIAS" | gh_personal secret set PERSONAL_KEY_ALIAS --repo "$repo"
# Bypass cached Keychain credentials and use the same personal token for Git.
GH_TOKEN="$personal_token" git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin main
# Verify that the file reached GitHub, then allow time for workflow registration.
gh_personal api "repos/$repo/contents/.github/workflows/personal-apk.yml?ref=main" --jq .path
workflow_id=
for attempt in {1..15}; do
  if workflow_id=$(gh_personal api "repos/$repo/actions/workflows/personal-apk.yml" --jq .id 2>/dev/null); then
    break
  fi
  echo "Waiting for GitHub to register the APK workflow ($attempt/15)..."
  sleep 2
done
if [[ -z "$workflow_id" ]]; then
  echo "GitHub has the workflow file but has not registered it. Open https://github.com/$repo/actions and enable workflows for this fork, then retry." >&2
  exit 1
fi
workflow_state=$(gh_personal api "repos/$repo/actions/workflows/$workflow_id" --jq .state)
if [[ "$workflow_state" != active ]]; then
  gh_personal api --method PUT "repos/$repo/actions/workflows/$workflow_id/enable"
fi
gh_personal workflow run personal-apk.yml --repo "$repo" --ref main
echo "Build started: https://github.com/$repo/actions/workflows/personal-apk.yml"
echo "APK will appear at: https://github.com/$repo/releases"
