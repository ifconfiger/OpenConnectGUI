# OpenConnect GUI

Native SwiftUI clients for macOS and iOS with OpenConnect built in. They support multiple connections, Cisco AnyConnect and the other OpenConnect protocols, saved usernames and passwords, remote or local DNS, automatic reconnection, and connection status and logs.

The interface is available in English and Simplified Chinese and follows the system language. English is the source language; translations live in `Resources/Localizable.xcstrings`, shared by the macOS app, the iOS app and the VPN extension. The privileged helper runs as root without the user's language settings, so it replies only in English and the app translates each reply against the same string catalog before showing it. Messages printed by the extension's C code are looked up with `CFBundleCopyLocalizedString`. When adding text, add the English original as a key to the string catalog.

The flat icon is drawn by `Tools/GenerateFlatLogo.swift`; run `swift Tools/GenerateFlatLogo.swift` from the project root to regenerate every macOS and iOS icon size.

## Installing and building

Requires an Apple silicon Mac (macOS 13+) and Xcode. OpenConnect is bundled, so neither Homebrew nor any other dependency is needed:

```sh
xcodegen generate
xcodebuild -project OpenConnectGUI.xcodeproj -scheme OpenConnectGUI -configuration Release -derivedDataPath build-signed build
```

`Vendor/OpenConnect/` holds a prebuilt OpenConnect 9.21 (statically linked against OpenSSL 3.5.9, arm64 only): the macOS command-line tool `macos/openconnect`, the iOS static library `OpenConnect.xcframework`, and `vpnc-script`. They depend only on the system's libxml2, zlib and iconv. `Scripts/build-openconnect.sh` rebuilds them from pinned, SHA-256-verified sources and needs only the Xcode command-line tools. Licenses are in `Vendor/OpenConnect/licenses/`.

Pushing a tag of the form `main-vX.Y.Z` triggers GitHub Actions (`.github/workflows/release.yml`), which signs the app with Developer ID, packages it as a dmg, has Apple notarize it and publishes it to Releases. The signing certificate and notarization API key come from the organization secrets `APPLE_SIGN_*` / `APPLE_NOTARY_*`.

### Automatic updates

The macOS app updates itself from GitHub Releases. Every 6 hours it asks the GitHub API for the latest release of `ifconfiger/OpenConnectGUI`, and you can also choose "Check for Updates…" from the menu bar or the app menu. When the release tag `main-vX.Y.Z` is newer than the running `CFBundleShortVersionString`, the app downloads the release's `.dmg` in the background and copies the app out of it. It then replaces itself and relaunches once no VPN is connected, no reconnect is pending and the main window is closed; otherwise the update is installed when the app quits.

- **Verification**: there is no separate update-signing key. Before installing, the downloaded app must have this app's bundle identifier and the release's version, and must pass a strict code-signature check (including nested code) against a Developer ID requirement for the same team as the running copy. A build without a team, such as one signed ad hoc, never installs updates.
- **Installation**: a detached shell script waits for the app to exit, swaps the bundles with rollback on failure, and reopens the app. If the app runs from a read-only or translocated location, it cannot replace itself; a manual check then opens the release page instead.
- **Releases**: the workflow must attach the notarized `.dmg`. `releases/latest` excludes prereleases.
- **Privileged helper**: an update replaces the helper binary inside the app bundle, but launchd keeps the old process running. On launch and before each helper call, the app compares its `CFBundleVersion` with the one the helper started from. If they differ, it asks the helper to exit once no OpenConnect session is running and no request is in flight; launchd starts the new binary on the next request. The service is not re-registered and needs no new approval. The 0.1.0 helper does not support this handshake; it keeps running until the next restart and stays compatible with the new app meanwhile.
- **0.1.0 has no updater**: upgrading from 0.1.0 requires installing the new dmg by hand once.

The macOS target signs with the project's Developer ID by default. To install and use the privileged helper, sign the app and the helper with a valid certificate from the same development team, then install the signed app in `/Applications`. On first launch, approve the background service in System Settings. For compile-only checks, append `CODE_SIGNING_ALLOWED=NO` to the build command.

During the build, `openconnect` is signed and placed in `Contents/MacOS/`, and `vpnc-script` in `Contents/Resources/`; the bundled OpenSSL verifies servers against the system certificates in `/etc/ssl/cert.pem`. The macOS app includes a privileged helper registered with `SMAppService`. After the first install, approve it in System Settings → General → Login Items & Extensions; connecting and disconnecting then go through a narrowly scoped XPC interface. The app and the helper must carry valid signatures from the same development team; builds made with `CODE_SIGNING_ALLOWED=NO` cannot register the service. VPN passwords are kept in the local keychain, handed to the helper over XPC when connecting, and passed to OpenConnect on standard input, so they never appear in command arguments or configuration files. Settings and logs are stored in `~/Library/Application Support/OpenConnectGUI/`, PID files in `/var/run/vpnc/`.

