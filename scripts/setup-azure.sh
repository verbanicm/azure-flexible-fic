#!/usr/bin/env bash
#
# setup-azure.sh — provisions Azure infrastructure for the Flexible FIC demo.
#
# Creates two APP REGISTRATIONS (service principals), both pinned to the `main`
# branch, and gives each one a *flexible* federated identity credential so that
# one identity only trusts `push` events and the other only trusts
# `workflow_dispatch` events (differentiated by `event_name` — see below).
#
# WHY APP REGISTRATIONS AND NOT MANAGED IDENTITIES?
#   Flexible FIC for the GitHub issuer requires the expression to include the
#   `repository_id` (or `repository_owner_id`) claim with the `eq` operator.
#   On a user-assigned managed identity, `repository_id` accepts NO operator, so
#   that required claim can never be added and every GitHub expression is
#   rejected. On app registrations, `repository_id eq` is accepted. This was
#   verified empirically against live Azure.
#
# HOW DO WE DIFFERENTIATE push vs workflow_dispatch?
#   The `event_name` claim itself accepts NO operator (neither `eq` nor
#   `matches`) for the GitHub issuer, so it cannot be a standalone claim in the
#   expression. Instead we fold the event INTO the `sub` claim by customizing
#   the repo's OIDC subject template to `repo:event_name:ref` (run
#   scripts/set-oidc-sub.sh first). The token's `sub` then becomes:
#     push     -> repo:OWNER/REPO:event_name:push:ref:refs/heads/main
#     dispatch -> repo:OWNER/REPO:event_name:workflow_dispatch:ref:refs/heads/main
#   and each FIC matches its event via `sub` + the required `repository_id eq`.
#   (A single "any event" identity would just wildcard the event segment:
#    claims['sub'] matches 'repo:*:event_name:*:ref:refs/heads/main' — documented
#    in the README but intentionally NOT provisioned here.)
#
# Requirements: az CLI (logged in, rights to create app registrations + role
# assignments), jq, gh (or a public repo for curl).
#
# Usage:
#   ./scripts/setup-azure.sh <owner/repo> [subscription-scope-role]
#
# Example:
#   ./scripts/setup-azure.sh verbanicm/azure-flexible-fic

set -euo pipefail

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
REPO="${1:?Usage: setup-azure.sh <owner/repo> [role]}"
ROLE="${2:-Reader}"

ISSUER="https://token.actions.githubusercontent.com"
AUDIENCE="api://AzureADTokenExchange"

# One app registration per event, both pinned to main.
APP_PUSH="flexfic-push-deploy"
APP_MANUAL="flexfic-manual-deploy"
EVENT_PUSH="push"
EVENT_MANUAL="workflow_dispatch"

