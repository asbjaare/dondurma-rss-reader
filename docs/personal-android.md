# Personal Android development and APK releases

This fork has a separate manual workflow, **Personal Android APK**. It builds a
signed release APK and publishes it to this repository's GitHub Releases without
requiring Apple or Google Play credentials. Personal builds use
`io.github.asbjaare.dondurma`, so they can coexist with the store app.

## Set up this Mac

Run from your normal terminal, where downloads are available:

```bash
cd /Users/asbjaare/priv/dondurma-rss-reader
bash scripts/setup-dev.sh
```

The script installs the pinned Flutter 3.47.4 into `.tools/flutter`, uses your
existing Temurin 21 installation (or installs Homebrew OpenJDK 17), and installs
Android command-line tools through Homebrew. SDK packages and dependency caches
live in the ignored `.tools` directory. Review and accept Android SDK licenses
when prompted. Gradle may download additional SDK/NDK packages on the first build.

Setup creates a personal signing key, downloads locked dependencies, runs
analysis and tests, and builds a signed release APK at
`build/app/outputs/flutter-apk/app-release.apk`. Flutter Doctor may report missing
iOS or desktop tooling; those are not required for Android development.

## Make changes

Edit `lib/`, then use the wrapper so Flutter gets the local SDK, Java, personal
app ID, caches, and signing credentials:

```bash
bash scripts/flutter.sh devices
bash scripts/flutter.sh run
bash scripts/flutter.sh analyze
bash scripts/flutter.sh test
bash scripts/flutter.sh build apk --release --no-tree-shake-icons
```

For `run`, connect your Android phone with USB debugging enabled and approve its
connection, or start an Android emulator separately. Press `r` for hot reload.
You can also run `source .tools/env.sh` in your terminal to use Flutter directly;
source `.tools/signing.env` as well for release builds. Debug and release builds
have different signing certificates, so switching between them requires an
uninstall. Export feeds through OPML first if needed.

## Publish an APK to your GitHub

Commit your changes to `main`, then run:

```bash
bash scripts/publish-apk.sh
```

This verifies repository access through `gh`, uploads the four personal signing
secrets using stdin, pushes `main`, and triggers the manual APK workflow. Existing
signing credentials are reused. The workflow runs analysis and tests before
building, verifies the APK signature, and publishes a new `personal-*` release
with `dondurma-personal.apk` and its SHA-256 checksum. CI build numbers start at
1,000,001 to stay above the current local build number.

Follow progress at
[Actions](https://github.com/asbjaare/dondurma-rss-reader/actions/workflows/personal-apk.yml).
On your phone, open
[Releases](https://github.com/asbjaare/dondurma-rss-reader/releases), download the
APK, open it, and allow installation from your browser when Android asks.
Later personal releases signed with the same key install as updates and retain
your data. A local release APK with a lower version code cannot replace a newer
CI build unless you uninstall first or build locally with a higher
`--build-number`.

Back up `.tools/personal.jks` and `.tools/signing.env` privately. The same key is
needed for future updates. Do not commit either file. On another Mac, restore
both files and adjust `ANDROID_KEYSTORE_PATH` in `signing.env` before publishing;
otherwise a new key would replace the repository's personal signing secrets.

The original `v*` tags still trigger the upstream store-release workflow. Use
the personal workflow for GitHub APK releases. Its `personal-*` tags do not
match those store-release triggers.

References: [Flutter SDK archive](https://docs.flutter.dev/install/archive),
[Android command-line tools](https://developer.android.com/tools/releases/cmdline-tools),
and [manual GitHub workflows](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow).