The Log tab shows the current connection attempt; the previous log is cleared whenever a new connection starts. Connection and save failures are reported in the window. After the main window is closed the app stays in the menu bar, from which you can reopen the window, connect, disconnect or quit.

Remote DNS uses the resolvers pushed by the VPN, configured by the bundled `vpnc-script`; local DNS mode keeps the existing macOS DNS while configuring VPN routes as usual. The Disconnect button waits for the OpenConnect process to exit; if the normal signals do not work, it kills the process and cleans up routes and DNS using the script environment saved at connect time. With automatic reconnection on, the app pauses the VPN when the network drops and waits for it to come back; OpenConnect retries short interruptions for up to 15 seconds. If the VPN process exits, the app tries to reconnect up to 3 times and tries again whenever the network comes back or changes; a running connection is refreshed after a network change. A manual disconnect never triggers a reconnect.

On a network change, the bundled wrapper script checks whether the VPN server still has a static host route to the old gateway and removes it before reconfiguring; such leftover routes are also cleaned up after disconnecting. Because OpenConnect runs its script only after the tunnel is up, a leftover route would first make `connect()` fail with `Can't assign requested address`, blocking the very connection that should clean it up. The helper therefore resolves the server address and prunes that route on its own before starting OpenConnect. DNS results need no change.

macOS connections are direct by default and ignore the system proxy; proxy addresses from older settings are not enabled automatically. OpenConnect builds its HTTPS tunnel through a proxy only when "Use HTTP Proxy" is explicitly turned on in the Account tab and an address such as `http://127.0.0.1:7897` is filled in. The proxy address carries no username or password.

When the server certificate is invalid (self-signed, expired or for the wrong host name), you can turn on "Ignore Certificate Errors (Insecure)" in the account. The macOS app then reads the server's current certificate before connecting and pins it with `--servercert`; the iOS app accepts the certificate directly. This gives up protection against man-in-the-middle attacks and is only advisable for self-signed certificates on internal networks.

When a connection fails, the helper turns the OpenConnect log into an actionable message for the interface. A rejected password needs this most: after the server's 401, OpenConnect adds "requested Basic authentication which is disabled by default", but that only reflects OpenConnect disabling HTTP Basic for every server at startup (`library.c` initializes `AUTH_DEFAULT_DISABLED`). It has nothing to do with what the server asked for, and ocserv's 401 response carries no `WWW-Authenticate` header. Taking it literally leads to chasing proxy or protocol problems, so the interface says directly that the server rejected the username or password.

The server must support username and password login for the chosen protocol. Gateways that require web SSO, client certificates or interactive two-factor authentication cannot be logged into from this interface yet.

## iPhone and iPad

`OpenConnectiOS` is the SwiftUI app for iPhone and iPad, and `OpenConnectPacketTunnel` is the system VPN extension. The extension statically links `OpenConnect.xcframework`, performs OpenConnect authentication and tunnelling in process, and moves packets through `NEPacketTunnelFlow`; server certificates are verified against the iOS system trust store.

- **No retyping passwords**: passwords are stored in the keychain access group `$(AppIdentifierPrefix)xyz.nows.openconnect.shared`, shared by the app and the extension. On start, the extension reads them and answers the login form (username, password, auth group) automatically.
- **Reconnecting**: turning on "Reconnect Automatically" enables system On Demand, so the system brings the tunnel back after it drops. Inside the extension, a network change reconnects immediately with the existing session; a network outage waits for the network to return; an expired or server-terminated session logs in again with the saved password, retrying with a 4–60 second backoff while the status shows "Reconnecting". A manual disconnect turns On Demand off.
- **Avoiding account lockout**: if the server rejects the saved password or asks for two-factor authentication, the extension stops and does not retry. Automatic reconnection will not try the same credentials again until you update the password in the app or connect manually.

The Log tab shows the extension log live, and the reason for disconnecting when a connection ends. Gateways that require web SSO, client certificates or two-factor authentication are not supported yet. Running on a device requires signing and a provisioning profile with the `packet-tunnel-provider` and keychain sharing entitlements (team SWKH4B9DH8, automatic signing). To compile for the simulator:

```sh
xcodegen generate
xcodebuild -project OpenConnectGUI.xcodeproj -scheme OpenConnectiOS -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios CODE_SIGNING_ALLOWED=NO build
```
