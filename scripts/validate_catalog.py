#!/usr/bin/env python3
"""Validate the aggregate search catalog embedded in DYStorageSearchCatalog.m.

The catalog is produced by the developer scanner and pasted back as adjacent
Objective-C string literals. A stale or hand-edited scan can ship duplicate
titles or a plugin the tweak no longer recognizes, and nothing at runtime would
complain. Run this before every build; it is also a CI step.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "DYStorageSearchCatalog.m"
TWEAK = ROOT / "Tweak.xm"


def read_literals(source):
    """Collect every at-string literal in file order, joining the fragments."""
    out = []
    index = 0
    length = len(source)
    while True:
        start = source.find('@"', index)
        if start < 0:
            return out
        position = start + 2
        buffer = []
        while position < length:
            char = source[position]
            if char == "\\":
                escaped = source[position + 1]
                mapping = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "/": "/"}
                buffer.append(mapping.get(escaped, escaped))
                position += 2
                continue
            if char == '"':
                break
            buffer.append(char)
            position += 1
        out.append("".join(buffer))
        index = position + 1


def known_plugin_titles(tweak_source):
    match = re.search(r"DYStorageKnownPluginTitles\(void\)\s*\{(.*?)dispatch_once", tweak_source, re.S)
    if match is None:
        return set()
    return set(re.findall(r'@"([^"]+)"', match.group(1)))


def main():
    entries = json.loads("".join(read_literals(CATALOG.read_text(encoding="utf-8"))))
    known = known_plugin_titles(TWEAK.read_text(encoding="utf-8"))

    errors = []
    warnings = []
    total = 0
    seen_plugins = set()

    if isinstance(entries, list) is False:
        print("catalog root must be a list", file=sys.stderr)
        return 1

    for entry in entries:
        plugin = (entry.get("plugin") or "").strip()
        if not plugin:
            errors.append("catalog entry without a plugin name")
            continue
        if plugin in seen_plugins:
            errors.append("duplicate plugin %r" % plugin)
        seen_plugins.add(plugin)

        aliases = [alias for alias in entry.get("aliases") or [] if alias]
        if known and plugin not in known and not (set(aliases) & known):
            errors.append("plugin %r is missing from DYStorageKnownPluginTitles" % plugin)

        features = entry.get("features") or []
        if isinstance(features, list) is False or not features:
            errors.append("plugin %r has no features" % plugin)
            continue

        titles = {}
        for feature in features:
            title = (feature.get("title") or "").strip()
            section = (feature.get("section") or "").strip()
            if not title:
                errors.append("plugin %r has a feature without a title" % plugin)
                continue
            if not section:
                warnings.append("plugin %r feature %r has no section" % (plugin, title))
            titles[title] = titles.get(title, 0) + 1
        for title, count in titles.items():
            if count > 1:
                warnings.append("plugin %r repeats title %r x%d" % (plugin, title, count))

        total += len(features)
        print("%-10s %3d features" % (plugin, len(features)))

    for warning in warnings:
        print("warning: %s" % warning)
    for error in errors:
        print("error: %s" % error, file=sys.stderr)

    print("total: %d features across %d plugins" % (total, len(seen_plugins)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
