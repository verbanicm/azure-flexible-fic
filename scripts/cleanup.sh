#!/usr/bin/env bash
#
# cleanup.sh — tears down everything the demo (and the earlier probing) created:
#   - the two demo app registrations (flexfic-push-deploy, flexfic-manual-deploy)
#     and their federated identity credentials + service principals
#   - leftover managed-identity resource group from the initial attempts
#   - leftover probe resource group and probe app registration
#
# Safe to run repeatedly; missing resources are ignored.
#
# Requirements: az CLI (logged in).
#
# Usage:
#   ./scripts/cleanup.sh

set -euo pipefail

command -v az >/dev/null || { echo "ERROR: az CLI not found." >&2; exit 1; }

# App registrations created by the demo and the probe.
APPS=(flexfic-push-deploy flexfic-manual-deploy flexfic-probe-app)

# Resource groups created along the way (managed-identity attempts + probe).
RGS=(rg-flexfic-demo rg-flexfic-probe)

echo "==> Deleting app registrations..."
for name in "${APPS[@]}"; do
  ids="$(az ad app list --display-name "$name" --query "[].appId" -o tsv)"
  if [ -z "$ids" ]; then
    echo "    (none) $name"
    continue
  fi
  while IFS= read -r app_id; do
    [ -n "$app_id" ] || continue
    echo "    deleting $name ($app_id)"
    az ad app delete --id "$app_id" -o none 2>/dev/null || echo "      (already gone)"
  done <<< "$ids"
done

echo "==> Deleting resource groups..."
for rg in "${RGS[@]}"; do
  if az group show -n "$rg" -o none 2>/dev/null; then
    echo "    deleting $rg"
    az group delete -n "$rg" --yes --no-wait
  else
    echo "    (none) $rg"
  fi
done

echo "==> Checking for orphaned role assignments (deleted principals)..."
orphans="$(az role assignment list --all --query "[?principalName==null].id" -o tsv 2>/dev/null || true)"
if [ -n "$orphans" ]; then
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    echo "    removing orphaned role assignment"
    az role assignment delete --ids "$id" -o none 2>/dev/null || true
  done <<< "$orphans"
else
  echo "    none found"
fi

echo
echo "Cleanup complete. Resource-group deletions run in the background (--no-wait)."
