#!/usr/bin/env python3
"""Build files/usr/share/owrt-supervisor/catalog.json from a checkout of an add-on repository.

The catalog is a pre-rendered Supervisor `StoreInfo` (add-ons + repositories), so the router
needs no YAML parser. Only add-ons that declare the target architecture are kept.

    git clone https://github.com/home-assistant/addons && git -C addons checkout b9b856c9
    python3 -I tools/build_catalog.py addons armv7 > files/usr/share/owrt-supervisor/catalog.json

The checkout is untrusted input: it is only read, never executed.
"""
import json
import pathlib
import re
import sys

REPO = {
    "slug": "core",
    "name": "Official add-ons (snapshot)",
    "source": "https://github.com/home-assistant/addons",
    "url": "https://github.com/home-assistant/addons",
    "maintainer": "Home Assistant",
}


def scalar(text, key):
    m = re.search(rf'^{key}:[ ]*"?([^"\n#]+?)"?[ ]*(?:#.*)?$', text, re.M)
    return m.group(1).strip() if m else None


def arch_list(text):
    m = re.search(r'^arch:[ ]*\[([^\]]*)\]', text, re.M)
    if m:
        return [a.strip().strip("\"'") for a in m.group(1).split(",") if a.strip()]
    m = re.search(r'^arch:[ ]*\n((?:[ ]*-[ ]*\S+[ ]*\n)+)', text, re.M)
    return re.findall(r'-[ ]*(\S+)', m.group(1)) if m else []


def main(root, arch):
    addons = []
    for cfg in sorted(pathlib.Path(root).glob("*/config.yaml")):
        text = cfg.read_text()
        archs = arch_list(text)
        slug = scalar(text, "slug") or cfg.parent.name
        if arch not in archs or not scalar(text, "version"):
            continue
        d = cfg.parent
        addons.append({
            "advanced": False,
            "available": True,
            "build": False,
            "description": scalar(text, "description") or "",
            "homeassistant": scalar(text, "homeassistant"),
            "icon": False,   # icon/logo are served by Supervisor per add-on; not provided here
            "logo": False,
            "name": scalar(text, "name") or slug,
            "repository": REPO["slug"],
            "slug": f"{REPO['slug']}_{slug}",
            "stage": scalar(text, "stage") or "stable",
            "update_available": False,
            "url": scalar(text, "url"),
            "version_latest": scalar(text, "version"),
            "version": None,
            "arch": archs,
            "documentation": (d / "DOCS.md").exists(),
            "installed": False,
        })
    json.dump({"addons": addons, "repositories": [REPO]}, sys.stdout, indent=1, ensure_ascii=False)
    print()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
