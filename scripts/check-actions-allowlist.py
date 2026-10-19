#!/usr/bin/env python3
"""Fail when a workflow uses an action the repository's Actions policy will refuse to start.

The repository allows GitHub-owned actions plus an explicit list of SHA-pinned third-party actions.
A pin outside that list does not fail a check: GitHub refuses to start the workflow at all
(`startup_failure`), so no check run is created, every visible check stays green, and a required
check simply never reports. That is how a Dependabot bump of ossf/scorecard-action reached a PR
looking green while the merge stayed blocked. Run before pushing, where it can still be fixed.

The policy is read live with `gh api` because it lives in repository settings, not in the tree.
Reading it needs admin access, which CI's token does not have, so without `gh` or that access this
prints a warning and exits 0 rather than failing every non-admin checkout.

Usage: scripts/check-actions-allowlist.py [--policy FILE]
  --policy FILE  read {"allowed_actions", "sha_pinning_required", "github_owned_allowed",
                 "patterns_allowed"} from FILE instead of the API (used by the self-test).
"""

from fnmatch import fnmatchcase
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
USES = re.compile(r"^\s*-?\s*uses:\s*['\"]?([^\s'\"#]+)")
SHA = re.compile(r"^[0-9a-f]{40}$")
GITHUB_OWNED = ("actions/", "github/")


def workflow_uses():
    files = sorted((ROOT / ".github/workflows").glob("*.y*ml"))
    files += sorted((ROOT / ".github/actions").glob("**/action.y*ml"))
    for path in files:
        for number, line in enumerate(path.read_text().splitlines(), 1):
            match = USES.match(line)
            if match and not match[1].startswith(("./", "docker://")):
                yield path.relative_to(ROOT), number, match[1]


def gh_json(endpoint):
    result = subprocess.run(["gh", "api", endpoint], capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"gh api {endpoint} failed")
    return json.loads(result.stdout)


def live_policy():
    remote = subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        capture_output=True, text=True, timeout=60, cwd=ROOT,
    )
    if remote.returncode != 0:
        raise RuntimeError(remote.stderr.strip() or "cannot resolve the GitHub repository")
    repo = remote.stdout.strip()
    policy = gh_json(f"repos/{repo}/actions/permissions")
    if policy.get("allowed_actions") == "selected":
        policy.update(gh_json(f"repos/{repo}/actions/permissions/selected-actions"))
    return policy


def violations(policy, uses):
    allowed = policy.get("allowed_actions", "all")
    patterns = policy.get("patterns_allowed", [])
    for path, number, action in uses:
        name, _, ref = action.partition("@")
        if policy.get("sha_pinning_required") and not SHA.match(ref):
            yield f"{path}:{number}: {action} is not pinned to a full commit SHA"
        if allowed == "all":
            continue
        if allowed == "local_only":
            yield f"{path}:{number}: {action} — only local actions are allowed"
        elif not (
            (policy.get("github_owned_allowed") and name.startswith(GITHUB_OWNED))
            or any(fnmatchcase(action, pattern) for pattern in patterns)
        ):
            yield f"{path}:{number}: {action} is not in the repository's allowed-actions list"


def main(argv):
    if len(argv) == 2 and argv[0] == "--policy":
        policy = json.loads(Path(argv[1]).read_text())
    elif argv:
        raise SystemExit(__doc__)
    else:
        try:
            policy = live_policy()
        except (OSError, RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
            print(f"WARNING: Actions allowlist not checked ({error}); PR CI cannot check it either.",
                  file=sys.stderr)
            return 0
    found = list(violations(policy, list(workflow_uses())))
    if found:
        print("GitHub will refuse to start these workflows (startup_failure, no check run):",
              file=sys.stderr)
        for line in found:
            print(f"  {line}", file=sys.stderr)
        print("Update the pin, or the allowlist in Settings → Actions, before pushing.",
              file=sys.stderr)
        return 1
    print("Every workflow action is allowed by the repository's Actions policy.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
