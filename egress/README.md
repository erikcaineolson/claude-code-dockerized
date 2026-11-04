# Egress lockdown

Restricts the `claude` container's outbound network to an **allowlist**, so a
leaked credential or a compromised dependency can't exfiltrate to or call out to
an arbitrary host. This is the strongest control in this repo against the
"agent as exfiltration vector" problem — see [../SECURITY.md](../SECURITY.md) §5.

It is **opt-in** and lives in its own overlay so it never merges automatically.

## Files

| File | Role |
|---|---|
| `../docker-compose.egress.yml` | overlay: makes the network internal, adds the proxy |
| `squid.conf` | the allowlist policy (reviewable; core domains live here) |
| `allowed-domains.txt` | your extra allowed domains, one per line |
| `allowed-ssh-hosts.txt` | optional SSH destinations (see "Outbound SSH") |

## How it works

- The compose **default network is made `internal: true`** — nothing on it can
  reach the internet directly.
- A **Squid proxy sidecar** (`egress-proxy`) bridges the internal network and a
  separate `egress-allowed` network. It forwards only to allowlisted domains,
  matching HTTPS at the `CONNECT` stage — it sees the destination host but never
  decrypts the tunnel, so **traffic stays end-to-end encrypted and no custom CA
  is needed**.
- `claude` is pointed at the proxy via `HTTP(S)_PROXY`. Tools that honor it
  (Claude Code, `gh`, `git`, `curl`, `npm`, `pip`, `go`, Composer) route through
  it; anything that ignores it has no route out and **fails closed** — the safe
  default. The client never resolves external DNS itself (the proxy does), so
  DNS-based exfiltration is closed off too.

## Enable it

```bash
docker compose -f docker-compose.yml \
               -f docker-compose.override.yml \
               -f docker-compose.egress.yml up -d --force-recreate
```

Tip: make that an alias (e.g. `dce`) so you don't forget the overlay. If you
run plain `docker compose up`, the lockdown is simply not applied.

## Verify

```bash
A="docker compose -f docker-compose.yml -f docker-compose.override.yml -f docker-compose.egress.yml"

# Allowed host should succeed:
$A exec claude sh -c 'curl -sS -o /dev/null -w "anthropic: %{http_code}\n" https://api.anthropic.com/'

# A non-allowlisted host should be refused by the proxy (403 / connection fails):
$A exec claude sh -c 'curl -sS -o /dev/null -w "evil: %{http_code}\n" https://example.com/ || echo "evil: blocked"'

# Watch what the proxy allows/denies (this is how you find a domain to add):
$A logs -f egress-proxy
```

A `TCP_DENIED` line in the proxy log names the host that was blocked.

## Add a destination

Put the domain in `allowed-domains.txt` (one per line; a leading dot includes
subdomains), then reload the proxy:

```bash
$A up -d egress-proxy
```

The built-in allowlist in `squid.conf` already covers the Anthropic / OpenAI /
Google APIs, GitHub, and the common npm / PyPI / Composer / Go / Debian
registries. Add only what your workflow actually needs.

## Outbound SSH (optional)

SSH does not use an HTTP proxy, so under the lockdown direct `ssh` fails. To
allow SSH to **your own** hosts, tunnel it through the proxy's `CONNECT`:

1. Add each host to `allowed-ssh-hosts.txt` and reload the proxy.
2. Point the SSH client at the proxy. In the container's `~/.ssh/config` (or via
   the gitignored `./ssh/config` that the entrypoint imports):

   ```
   Host deploy.example.com
       ProxyCommand nc -X connect -x egress-proxy:3128 %h %p
   ```

   (`nc`/`socat` with CONNECT support must be available in the container.)

Leave this off unless you need it — fewer open paths is better.

## Troubleshooting

- **Claude Code can't start / "connection error".** The agent must reach
  `api.anthropic.com`. Confirm `.anthropic.com` is allowed (it is, in
  `squid.conf`) and check `docker logs egress-proxy` for a `TCP_DENIED` to an
  Anthropic subdomain, then add it.
- **A tool hangs instead of erroring.** It's probably attempting a direct
  connection the internal network silently drops. Either it doesn't honor
  `HTTPS_PROXY`, or its destination isn't allowlisted.
- **`dind` can't pull images.** The overlay gives `dind` the egress network so
  it can. If you removed that, pulls will fail by design.
- **Squid won't start.** Run `$A logs egress-proxy`; a config error names the
  line. If it complains about writing `/dev/stdout`, delete the `access_log`/
  `cache_log` lines in `squid.conf` and tail the in-container log file instead.

## Status

Scaffold is complete but **unverified on a host** (this container has no Docker
access by design). Treat the allowlist as a starting point and tune it from the
proxy logs on first run.
