import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("update_feed", ROOT / "scripts/prepare-update-feed.py")
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)
S = "{" + feed.SPARKLE + "}"


def appcast(version, minimum=None):
    root = ET.Element("rss"); channel = ET.SubElement(root, "channel"); item = ET.SubElement(channel, "item")
    ET.SubElement(item, S + "version").text = version
    if minimum:
        ET.SubElement(item, S + "minimumUpdateVersion").text = minimum
    ET.SubElement(item, "enclosure", {"url": f"{feed.RELEASES}/v{version}/Noodle-{version}-macOS.zip",
                                     S + "edSignature": "unchanged-archive-signature", "length": "123"})
    return ET.tostring(root)


class UpdateFeedTests(unittest.TestCase):
    def test_migration_release_is_reachable_from_older_versions(self):
        result = feed.prepare(appcast("0.13.0"), "0.13.0", ["0.13.0"], lambda _: self.fail("No old release needed"))
        self.assertIsNone(ET.fromstring(result).find("channel/item/" + S + "minimumUpdateVersion"))

    def test_successor_keeps_signed_milestone_and_requires_it(self):
        result = feed.prepare(appcast("0.14.0"), "0.14.0", ["0.13.0"], lambda v: appcast(v))
        items = ET.fromstring(result).findall("channel/item")
        self.assertEqual([feed.item_version(i) for i in items], ["0.14.0", "0.13.0"])
        self.assertEqual(items[0].findtext(S + "minimumUpdateVersion"), "0.13.0")
        self.assertIsNone(items[1].find(S + "minimumUpdateVersion"))
        self.assertEqual(items[1].find("enclosure").get(S + "edSignature"), "unchanged-archive-signature")

    def test_multiple_migrations_form_a_reachable_chain(self):
        result = feed.prepare(appcast("0.16.0"), "0.16.0", ["0.13.0", "0.15.0"],
                              lambda v: appcast(v, "0.13.0" if v == "0.15.0" else None))
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
                    appcast("0.13.0").replace(b"Noodle-0.13.0-macOS.zip", b"modified.zip")]:
            with self.assertRaises(ValueError):
                feed.prepare(appcast("0.14.0"), "0.14.0", ["0.13.0"], lambda _: old)


if __name__ == "__main__":
    unittest.main()
