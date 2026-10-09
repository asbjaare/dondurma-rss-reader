# Credential and workflow security review

Reviewed 2026-10-09. This is a targeted source review, not proof that every app,
dependency, action, or earlier workflow run is safe. Live GitHub settings, logs,
and dependency advisory queries could not be verified from the local sandbox.

## Findings addressed

| Finding | Exposure before patch | Change |
| --- | --- | --- |
| Signing credentials available during builds | Gradle, Flutter tests, dependencies, and actions ran on the same runner as the restored signing key; passwords were job-wide environment variables. | Build an unsigned APK without secrets, sign it on a fresh runner without source checkout, and expose signing secrets only to the signing step. |
| Repository write access during builds | The whole build job had `contents: write`, with checkout credentials persisted by default. | Only the separate publishing job has write access. Build checkout uses `persist-credentials: false`. Signing has no GitHub token permissions. |
| Actions selected by mutable tags | A changed `@v2` or `@v4` tag could change executed code without a commit in this fork. | Pin every action in the personal workflow to a full commit SHA. Disable the Flutter composite action's mutable internal cache actions. Add Dependabot updates for review. |
| Local token inherited by signing helper | The publishing script exported the personal GitHub token before executing a repository helper. | Execute the helper before obtaining the token, strip inherited GitHub token variables, and pass the selected token only to `gh` calls and the Git push. |
| Unneeded inherited store automation | The original workflow ran on fork pushes and had mutable action references and store secret inputs. | Restrict all its jobs to the upstream repository. Personal publication remains manual and restricted to this fork's `main`. |

No credential-stealing code was identified in the inspected workflow, Fastlane,
publishing, browser, or network paths. No signing files are tracked by Git. The
personal local keystore and credential file have mode `0600` and are ignored.
This review does not establish that secrets were never exposed in an earlier run.

## What a malicious workflow could access

A GitHub-hosted runner does not automatically have your Mac's Keychain, work
account credentials, or local GitHub CLI token. The publishing script uploads
only the personal Android keystore, its passwords, and alias. Actions receive a
short-lived GitHub token with the permissions declared for their job, and any
secrets explicitly passed to them. This workflow never uploads your personal
GitHub access token.

Repository secrets can be referenced by other workflows in this repository;
the `PERSONAL_` prefix is a naming convention, not an access boundary. A malicious
workflow edit could request and exfiltrate them. Secret masking in logs does not
stop network exfiltration or transformations of secret values. Do not add work,
Apple, Play, cloud, or unrelated credentials to this fork.

For a separate approval barrier, migrate signing secrets to a protected GitHub
environment with required reviewers and a `main` deployment restriction. Update
the signing job and upload script to use that environment and remove repository
copies. Review the exact commit before approving a deployment. This migration
has not been performed; the current workflow still uses repository secrets.

## Remaining trust

- A pinned action can already contain harmful code. Pins prevent silent tag
  changes; they do not certify the pinned code. Review proposed updates.
- A clean signing runner still parses an untrusted APK with Android signing
  tools. Isolation reduces exposure but is not protection against every possible
  tool vulnerability.
- Signing a malicious app does not make its runtime behavior safe. Review source,
  dependencies, and Android permissions before installing it. The inspected
  browser uses JavaScript for news sites; no native JavaScript credential bridge
  or TLS verification bypass was found in the inspected Dart code.
- Local scripts run with your OS account's access. Do not run unreviewed upstream
  shell scripts or Gradle tasks on your Mac merely because CI has been hardened.
- Review upstream changes to `.github/`, `scripts/`, `android/`, `fastlane/`,
  `pubspec.yaml`, and lockfiles before merging. No full dependency CVE scan or
  installed-APK dynamic security test was completed.

References: [GitHub Actions security hardening](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions),
[GitHub Actions secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets),
and [Android APK signing](https://developer.android.com/tools/apksigner).
