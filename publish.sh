#!/bin/bash
# Publish dsh-desktop-pet to GitHub (one-time setup).
# 1) Create a Personal Access Token (classic, scope: repo) at:
#    https://github.com/settings/tokens/new
# 2) Run this script and paste the token when prompted.
#    The token is stored ONLY in your macOS Keychain (via git credential).
set -e
cd "$(dirname "$0")"

USER="kouh1811"
REPO="dsh-desktop-pet"
URL="https://github.com/${USER}/${REPO}.git"

read -r -s -p "GitHub Personal Access Token (repo scope): " TOKEN
echo

# 1) Store credentials in macOS Keychain (never written to disk in plaintext)
printf 'protocol=https\nhost=github.com\nusername=%s\npassword=%s\n' "$USER" "$TOKEN" | git credential approve
echo "✔ Credentials stored in Keychain"

# 2) Create the public repo if it does not exist yet
if ! curl -fs -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/${USER}/${REPO}" >/dev/null 2>&1; then
  curl -fs -X POST -H "Authorization: Bearer $TOKEN" \
    -d '{"name":"'$REPO'","description":"Desktop pet for DeepSeek Harness: a floating companion showing live task status","homepage":"","public":true}' \
    "https://api.github.com/user/repos" >/dev/null
  echo "✔ Created public repo ${USER}/${REPO}"
else
  echo "✔ Repo ${USER}/${REPO} already exists"
fi

# 3) Push
git remote add origin "$URL" 2>/dev/null || git remote set-url origin "$URL"
git push -u origin main
echo "✔ Published: https://github.com/${USER}/${REPO}"
