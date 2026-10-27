# infra

Ansible that sets up Burrow on a VM, from this computer.

```
burrow-1 (Ubuntu 26.04)
 ├─ burrow           mix phx.server (prod) from a checkout of burrow_version, SQLite
 ├─ burrow-router    Caddy on loopback: peon-<port>.<domain> → the preview or app on that port
 ├─ burrow-tunnel    cloudflared: <domain> and *.<domain>; nothing listens publicly
 ├─ Docker           every project's containers (agents, previews, checks, staging, prod)
 └─ burrow-backup    nightly restic of /var/lib/burrow (optional)
```

Groups in `inventory.yml`: `burrow` is the machine Burrow runs on, `projects`
the machines that run projects' containers. Today they must be the same VM:
Burrow starts containers with its local `docker`.

## What you need

1. **A VM**: Ubuntu 26.04 LTS, x86_64, root over SSH with your key. Start with
   4 vCPU, 16 GB RAM, 160 GB disk. Each running chat has two containers of up
   to 3 GB; `burrow_max_host_chats` caps how many run at once.
2. **A domain on Cloudflare**, used whole (e.g. `example.com`): previews and
   apps are `peon-<port>.example.com`, and Cloudflare's free certificate covers
   one level of `*.example.com` only.
3. **A Resend account** (resend.com) for login emails.
4. Optional: **an S3-compatible bucket** for backups (Backblaze B2, Cloudflare
   R2, Hetzner Object Storage, …).

Locally: Ansible with `community.general`, `cloudflared`, opencode at
`~/.opencode/bin/opencode`, and the vault password in `~/.config/ansible/vault-pass`.

## First setup

1. Make the tunnel, on this computer:
   ```
   cloudflared tunnel login
   cloudflared tunnel create burrow          # prints its id, writes ~/.cloudflared/<id>.json
   cloudflared tunnel route dns burrow example.com
   cloudflared tunnel route dns burrow '*.example.com'
   ```
2. Resend: Domains → Add domain → put the DNS records it shows into Cloudflare
   → Verify. Then API Keys → Create API key, permission "Sending access", that
   domain.
3. The vault: `ansible-vault create group_vars/all/vault.yml`, with the keys in
   `group_vars/all/vault.yml.example`.
4. Fill in `inventory.yml` (the VM's IP) and `group_vars/all/vars.yml`
   (`burrow_domain`, `burrow_mail_from`, `burrow_tunnel_id`).
5. `make check`, then `make apply`. The first run takes about 15 minutes
   (Burrow's build and the sandbox image).
6. Open https://example.com and sign up. The first account is the admin;
   after it, sign-ups are closed unless `burrow_sign_ups: open`.

## Deploying Burrow

Push to GitHub, then `make deploy`: it checks out `burrow_version`, builds
when the commit changed, and restarts Burrow. Open chats' agents stop and
start again when a chat opens; projects' staging and prod keep running.

## Backups

Set `backup_restic_repository` and the backup keys in the vault, then
`make apply TAGS=backup`. Every night at 03:30 it copies each SQLite database
(Burrow's and every app's) consistently, then backs up `/var/lib/burrow`
without caches and build output. Run one now: `systemctl start burrow-backup`.

To restore, on the VM:
```
set -a; . /etc/burrow/restic.env; set +a
restic snapshots
restic restore latest --target /restore
```
`/restore/var/lib/burrow` holds the files and `/restore/var/lib/burrow-backup`
the databases, at the same paths.

Tags for `make check|apply TAGS=…`: base docker sandbox burrow tunnel backup.
