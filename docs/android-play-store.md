# Android release checklist

NeonAmp produces ARM-only APKs and an Android App Bundle. The APKs are for
direct installation; the App Bundle is the artifact to upload to Google Play.

## Signing

Create a dedicated upload keystore and keep it outside the repository. Configure
these GitHub Actions repository secrets before creating a version tag:

- `ANDROID_KEYSTORE_BASE64`: base64-encoded `.jks` file
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Tagged Android workflows fail if any of these values is absent. Branch and pull
request builds remain usable with the local debug fallback.

## Play Console setup

1. Create the application with the final package ID `com.neonamp.neonamp`.
2. Upload `app-release.aab` to an internal testing track first.
3. Register the upload certificate generated from the dedicated keystore.
4. Enable Play App Signing and retain the Play signing key separately from the
   upload key.
5. Configure Play Integrity for the package and signing certificate, then test
   the integrity verdicts on the internal track.
6. Add the store listing, privacy policy, data-safety form, content rating,
   screenshots, release notes, and a staged rollout percentage.

NeonAmp includes an optional standard Play Integrity client in
`lib/play_integrity.dart` and the `neonamp/play_integrity` Android channel.
Call `prepare` with the Google Cloud project number before requesting a token,
then bind each protected request with `PlayIntegrityClient.requestHash` and
send the opaque token to the protected backend. Tokens are intentionally not
decoded in NeonAmp; decryption keys and verdict policy must never be shipped
in the APK. Configure the cloud project number and backend endpoint when
enabling protected Play services or account flows.

The workflow also publishes one ARMv7 APK and one ARM64 APK for users who need
direct installation. Google Play should receive the App Bundle so it can handle
device-specific split delivery.

Tagged workflows fail if a release APK is debug-signed or contains x86/x86_64
native libraries. The Gradle configuration also restricts Android native
artifacts to `armeabi-v7a` and `arm64-v8a`, keeping direct APK downloads aligned
with the supported device set.
