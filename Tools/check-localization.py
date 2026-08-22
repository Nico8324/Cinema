#!/usr/bin/env python3
"""Catches user-facing strings that never reached the string catalog.

Xcode extracts every localizable string into `.stringsdata` files as it compiles, and
**Xcode.app** merges those into `Localizable.xcstrings`. `xcodebuild` does not. Nobody
notices, because a string missing from the catalog is not an error — it simply renders in
English forever, in every language.

That gap has a shape: it swallows whatever the platform you last opened in Xcode does not
compile. Cinema's converter is entirely inside `#if os(macOS)`, so 57 strings — every warning
the conversion queue shows about what a film is about to lose, the whole tidy sheet, the
automation toggles — sat outside the catalog from the day they were written.

Run with no arguments to check, or `--fix` to merge what is missing:

    python3 Tools/check-localization.py           # exits 1 and lists the gaps
    python3 Tools/check-localization.py --fix     # adds them, untranslated, and exits 0

`--fix` adds the keys and no translations, which is the honest state: the string is now
visible to translators instead of invisible to everyone.
"""

import json
import pathlib
import re
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
CATALOG = REPO / "Cinema/Resources/Localizable.xcstrings"

# Built for macOS on purpose: it is the superset. Every other platform's strings compile here
# too, while the macOS-only converter compiles nowhere else — which is exactly how it went
# missing. Checking on any other destination would reproduce the bug rather than catch it.
DESTINATION = "platform=macOS"


# printf's actual grammar, not "a run of letters". `%llds` is `%lld` followed by a literal `s`,
# and a greedy letter run reads it as one specifier of type "llds" — which then fails to match a
# translation that correctly writes `%lld` and puts the `s` somewhere else. The checker was
# rejecting the translation for being right.
_LENGTH = r"(?:hh|h|ll|l|q|L|z|t|j)?"
_CONVERSION = r"[diufFeEgGxXoscpaA@]"
SPECIFIER = re.compile(
    rf"%%|%(\d+)\$[-+ #0]*[\d*]*(?:\.[\d*]+)?({_LENGTH}{_CONVERSION})"
    rf"|%[-+ #0]*[\d*]*(?:\.[\d*]+)?({_LENGTH}{_CONVERSION})")


def argument_types(text: str) -> list[str] | None:
    """The format arguments a string takes, in order, or None if it is self-contradictory.

    Positional and plain forms have to compare equal: `%1$@ %2$@` and `%@ %@` take the same
    arguments, and a translator reordering a sentence for German or Japanese word order is
    *required* to switch to the positional form. A naive text comparison rejects exactly the
    translations that were done correctly.

    `%%` is a literal per cent sign and takes no argument, so it is not counted.
    """
    sequential: list[str] = []
    positional: dict[int, str] = {}
    for match in SPECIFIER.finditer(text):
        if match.group(0) == "%%":
            continue
        if match.group(1):
            positional[int(match.group(1))] = match.group(2)
        else:
            sequential.append(match.group(3))
    if positional and sequential:
        return None  # Mixing the two forms is undefined; refuse rather than guess.
    if positional:
        return [positional[i] for i in sorted(positional)]
    return sequential


def mistranslations(catalog: dict) -> list[str]:
    """Translations that take different arguments from their source string.

    A dropped or extra `%@` is not a typo — the formatter reads whatever is next on the stack
    and the app crashes, in one language, for the people least able to report it in English.
    """
    problems = []
    for key, entry in catalog["strings"].items():
        expected = argument_types(key)
        for language, localization in (entry.get("localizations") or {}).items():
            value = (localization.get("stringUnit") or {}).get("value")
            if value is None:
                continue
            actual = argument_types(value)
            if actual != expected:
                problems.append(f"{language}: {key[:70]!r}")
    return problems


def extracted_keys(derived: pathlib.Path) -> dict[str, str]:
    """Every localizable key the compiler saw, mapped to its comment."""
    keys: dict[str, str] = {}
    for path in derived.rglob("*.stringsdata"):
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        for entries in data.get("tables", {}).values():
            for entry in entries:
                key = entry.get("key")
                if key:
                    keys.setdefault(key, entry.get("comment") or "")
    return keys


def main() -> int:
    fixing = "--fix" in sys.argv

    with tempfile.TemporaryDirectory() as scratch:
        derived = pathlib.Path(scratch)
        build = subprocess.run(
            ["xcodebuild", "build",
             "-project", str(REPO / "Cinema.xcodeproj"),
             "-scheme", "Cinema",
             "-destination", DESTINATION,
             "-derivedDataPath", str(derived),
             "CODE_SIGNING_ALLOWED=NO"],
            capture_output=True, text=True)
        if build.returncode != 0:
            print("Couldn't build to extract strings:", file=sys.stderr)
            print(build.stdout[-3000:], file=sys.stderr)
            return build.returncode

        found = extracted_keys(derived)

    if not found:
        # No strings at all means the extraction itself broke, not that the app has none.
        # Reporting "all clear" here would be the same silence this script exists to end.
        print("No strings were extracted at all — SWIFT_EMIT_LOC_STRINGS may be off.",
              file=sys.stderr)
        return 1

    catalog = json.loads(CATALOG.read_text())
    missing = sorted(k for k in found if k not in catalog["strings"])

    broken = mistranslations(catalog)
    if broken and not fixing:
        print(f"{len(broken)} translation(s) take different arguments from their source.")
        print("The formatter reads whatever is next on the stack, so these crash.\n")
        for problem in broken:
            print(f"  {problem}")
        print()

    if not missing:
        if broken:
            return 1
        print(f"All {len(found)} extracted strings are in the catalog, "
              f"and every translation takes the same arguments.")
        return 0

    if not fixing:
        print(f"{len(missing)} string(s) are used in the app but absent from the catalog.")
        print("They will render in English in every language, silently.\n")
        for key in missing:
            print(f"  {key[:100]}")
        print("\nRun: python3 Tools/check-localization.py --fix")
        return 1

    for key in missing:
        entry: dict = {"extractionState": "manual", "localizations": {}}
        if found[key]:
            entry["comment"] = found[key]
        catalog["strings"][key] = entry
    catalog["strings"] = dict(sorted(catalog["strings"].items()))
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"Added {len(missing)} string(s) to the catalog, untranslated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
