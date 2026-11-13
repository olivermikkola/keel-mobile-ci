# Build a signed iPhone archive before uploading

Run the manual `ios-signed-artifact` workflow to produce a signed IPA and a
small verification report in Codemagic artifacts. This workflow has no App
Store Connect integration or publishing section. It uses only matching signing
files already uploaded to the Codemagic account/team; it has no certificate,
key, profile or app-record creation commands.

The workflow needs an uploaded App Store distribution provisioning profile for
`com.olivermikkola.keelmobile` and its matching signing certificate/private key.
The presence of a profile alone does not prove that the private key is
available. Missing signing files must be configured separately; the build
does not create replacement credentials automatically.

After Xcode exports the IPA, `verify-signed-ipa.py` checks:

- The exact bundle ID and an arm64 iPhoneOS executable.
- The bundled privacy manifest matches the source resource.
- The application and embedded code signatures, rejecting ad-hoc signing.
- An unexpired App Store distribution profile with matching application/team
  entitlements and debugging disabled.

The report includes the exact source commit, version/build, profile expiration,
architectures and IPA SHA-256. It contains no private keys or credentials.
Inspect the report and native build output before choosing an upload.

An App Store IPA cannot be installed directly on an iPhone. TestFlight requires
a separate upload and Apple processing. Signed packaging does not prove Metal
performance, model memory headroom, offline behavior or physical-device UI.

## Upload is a separate workflow

`ios-testflight` uploads to App Store Connect using `keel-mobile-apple`. Its
`submit_to_testflight: false` and `submit_to_app_store: false` settings do not
turn it into a build-only workflow. Run it only when you intend to upload that
build; do not use it merely to check whether signing files exist.

No build starts automatically. The normal simulator and unsigned iPhone
workflows remain available without signing identities.

References: [Codemagic uploaded signing files](https://docs.codemagic.io/yaml-code-signing/signing-ios/#referencing-certificates-and-profiles-in-codemagicyaml)
and [App Store Connect publishing](https://docs.codemagic.io/yaml-publishing/app-store-connect/).
