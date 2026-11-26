#!/usr/bin/env python3
"""The product name is `Konstruct`, in Latin, in every locale (AGENTS.md, Localization).

Until 2026-11-26 the onboarding title read КОНСТРУКТ in Russian, ԿՈՆՍՏՐՈՒԿՏ in Armenian and
Konstruct in Japanese, while English and French showed KONSTRUCT: the rule was written down and
nothing read the strings files. Store screenshots in Russian showed it first.

Fails when:
  * `construct_title` (the wordmark on onboarding) differs between locales — one glyph form;
  * any app string, in any locale, holds a transliteration of the name (Cyrillic, Armenian,
    Japanese). Store keywords in fastlane/metadata may carry them; they are not read here.

`self-test` runs the matcher on fixed samples first, so a regex that stops matching fails here
instead of passing everything. Run from anywhere; CI runs it through scripts/check_all.sh.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "ConstructMessenger")
LOCALES = ("en", "ru", "ja", "fr", "hy-AM")
FILES = ("Localizable.strings", "InfoPlist.strings")
TITLE_KEY = "construct_title"

# The name with any case ending; `конструктор`, `конструктивный` are ordinary Russian words.
TRANSLITERATION = re.compile(
    r"конструкт(?:а|у|ом|е|ы|ов|ам|ами|ах)?(?![а-яё])"
    r"|կոնստրուկտ"
    r"|コンストラクト",
    re.IGNORECASE,
)
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.MULTILINE)


def transliterations(text):
    return [m.group(0) for m in TRANSLITERATION.finditer(text)]


def entries(path):
    with open(path, encoding="utf-8") as f:
        return ENTRY.findall(f.read())


def self_test():
    must = ["КОНСТРУКТ", "в Конструкте", "Конструкта", "ԿՈՆՍՏՐՈՒԿՏ", "Կոնստրուկտը", "コンストラクトの"]
    must_not = ["KONSTRUCT", "Konstruct-ը", "Konstructの", "конструктор", "конструктивный разговор"]
    bad = [s for s in must if not transliterations(s)] + [s for s in must_not if transliterations(s)]
    if bad:
        print(f"✗ brand-name self-test: wrong verdict on {bad}")
        return 1
    print("✓ brand-name self-test")
    return 0


def check():
    failures = []
    titles = {}
    for locale in LOCALES:
        for name in FILES:
            path = os.path.join(APP, f"{locale}.lproj", name)
            if not os.path.exists(path):
                failures.append(f"{locale}.lproj/{name} is missing")
                continue
            for key, value in entries(path):
                if key == TITLE_KEY:
                    titles[locale] = value
                for found in transliterations(value):
                    failures.append(f'{locale}.lproj/{name}: "{key}" spells the name as {found!r}')
    if set(titles) != set(LOCALES):
        failures.append(f"{TITLE_KEY} is missing in {sorted(set(LOCALES) - set(titles))}")
    elif len(set(titles.values())) != 1:
        failures.append(f"{TITLE_KEY} differs between locales: {titles}")
    for line in failures:
        print(f"✗ {line}")
    if failures:
        print("The product name is Konstruct, in Latin, in every locale (AGENTS.md, Localization).")
        return 1
    print(f"✓ brand name: Latin in every locale, {TITLE_KEY} = {titles['en']!r} everywhere")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["self-test"]:
        sys.exit(self_test())
    sys.exit(check())