command -v az >/dev/null || { echo "ERROR: az CLI not found." >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not found." >&2; exit 1; }

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

# GitHub flexible FIC requires the immutable repository_id claim (eq).
get_github_field() {
  if command -v gh >/dev/null; then gh api "repos/${REPO}" --jq "$1"
  else curl -fsSL "https://api.github.com/repos/${REPO}" | jq -r "$1"; fi
}
REPO_ID="$(get_github_field '.id')"
[ -n "$REPO_ID" ] || { echo "ERROR: could not resolve repository_id for $REPO (private repo? run 'gh auth login')." >&2; exit 1; }

echo "Subscription : $SUBSCRIPTION_ID"
echo "Tenant       : $TENANT_ID"
echo "Repo         : $REPO (repository_id=$REPO_ID)"
echo "Role         : $ROLE (subscription scope)"
echo

# ---------------------------------------------------------------------------
# App registration + service principal (idempotent)
# ---------------------------------------------------------------------------
# ensure_app <display-name>  -> echoes "<appId> <objectId>"
ensure_app() {
  local name="$1" app_id obj_id
  app_id="$(az ad app list --display-name "$name" --query '[0].appId' -o tsv)"
  if [ -z "$app_id" ]; then
    app_id="$(az ad app create --display-name "$name" --query appId -o tsv)"
  fi
  obj_id="$(az ad app show --id "$app_id" --query id -o tsv)"
  # Ensure a service principal exists (needed for role assignment).
  az ad sp show --id "$app_id" -o none 2>/dev/null || az ad sp create --id "$app_id" -o none
  echo "$app_id $obj_id"
}

echo "==> Ensuring app registration: $APP_PUSH"
read -r APP_ID_PUSH OBJ_ID_PUSH < <(ensure_app "$APP_PUSH")
echo "==> Ensuring app registration: $APP_MANUAL"
read -r APP_ID_MANUAL OBJ_ID_MANUAL < <(ensure_app "$APP_MANUAL")

# ---------------------------------------------------------------------------
# Flexible FIC via Microsoft Graph beta (app registrations only)
# ---------------------------------------------------------------------------
# create_fic <app-object-id> <fic-name> <expression>
create_fic() {
  local obj_id="$1" fic="$2" expression="$3" url body existing
  url="https://graph.microsoft.com/beta/applications/${obj_id}/federatedIdentityCredentials"

  # Delete an existing FIC of the same name so the script is idempotent.
  existing="$(az rest --method get --url "$url" --query "value[?name=='${fic}'].id" -o tsv 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    az rest --method delete --url "${url}/${existing}" -o none 2>/dev/null || true
  fi

  body="$(jq -nc \
    --arg n "$fic" --arg issuer "$ISSUER" --arg aud "$AUDIENCE" --arg expr "$expression" \
    '{name:$n, issuer:$issuer, audiences:[$aud], claimsMatchingExpression:{value:$expr, languageVersion:1}}')"
  az rest --method post --url "$url" --headers "Content-Type=application/json" --body "$body" -o none
}

# The expression differentiates by event via the customized `sub`, plus the
# mandatory `repository_id eq` required-claim. A wildcard covers the repo
# segment so this works whether or not the repo uses immutable subject claims
# (repo:OWNER/REPO... vs repo:OWNER@id/REPO@id...) — repository_id still pins it.
fic_expression() {
  local event="$1"
  printf "claims['sub'] matches 'repo:*:event_name:%s:ref:refs/heads/main' and claims['repository_id'] eq '%s'" \
    "$event" "$REPO_ID"
}

echo "==> Creating flexible FIC for $APP_PUSH (event: $EVENT_PUSH)"
create_fic "$OBJ_ID_PUSH" "flexfic" "$(fic_expression "$EVENT_PUSH")"
echo "==> Creating flexible FIC for $APP_MANUAL (event: $EVENT_MANUAL)"
create_fic "$OBJ_ID_MANUAL" "flexfic" "$(fic_expression "$EVENT_MANUAL")"

# ---------------------------------------------------------------------------
# Role assignment (subscription scope, so the login proves out)
# ---------------------------------------------------------------------------
assign_role() {
  local app_id="$1"
  az role assignment create \
    --assignee "$app_id" \
    --role "$ROLE" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}" -o none 2>/dev/null \
    || echo "    (role assignment already exists or is still propagating)"
}
echo "==> Assigning $ROLE role..."
assign_role "$APP_ID_PUSH"
assign_role "$APP_ID_MANUAL"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "============================================================"
echo " Flexible FIC demo provisioned (app registrations)."
echo "   push-deploy   -> client-id $APP_ID_PUSH"
echo "   manual-deploy -> client-id $APP_ID_MANUAL"
echo "============================================================"
echo
echo "Store these on the repo as SECRETS (masked in public Actions logs):"
echo "  AZURE_TENANT_ID=$TENANT_ID"
echo "  AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID"
echo "  AZURE_CLIENT_ID_PUSH=$APP_ID_PUSH"
echo "  AZURE_CLIENT_ID_MANUAL=$APP_ID_MANUAL"
echo
echo "Quick copy/paste (set-github-vars.sh stores them all as secrets):"
echo "  ./scripts/set-github-vars.sh $REPO $TENANT_ID $SUBSCRIPTION_ID $APP_ID_PUSH $APP_ID_MANUAL"
echo
echo "IMPORTANT: the FICs above match a CUSTOMIZED subject claim. Apply it once:"
echo "  ./scripts/set-oidc-sub.sh $REPO"
echo "  (folds event_name into 'sub' so push vs workflow_dispatch can differ)"
