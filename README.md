# azure-flexible-fic

A minimal, **empirically-verified** demo of **Azure Flexible Federated Identity
Credentials (FIC)** with GitHub Actions OIDC — no client secrets.

Along the way this repo documents what actually works today (mid-2026, preview),
which differs significantly from the Microsoft docs. See
[Findings](#findings-what-actually-works) below.

## What this demonstrates

Two GitHub Actions workflows, both running on `main`, each authenticating to
Azure as a **different app registration**, differentiated by the **event that
triggered the run** (`push` vs `workflow_dispatch`), folded into the `sub` claim
via a customized OIDC subject template:

| Workflow | Trigger | Identity (app registration) | Flexible FIC trusts |
|---|---|---|---|
| `.github/workflows/push-deploy.yml` | `push` → `main` | `flexfic-push-deploy` | only `event_name:push` on main |
| `.github/workflows/manual-deploy.yml` | `workflow_dispatch` | `flexfic-manual-deploy` | only `event_name:workflow_dispatch` on main |

The **flexible** part is the `claimsMatchingExpression`: instead of one
exact-match `subject` per credential, each identity matches a `sub` that carries
the event name plus the required `repository_id`, so the push identity will not
accept a token minted by a manual run — even though both run on the same branch.

## Findings (what actually works)

These were discovered by probing the live API (creating flexible FICs on both a
user-assigned managed identity and an app registration and observing which
expressions Azure accepted), not from the docs.

1. **Flexible FIC does NOT work on user-assigned managed identities (GitHub
   issuer).** The ARM API added the `claimsMatchingExpression` field in
   api-version `2025-05-31-preview`, but every GitHub expression is rejected at
   the Graph validation layer. This matches the one accurate doc line:
   *"support exists only for federated identity credentials configured on
   application objects currently."* Use **app registrations**.

2. **A `repository_id` OR `repository_owner_id` claim with `eq` is REQUIRED.**
   Any expression with only `sub` (or only `job_workflow_ref`) is rejected with
   *"lacks all required claims or contains unallowed claims."* Adding either
   `claims['repository_id'] eq '<id>'` or `claims['repository_owner_id'] eq
   '<id>'` satisfies the rule (both standalone and combined were verified as
   accepted). This is undocumented. (It's also exactly why managed identities
   fail: on an MI, `repository_id` accepts no operator, so the required claim can
   never be added.)

3. **`event_name` cannot be used as a standalone claim — but you can fold it into
   `sub`.** Azure recognizes the token's `event_name` claim (`push`,
   `workflow_dispatch`, …) but rejects **both** operators (`eq` and `matches`) on
   every identity type, so `claims['event_name'] …` never works. The workaround:
   **customize the repo's OIDC subject template** (`scripts/set-oidc-sub.sh`, using
   `include_claim_keys: [repo, event_name, ref]`) so the event becomes part of
   `sub`. `sub` fully supports `matches`/`eq`, so push vs `workflow_dispatch` on
   the same branch becomes expressible after all.

