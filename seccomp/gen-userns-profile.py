#!/usr/bin/env python3
"""Generate `userns.json`: Docker's default seccomp profile + the minimum
needed for an UNPRIVILEGED user namespace, so bubblewrap (and therefore the
Codex CLI's own `--sandbox` modes) can build a sandbox inside the container.

Why this exists
---------------
The container runs with every capability dropped (`CapEff: 0000...0`). Docker's
default seccomp profile gates the namespace syscalls behind CAP_SYS_ADMIN, so
`unshare(CLONE_NEWUSER)` returns EPERM and bwrap dies with:

    bwrap: No permissions to create a new namespace, likely because the kernel
    does not allow non-privileged user namespaces.

Codex's sandbox fails CLOSED when that happens -- nothing executes at all, not
even writes inside the workspace -- so the practical choice without this
profile is `danger-full-access` or nothing.

What it does NOT do
-------------------
This does not grant the container any access to the host. It lets an
unprivileged process inside the container build a *nested* sandbox for itself.
It is a different lever entirely from bind-mounting the host Docker socket,
which would be host root.

The honest cost
---------------
User namespaces widen the kernel attack surface reachable from inside the
container: code paths that normally require capabilities become reachable by an
unprivileged process holding caps in its own new namespace. That is a real
tradeoff, not a free win. It is accepted here deliberately, in exchange for
confining the agent that runs untrusted-ish model output. The other 420+
syscall rules in the default profile stay enforced.

Usage
-----
    python3 gen-userns-profile.py          # writes userns.json next to this file
    python3 gen-userns-profile.py --check  # verify userns.json matches (CI)
"""

import argparse
import json
import pathlib
import sys
import urllib.request

# Pinned so the generated profile is reproducible. Bump deliberately, re-run,
# and review the diff -- do not float this to a branch name.
MOBY_VERSION = "v27.3.1"
DEFAULT_URL = (
    f"https://raw.githubusercontent.com/moby/moby/{MOBY_VERSION}"
    "/profiles/seccomp/default.json"
)

# bwrap builds its sandbox with the classic mount API: unshare into fresh
# user+mount namespaces, bind-mount the allowed paths, pivot_root onto the new
# root, then unmount the old one. Each of these lives only in the default
# profile's CAP_SYS_ADMIN group, which does not apply to us.
USERNS_SYSCALLS = ["unshare", "mount", "umount2", "pivot_root"]

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "userns.json"


def build() -> dict:
    with urllib.request.urlopen(DEFAULT_URL, timeout=30) as resp:
        profile = json.load(resp)

    if profile.get("defaultAction") != "SCMP_ACT_ERRNO":
        raise SystemExit(
            f"unexpected defaultAction {profile.get('defaultAction')!r} -- "
            "upstream profile changed shape, review before regenerating"
        )

    # 1. Allow the namespace/mount syscalls bwrap needs WITHOUT CAP_SYS_ADMIN.
    #    Upstream already allows these when CAP_SYS_ADMIN is present; this adds
    #    the no-capability case rather than editing the existing rule, so the
    #    delta stays obvious to a reviewer.
    profile["syscalls"].append(
        {
            "names": USERNS_SYSCALLS,
            "action": "SCMP_ACT_ALLOW",
            "comment": (
                "lattisone: unprivileged user namespaces for bubblewrap, so the "
                "Codex CLI can sandbox its own shell commands"
            ),
            "excludes": {"caps": ["CAP_SYS_ADMIN"]},
        }
    )

    # 2. Drop the namespace-flag mask on the non-CAP_SYS_ADMIN `clone` rule.
    #    Upstream restricts it to `(flags & 0x7E020000) == 0`, i.e. clone may not
    #    create ANY new namespace. bwrap needs at least CLONE_NEWUSER|CLONE_NEWNS.
    #    Removing `args` allows the namespace flags; the rule's other guards stay.
    patched = 0
    for rule in profile["syscalls"]:
        if (
            rule.get("names") == ["clone"]
            and rule.get("action") == "SCMP_ACT_ALLOW"
            and "CAP_SYS_ADMIN" in rule.get("excludes", {}).get("caps", [])
            and rule.get("args")
        ):
            rule.pop("args")
            rule["comment"] = (
                "lattisone: namespace-flag mask removed so clone() may create "
                "user/mount namespaces without CAP_SYS_ADMIN"
            )
            patched += 1

    if patched == 0:
        raise SystemExit(
            "found no non-CAP_SYS_ADMIN clone rule to patch -- upstream profile "
            "changed shape, review before regenerating"
        )

    # NOTE: `clone3` is left denied (SCMP_ACT_ERRNO) exactly as upstream has it.
    # That is deliberate: glibc probes clone3, takes the ENOSYS/EPERM answer, and
    # falls back to clone. Allowing it is not needed for bwrap.
    return profile


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if userns.json is stale instead of rewriting it",
    )
    args = ap.parse_args()

    rendered = json.dumps(build(), indent=2) + "\n"

    if args.check:
        if not OUT.exists():
            print(f"{OUT.name} missing", file=sys.stderr)
            return 1
        if OUT.read_text() != rendered:
            print(f"{OUT.name} is stale -- re-run {pathlib.Path(__file__).name}", file=sys.stderr)
            return 1
        print(f"{OUT.name} up to date")
        return 0

    OUT.write_text(rendered)
    print(f"wrote {OUT} ({len(rendered)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
