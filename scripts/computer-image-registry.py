#!/usr/bin/env python3
"""Verify public GHCR images without using the publisher's credentials."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


class Registry:
    def __init__(self, kind):
        self.repo = f"pdparchitect/noodle-computer-{kind}-image"
        query = urlencode({"service": "ghcr.io", "scope": f"repository:{self.repo}:pull"})
        # This is an anonymous, pull-only registry token, never a saved login.
        with urlopen(f"https://ghcr.io/token?{query}", timeout=60) as response:
            self.token = json.load(response)["token"]

    def get(self, path, missing_ok=False):
        request = Request(f"https://ghcr.io/v2/{self.repo}/{path}", headers={
            "Authorization": "Bearer " + self.token, "Accept": ACCEPT})
        try:
            with urlopen(request, timeout=60) as response:
                data = response.read()
        except HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            raise
        return json.loads(data), "sha256:" + hashlib.sha256(data).hexdigest()

    def image(self, reference, missing_ok=False):
        result = self.get("manifests/" + reference, missing_ok)
        if result is None:
            return None
        manifest, digest = result
        if "manifests" in manifest:
            arm = [m for m in manifest["manifests"]
                   if m.get("platform", {}).get("os") == "linux"
                   and m.get("platform", {}).get("architecture") == "arm64"]
            if len(arm) != 1:
                raise ValueError(f"{self.repo}:{reference} needs one Linux ARM64 image")
            manifest, _ = self.get("manifests/" + arm[0]["digest"])
        config_digest = manifest["config"]["digest"]
        config, actual_config_digest = self.get("blobs/" + config_digest)
        if config_digest != actual_config_digest:
            raise ValueError("Registry config checksum mismatch")
        if (config.get("os"), config.get("architecture")) != ("linux", "arm64"):
            raise ValueError("Expected a Linux ARM64 image")
        return digest, config_digest, config["config"].get("Labels", {})


def verify_labels(labels, version, revision=None):
    if labels.get("org.opencontainers.image.version") != version:
        raise ValueError("Image version does not match Computer/Images/VERSION")
    if revision and labels.get("org.opencontainers.image.revision") != revision:
        raise ValueError("Image does not come from the checked source revision")


def main():
    command = sys.argv[1]
    if command not in ("preflight", "verify", "channel"):
        raise ValueError("Expected preflight, verify or channel")
    version = (ROOT / "Computer/Images/VERSION").read_text().strip()
    for kind in ("shell", "desktop"):
        registry = Registry(kind)
        published = registry.image(version, missing_ok=command == "preflight")
        if command == "preflight":
            local = json.loads(subprocess.check_output([
                "docker", "image", "inspect", f"noodle-computer-{kind}-image:check"], text=True))[0]
            verify_labels(local["Config"]["Labels"], version, os.environ["GITHUB_SHA"])
            if published and published[1] != local["Id"]:
                raise ValueError(f"Refusing to overwrite {kind}:{version} with a different image")
            latest = registry.image("latest", missing_ok=True)
            if latest:
                previous = latest[2]["org.opencontainers.image.version"]
                if tuple(map(int, previous.split("."))) > tuple(map(int, version.split("."))):
                    raise ValueError("Refusing to roll back the image channel")
        else:
            verify_labels(published[2], version,
                          os.environ["GITHUB_SHA"] if command == "verify" else None)
            latest = registry.image("latest")
            if latest[0] != published[0]:
                raise ValueError(f"{kind}:latest does not match {kind}:{version}")
            print(f"{kind}=ghcr.io/{registry.repo}@{published[0]}")


if __name__ == "__main__":
    main()
