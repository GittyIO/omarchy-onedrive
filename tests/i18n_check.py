"""Checks that every string the QML uses exists in English, and that translations
use the same keys and placeholders."""

import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
I18N = os.path.join(ROOT, "i18n")

used = set()
for name in os.listdir(ROOT):
    if name.endswith(".qml"):
        with open(os.path.join(ROOT, name), encoding="utf-8") as f:
            text = f.read()
        used |= set(re.findall(r'(?:strings|picker)\.tn?\("([A-Za-z0-9_.]+)"', text))
        used |= set(re.findall(r'\bt\("([A-Za-z0-9_.]+)"\)', text))
        used |= set(re.findall(r'"(state\.[A-Za-z]+)"', text))
used = {k for k in used if not k.endswith(".")}  # prefixes completed at runtime
# Built dynamically from these prefixes in Panel.qml / Model.js.
used |= {f"state.{s}" for s in ["synced", "syncing", "starting", "paused", "offline", "error", "notInstalled", "serviceMissing"]}
used |= {f"change.{c}" for c in ["downloaded", "uploaded", "deletedOnline", "deletedLocal", "failed", "changed"]}
used |= {"time.justNow", "time.minutes", "time.hours", "time.days"}


def placeholders(value):
    values = value.values() if isinstance(value, dict) else [value]
    return sorted(set(re.findall(r"%\d", " ".join(values))))


catalogs = {}
for name in sorted(os.listdir(I18N)):
    with open(os.path.join(I18N, name), encoding="utf-8") as f:
        catalogs[name[:-5]] = json.load(f)

errors = []
en = catalogs["en"]
for key in sorted(used - set(en)):
    errors.append(f"en.json is missing {key}")
for lang, cat in catalogs.items():
    for key in cat:
        if key not in en:
            errors.append(f"{lang}.json has unknown key {key}")
        elif placeholders(cat[key]) != placeholders(en[key]):
            errors.append(f"{lang}.json {key}: placeholders differ from English")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"i18n ok: {len(en)} strings, languages: {', '.join(catalogs)}")
