#!/usr/bin/env python3
"""Preserve required migration releases and gate their successors before signing."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")
RELEASES = "https://github.com/pdparchitect/noodle/releases/download"


def number(version):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Expected a semantic version: " + version)
    return tuple(map(int, version.split(".")))


def item_version(item):
    value = item.findtext(f"{{{SPARKLE}}}version")
    enclosure = item.find("enclosure")
    if value is None and enclosure is not None:
        value = enclosure.get(f"{{{SPARKLE}}}version")
    if not value:
        raise ValueError("Update item has no bundle version")
    number(value)
    return value


def prepare(feed, version, milestones, fetch_verified):
    """fetch_verified returns bytes only AFTER their embedded signature verifies."""
    number(version)
    if milestones != sorted(set(milestones), key=number):
        raise ValueError("Milestones must be unique and in ascending version order")
    required = [v for v in milestones if number(v) < number(version)]
    tree = ET.fromstring(feed)
    channel = tree.find("channel")
    if channel is None:
        raise ValueError("Appcast has no channel")
    items = channel.findall("item")
    if len(items) != 1 or item_version(items[0]) != version:
        raise ValueError("Expected the freshly generated feed for this release only")
    current = items[0]
    if required:
        minimum = current.find(f"{{{SPARKLE}}}minimumUpdateVersion")
        if minimum is None:
            minimum = ET.SubElement(current, f"{{{SPARKLE}}}minimumUpdateVersion")
        minimum.text = required[-1]
    for index in range(len(required) - 1, -1, -1):
        milestone = required[index]
        source = ET.fromstring(fetch_verified(milestone))
        candidates = [item for item in source.findall("channel/item") if item_version(item) == milestone]
        if len(candidates) != 1:
            raise ValueError("Missing or duplicate milestone: " + milestone)
        item = deepcopy(candidates[0])
        enclosure = item.find("enclosure")
        expected_url = f"{RELEASES}/v{milestone}/Noodle-{milestone}-macOS.zip"
        if enclosure is None or enclosure.get("url") != expected_url or not enclosure.get(f"{{{SPARKLE}}}edSignature"):
            raise ValueError("Milestone must retain its signed, immutable release archive")
        expected_minimum = required[index - 1] if index else None
        if item.findtext(f"{{{SPARKLE}}}minimumUpdateVersion") != expected_minimum:
            raise ValueError("Milestone's upgrade chain does not match the release policy")
        channel.append(item)
    ET.indent(tree, space="  ")
    return ET.tostring(tree, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--feed", type=Path, required=True)
    parser.add_argument("--milestones", type=Path, required=True)
    parser.add_argument("--sign-update", required=True)
    parser.add_argument("--key-file", required=True)
    args = parser.parse_args()

    def fetch_verified(version):
        url = f"{RELEASES}/v{version}/appcast.xml"
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024:
            raise ValueError("Milestone feed exceeds the size limit")
        with tempfile.TemporaryDirectory(prefix="noodle-milestone-") as temporary:
            path = Path(temporary) / "appcast.xml"
            path.write_bytes(data)
            subprocess.run([args.sign_update, "--ed-key-file", args.key_file, "--verify", str(path)], check=True)
        return data

    milestones = json.loads(args.milestones.read_text())["milestones"]
    data = prepare(args.feed.read_bytes(), args.version, milestones, fetch_verified)
    args.feed.write_bytes(data)
    # XML assembly invalidates generate_appcast's signature. Re-sign the entire
    # feed; copied archive signatures and immutable URLs remain unchanged.
    subprocess.run([args.sign_update, "--ed-key-file", args.key_file, str(args.feed)], check=True)


if __name__ == "__main__":
    main()
