#!/usr/bin/env bash
set -euo pipefail

# leafmill publish script — publishes markdown and gets a shareable URL.
# Dependencies: curl, jq

LEAFMILL_BASE_URL="https://leafmill.net"
ALLOW_CUSTOM_BASE=false

# --- helpers ----------------------------------------------------------------

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
emit() { echo "$1" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: publish.sh <markdown-file> [options]

Options:
  --title <text>                   Title (default: filename)
  --description <text>             Description
  --channel <slug>                 Assign to a channel (requires auth)
  --client <name>                  Agent attribution (e.g. cursor, claude-code)
  --api-key <key>                  API key override (prefer credentials file)
  --base-url <url>                 API base (default: https://leafmill.net)
  --allow-nonleafmill-base-url     Required when using --base-url
EOF
  exit 1
}

# --- dependency checks ------------------------------------------------------

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not installed"
done

# --- parse args -------------------------------------------------------------

MD_FILE=""
TITLE=""
DESCRIPTION=""
CHANNEL=""
CLIENT=""
API_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)       TITLE="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --channel)     CHANNEL="$2"; shift 2 ;;
    --client)      CLIENT="$2"; shift 2 ;;
    --api-key)     API_KEY="$2"; shift 2 ;;
    --base-url)    LEAFMILL_BASE_URL="$2"; shift 2 ;;
    --allow-nonleafmill-base-url) ALLOW_CUSTOM_BASE=true; shift ;;
    --help|-h)     usage ;;
    -*)            die "unknown option: $1" ;;
    *)
      [[ -z "$MD_FILE" ]] || die "unexpected argument: $1"
      MD_FILE="$1"; shift ;;
  esac
done

[[ -n "$MD_FILE" ]] || usage

# --- base URL safety --------------------------------------------------------

if [[ "$LEAFMILL_BASE_URL" != "https://leafmill.net" ]]; then
  if [[ "$ALLOW_CUSTOM_BASE" != "true" ]]; then
    die "refusing to send credentials to non-leafmill URL: $LEAFMILL_BASE_URL (pass --allow-nonleafmill-base-url to override)"
  fi
  warn "*** USING NON-STANDARD BASE URL: $LEAFMILL_BASE_URL ***"
fi

# --- resolve API key --------------------------------------------------------

API_KEY_SOURCE="none"

if [[ -n "$API_KEY" ]]; then
  API_KEY_SOURCE="flag"
elif [[ -n "${LEAFMILL_API_KEY:-}" ]]; then
  API_KEY="$LEAFMILL_API_KEY"
  API_KEY_SOURCE="env"
elif [[ -f "$HOME/.leafmill/credentials" ]]; then
  API_KEY="$(cat "$HOME/.leafmill/credentials" | tr -d '[:space:]')"
  API_KEY_SOURCE="credentials_file"
fi

# --- validate file ----------------------------------------------------------

[[ -f "$MD_FILE" ]] || die "file not found: $MD_FILE"

# --- default title from filename --------------------------------------------

if [[ -z "$TITLE" ]]; then
  TITLE="$(basename "$MD_FILE")"
  TITLE="${TITLE%.*}"
fi

# --- channel requires auth --------------------------------------------------

if [[ -n "$CHANNEL" ]] && [[ -z "$API_KEY" ]]; then
  die "--channel requires authentication (set API key via --api-key, \$LEAFMILL_API_KEY, or ~/.leafmill/credentials)"
fi

# --- build JSON payload using jq --rawfile for proper escaping --------------

JSON_PAYLOAD="$(jq -n \
  --arg title "$TITLE" \
  --rawfile body "$MD_FILE" \
  --arg description "$DESCRIPTION" \
  --arg channel "$CHANNEL" \
  '{title: $title, body: $body} +
   (if $description != "" then {description: $description} else {} end) +
   (if $channel != "" then {channel: $channel} else {} end)'
)"

# --- build curl args --------------------------------------------------------

CURL_ARGS=(
  -sS
  --fail-with-body
  -X POST
  "${LEAFMILL_BASE_URL}/api/v1/publish"
  -H "Content-Type: application/json"
  -d "$JSON_PAYLOAD"
)

