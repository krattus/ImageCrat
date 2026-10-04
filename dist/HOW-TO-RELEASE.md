# Releasing a signed, notarized ImageCrat

## One-time setup (about 10 minutes)

### 1. Developer ID certificate
1. Open **Xcode ▸ Settings… ▸ Accounts**.
2. If your Apple ID isn't listed, click **+** and add it.
3. Select your team and click **Manage Certificates…**.
4. Click **+** and choose **Developer ID Application**.

Only the team's **Account Holder** can create this certificate. If it's greyed out, sign in with the account holder's Apple ID.

To check it worked, run this in Terminal:
```bash
security find-identity -v -p codesigning
```
You should see a line like `"Developer ID Application: Your Name (ABCDE12345)"`.

### 2. Notarization credentials
1. Create an **app-specific password**: account.apple.com ▸ **Sign-In and Security ▸ App-Specific Passwords**. Name it, for example, "ImageCrat notary".
2. Find your **Team ID**: developer.apple.com/account ▸ **Membership details**. It's the 10-character code.
3. Save the credentials in your keychain. Type this yourself in Terminal; it asks for the app-specific password:
   ```bash
   xcrun notarytool store-credentials imagecrat-notary --apple-id YOUR_APPLE_ID_EMAIL --team-id YOUR_TEAM_ID
   ```

The password stays in your keychain. It's never written into the project, and Claude never sees it.

## Each release
```bash
scripts/release.sh
```
This builds ImageCrat (`build/ImageCrat.app`, bundle ID `app.imagecrat.editor`), signs it with your Developer ID (hardened runtime), sends it to Apple for notarization (usually a few minutes), staples the result, and creates:
- `dist/ImageCrat-<version>-<build>.dmg` (volume name “ImageCrat <version>”): send this to testers. It contains the app, a shortcut to Applications, **Read Me First** and the **Testing Checklist**.
- `dist/ImageCrat-<version>-<build>.zip`: the same app as a zip.

Options:
- `scripts/release.sh --no-notarize`: sign only, to test signing before notarization is set up.
- `scripts/release.sh --skip-build`: re-sign and re-package the existing `build/ImageCrat.app`.
- `IMAGECRAT_VERSION=1.1 scripts/release.sh`: set the version number. The build number is the date and time.
- `IMAGECRAT_SIGN_ID="Developer ID Application: …"` and `IMAGECRAT_NOTARY_PROFILE=…` pick a certificate or notary profile. The older `LUMEN_*` names still work.

If notarization fails, Apple's log is saved as `dist/notary-log.json`.
