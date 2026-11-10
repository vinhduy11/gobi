import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "appcast.py")
NS = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
SIG = "A" * 86 + "=="


def add(appcast, version, build, **extra):
    args = [sys.executable, SCRIPT, "add", "--appcast", appcast, "--version", version, "--build", str(build),
            "--url", extra.get("url", f"https://github.com/o/r/releases/download/v{version}/Gobi-{version}.dmg"),
            "--signature", extra.get("signature", SIG), "--length", str(extra.get("length", 12345)),
            "--notes-url", f"https://github.com/o/r/releases/tag/v{version}", "--date", "Tue, 10 Nov 2026 06:00:00 +0000"]
    return subprocess.run(args, capture_output=True, text=True)


def items(appcast):
    root = ET.parse(appcast).getroot()
    return root.findall("./channel/item")


def field(item, name):
    return item.find(name, NS).text


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "appcast.xml")

    def tearDown(self):
        self.dir.cleanup()

    def test_a_missing_file_is_created_with_the_item(self):
        result = add(self.path, "0.1.0-alpha.8", 150)
        self.assertEqual(result.returncode, 0, result.stderr)
        [item] = items(self.path)
        self.assertEqual(field(item, "sparkle:version"), "150")
        self.assertEqual(field(item, "sparkle:shortVersionString"), "0.1.0-alpha.8")
        self.assertEqual(field(item, "sparkle:minimumSystemVersion"), "14.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://github.com/o/r/releases/download/v0.1.0-alpha.8/Gobi-0.1.0-alpha.8.dmg")
        self.assertEqual(enclosure.get("length"), "12345")
        self.assertEqual(enclosure.get("{%s}edSignature" % NS["sparkle"]), SIG)
        self.assertEqual(enclosure.get("type"), "application/x-apple-diskimage")
        self.assertEqual(field(item, "sparkle:fullReleaseNotesLink"), "https://github.com/o/r/releases/tag/v0.1.0-alpha.8")

    def test_a_pre_release_is_on_the_prerelease_channel_and_a_stable_one_on_none(self):
        add(self.path, "0.1.0-alpha.8", 150)
        add(self.path, "0.1.0", 200)
        by_version = {field(i, "sparkle:shortVersionString"): i for i in items(self.path)}
        self.assertEqual(field(by_version["0.1.0-alpha.8"], "sparkle:channel"), "prerelease")
        self.assertIsNone(by_version["0.1.0"].find("sparkle:channel", NS))

    def test_items_are_newest_build_first_whatever_the_order_added(self):
        add(self.path, "0.1.0-alpha.9", 160)
        add(self.path, "0.1.0-alpha.7", 140)
        add(self.path, "0.1.0-alpha.8", 150)
        self.assertEqual([field(i, "sparkle:version") for i in items(self.path)], ["160", "150", "140"])

    def test_adding_the_same_build_again_replaces_the_item(self):
        add(self.path, "0.1.0-alpha.8", 150, length=1)
        add(self.path, "0.1.0-alpha.8", 150, length=2)
        [item] = items(self.path)
        self.assertEqual(item.find("enclosure").get("length"), "2")

    def test_the_namespace_prefix_stays_sparkle(self):
        add(self.path, "0.1.0-alpha.8", 150)
        text = open(self.path, encoding="utf-8").read()
        self.assertIn("xmlns:sparkle=", text)
        self.assertIn("<sparkle:version>150</sparkle:version>", text)
        self.assertNotIn("ns0:", text)

    def test_bad_input_is_refused_and_leaves_the_file_alone(self):
        add(self.path, "0.1.0-alpha.8", 150)
        before = open(self.path, encoding="utf-8").read()
        for kwargs, version, build in [({"signature": "short"}, "0.1.0-alpha.9", 160), ({}, "not-a-version", 160), ({}, "0.1.0-alpha.9", "x"),
                                       ({"url": "http://insecure/x.dmg"}, "0.1.0-alpha.9", 160), ({"length": 0}, "0.1.0-alpha.9", 160)]:
            result = add(self.path, version, build, **kwargs)
            self.assertNotEqual(result.returncode, 0, (kwargs, version, build))
        self.assertEqual(open(self.path, encoding="utf-8").read(), before)

    def test_a_http_url_is_allowed_only_for_localhost_tests(self):
        result = add(self.path, "0.1.0-alpha.8", 150, url="http://127.0.0.1:8000/Gobi.dmg")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
