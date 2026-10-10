#!/bin/bash
# Publishes a GitHub release: builds dist/Theine-<version>.dmg from the committed code, tags v<version>, pushes
# main and the tag, then publishes the release with the DMG attached.
#   VERSION=1.1.0 NOTES=~/notes-1.1.0.md ./scripts/release.sh     (keep the notes file outside the repo)
# One fine-grained token of tihomirov-nick with Contents: Read and write on this repo serves both git and the release
# API. It is kept in the Keychain (account tihomirov-nick, service TOKEN_SERVICE, by default github-theine-token).
# git goes over HTTPS (https://github.com/tihomirov-nick/theine.git): the script gives this repository its own
# credential helper that hands the token out, because the global helper (gh auth git-credential) belongs to another
# account. gh's own login is not used either. Without such a token the script stops before the build.
# Safe to re-run: an existing tag on HEAD and an existing (draft) release are reused.
set -euo pipefail

VERSION="${VERSION:?set VERSION, e.g. VERSION=1.1.0}"
NOTES="${NOTES:?set NOTES to a Markdown file with the release notes}"
[ -f "$NOTES" ] || { echo "no notes file: $NOTES"; exit 1; }
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="tihomirov-nick/theine"
SERVICE="${TOKEN_SERVICE:-github-theine-token}"
TAG="v$VERSION"
DMG="dist/Theine-$VERSION.dmg"

# 1. The release must match committed code on main
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "switch to main first"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash changes first (untracked files count too)"; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
    echo "$TAG already points to another commit"; exit 1
fi

# 2. Token and git access, checked before anything is built
TOKEN="$(security find-generic-password -a tihomirov-nick -s "$SERVICE" -w 2>/dev/null)" || TOKEN=""
[ -n "$TOKEN" ] || { echo "no GitHub token in the Keychain (account tihomirov-nick, service $SERVICE)"; exit 1; }
gh_() { GH_TOKEN="$TOKEN" gh "$@"; }

# git over HTTPS with the same token. The empty helper entry drops the global helper (another account's); the second one
# prints the token for every request, read from the Keychain at that moment, so it is never written to disk.
export GIT_TERMINAL_PROMPT=0
URL="https://github.com/$REPO.git"
git remote get-url origin >/dev/null 2>&1 || git remote add origin "$URL"
[ "$(git remote get-url origin)" = "$URL" ] || { echo "origin is $(git remote get-url origin), this script expects $URL"; exit 1; }
git config --local --unset-all credential.helper || true
git config --local --add credential.helper ''
git config --local --add credential.helper '!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=$(security find-generic-password -a tihomirov-nick -s '"$SERVICE"' -w)"; }; f'
# A dry run proves that the token can push main. An empty repository has nothing for a release to point at, so main
# goes first there.
if [ -z "$(git ls-remote --heads origin)" ]; then
    git push origin main
else
    git push --dry-run origin main >/dev/null 2>&1 || {
        echo "git can't push main to $URL with the token from Keychain service $SERVICE (nothing was built)"
        echo "(it needs Contents: Read and write on this repo, and the remote main must not be ahead of this clone)"
        exit 1
    }
fi

# The draft release checks the token for the API
if ! gh_ release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh_ release create "$TAG" --repo "$REPO" --draft --title "Theine $VERSION" --notes-file "$NOTES" >/dev/null || {
        echo "the token from Keychain service $SERVICE can't create releases in $REPO"
        echo "(it needs Contents: Read and write on this repo; nothing was built or pushed)"
        exit 1
    }
fi

# 4. Build (build_app.sh regenerates Localizable.strings, which is tracked; make_dmg.sh signs with "tihomirov-nick")
VERSION="$VERSION" ./scripts/make_dmg.sh
[ -z "$(git status --porcelain)" ] || { echo "the build changed tracked files, commit them and run again:"; git status --short; exit 1; }

# The app in the DMG must be signed by the certificate "tihomirov-nick": installed copies update only to such a version.
CERT_SHA1="af82036140843a7d76497ea8e4cd23403c8aedc2"
MOUNT="$(mktemp -d /tmp/theine-release.XXXXXX)"
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null
REQUIREMENT="$(codesign -d -r- "$MOUNT/Theine.app" 2>&1 | tr '[:upper:]' '[:lower:]' || true)"
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
rmdir "$MOUNT" 2>/dev/null || true
case "$REQUIREMENT" in
    *"certificate leaf = h\"$CERT_SHA1\""*) echo "==> the app in the DMG is signed by tihomirov-nick" ;;
    *) echo "the app in $DMG is not signed by the certificate tihomirov-nick: installed copies would refuse it; nothing pushed"; exit 1 ;;
esac

# 5. Tag and push
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "Theine $VERSION"
git push origin main "$TAG"

# 6. Attach the DMG and publish
gh_ release upload "$TAG" "$DMG" --repo "$REPO" --clobber
gh_ release edit "$TAG" --repo "$REPO" --draft=false --title "Theine $VERSION" --notes-file "$NOTES"
echo "==> https://github.com/$REPO/releases/tag/$TAG"
