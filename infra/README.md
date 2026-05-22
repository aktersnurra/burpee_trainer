### Phase 5 — NUC: create jails

Run on the NUC as root. These can run in parallel in separate terminals.

```sh
sh nuc/apps/burpee/jail
sh nuc/apps/tore/jail
```

Each script:
- Fetches a FreeBSD base into `/jails/<name>`
- Writes the jail entry in `/etc/jail.conf` and starts the jail
- Installs Erlang, Elixir, SQLite (burpee also builds/installs HiGHS)
- Creates a service user

---

### Phase 6 — NUC: install app services

Run from within each application's repository (after copying scripts there —
see [Scripts that live in app repos](#scripts-that-live-in-app-repos)).

**Burpee:**

```sh
# From burpee_trainer repo root:
sh infra/service
```

This installs the rc.d script and writes an env template at
`/jails/burpee/etc/burpee/env`. Fill in the secrets before deploying:

```sh
# On the NUC:
vi /jails/burpee/etc/burpee/env
# Set: SECRET_KEY_BASE, RELEASE_COOKIE
```

Then install the protected-video server (requires the same `VIDEO_SECRET` from
Phase 2):

```sh
VIDEO_SECRET=<same value as phase 2> sh infra/video-server
```

**Tore:**

```sh
# From tore repo root:
sh infra/service
```

Fill in secrets:

```sh
# On the NUC:
vi /jails/tore/etc/tore/env
# Set: SECRET_KEY_BASE, RELEASE_COOKIE, SMTP_RELAY (VPS Tailscale IP from Phase 3)
```

---

### Phase 7 — NUC: open pf for VPS traffic

Use the VPS Tailscale IP printed by `vps/01-tailscale` (Phase 3).

Edit `/etc/pf.conf` on the NUC and uncomment the jail port rules, replacing
`<VPS_TS_IP>` with the actual IP:

```
pass in on $ts_if proto tcp from <VPS_TS_IP> to 172.16.0.2 port 4000 keep state  # burpee Phoenix
pass in on $ts_if proto tcp from <VPS_TS_IP> to 172.16.0.2 port 4002 keep state  # burpee video server
pass in on $ts_if proto tcp from <VPS_TS_IP> to 172.16.0.3 port 4001 keep state  # tore
```

```sh
pfctl -f /etc/pf.conf
```

---

### Phase 8 — Deploy apps

Run from each application repository. The deploy script builds a release
locally and pushes it to the NUC over SSH.

**Burpee:**

```sh
# From burpee_trainer repo root:
sh infra/deploy user@nuc
```

**Tore:**

```sh
# From tore repo root:
sh infra/deploy user@nuc
```

Each deploy script:
1. Builds assets (`mix assets.deploy`)
2. Builds a production release (`mix release`)
3. Uploads the tarball or rsync's the release directory to the jail
4. Runs migrations inside the jail
5. Restarts the service

Verify after deploy:

```sh
curl -I https://burpee.gustafrydholm.xyz
curl -I https://tore.gustafrydholm.xyz
```

---

## Ports reference

| Service | Jail IP | Port |
|---|---|---|
| burpee Phoenix | 172.16.0.2 | 4000 |
| burpee video server | 172.16.0.2 | 4002 |
| tore Phoenix | 172.16.0.3 | 4001 |

---

## Secrets reference

| Secret | Where set | Used by |
|---|---|---|
| `PREAUTH_KEY` | Printed by `vps/00-headscale` (Phase 1) | `nuc/01-base` (Phase 3) |
| `SSH_PUBKEY` | `cat ~/.ssh/nuc_ed25519.pub` | `nuc/01-base` — added to `/root/.ssh/authorized_keys` |
| `VIDEO_SECRET` | `openssl rand -hex 32` — generate in Phase 2 | `vps/02-caddy`, `nuc/apps/burpee/video-server` |
| `SECRET_KEY_BASE` | `/jails/burpee/etc/burpee/env` | burpee Phoenix |
| `RELEASE_COOKIE` | `/jails/burpee/etc/burpee/env` | burpee Phoenix |
| `SECRET_KEY_BASE` | `/jails/tore/etc/tore/env` | tore Phoenix |
| `RELEASE_COOKIE` | `/jails/tore/etc/tore/env` | tore Phoenix |
| `SMTP_RELAY` | `/jails/tore/etc/tore/env` | tore (VPS Tailscale IP) |

---

## Logs

```sh
# On NUC — burpee Phoenix
tail -f /jails/burpee/var/log/burpee/burpee_trainer.log

# On NUC — burpee video server
tail -f /jails/burpee/var/log/burpee/burpee_videos.log

# On NUC — tore
tail -f /jails/tore/var/log/tore/tore.log

# On VPS — Caddy
journalctl -fu caddy
```
