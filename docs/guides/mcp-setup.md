# Setting up Claude as a coach (MCP)

## Summary

The app is an MCP server at `<PHX_HOST>/mcp`. Claude signs in through Pocket ID, the same
way Fund does: Pocket ID issues the token, the app only checks it. Who may use the app,
who may use it from Claude, and who has the app's own coach are all set in Pocket ID.
Design: `docs/specs/2026-10-16-mcp-design.md`.

## Pocket ID

### Groups

A group says who may do what. One group per app, and one per paid-for feature:

| Group | Members |
|---|---|
| `burpee` | everyone who may use BurpeeTrainer |
| `burpee-coach` | whoever gets the app's own coach (its model costs money) |

The app knows the coach group by its Pocket ID id (`COACH_GROUP_ID`), never its name, so
renaming it needs no change in the app. A custom claim on it is no longer read.

### SCIM provisioning

Pocket ID pushes users and groups to the app, so blocking a user, removing them from
`burpee`, or changing `burpee-coach` reaches the app within about five minutes. Design:
`docs/specs/2026-10-20-scim-provisioning-design.md`.

1. Generate a token, e.g. `openssl rand -base64 32`, and set it as `SCIM_TOKEN`.
2. Set `COACH_GROUP_ID` to the `burpee-coach` group's id (the id in its URL in Pocket ID).
3. Allow both `burpee` and `burpee-coach` on the BurpeeTrainer client: Pocket ID only
   sends the client's allowed groups.
4. BurpeeTrainer client → **SCIM Provisioning**: endpoint `https://<PHX_HOST>/scim/v2`,
   the token, **Enable**, then **Sync now**.

A blocked user is signed out of open pages at once and cannot sign in or use `/mcp`;
removing them from the client keeps their data, and allowing them again restores it.

### The MCP API

Claude does not get a client of its own. Pocket ID lets MCP clients register themselves
through Client ID Metadata Documents (CIMD), per API. Set it up as for Fund (see
`nuc/apps/pocketid/apis.md` in nuc-setup):

1. Admin → **APIs** → create an API. Resource: `https://<PHX_HOST>/mcp`, no trailing
   slash. It can't be changed later, and it must be exactly what the app publishes as its
   resource.
2. No permissions: the app checks none, and every tool is open to any signed-in user.
3. That API → **Access** → *Metadata document clients* → turn on "Allow all metadata
   document clients". The allowlist of Claude's and OpenAI's URLs is global (Application
   Configuration) and is already there from Fund.
4. Record the API in `nuc/apps/pocketid/apis.md`.

Who may use it is still the `burpee` group: a token is only accepted for someone who
already has an account, and accounts are made by signing in to the app, whose client
allows only `burpee`.

The existing BurpeeTrainer client stays as it is, with `burpee` as its allowed group.

### Order, so nobody is locked out

1. Create the groups and add members.
2. Switch the BurpeeTrainer client's allowed group to `burpee`.
3. Sign in to the app once.
4. Remove the old catch-all group.

## The app

| Variable | Value |
|---|---|
| `MCP_OIDC_AUDIENCE` | the API's resource, `https://<PHX_HOST>/mcp`. Unset: `/mcp` and its metadata are 404. |
| `SCIM_TOKEN` | the token Pocket ID sends to `/scim/v2`. Unset: `/scim/v2` is 404. |
| `COACH_GROUP_ID` | the Pocket ID id of `burpee-coach`, whose members get the app's coach. |

`OIDC_ISSUER` is the one login already uses.

A token's audience is that resource. When Claude also asks for `openid`, Pocket ID adds
the issuer as a second audience so the token works at `/userinfo`; the app allows that one
extra value and refuses any other.

Existing users keep their coach until the first SCIM sync writes `burpee-coach`; from
then on its members have the app's coach and everyone else coaches over MCP.

Back up the database before deploying: two migrations change it (`coach_recommendations.
planned_by`, `users.coach`, and SCIM's `users.access` and `scim_groups`) and one narrows
the lock on completed sessions so their feedback can be corrected.

## Claude

- **claude.ai and the phone app:** Settings, Connectors, add a custom connector with URL
  `https://<PHX_HOST>/mcp`. Leave the client ID and secret empty; Claude registers itself.
- **Claude Code:** `claude mcp add --transport http burpee https://<PHX_HOST>/mcp`, then
  `/mcp` to sign in.

Start a conversation with the `coach` prompt; Claude then reads `get_coach_context` first.

## Check it

1. `curl https://<PHX_HOST>/.well-known/oauth-protected-resource` names
   `https://<PHX_HOST>/mcp`, the API's resource, and the Pocket ID issuer.
2. `curl -i -X POST https://<PHX_HOST>/mcp` is a 401 with a `WWW-Authenticate` header
   pointing at that metadata.
3. In Claude, ask for this week (`get_week`): the minutes match Home.
4. Ask Claude to note something; it shows on Home as "Noted: …".
