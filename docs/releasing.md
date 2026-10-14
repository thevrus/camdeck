# Releasing Camdeck

```sh
make release VERSION=0.2.0
```

`scripts/release.sh` pushes `main`, tags `v0.2.0` and pushes the tag. `.github/workflows/release.yml` then:

1. runs the tests,
2. builds the app (`scripts/bundle.sh`),
3. signs it with Developer ID (only if the signing secrets exist),
4. zips it for Sparkle and wraps it in a dmg (`scripts/make-dmg.sh`),
5. signs, notarizes and staples the dmg (only if the notary secrets exist),
6. prints the dmg sha256 for the Homebrew cask,
7. signs the update with the Sparkle key and refreshes `appcast.xml`,
8. publishes the GitHub Release (`Camdeck-<version>.zip` and `Camdeck.dmg`), then the appcast.

Run the workflow from the Actions tab for a dry run: it does everything except publish.

## Developer ID signing and notarization

Optional. With none of the secrets below, the workflow logs `Unsigned build ... Skipping Developer ID signing and notarization` and ships the ad-hoc signed build exactly as before. Users then go through the "Open Anyway" steps in the README. Add the secrets and the next release is signed and notarized with no other change.

### One-time setup

You need a paid Apple Developer Program membership.

1. **Developer ID Application certificate.** Create it at developer.apple.com under Certificates (type "Developer ID Application"), or in Xcode under Settings > Accounts > Manage Certificates. In Keychain Access, export it together with its private key as a `.p12` and set a password.
2. **App Store Connect API key** for notarytool. In App Store Connect open Users and Access > Integrations > App Store Connect API, create a key (Developer access is enough) and download the `.p8` once. Note the Key ID and the Issuer ID.
3. **Repo secrets** (Settings > Secrets and variables > Actions):

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12` | the `.p12`, base64 encoded: `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | the password you set on export |
| `NOTARY_KEY_ID` | the 10 character Key ID |
| `NOTARY_ISSUER` | the Issuer ID (a UUID) |
| `NOTARY_KEY_P8` | the full text of the `.p8` file, including the BEGIN/END lines |

Behavior by what is set:

| Set | Result |
| --- | --- |
| nothing | ad-hoc signed, as before |
| the two `DEVELOPER_ID_*` | signed with Developer ID and hardened runtime, dmg signed, not notarized |
| all five | signed, notarized and stapled |

### What the script does

`scripts/sign-notarize.sh` has two modes, both driven by environment variables so it also works locally.

- `app` re-signs `build/Camdeck.app` with `--options runtime --timestamp`, inside-out and without `--deep`, as Sparkle's docs require: `Installer.xpc`, `Downloader.xpc` (with `--preserve-metadata=entitlements`, Sparkle 2.6 and later), `Autoupdate`, `Updater.app`, then `Sparkle.framework`, then the app with `scripts/Camdeck.entitlements`.
- `dmg` signs the dmg, runs `xcrun notarytool submit --wait` with the API key, prints Apple's log if the verdict is not `Accepted`, then staples and validates.

The entitlements file holds `com.apple.security.device.camera`, which hardened runtime needs before the app can use the camera, and `com.apple.security.device.usb`. `NSCameraUsageDescription` is already in the Info.plist written by `scripts/bundle.sh`.

To try it on your own Mac, with the certificate in your login keychain:

```sh
make app
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/sign-notarize.sh app
scripts/make-dmg.sh build/Camdeck.dmg
SIGN_IDENTITY="..." NOTARY_KEY_ID=... NOTARY_ISSUER=... NOTARY_KEY_P8="$(cat AuthKey_XXXX.p8)" scripts/sign-notarize.sh dmg
```

`make release-local` is the CI-is-down fallback and still ships an ad-hoc signed build.

### First signed release: check by hand

Install the signed dmg on a clean Mac (or a fresh user) and confirm that the camera prompt appears, the preview works, camera controls move the picture, and Check for Updates works. Hardened runtime is the first time the app runs under these restrictions.

```sh
spctl -a -vv /Applications/Camdeck.app      # source=Notarized Developer ID
xcrun stapler validate build/Camdeck.dmg
```

## Homebrew cask

The cask lives in a separate repository, the tap `thevrus/homebrew-tap`, so that `brew install --cask thevrus/tap/camdeck` works. `packaging/homebrew/camdeck.rb` is the source copy.

One-time: create the public repo `thevrus/homebrew-tap` and copy the file to `Casks/camdeck.rb`.

Each release:

1. Open the release workflow run. The step "Print dmg sha256 for the Homebrew cask" prints the `version` and `sha256` lines (also in the run summary). To compute it by hand: `curl -sL https://github.com/thevrus/camdeck/releases/download/v0.2.0/Camdeck.dmg | shasum -a 256`.
2. Put them in `packaging/homebrew/camdeck.rb`, copy it to `Casks/camdeck.rb` in the tap and push.
3. Check: `brew audit --cask --online thevrus/tap/camdeck` and `brew install --cask thevrus/tap/camdeck`.

The cask sets `auto_updates true` because Sparkle updates the app itself, so `brew upgrade` skips it unless run with `--greedy`. It needs macOS 26 (`depends_on macos: :tahoe`). `brew uninstall --zap` also removes `~/Library/Application Support/Camdeck`, the `app.camdeck` caches and preferences.

## Site

`site/index.html` is published (`site/icon.png` is a copy of `docs/icon.png`; refresh it if the icon changes) by `.github/workflows/pages.yml` on every push to `main` that touches `site/`. One-time: Settings > Pages > Source: GitHub Actions. The URL is `https://thevrus.github.io/camdeck/`. The download button links to `releases/latest/download/Camdeck.dmg`, so it needs no edit per release.
