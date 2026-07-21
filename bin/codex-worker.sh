#!/usr/bin/env bash
# codex-worker — run an OpenAI Codex worker in a disposable sibling container.
#
# Usage: codex-worker.sh <workdir> "<task prompt>" [extra codex exec flags]
#   e.g. codex-worker.sh /projects/myapp "Review src/parser" -m gpt-5.6-sol
#
# Supervisor model: the claude-code container (Fable) is the sole holder of
# SSH / GitHub / .env secrets and the docker socket. Workers get exactly two
# mounts — the codex-auth volume and the task's project dir — and are never
# told credentials exist. The container boundary is the sandbox; Codex's own
# bwrap sandbox cannot initialize here (no unprivileged userns), so inside the
# worker Codex runs with danger-full-access, which reaches only these mounts.
#
# Env knobs:
#   CODEX_WORKER_IMAGE    image to run (default: claude-code-dockerized-claude:latest)
#   CODEX_AUTH_VOLUME     volume holding ChatGPT login (default: codex-auth)
#   CODEX_WORKER_NETWORK  docker network; set claude-code-dockerized_default to
#                         reach dev services (default: bridge)
#   PROJECTS_HOST_ROOT    host path bound at /projects (else derived via
#                         docker inspect of this container's own mounts)
set -euo pipefail

IMAGE="${CODEX_WORKER_IMAGE:-claude-code-dockerized-claude:latest}"
AUTH_VOLUME="${CODEX_AUTH_VOLUME:-codex-auth}"
NETWORK="${CODEX_WORKER_NETWORK:-bridge}"

if [ $# -lt 2 ]; then
  echo "usage: codex-worker.sh <workdir> <prompt> [codex exec flags...]" >&2
  exit 2
fi

workdir="$(cd "$1" && pwd)"
prompt="$2"
shift 2

# The docker socket talks to the HOST daemon, so every bind source must be a
# host path. Translate this container's view (/projects/...) to the host's.
to_host_path() {
  local p="$1"
  if [ -n "${PROJECTS_HOST_ROOT:-}" ] && [ "${p#/projects}" != "$p" ]; then
    printf '%s%s\n' "$PROJECTS_HOST_ROOT" "${p#/projects}"
    return
  fi
  docker inspect "$(hostname)" \
    --format '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' 2>/dev/null |
    awk -v p="$p" -F'|' '
      $2 != "" && index(p, $2) == 1 && length($2) > best {
        best = length($2); src = $1; dst = $2
      }
      END {
        if (best) { printf "%s%s\n", src, substr(p, length(dst) + 1) }
        else { exit 1 }
      }'
}

host_workdir="$(to_host_path "$workdir")" || {
  echo "codex-worker: cannot map ${workdir} to a host path (set PROJECTS_HOST_ROOT)" >&2
  exit 1
}

# Mount the workdir at the SAME absolute path the supervisor sees, so git
# metadata, module paths, and the preamble all agree.
mounts=(-v "${AUTH_VOLUME}:/home/node/.codex" -v "${host_workdir}:${workdir}")

# Git worktrees keep a `.git` FILE pointing into the main repo — mount the
# main repo too (read-write: git status/diff need its object store) or git
# inside the worker is dead on arrival.
if [ -f "${workdir}/.git" ]; then
  gitdir="$(sed -n 's/^gitdir: //p' "${workdir}/.git")"
  main_repo="$(cd "${gitdir%/.git/worktrees/*}" && pwd)"
  if [ -n "$main_repo" ] && [ "$main_repo" != "$workdir" ]; then
    host_main="$(to_host_path "$main_repo")" || {
      echo "codex-worker: cannot map worktree main repo ${main_repo}" >&2
      exit 1
    }
    mounts+=(-v "${host_main}:${main_repo}")
  fi
fi

preamble="You are a worker agent operating under a supervisor. Standing rules:
- Work ONLY inside ${workdir}.
- Never run git push, git commit, gh, ssh, scp, or rsync, and never contact remote servers unless the task explicitly says otherwise.
- Leave code changes as uncommitted working-tree edits for the supervisor to review.
- Your final message is machine-consumed by the supervisor: report exactly what you changed or found as plain factual output (files touched, findings, commands run). No pleasantries, no questions.

TASK:
${prompt}"

exec docker run --rm \
  --name "codex-worker-$$-${RANDOM}" \
  --security-opt no-new-privileges:true \
  --network "$NETWORK" \
  -e CODEX_HOME=/home/node/.codex \
  "${mounts[@]}" \
  -w "$workdir" \
  --entrypoint codex \
  "$IMAGE" \
  exec --skip-git-repo-check "$@" "$preamble"
