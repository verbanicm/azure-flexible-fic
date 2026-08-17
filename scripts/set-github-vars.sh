#!/usr/bin/env bash
#
# set-github-vars.sh — configures the repo the workflows need.
#
# OIDC means there are no client secrets. But on a PUBLIC repo, GitHub
# Actions *variables* are not masked in logs, so everything here is stored
# as a *secret* (masked, hidden) for defense-in-depth.
#
# Requirements: gh CLI (logged in via `gh auth login`).
#
# Usage:
#   ./scripts/set-github-vars.sh <owner/repo> <tenant-id> <subscription-id> \
#       <client-id-push> <client-id-manual>

set -euo pipefail

REPO="${1:?owner/repo required}"
TENANT_ID="${2:?tenant id required}"
SUBSCRIPTION_ID="${3:?subscription id required}"
CLIENT_ID_PUSH="${4:?push client id required}"
CLIENT_ID_MANUAL="${5:?manual client id required}"

command -v gh >/dev/null || { echo "ERROR: gh CLI not found." >&2; exit 1; }

set_secret() {
  echo "==> Setting secret $1 (masked)"
  gh secret set "$1" --repo "$REPO" --body "$2"
}

# Everything stored as secrets (masked in public Actions logs).
set_secret AZURE_TENANT_ID        "$TENANT_ID"
set_secret AZURE_SUBSCRIPTION_ID  "$SUBSCRIPTION_ID"
set_secret AZURE_CLIENT_ID_PUSH   "$CLIENT_ID_PUSH"
set_secret AZURE_CLIENT_ID_MANUAL "$CLIENT_ID_MANUAL"

echo "Done. Secrets set on $REPO."
