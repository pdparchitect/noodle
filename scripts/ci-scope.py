#!/usr/bin/env python3
"""Choose the test suites a run of "Validate and release versions" needs.

A suite tests some Swift packages or Tuist projects. A change runs every suite whose packages contain
it or depend on a package that does, directly or through others, as the manifests declare. Changes to
CI itself, and anything this cannot place, run every suite, as do releases and manual runs.

A push to main that only lands a pull request whose last run passed CI runs none: that pull request
already ran them. Other pushes run what they change. A release pull request, changing only VERSION and
CHANGELOG.md files, runs none either: the release run on main tests everything before publishing. The
result is the JSON list `suites`: "checks" for the checks job and NAME for each test-NAME job.
"""
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent

# Suite: (packages or projects it tests, '' being the root package; other files its steps run).
SUITES = {
    "noodle": ([""], ["scripts/coverage-report.py"]),
    "shared": (["Shared/Wallpaper", "Shared/SettingsUI", "Shared/LaunchChecks", "Shared/HubLink", "Shared/Surface",
                "Shared/Brand", "Shared/ExternalTools", "Shared/Patch", "Push"], []),
    "noodle-macos27": (["", "Shared/SettingsUI"], ["scripts/build-mlx-metal.sh"]),
    "computer": (["Computer", "Computer/LocalMac"], []),
    "applet": (["Applet"], []),
    "applet-rendering": (["Applet"], ["scripts/install-tuist.sh"]),
    "bridge": (["Computer/Bridge"], []),
    "browser": (["Browser"], []),
    # The Hub builds on the root package, so whatever can affect the root package builds it too.
    "hub": (["Hub"], []),
    "mobile": (["Mobile"], ["scripts/mobile.sh", "scripts/install-tuist.sh", "scripts/build-priority.sh"]),
}
EVERYTHING = ["checks", *SUITES]
# The same files the workflow's trigger leaves out: they never start a run, so they never widen one.
IGNORED = ["**.md", "docs/**", "website/**", "Scenarios/**", ".github/workflows/website.yml"]
# The workflows, their own tests and the release scripts can break any suite or the release itself.
EVERYWHERE = [".github/", "Tests/ReleaseAutomation/", "Tests/CoverageReporting/", "scripts/"]
# Folders no suite builds: their own workflows test them (embed.yml for the Embed Worker), so here they
# need only the checks.
SEPARATE = ["Embed/"]
# What the root package owns outside the other packages. Anything else at the top runs every suite.
ROOT_FILES = ["Sources/", "Tests/", "Tools/", "Support/", "Package.swift", "Package.resolved", "Project.swift",
              "Tuist.swift", "VERSION"]


def git(*args, root=ROOT):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def normalize(base, relative):
    parts = []
    for part in (base + "/" + relative).split("/"):
        if part == "..":
            if parts:
                parts.pop()
        elif part not in ("", "."):
            parts.append(part)
    return "/".join(parts)


def graph(root=ROOT):
    """Each package or project directory: (the packages it uses, other paths outside it that it builds)."""
    manifests = {}
    for manifest in git("ls-files", "--", "Package.swift", "*/Package.swift", "Project.swift", "*/Project.swift",
                        root=root).splitlines():
        text = (root / manifest).read_text()
        # A source file may share a manifest's name, as Applet's AppletCore/Package.swift does.
        if re.search(r"^import (PackageDescription|ProjectDescription)$", text, re.M):
            parent = str(Path(manifest).parent)
            manifests.setdefault("" if parent == "." else parent, []).append(text)
    nodes = {}
    for base, texts in manifests.items():
        packages, paths = nodes.setdefault(base, (set(), set()))
        for text in texts:
            for path in re.findall(r'\.(?:package|local)\(path:\s*"([^"]+)"', text):
                packages.add(normalize(base, path))
            # Files a project takes from outside its folder, such as the phone app's voice previews.
            for path in re.findall(r"\.\./[\w./-]+", text):
                path = normalize(base, path)
                if path not in manifests:
                    paths.add(path)
    return nodes


def closure(roots, nodes):
    seen, pending = set(), list(roots)
    while pending:
        node = pending.pop()
        if node not in seen:
            seen.add(node)
            pending.extend(nodes.get(node, (set(), set()))[0])
    return seen


def inside(path, directory):
    return directory == "" or path == directory or path.startswith(directory + "/")


