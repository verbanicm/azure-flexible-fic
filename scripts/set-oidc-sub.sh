#!/usr/bin/env bash
#
# set-oidc-sub.sh — customizes this repo's GitHub Actions OIDC subject (`sub`)
# claim so that `event_name` is folded INTO the subject.
#
# WHY: the `event_name` claim on its own accepts no operator for the GitHub
# issuer in an Azure flexible FIC, so push-vs-dispatch cannot be expressed as a
# standalone claim. By customizing the subject template to `repo:event_name:ref`
# the event becomes part of `sub`, which DOES support `matches`/`eq`:
#   push     -> repo:OWNER/REPO:event_name:push:ref:refs/heads/main
#   dispatch -> repo:OWNER/REPO:event_name:workflow_dispatch:ref:refs/heads/main
# (Repos created after 2026-07-15 use the immutable form, embedding owner/repo
#  IDs in the repo segment: repo:OWNER@id/REPO@id:event_name:... — the demo's
#  FIC expressions wildcard that segment so either format matches.)
#
# NOTE: this is a REPO-WIDE setting — it changes `sub` for every workflow in the
# repo. Run it once, before (or right after) provisioning the FICs.
#
# Requirements: gh CLI (logged in, admin on the repo).
#
# Usage:
#   ./scripts/set-oidc-sub.sh <owner/repo>

set -euo pipefail

REPO="${1:?Usage: set-oidc-sub.sh <owner/repo>}"
command -v gh >/dev/null || { echo "ERROR: gh CLI not found." >&2; exit 1; }

echo "==> Applying custom OIDC subject template to $REPO"
echo "    include_claim_keys = [repo, event_name, ref]"
gh api --method PUT "/repos/${REPO}/actions/oidc/customization/sub" \
  -F use_default=false \
  -f 'include_claim_keys[]=repo' \
  -f 'include_claim_keys[]=event_name' \
  -f 'include_claim_keys[]=ref'

echo
echo "==> Current template:"
gh api "/repos/${REPO}/actions/oidc/customization/sub"
echo
echo "Done. New runs will emit sub = repo:OWNER/REPO:event_name:<event>:ref:<ref>."
echo "To revert to the default subject:"
echo "  gh api --method PUT /repos/${REPO}/actions/oidc/customization/sub -F use_default=true"
