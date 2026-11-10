#!/usr/bin/env python3
"""Adds a release to the Sparkle appcast (appcast.xml), the feed Gobi checks for updates.

  scripts/appcast.py add --appcast appcast.xml --version 0.1.0-alpha.8 --build 150 --url URL --signature B64 --length N \
                         --notes-url URL --date "Tue, 10 Nov 2026 06:00:00 +0000"

The file is created when missing. Items are kept newest build first; an item with the same build is replaced (so a re-run is safe).
A pre-release version (0.1.0-alpha.8) goes in the "prerelease" channel, which apps offer only when told to (Settings > General).
Nothing is written when an argument is wrong. Standard library only.
"""
import argparse
import base64
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$")


def q(name):
    return "{%s}%s" % (SPARKLE, name)


def check(args):
    problems = []
    if not SEMVER.match(args.version):
        problems.append(f"not a Semantic Version: {args.version}")
    if not re.fullmatch(r"[1-9][0-9]*", str(args.build)):
        problems.append(f"the build number must be a positive integer: {args.build}")
    if not (args.url.startswith("https://") or re.match(r"^http://(127\.0\.0\.1|localhost)[:/]", args.url)):
        problems.append(f"the download URL must be https: {args.url}")
    try:
        if len(base64.b64decode(args.signature, validate=True)) != 64:
            raise ValueError
    except ValueError:
        problems.append("the signature must be the base64 of a 64-byte EdDSA signature")
    if args.length <= 0:
        problems.append(f"the length must be positive: {args.length}")
    return problems


def new_item(args):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.version
    ET.SubElement(item, q("version")).text = str(args.build)
    ET.SubElement(item, q("shortVersionString")).text = args.version
    ET.SubElement(item, q("minimumSystemVersion")).text = args.min_system
    if "-" in args.version:
        ET.SubElement(item, q("channel")).text = "prerelease"
    ET.SubElement(item, "pubDate").text = args.date
    ET.SubElement(item, q("fullReleaseNotesLink")).text = args.notes_url
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("length", str(args.length))
    enclosure.set("type", "application/x-apple-diskimage")
    enclosure.set(q("edSignature"), args.signature)
    return item


def load(path):
    try:
        return ET.parse(path).getroot()
    except FileNotFoundError:
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Gobi"
        ET.SubElement(channel, "link").text = "https://github.com/vinhduy11/gobi"
        ET.SubElement(channel, "description").text = "Updates for Gobi"
        return root


def build_of(item):
    return int(item.find(q("version")).text)


def add(args):
    problems = check(args)
    if problems:
        sys.exit("appcast: " + "; ".join(problems))
    ET.register_namespace("sparkle", SPARKLE)
    root = load(args.appcast)
    channel = root.find("channel")
    kept = [i for i in channel.findall("item") if build_of(i) != int(args.build)]
    for item in channel.findall("item"):
        channel.remove(item)
    for item in sorted(kept + [new_item(args)], key=build_of, reverse=True):
        channel.append(item)
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(args.appcast, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("add", help="add or replace a release")
    p.add_argument("--appcast", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--signature", required=True)
    p.add_argument("--length", required=True, type=int)
    p.add_argument("--notes-url", required=True)
    p.add_argument("--date", required=True)
    p.add_argument("--min-system", default="14.0")
    args = parser.parse_args()
    if args.command == "add":
        add(args)


if __name__ == "__main__":
    main()
