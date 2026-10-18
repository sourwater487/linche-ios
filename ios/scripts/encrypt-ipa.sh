#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ipa="ios/build/LinChe-unsigned.ipa"
[[ -s "$ipa" ]] || { echo 'Missing IPA; build and validate it first.' >&2; exit 1; }
# Isolate GnuPG configuration from the user's existing keyring.
gpg_home="$(mktemp -d)"
chmod 700 "$gpg_home"
gpg --homedir "$gpg_home" --batch --no-tty --trust-model always \
  --cipher-algo AES256 --recipient-file build-recipient.asc \
  --output "$ipa.gpg" --encrypt "$ipa"
[[ -s "$ipa.gpg" ]]
