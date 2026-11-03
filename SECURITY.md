# Security model

This image runs autonomous coding agents (Claude Code, and the Codex/Gemini
CLIs it drives) that **execute model-generated commands without an in-container
approval prompt** — `bypassPermissions` for Claude Code, `approval_policy =
"never"` / `sandbox_mode = "danger-full-access"` for Codex. That is deliberate:
**the container itself is the trust boundary**, not the agent. Everything below
follows from that one decision.

> The single most important rule: **the agent can read every secret it is able
> to use.** No in-container trick changes that. Real protection comes from
> limiting what each credential can do *at the service that issued it* — scopes,
> permissions, expiry, and spend caps. Container hardening only limits
> *accidental* leakage and shrinks the host blast radius. Do both; rely on the
> service-side half.

---

## 1. Control access in the token/key service — do this first

In-container storage (env var, file, `gh` store, secret mount) only changes *who
incidentally sees* a credential. It does **not** change what a stolen credential
can do. That is set entirely on the issuing service, so scope everything there to
the minimum.

### GitHub tokens

- **Use fine-grained PATs, not classic tokens.** Classic PATs with `repo` grant
  every repo you can touch, forever. A fine-grained PAT is scoped to **specific
  repositories** with **per-permission** access (e.g. Contents: read/write,
  Pull requests: read/write — and nothing else).
  Create at: <https://github.com/settings/personal-access-tokens>
- **One token per GitHub account/org**, each scoped only to the repos that
  account actually works on. This repo's convention gives each its own
  credential (see §3), so a leak of one never exposes the others.
- **Set a short expiry** (7–30 days). This is the cap on the damage window; the
  container cannot provide that for you.
- **Grant the least permission that works.** Most agent work needs only
  Contents + Pull requests on a handful of repos. Avoid Administration,
  org-wide, and delete permissions unless a task truly needs them.
- **Revoke, don't just rotate, on suspicion.** Delete the PAT at GitHub; any copy
  anywhere dies instantly.

### Anthropic / OpenAI / Google API keys

These must be present as environment variables for the CLIs to work, so the
agent can always read them. Contain them at the provider:

- **Per-key spend limits / budgets.** Anthropic and OpenAI both support
  per-key usage limits — set a monthly cap so a leaked or runaway key can't bill
  unbounded. This is the main blast-radius control for API keys.
- **A dedicated key per environment**, named so it's obvious in the dashboard
  (e.g. `claude-code-docker`). Never reuse a production-app key here.
- **Rotate on a schedule** and after any suspected exposure; delete the old key.
- **Scope/restrict where supported** (e.g. Google AI Studio key restrictions).

### SSH keys

- The container generates its **own** outbound key on first boot
  (`entrypoint.sh`) — your personal key is never copied in. Authorize that
  container key on remote hosts with the **least access** it needs (a deploy
  user, not root; `command="..."`/`restrict` in `authorized_keys` where
  possible).
- Host keys imported via the gitignored `./ssh` mount are your choice — prefer
  per-purpose keys over a master key.

---

## 2. What the container does and does not protect

### Enforced isolation (verified from inside the container)

| Control | State |
|---|---|
| Linux capabilities | all dropped (`CapEff=0000000000000000`) |
| `no_new_privileges` | on |
| seccomp | custom profile in filter mode (~420 rules; **not** `unconfined`) |
| Runs as | non-root `node` (uid 1000) |
| Host Docker socket | **not** mounted (mounting it would be host root) |
| Docker-in-Docker | isolated rootless sidecar, off by default, host-unreachable |

### The user-namespace tradeoff (this branch)

`seccomp/userns.json` deliberately re-allows unprivileged user namespaces so the
Codex CLI's own sandbox can initialize instead of failing closed. That widens the
kernel attack surface — historically a common escape origin. It is accepted on
purpose; see `seccomp/README.md` for the full rationale and delta.

Mitigating context on the typical dev setup here: under **Docker Desktop on
macOS/Windows**, "the host" an escape would reach is the disposable **LinuxKit
VM**, with the real OS behind the hypervisor. **If you deploy this image on a
bare-metal Linux host, that cushion is gone** and the userns surface matters
much more — reconsider the profile there.

### What it does **not** protect — the real exposure

Breaking *out* isn't required to reach what matters; it's already inside the box:

- **Writable host bind mounts.** `/projects` and `/workspace` are read-write
  mounts of host directories — the agent can read, change, or delete those files
  directly. **Mount read-only (`:ro`) anything the agent only needs to read**
  (the example override already does this for reference material). Mount only the
  trees a task needs.
- **Secrets in the environment** are readable by every child process and via
  `/proc/<pid>/environ`, and `environment:`/`env_file:` values also show up in
  `docker inspect`. See §3–4 for how this repo narrows that.
- **Network egress is unrestricted.** A leaked secret still has to leave the box
  to be abused or exfiltrated. An egress allowlist is the main defense against
  the agent-as-exfil-vector case (see §5).

---

## 3. How GitHub tokens are handled here

Declare one token per account in `.env` using the convention:

