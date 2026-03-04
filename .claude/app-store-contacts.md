# App Store Submission Details

## Contact Info (Apple App Review)
- **Name:** Mr. Sane (or set `APPSTORE_CONTACT_NAME`)
- **Phone:** Set `APPSTORE_CONTACT_PHONE` locally (do not commit real numbers)
- **Email:** Set `APPSTORE_CONTACT_EMAIL` locally (defaults to hi@saneapps.com if omitted)

## Mac App Store Screenshot Requirements
- Must be exact dimensions: 2880x1800, 2560x1600, 1440x900, or 1280x800
- 16:10 aspect ratio required
- Raw window captures WILL FAIL with IMAGE_BAD_ASPECT_RATIO
- Must composite app window onto a properly-sized canvas

## Known Issues (Feb 2026)
- SaneSales iOS had placeholder contact metadata — resolved via local secure contact env vars
- SaneSales macOS was stuck at PREPARE_FOR_SUBMISSION — screenshots wrong size, build not attached
- SaneClip macOS was REJECTED (needs investigation)
- Keep real contact details out of git-tracked files; provide them through local secrets/env
