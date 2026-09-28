#!/bin/bash
# Deploys the Oneshot server to Fly.io and points the Mac app at it.
# Needs: fly CLI logged in, OPENAI_API_KEY in the environment.
set -euo pipefail
cd "$(dirname "$0")"
APP="${FLY_APP:-murmur-dictation}"
: "${OPENAI_API_KEY:?Set OPENAI_API_KEY}"

fly apps list --json | grep -q "\"$APP\"" || fly apps create "$APP" --org "${FLY_ORG:-personal}"
fly volumes list -a "$APP" --json | grep -q murmur_data || fly volumes create murmur_data -a "$APP" -r gru -s 1 -y
# Through stdin so the key never shows up in the process list.
printf 'OPENAI_API_KEY=%s\n' "$OPENAI_API_KEY" | fly secrets import -a "$APP" --stage
fly deploy -a "$APP" --ha=false --remote-only --wait-timeout 300

URL="https://$APP.fly.dev"
curl -fsS "$URL/health" && echo
echo "$URL" > ../.server-url
cd .. && ./build.sh --open
echo "Oneshot now uses $URL"
