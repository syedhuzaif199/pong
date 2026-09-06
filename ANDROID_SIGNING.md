# Android release signing

Local development continues to use the debug APK produced by `build-android.bat` / `build-android.sh`.

For a real GitHub release, configure these repository secrets:

- `ANDROID_KEYSTORE_BASE64` — base64 of the `.jks`/`.keystore` file
- `ANDROID_STORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

The release workflow decodes the keystore into the runner's temporary directory and exposes it to Gradle only for that job. When all four secrets are present, CI builds:

- `pong-android-arm64-vX.Y.Z.apk` — release-signed APK
- `pong-android-arm64-vX.Y.Z.aab` — release-signed Android App Bundle

If any signing secret is absent, CI still validates Android and publishes `pong-android-arm64-vX.Y.Z-debug.apk`, clearly marked as debug-signed.

Never commit the keystore or passwords to this repository.