4. **A customized `sub` is deterministic, so wildcards are predictable.** Unlike
   the *default* `sub` (which changes shape per event: `:ref:…` vs `:pull_request`
   vs `:environment:…`), a customized template emits the same `key:value` layout
   every run. That means a single "any event" identity can wildcard just the event
   segment — see [The catch-all pattern](#the-catch-all-pattern-documented-not-built).

5. **The `az` CLI has no flexible-FIC flag.** Everything is created via `az rest`
   against the Microsoft Graph beta endpoint.

### Verified operator matrix (GitHub issuer)

| Claim | App registration | Managed identity |
|---|---|---|
| `sub` | `eq`, `matches` | `eq`, `matches` (but always fails required-claims gate) |
| `job_workflow_ref` | `eq`, `matches` | rejected |
| `repository_id` / `repository_owner_id` | `eq` (**required**; either satisfies the gate, standalone or combined) | no operator works |
| `event_name` | no operator works (fold it into `sub` instead — see finding 3) | no operator works |

## UAMI vs. app registration — which identity to use

Both are **workload identities** in Microsoft Entra ID (a thing your code can
*be* so it can obtain Azure tokens). They differ in who owns and manages the
lifecycle.

**User-assigned managed identity (UAMI)**
- An **Azure resource** (lives in a resource group, has an ARM resource ID);
  Azure creates its service principal automatically.
- **Azure fully manages the credentials** — you never see or rotate a secret.
  You assign it RBAC roles and attach it to Azure compute (VM, Function, Container
  App, AKS pod, …).
- No API-permissions model, no user sign-in — it exists purely to *be* an
  identity for a workload running **on** Azure.

**App registration (+ its service principal)**
- An Entra **directory object** you create and own. The app registration is the
  definition; the **service principal** is its instance in your tenant that holds
  role assignments.
- **You manage** its credentials — client secrets, certificates, and
  **federated credentials** (including flexible FIC) — plus any Microsoft Graph /
  API permissions. Can be multi-tenant and can sign in users.

### When to use which

| | UAMI | App registration |
|---|---|---|
| What it is | Azure resource | Entra directory object |
| Credential mgmt | Azure-managed (invisible) | You manage (secrets / certs / federated) |
| Best for | Workloads running **on** Azure compute | Workloads running **outside** Azure |
| Graph / API permissions | No | Yes |
| Federated creds (OIDC) | Standard FIC yes; **flexible FIC no** (GitHub issuer) | Standard **and** flexible FIC |
| This demo | ❌ can't do flexible FIC | ✅ required |

- **Use a UAMI** when the workload runs on Azure compute and you want zero
  credential handling (no secrets to rotate or leak), and you don't need Graph
  permissions or multi-tenant behavior.
- **Use an app registration** when the workload runs *outside* Azure (GitHub
  Actions, another cloud, on-prem) so it must federate an **external** issuer, or
  when you need Graph/API permissions, app roles, or multi-tenant.

### Why this project uses app registrations

The general rule ("external workload → app registration") and a sharp,
non-obvious rule we proved empirically both point the same way:

> **Flexible FIC (`claimsMatchingExpression`) for the GitHub issuer works only on
> app registrations, not UAMIs.**

The ARM API technically added the `claimsMatchingExpression` field to managed
identities in `2025-05-31-preview`, but every GitHub expression is rejected at the
Graph validation layer. Root cause: flexible FIC **requires** a `repository_id`
(or `repository_owner_id`) claim with `eq`, and on a UAMI that claim accepts **no
operator** — so the mandatory required-claim can never be satisfied. On an app
registration, `repository_id eq` is accepted. GitHub Actions also runs on
GitHub's runners (external issuer), not Azure compute, so there's nothing to
attach a UAMI to anyway. App registration is the only workable choice on both
counts.

## Prerequisites

- `az` CLI, logged in: `az login` (rights to create app registrations + role
  assignments in the target subscription)
- `jq`
- `gh` CLI, logged in: `gh auth login`

## Setup

```bash
# 1. Customize the repo's OIDC subject so `event_name` is part of `sub`.
#    Run once (repo-wide). Required for push-vs-dispatch differentiation.
./scripts/set-oidc-sub.sh <owner/repo>
# e.g.
./scripts/set-oidc-sub.sh verbanicm/azure-flexible-fic

# 2. Provision Azure: 2 app registrations + service principals, each with a
#    flexible FIC (sub carrying event_name@main + required repository_id).
./scripts/setup-azure.sh <owner/repo>

# 3. Store config on the repo. All four values (tenant, subscription, and
#    both app client IDs) go in as *secrets* (masked in public logs).
#    setup-azure.sh prints the exact command; it looks like:
./scripts/set-github-vars.sh <owner/repo> <tenant-id> <subscription-id> \
    <client-id-push> <client-id-manual>
```

## Test

```bash
# Push to main -> triggers push-deploy.yml -> logs in as flexfic-push-deploy
git commit --allow-empty -m "trigger push-deploy" && git push origin main

# Manual run -> triggers manual-deploy.yml -> logs in as flexfic-manual-deploy
gh workflow run manual-deploy.yml --ref main

# Watch either run; the "Azure login" step succeeding proves the flexible FIC.
gh run watch
```

To prove the isolation, swap `AZURE_CLIENT_ID_PUSH` and `AZURE_CLIENT_ID_MANUAL`
in the workflows: each login now fails, because the presented token's `sub`
carries a different `event_name` than that identity's credential accepts.

## The flexible FIC expression

What `setup-azure.sh` creates for the push identity (Graph beta
`applications/{objectId}/federatedIdentityCredentials`):

```json
{
  "name": "flexfic",
  "issuer": "https://token.actions.githubusercontent.com",
  "audiences": ["api://AzureADTokenExchange"],
  "claimsMatchingExpression": {
    "value": "claims['sub'] matches 'repo:*:event_name:push:ref:refs/heads/main' and claims['repository_id'] eq 'REPO_ID'",
    "languageVersion": 1
  }
}
```

The manual identity is identical except `event_name:workflow_dispatch`. The
`repo:*` wildcard covers the repo segment so the expression matches whether or
not the repo uses [immutable subject claims](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims)
(`repo:OWNER/REPO…` vs `repo:OWNER@id/REPO@id…`); `repository_id eq` still pins
the repo cryptographically.

## The catch-all pattern (documented, not built)

Because the customized `sub` always places `event_name` in the same fixed
position, a **single identity that trusts any event** is just a wildcard on that
segment. This repo intentionally does **not** provision it, but if you wanted a
broad "trusts the whole repo on main, any event" identity you would add a FIC
with:

```
claims['sub'] matches 'repo:*:event_name:*:ref:refs/heads/main' and claims['repository_id'] eq 'REPO_ID'
```

Or, ignoring the branch entirely, drop `sub` and lean on the required claim
alone:

```
claims['repository_id'] eq 'REPO_ID'
```

FICs are OR'd and evaluated independently, so a catch-all can coexist with the
event-specific credentials above — either as an extra FIC on an existing app or
on its own app registration.

## Cleanup

Tear down everything the demo (and the earlier managed-identity attempts)
created — app registrations, resource groups, and any orphaned role assignments:

```bash
./scripts/cleanup.sh
```
