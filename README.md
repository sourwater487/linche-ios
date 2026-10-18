# LinChe iOS client

UIKit / WebKit client for an authenticated personal web application.
Only native client sources and build tools are included. Web application sources,
backend services, deployment configuration, user data and private Git history
remain in the private main repository.

## Build

Requires macOS, Xcode 26.3 (iOS 26 SDK), and XcodeGen:

```sh
bash ios/scripts/build-ipa.sh
```

Output: `ios/build/LinChe-unsigned.ipa`. Sign it with SideStore on the owner's
device. No Apple credentials are used in CI. Keep the bundle identifier
`com.linche.privateapp` and signing account unchanged; install over the existing
app to preserve local state.

The manual-only workflow uses a standard `macos-15` runner. Pushes and pull
requests never trigger it. It compiles the device app, validates the IPA structure,
and uploads only an encrypted IPA retained for three days. No simulator tests
run. Device pairing, web/backend integration and appearance require separate
verification; complete integration tests remain in the private repository.

CI build numbers start at 1001, above the old repository's build numbers.
The first authorized cloud build must confirm runner/toolchain availability;
local Linux checks cannot compile UIKit code.

## Artifact privacy

`build-recipient.asc` is a public OpenPGP encryption key, not an Apple signing
certificate. Its private key stays outside this repository and is never sent to
Actions. After downloading and extracting the artifact ZIP, decrypt with:

```sh
gpg --homedir /path/to/private-keyring --output LinChe-unsigned.ipa --decrypt LinChe-unsigned.ipa.gpg
python3 ios/scripts/verify-ipa.py LinChe-unsigned.ipa
```

Keep a private backup of the keyring: losing it prevents decrypting existing
artifacts. Encryption protects uploaded builds, not public source code; anyone
can compile their own client. Server access still requires device pairing and
authorized sessions. Workflow logs are public.

## Maintenance

Maintain native sources in the private main repository and export only reviewed
native files and the required icon. Preserve this device-only project definition,
manual workflow, encrypted-only upload and stable bundle identifier. Review each
public diff. Never copy the entire private repository or its Git history.

The client includes the public hostnames `ios.lin-che.com` and `app.lin-che.com`,
client-side authentication protocol, native/web bridge and application branding.
It contains no pairing code, session token or server credential.
