#!/usr/bin/env python3
"""VERSION files own versions; Git tags only record validated releases."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
PRODUCTS = {
    "noodle": ("VERSION", "CHANGELOG.md", "v"),
    "computer": ("Computer/VERSION", "Computer/CHANGELOG.md", "computer-v"),
    "images": ("Computer/Images/VERSION", "Computer/Images/CHANGELOG.md", "computer-images-v"),
}
SEMVER = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def version(product):
    path, _, prefix = PRODUCTS[product]
    value = (ROOT / path).read_text().strip()
    if not re.fullmatch(SEMVER, value):
        raise ValueError(f"Invalid version in {path}: {value!r}")
    return value, prefix + value


def number(value):
    return tuple(map(int, value.split(".")))


def notes(product):
    value, _ = version(product)
    path = PRODUCTS[product][1]
    text = (ROOT / path).read_text()
    header = re.search(rf"^## \[{re.escape(value)}\] - (\d{{4}}-\d{{2}}-\d{{2}})$", text, re.M)
    if not header:
        raise ValueError(f"{path} needs a dated section for {value}")
    datetime.date.fromisoformat(header[1])
    body = re.split(r"^## ", text[header.end():], maxsplit=1, flags=re.M)[0].strip()
    if not body or not re.search(r"^[-*] \S", body, re.M):
        raise ValueError(f"{path} has no release notes for {value}")
    return body + "\n"


def released_versions(product):
    prefix = PRODUCTS[product][2]
    return [tag[len(prefix):] for tag in git("tag", "--list", prefix + "*").splitlines()
            if re.fullmatch(re.escape(prefix) + SEMVER, tag)]


def plan():
    selected = []
    for product in PRODUCTS:
        value, _ = version(product)
        previous = released_versions(product)
        if previous and number(value) < max(map(number, previous)):
            raise ValueError(f"{product}: VERSION would roll back a released version")
        if value not in previous:
            notes(product)
            selected.append(product)
    return selected


def mint(selected):
    if not selected or len(set(selected)) != len(selected) or any(p not in PRODUCTS for p in selected):
        raise ValueError("Expected a nonempty list of distinct products")
    if git("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Refusing to tag modified tracked files")
    head = git("rev-parse", "HEAD")
    tags = []
    # Validate every product before creating any tag. A retry may find this same
    # commit already tagged, but may never move an existing release tag.
    for product in selected:
        value, tag = version(product)
        notes(product)
        previous = released_versions(product)
        if previous and number(value) < max(map(number, previous)):
            raise ValueError(f"{product}: refusing release rollback")
        if value in previous and git("rev-parse", f"refs/tags/{tag}^{{commit}}") != head:
            raise ValueError(f"{tag} already identifies another commit")
        tags.append((tag, value in previous))
    for tag, exists in tags:
        if not exists:
            git("-c", "user.name=github-actions[bot]", "-c",
                "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "tag", "-a", tag, "-m", tag, head)
    # A rejected ref prevents all tags from being pushed, including races.
    git("push", "--atomic", "origin", *[f"refs/tags/{tag}" for tag, _ in tags])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["plan", "tag", "notes"])
    parser.add_argument("product", nargs="?", choices=PRODUCTS)
    args = parser.parse_args()
    if args.command == "plan":
        selected = plan()
        outputs = {p: str(p in selected).lower() for p in PRODUCTS}
        outputs.update(any=str(bool(selected)).lower(), products=json.dumps(selected))
        output = "".join(f"{key}={value}\n" for key, value in outputs.items())
        print(output, end="")
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as file:
                file.write(output)
    elif args.command == "tag":
        mint(json.loads(os.environ["RELEASE_PRODUCTS"]))
    else:
        if not args.product:
            parser.error("notes requires a product")
        print(notes(args.product), end="")


if __name__ == "__main__":
    main()
