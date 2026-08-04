# ssh/ — host SSH config and keys for the container

Everything in this directory except this README is **gitignored** and excluded
from the Docker build context (`.dockerignore`), so files dropped here cannot be
committed to GitHub or baked into an image.

The directory is bind-mounted read-only at `/home/node/host-ssh`, and on every
container start `entrypoint.sh` copies its contents into `~/.ssh` inside the
container. Copying (rather than mounting into `~/.ssh` directly) is deliberate:
bind mounts preserve host permissions, and ssh refuses keys that are group- or
world-readable — the copies get correct permissions (private keys `600`,
`*.pub` `644`).

What you can drop here:

- `config` — a standard ssh_config file. It is `Include`d *ahead of* the
  container's built-in defaults, so your per-host settings win. Reference keys
  by their in-container path, e.g. `IdentityFile ~/.ssh/id_work`.
- Private keys and `.pub` files — copied to `~/.ssh/<filename>`. Each private
  key is also appended as an `IdentityFile` fallback in the default config, so
  a bare key works even without a `config` file.
- `known_hosts` — entries are merged into the container's persisted
  `known_hosts`.

Changes take effect on the next container start
(`docker compose restart claude`).
