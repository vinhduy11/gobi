#!/bin/sh
# The release EdDSA key of the Sparkle updater, on the maintainer's machine. Run once, by hand.
#
#   scripts/sparkle-key.sh check     the key is in the login Keychain and is the one the app trusts (SUPublicEDKey in make-app.sh)
#   scripts/sparkle-key.sh secret    stores the private key as the SPARKLE_ED_PRIVATE_KEY secret of the repository (needs gh, logged in)
#   scripts/sparkle-key.sh backup F  writes the private key to the file F (mode 600); keep it offline, never in a repository
#
# The private key is the only proof that an update is Gobi's: lost, users install by hand once; leaked, anyone can ship an update.
set -eu
cd "$(dirname "$0")/.."
SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
gh release download -R sparkle-project/Sparkle "$SPARKLE_VERSION" -p "Sparkle-$SPARKLE_VERSION.tar.xz" -D "$TMP"
echo "$SPARKLE_SHA256  $TMP/Sparkle-$SPARKLE_VERSION.tar.xz" | shasum -a 256 -c - >/dev/null
mkdir "$TMP/sparkle" && tar -xf "$TMP/Sparkle-$SPARKLE_VERSION.tar.xz" -C "$TMP/sparkle"
KEYS="$TMP/sparkle/bin/generate_keys"
case "${1:-}" in
check)
    PUBLIC=$("$KEYS" -p 2>&1 | tail -1)
    TRUSTED=$(sed -n 's/.*SPARKLE_PUBLIC_KEY:-\([^}]*\)}.*/\1/p' ui/macos/scripts/make-app.sh)
    echo "Keychain key: $PUBLIC"
    echo "App trusts:   $TRUSTED"
    [ "$PUBLIC" = "$TRUSTED" ] && echo "match" || { echo "DIFFERENT: updates signed with the Keychain key would be refused" >&2; exit 1; }
    ;;
secret)
    (umask 077 && "$KEYS" -x "$TMP/key" >/dev/null)
    gh secret set SPARKLE_ED_PRIVATE_KEY < "$TMP/key"
    echo "SPARKLE_ED_PRIVATE_KEY is set"
    ;;
backup)
    [ -n "${2:-}" ] || { echo "usage: sparkle-key.sh backup FILE" >&2; exit 2; }
    (umask 077 && "$KEYS" -x "$2" >/dev/null)
    echo "written to $2: keep it offline and out of any repository"
    ;;
*) echo "usage: sparkle-key.sh check | secret | backup FILE" >&2; exit 2 ;;
esac
