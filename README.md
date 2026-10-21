# Almasar Hawalat - build pipeline proof

STATUS: written only. Never run. The first run on GitHub is the test.

## What happens
Every push to the main branch starts the "build" workflow (Actions tab):
tests, then an Android APK, then a Release page with a download link.

## What you do
- Green run: open the "Releases" page of this repository, download the APK on an
  Android phone, allow "install unknown apps", and install it.
- Red run: open the failed step and send the error text as is.

## Warning
This is a DEBUG build signed with a temporary key. Every build has a different
signature, so a new build cannot be installed over the old one without
uninstalling it first (which erases the app data). Do not keep real data in it.
A permanent signing key must be set up before real use.