if [[ -n "$API_KEY" ]]; then
  CURL_ARGS+=(-H "Authorization: Bearer ${API_KEY}")
fi

if [[ -n "$CLIENT" ]]; then
  CURL_ARGS+=(-H "X-Leafmill-Client: ${CLIENT}/publish-sh")
fi

# --- publish ----------------------------------------------------------------

RESP_FILE="$(mktemp)"
trap 'rm -f "$RESP_FILE"' EXIT

curl "${CURL_ARGS[@]}" > "$RESP_FILE" || {
  ERR="$(jq -r '.error // empty' < "$RESP_FILE" 2>/dev/null)"
  if [[ -n "$ERR" ]]; then
    die "publish failed: $ERR"
  else
    die "publish failed (server returned an error)"
  fi
}

# validate response is JSON with a slug
SLUG="$(jq -r '.slug // empty' < "$RESP_FILE")"
[[ -n "$SLUG" ]] || die "unexpected response: missing slug"

# --- parse response ---------------------------------------------------------

PAGE_URL="$(jq -r '.url' < "$RESP_FILE")"
CHANNEL_URL="$(jq -r '.channelUrl // empty' < "$RESP_FILE")"
RETURNED_API_KEY="$(jq -r '.apiKey // empty' < "$RESP_FILE")"
EXPIRES_AT="$(jq -r '.expiresAt // empty' < "$RESP_FILE")"
QR="$(jq -r '.qr // empty' < "$RESP_FILE")"

# --- auto-store API key if returned (first publish creates provisional user) -

if [[ -n "$RETURNED_API_KEY" ]]; then
  mkdir -p "$HOME/.leafmill"
  echo "$RETURNED_API_KEY" > "$HOME/.leafmill/credentials"
  chmod 600 "$HOME/.leafmill/credentials"
  API_KEY_SOURCE="auto_provisioned"
fi

# determine auth mode
if [[ -n "$EXPIRES_AT" ]] && [[ "$EXPIRES_AT" != "null" ]]; then
  AUTH_MODE="provisional"
  PERSISTENCE="expires_24h"
else
  AUTH_MODE="authenticated"
  PERSISTENCE="permanent"
fi

# --- update state file ------------------------------------------------------

STATE_DIR=".leafmill"
STATE_FILE="${STATE_DIR}/state.json"
mkdir -p "$STATE_DIR"

ENTRY_JSON="$(jq -n \
  --arg url "$PAGE_URL" \
  --arg channelUrl "$CHANNEL_URL" \
  --arg expiresAt "$EXPIRES_AT" \
  '{url: $url} +
   (if $channelUrl != "" then {channelUrl: $channelUrl} else {} end) +
   (if $expiresAt != "" and $expiresAt != "null" then {expiresAt: $expiresAt} else {} end)'
)"

if [[ -f "$STATE_FILE" ]]; then
  EXISTING="$(cat "$STATE_FILE")"
else
  EXISTING='{"articles":{}}'
fi

echo "$EXISTING" | jq \
  --arg slug "$SLUG" \
  --argjson entry "$ENTRY_JSON" \
  '.articles[$slug] = $entry' > "$STATE_FILE"

# --- stdout: URL only -------------------------------------------------------

echo "$PAGE_URL"

# --- stderr: structured output for agent parsing ----------------------------

emit "publish_result.url=${PAGE_URL}"
[[ -n "$CHANNEL_URL" ]] && emit "publish_result.channel_url=${CHANNEL_URL}"
emit "publish_result.auth_mode=${AUTH_MODE}"
emit "publish_result.api_key_source=${API_KEY_SOURCE}"
emit "publish_result.persistence=${PERSISTENCE}"

[[ -n "$EXPIRES_AT" ]] && [[ "$EXPIRES_AT" != "null" ]] && emit "publish_result.expires_at=${EXPIRES_AT}"

if [[ -n "$QR" ]]; then
  emit "publish_result.qr=${QR}"
fi
