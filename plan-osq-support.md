# Plan: OffSiteQuotes support in the claude-code container

Source of requirements: `/projects/necessary-support-osq.md` (2026-07-08).
Blueprint: same pattern as the lattis support work already on this branch —
bake tooling into the Dockerfile, wire services/env through docker-compose.

## Changes

1. **Dockerfile** — add PHP 8.4 CLI + extensions via the Sury Debian repo
   (`ARG PHP_VERSION=8.4`), plus Composer 2.x into `/usr/local/bin`.
   Extensions: mysql (pdo_mysql), gd, zip, intl, bcmath, redis (phpredis),
   mbstring, xml, curl, sqlite3. exif/ctype/fileinfo/tokenizer/pdo ship inside
   php8.4-cli/common — no separate packages.
2. **docker-compose.yml** — add sibling services on the project's default
   network (no manual `docker network create` needed):
   - `dev-mariadb` (mariadb:10.11, arm64 OK) with `osq-mariadb-data` volume,
     creds from `.env` with dev defaults, healthcheck.
   - `dev-mariadb-init` — one-shot idempotent sidecar that creates the empty
     `testing` database (phpunit.xml sets `DB_DATABASE=testing`) and grants the
     app user on it. Runs after mariadb is healthy, then exits.
   - `dev-redis` (redis:alpine). No seeding needed.
3. **.env.example** — document `MARIADB_ROOT_PASSWORD`, `MARIADB_DATABASE`,
   `MARIADB_USER`, `MARIADB_PASSWORD` (all optional, dev defaults in compose).
4. **README.md** — short section on the PHP toolchain + OSQ dev services.
5. **necessary-support-osq.md** — mark §1–§4 addressed, note rebuild step.

## Verification

- Test-build just the PHP layer in a scratch image (validates Sury package
  names on arm64) and check `php -m` covers the required extensions.
- `docker compose config` to validate the compose file.
- `docker compose up -d dev-mariadb dev-redis` from inside this container
  (docker socket is shared) so the services are live *now*; confirm the
  `testing` DB exists and hostnames resolve from `claude-code`.

## Caveat

PHP/Composer land in the **image**, so the running `claude-code` container
won't have them until the user rebuilds from the host:
`docker compose build && docker compose up -d` (recreates this container).
The DB/Redis siblings work immediately — no rebuild needed for them.