```dotenv
GH_TOKEN_<OWNER>=...        # OWNER = the github.com owner/org, UPPERCASED,
                            # with every non-alphanumeric turned into `_`
GH_TOKEN_EFFINA=github_pat_...
GH_TOKEN_ERIKCAINEOLSON=github_pat_...
# GH_TOKEN=...              # optional bare default/fallback account
# GH_OWNER_MAP=myorg=EFFINA,other=ERIKCAINEOLSON   # optional, only when a repo
                            # owner's name differs from its token's account key
```

On boot `entrypoint.sh`:

1. writes each token to a private `0600` file under `~/.config/gh-tokens`
   (not a persisted volume, not the environment), then
2. **unsets every `GH_TOKEN*` variable** so it is *not* inherited by Claude Code
   or anything it runs — no `env` dump, `/proc/<pid>/environ`, crash log, or
   `docker inspect` leaks it, and
3. wires routing by **repository owner**:
   - **git** uses a credential helper (`git-credential-ghmap`) that picks the
     token from the repo's owner automatically — `git push` in an `effina` repo
     uses the effina token with no extra step.
   - **`gh` CLI** is routed explicitly with `gh-for <owner> <args...>`
     (e.g. `gh-for effina pr create`). Bare `gh` uses the default account if a
     bare `GH_TOKEN` was set.

This means a single leaked token is **scoped to one account** (if you scoped it
per §1), and routine commands/logs don't carry any token at all. It does **not**
stop a command the agent deliberately runs from reading the token files — that's
what §1 (scoping) and §5 (egress) are for.

---

## 4. Narrowing API-key exposure (optional, staged)

The model CLIs need their keys as env vars, so the keys stay readable by the
agent regardless. The one concrete in-container win is keeping them out of
`docker inspect` / `docker compose config` by sourcing them from Docker
**secrets** (`/run/secrets/*`, tmpfs files) instead of `environment:`/`env_file:`,
and exporting them in the entrypoint only for the processes that need them.

This is **staged, not enabled**, because a misconfiguration would stop the agent
from starting and it can't be verified from inside the container. A commented
scaffold is in `docker-compose.yml`. Until then, the effective control for API
keys is the service-side scoping and spend caps in §1.

---

## 5. Recommended: restrict network egress

Unrestricted egress is what lets any stolen secret or compromised dependency
phone home. The robust pattern is an explicit **allowlist** (GitHub + the three
model-provider API endpoints + your own hosts) via an egress-proxy sidecar or a
host firewall rule, with the `claude` service otherwise on an `internal` network.

A complete, opt-in scaffold now ships in **`docker-compose.egress.yml`** +
**`egress/`**: it makes the compose network `internal` and routes all outbound
traffic through a Squid allowlist proxy (AI APIs, GitHub, package registries),
matching HTTPS by `CONNECT` host so TLS stays end-to-end (no interception).
Enable it by naming the overlay explicitly:

```bash
docker compose -f docker-compose.yml -f docker-compose.override.yml \
               -f docker-compose.egress.yml up -d --force-recreate
```

It is **not on by default** — a wrong allowlist silently breaks the agent's own
reach to the Anthropic API, so tune it from the proxy logs on the host. Full
instructions, verification, the outbound-SSH recipe, and troubleshooting are in
[`egress/README.md`](egress/README.md). This is the highest-value hardening step.

---

## 6. Verify the posture (run inside the container)

```bash
# Capabilities, no-new-privs, seccomp
grep -E 'CapEff|NoNewPrivs|Seccomp:' /proc/self/status
#   want: CapEff 0000000000000000 | NoNewPrivs 1 | Seccomp 2

# Host Docker socket must be absent
ls /var/run/docker.sock 2>&1    # -> No such file or directory

# GitHub tokens must NOT be in the environment after boot
env | grep -i gh_token          # -> (no output)

# Token routing works (after `docker compose up`)
GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/<owner>/<repo>.git >/dev/null && echo OK
gh-for <owner> auth status

# seccomp profile is in sync with its generator
python3 seccomp/gen-userns-profile.py --check
```

---

## 7. If a credential is exposed

1. **Revoke at the service immediately** — delete the PAT/API key in the
   provider dashboard. Revocation beats rotation; it kills every copy at once.
2. Issue a fresh, re-scoped credential and update `.env`.
3. `docker compose up -d --force-recreate claude` to reload.
4. For SSH: remove the container's public key from remote `authorized_keys` and
   let the entrypoint regenerate a new keypair.
5. Review what the credential could touch (its scopes/mounts) to size the
   incident.

---

## Status

The GitHub multi-account token handling (§3) is implemented and its routing
logic unit-tested, but — like the seccomp profile — has **not** been exercised in
a fully rebuilt container on a host (this container has no Docker access by
design). The API-key secrets migration (§4) is
documented and scaffolded (commented) but **not enabled**. The egress allowlist
(§5) is fully scaffolded in `docker-compose.egress.yml` + `egress/` but is
opt-in and **unverified on a host**. Verify §3 and tune/enable §5 on the host.
