import importlib.util
import json
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("update_feed", ROOT / "scripts/prepare-update-feed.py")
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)
S = "{" + feed.SPARKLE + "}"


def appcast(version, minimum=None, legacy=False):
    root = ET.Element("rss"); channel = ET.SubElement(root, "channel"); item = ET.SubElement(channel, "item")
    ET.SubElement(item, S + "version").text = version
    if minimum:
        ET.SubElement(item, S + "minimumUpdateVersion").text = minimum
    archive = f"Noodle-{version}-macOS.zip" if legacy else "Noodle-arm64.zip"
    ET.SubElement(item, "enclosure", {"url": f"{feed.RELEASES}/v{version}/{archive}",
                                     S + "edSignature": "unchanged-archive-signature", "length": "123"})
    return ET.tostring(root)


class UpdateFeedTests(unittest.TestCase):
    def test_registered_backstory_milestone_remains_in_the_upgrade_chain(self):
        milestones = json.loads((ROOT / "Support/update-milestones.json").read_text())["milestones"]
        # 0.21.0 removes the skills and command links earlier versions wrote into bot workspaces.
        self.assertEqual(milestones, ["0.13.0", "0.14.0", "0.21.0"])
        def previous(version):
            return appcast(version, {"0.14.0": "0.13.0", "0.21.0": "0.14.0"}.get(version), legacy=version == "0.13.0")
        for version, expected in [("0.14.0", ["0.13.0", None]), ("0.15.0", ["0.14.0", "0.13.0", None]),
                                  ("0.21.0", ["0.14.0", "0.13.0", None]),
                                  ("0.22.0", ["0.21.0", "0.14.0", "0.13.0", None])]:
            result = feed.prepare(appcast(version), version, milestones, previous)
            items = ET.fromstring(result).findall("channel/item")
            self.assertEqual([i.findtext(S + "minimumUpdateVersion") for i in items], expected)

    def test_migration_release_is_reachable_from_older_versions(self):
        result = feed.prepare(appcast("0.13.0"), "0.13.0", ["0.13.0"], lambda _: self.fail("No old release needed"))
        self.assertIsNone(ET.fromstring(result).find("channel/item/" + S + "minimumUpdateVersion"))

    def test_successor_keeps_signed_milestone_and_requires_it(self):
        result = feed.prepare(appcast("0.14.0"), "0.14.0", ["0.13.0"], lambda v: appcast(v, legacy=True))
        items = ET.fromstring(result).findall("channel/item")
        self.assertEqual([feed.item_version(i) for i in items], ["0.14.0", "0.13.0"])
        self.assertEqual(items[0].findtext(S + "minimumUpdateVersion"), "0.13.0")
        self.assertIsNone(items[1].find(S + "minimumUpdateVersion"))
        self.assertEqual(items[1].find("enclosure").get(S + "edSignature"), "unchanged-archive-signature")
        self.assertEqual(items[0].find("enclosure").get("url"), f"{feed.RELEASES}/v0.14.0/Noodle-arm64.zip")
        self.assertEqual(items[1].find("enclosure").get("url"), f"{feed.RELEASES}/v0.13.0/Noodle-0.13.0-macOS.zip")

    def test_multiple_migrations_form_a_reachable_chain(self):
        result = feed.prepare(appcast("0.16.0"), "0.16.0", ["0.13.0", "0.15.0"],
                              lambda v: appcast(v, "0.13.0" if v == "0.15.0" else None, legacy=v == "0.13.0"))
        items = ET.fromstring(result).findall("channel/item")
        self.assertEqual([i.findtext(S + "minimumUpdateVersion") for i in items], ["0.15.0", "0.13.0", None])
        # Model Sparkle's version eligibility: skipping releases still visits
        # every required migration, while intermediate patch versions are skipped.
        current = "0.12.1"
        visited = []
        while current != "0.16.0":
            eligible = [i for i in items if feed.number(feed.item_version(i)) > feed.number(current)
                        and (i.findtext(S + "minimumUpdateVersion") is None
                             or feed.number(current) >= feed.number(i.findtext(S + "minimumUpdateVersion")))]
            current = max(map(feed.item_version, eligible), key=feed.number)
            visited.append(current)
        self.assertEqual(visited, ["0.13.0", "0.15.0", "0.16.0"])

    def test_missing_unverified_or_changed_milestone_fails(self):
        def rejected(_):
            raise ValueError("signature verification failed")
        with self.assertRaises(ValueError):
            feed.prepare(appcast("0.14.0"), "0.14.0", ["0.13.0"], rejected)
        for old in [appcast("0.12.0"), appcast("0.13.0", "0.12.0"),
                    appcast("0.13.0").replace(b"Noodle-arm64.zip", b"modified.zip"),
                    appcast("0.13.0").replace(b"/v0.13.0/", b"/v0.14.0/"),
                    appcast("0.13.0").replace(b"/download/v0.13.0/", b"/latest/download/"),
                    appcast("0.13.0", legacy=True).replace(b"Noodle-0.13.0", b"Noodle-0.12.0")]:
            with self.assertRaises(ValueError):
                feed.prepare(appcast("0.14.0"), "0.14.0", ["0.13.0"], lambda _: old)


if __name__ == "__main__":
    unittest.main()
