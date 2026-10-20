# Pocket ID provisioning over SCIM

## Why

Signing in reads Pocket ID once; the app's session is then a 30-day cookie. Without
provisioning, blocking someone in Pocket ID or taking them out of a group changed nothing
in the app until their next sign-in. Pocket ID (v2.14 and later) pushes users and groups
to an app over SCIM 2.0, so Pocket ID stays the one place access is decided.

## What Pocket ID sends (v2.16, `backend/internal/scimsync/service.go`)

- `GET /Users` and `GET /Groups`, paged with `startIndex` and `count=1000`.
- Then, per record: `POST` (create), `PUT /:id` (replace), `DELETE /:id`. No `PATCH`, no
  filters, no `/Schemas` or `/ServiceProviderConfig`. Bodies are `application/scim+json`;
  every request carries `Authorization: Bearer <token>`.
- It matches its records by `externalId`: its own user id, which is also the ID token's
  `sub` (the app's `users.oidc_sub`), and its group id for groups.
- A blocked user is a `PUT` with `active: false`. A user who loses access to the client
  (out of its allowed groups) is a `DELETE`, as is any listed resource Pocket ID does not
  know.
- Groups are only the client's allowed groups. A member is the app's own user id, from
  the user list. Custom claims are never sent.
- A record is only written when it changed after the app's `meta.lastModified`. Syncs
  run five minutes after a change in Pocket ID, hourly, and on "Sync now".

## The app

- `/scim/v2/Users` and `/scim/v2/Groups` (`ScimController`, `ScimJSON`), admitted by
  `ScimAuth` against `SCIM_TOKEN`; unset, `/scim/v2` is a 404.
- **Access is a sum type,** `users.access` :: `:active | :disabled | :removed`. `active`
  maps to `:active`/`:disabled`; `DELETE` marks `:removed` and keeps the user's data.
  Only `:active` passes `Auth` (browser and LiveView) and `McpAuth`. A removed user is
  not listed and is a 404; Pocket ID creating them again (same `externalId`) restores
  the same row and its history. Signing in also restores `:active`: Pocket ID only lets
  a user with access sign in.
- **Open pages close at once.** Sessions carry a `live_socket_id`; a write that leaves a
  user without access broadcasts `disconnect` to it, and the reconnect meets the access
  check.
- **The coach is group membership.** `COACH_GROUP_ID` is the Pocket ID id of the group
  whose members get the app's coach (`users.coach = :app`); everyone else is `:mcp`.
  Writing that group sets every user's coach; writing a user, or signing in, sets theirs
  from the stored group. Until the group is provisioned, coaches are left as they are.
  The group must be one of the client's allowed groups, or Pocket ID never sends it.
- `users.scim_synced_at` and `scim_groups.scim_synced_at` stamp each SCIM write and are
  reported as `meta.lastModified`. A user never written over SCIM reports none, so the
  first sync writes every user. Sign-in does not stamp it, so Pocket ID's own later
  changes still arrive.
- Users without an `oidc_sub` are not SCIM resources: Pocket ID does not know them and
  would otherwise delete them.
- Creating a user resolves the identity as sign-in does (`Accounts.resolve_oidc_identity/2`):
  the user with that `sub`, else an unlinked user with that username, else a new user. A
  username linked to another `sub` is a `409 uniqueness`.

## Out of scope

- `PATCH`, filters and the discovery endpoints: Pocket ID does not use them.
- Renaming a user from Pocket ID: the `sub` is the identity; the username stays.
- Back-channel logout: a change takes effect at the next sync (about five minutes).
