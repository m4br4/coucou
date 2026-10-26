#!/usr/bin/env python3
"""Show this fork's name (Brand.name, "Jarvis") instead of "Coucou" in the string catalog.

Rewrites the values of NotchBuddy/Resources/Localizable.xcstrings, never the keys. Kept as
"Coucou": the updater and What's new (they speak about the author's releases, which the
updater still installs), the iPhone app and the relay (still named Coucou), and the
author's credit line. The updater's announcements say "Coucou (upstream)".

Run it again after a rebase on upstream: it only touches what still says "Coucou".
  python3 scripts/jarvis-brand.py          rewrite the catalog
  python3 scripts/jarvis-brand.py --check  exit 1 when a string still needs it
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "NotchBuddy/Resources/Localizable.xcstrings"
BRAND = ROOT / "NotchBuddy/Sources/App/Brand.swift"

KEEP_PREFIXES = ("update.", "whatsnew.", "iphone.")
KEEP_KEYS = {"Coucou · github.com/Louis-CFM/coucou"}
UPSTREAM_KEYS = {"update.title %@", "update.menu %@", "update.ask.body"}
UPSTREAM = "Coucou (upstream)"
# Spanish is the fork's language: its update announcement reads as asked.
SPANISH = {"update.title %@": "Nueva versión de Coucou (upstream): %@"}

# "OK Coucou" was the wake word; the fork's is the name alone.
WAKE = re.compile(r"\b(?:OK|Ok|ok|Okay|okay)[   ]+Coucou\b")
# Not inside a path: the app's folder stays ~/Library/Application Support/Coucou/.
NAME = re.compile(r"(?<!/)Coucou(?!/)")
# Arabic transliterates the name in a few strings.
ARABIC = "كوكو"


def brand_name():
    match = re.search(r'static let name = "([^"]+)"', BRAND.read_text())
    if not match:
        sys.exit(f"No `static let name` in {BRAND}")
    return match.group(1)


def rebrand(value, name):
    value = WAKE.sub(name, value)
    value = NAME.sub(name, value)
    return value.replace(ARABIC, name)


def upstream(value):
    if UPSTREAM in value:
        return value
    return value.replace("Coucou", UPSTREAM, 1)


def units(node):
    if isinstance(node, dict):
        if "stringUnit" in node:
            yield node["stringUnit"]
        else:
            for child in node.values():
                yield from units(child)


def apply(catalog, name):
    """Returns the keys whose values changed."""
    changed = []
    for key, entry in catalog["strings"].items():
        if key in KEEP_KEYS or (key.startswith(KEEP_PREFIXES) and key not in UPSTREAM_KEYS):
            continue
        convert = upstream if key in UPSTREAM_KEYS else (lambda v: rebrand(v, name))
        localizations = entry.setdefault("localizations", {})
        # A key without an English value shows the key itself in English.
        if "en" not in localizations and "Coucou" in key:
            localizations["en"] = {"stringUnit": {"state": "translated", "value": key}}
        touched = False
        spanish = localizations.get("es", {}).get("stringUnit")
        if key in SPANISH and spanish and spanish["value"] != SPANISH[key]:
            spanish["value"] = SPANISH[key]
            touched = True
        for unit in units(localizations):
            new = convert(unit["value"])
            if new != unit["value"]:
                unit["value"] = new
                touched = True
        if touched:
            changed.append(key)
        elif not localizations:
            del entry["localizations"]
    return changed


def main():
    check = "--check" in sys.argv[1:]
    catalog = json.loads(CATALOG.read_text())
    changed = apply(catalog, brand_name())
    if check:
        if changed:
            print(f"{len(changed)} catalog strings still say Coucou; run python3 scripts/jarvis-brand.py:")
            for key in changed:
                print(f"  {key!r}")
            return 1
        print("Catalog shows the fork's name.")
        return 0
    # Xcode's formatting, so the diff shows only the values.
    CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", " : ")))
    print(f"{len(changed)} catalog strings now say {brand_name()}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
