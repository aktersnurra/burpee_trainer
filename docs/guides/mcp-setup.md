# Setting up Claude as a coach (MCP)

## Summary

The app is an MCP server at `<PHX_HOST>/mcp`. Claude signs in through Pocket ID, the same
way kcal does: Pocket ID issues the token, the app only checks it. Who may use the app,
who may use it from Claude, and who has the app's own coach are all set in Pocket ID.
Design: `docs/specs/2026-10-16-mcp-design.md`.

## Pocket ID

### Groups

A group says who may do what. One group per app, and one per paid-for feature:

| Group | Members | Custom claim |
|---|---|---|
| `burpee` | everyone who may use BurpeeTrainer | none |
| `burpee-coach` | whoever gets the app's own coach (its model costs money) | `burpee_coach` = `true` |

The app reads the claim, never a group name, so renaming the group or granting the coach
through a second group needs no change in the app.

### Clients

| Client | Allowed groups | Notes |
|---|---|---|
| BurpeeTrainer (exists) | `burpee` | callback unchanged |
| Claude – BurpeeTrainer (new) | `burpee` | the callback URLs of your kcal Claude client; its client ID is `MCP_OIDC_AUDIENCE` |

Keep the Claude client BurpeeTrainer's own. The app accepts only tokens issued for it, so a
token Claude holds for kcal cannot be used here, and the other way round.

### Order, so nobody is locked out

1. Create the groups, add members, and put the claim on `burpee-coach`.
2. Switch each client's allowed groups to its new group.
3. Sign in to each app once.
4. Remove the old catch-all group.

## The app

| Variable | Value |
|---|---|
| `MCP_OIDC_AUDIENCE` | the Claude – BurpeeTrainer client ID. Unset: `/mcp` and its metadata are 404. |
| `COACH_CLAIM` | optional; the claim key, default `burpee_coach`. |

`OIDC_ISSUER` is the one login already uses.

Existing users keep the app's coach until their next sign-in, when the claim decides. Put
the claim on the group before then.

Back up the database before deploying: two migrations change it (`coach_recommendations.
planned_by`, `users.coach_enabled`) and one narrows the lock on completed sessions so
their feedback can be corrected.

## Claude

- **claude.ai and the phone app:** Settings, Connectors, add a custom connector with URL
  `https://<PHX_HOST>/mcp`; under advanced settings, the Claude – BurpeeTrainer client ID
  and secret.
- **Claude Code:** `claude mcp add --transport http burpee https://<PHX_HOST>/mcp`, then
  `/mcp` to sign in. If it asks for a client, use the same ID and secret.

Start a conversation with the `coach` prompt; Claude then reads `get_coach_context` first.

## Check it

1. `curl https://<PHX_HOST>/.well-known/oauth-protected-resource` names `/mcp` and the
   Pocket ID issuer.
2. `curl -i -X POST https://<PHX_HOST>/mcp` is a 401 with a `WWW-Authenticate` header
   pointing at that metadata.
3. In Claude, ask for this week (`get_week`): the minutes match Home.
4. Ask Claude to note something; it shows on Home as "Noted: …".