def affected(paths, nodes=None):
    """The suites a set of changed paths needs, in workflow order."""
    nodes = graph() if nodes is None else nodes
    selected = {"checks"}
    for path in paths:
        if any(fnmatch.fnmatchcase(path, pattern) for pattern in IGNORED):
            continue
        extra = {suite for suite, (_, files) in SUITES.items() if path in files}
        if extra:
            selected |= extra
            continue
        if any(path.startswith(prefix) for prefix in EVERYWHERE):
            return list(EVERYTHING)
        if any(path.startswith(prefix) for prefix in SEPARATE):
            continue
        owners = {node for node in nodes if node and inside(path, node)}
        if not owners:
            if not any(path == prefix or path.startswith(prefix) for prefix in ROOT_FILES):
                return list(EVERYTHING)
            owners = {""}
        owners |= {node for node, (_, built) in nodes.items() if any(inside(path, other) for other in built)}
        selected |= {suite for suite, (roots, _) in SUITES.items() if owners & closure(roots, nodes)}
    return [suite for suite in EVERYTHING if suite in selected]


def changed(base, head="HEAD", root=ROOT):
    # Without rename pairing, a moved file counts where it left as well as where it arrived.
    return git("diff", "--name-only", "--no-renames", base, head, root=root).splitlines()


def resolves(revision, root=ROOT):
    try:
        return subprocess.run(["git", "rev-parse", "--verify", "--quiet", revision + "^{commit}"], cwd=root,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        return False


def gh(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def tested_merge(repository, sha, before, root=ROOT):
    """Whether this push only lands one pull request, merged or squashed, whose last CI run passed."""
    try:
        # Exactly one new commit on main, so nothing else rides along with the pull request.
        if not resolves(before, root) or not resolves("HEAD^1", root) or git("rev-parse", "HEAD^1", root=root) != git(
                "rev-parse", before + "^{commit}", root=root) or git("rev-parse", "HEAD", root=root) != sha:
            return False
        def landing(pulls):
            return [pull for pull in pulls if pull.get("merged_at") and pull.get("merge_commit_sha") == sha
                    and pull["base"]["ref"] == "main"]
        # GitHub links a commit to its pull request some time after the merge, or never, as it never did
        # for #142's: then the pull requests most recently closed on main show which one made this commit.
        pulls = landing(gh(f"repos/{repository}/commits/{sha}/pulls")) or landing(
            gh(f"repos/{repository}/pulls?state=closed&base=main&sort=updated&direction=desc&per_page=100"))
        if len(pulls) != 1:
            return False
        head = pulls[0]["head"]["sha"]
        runs = gh(f"repos/{repository}/commits/{head}/check-runs?check_name=CI%20passed&filter=latest")["check_runs"]
        runs = [run for run in runs if run.get("app", {}).get("slug") == "github-actions"]
        latest = max(runs, key=lambda run: run.get("started_at") or "", default=None)
        return bool(latest) and latest.get("status") == "completed" and latest.get("conclusion") == "success"
    except (subprocess.CalledProcessError, OSError, ValueError, KeyError, TypeError):
        return False


def release_only(paths):
    """Whether a change only sets versions and their release notes, as a release pull request does."""
    return bool(paths) and all(path.rsplit("/", 1)[-1] in ("VERSION", "CHANGELOG.md") for path in paths)


def scope(environment, root=ROOT):
    event = environment.get("GITHUB_EVENT_NAME", "")
    merged = event == "pull_request" and resolves("HEAD^2", root)
    # A release pull request: the versions job has checked its notes, and the release run on main
    # tests everything before anything is published.
    if merged and release_only(changed("HEAD^1", root=root)):
        return [], "a release pull request: the release run on main tests every suite before publishing"
    if environment.get("RELEASE") == "true":
        return list(EVERYTHING), "a release is being validated: every suite runs"
    if event == "pull_request":
        if not merged:
            return list(EVERYTHING), "the pull request's merge commit is missing: every suite runs"
        return affected(changed("HEAD^1", root=root), graph(root)), "the pull request's changes"
    if event == "push":
        before = environment.get("BEFORE", "")
        if not before.strip("0") or not resolves(before, root):
            return list(EVERYTHING), "the previous commit is unknown: every suite runs"
        if tested_merge(environment.get("GITHUB_REPOSITORY", ""), environment.get("GITHUB_SHA", ""), before, root):
            return [], "this merges a pull request that passed CI: no suite runs again"
        return affected(changed(before, root=root), graph(root)), "the pushed changes"
    return list(EVERYTHING), f"{event or 'this'} runs: every suite runs"


def main():
    suites, reason = scope(os.environ)
    output = f"suites={json.dumps(suites)}\n"
    print(output + reason)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as file:
            file.write(output)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as file:
            file.write(f"Test suites: {', '.join(suites) or 'none'} ({reason}).\n")


if __name__ == "__main__":
    main()
