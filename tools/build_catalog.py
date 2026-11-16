#!/usr/bin/env python3
"""Build files/usr/share/owrt-supervisor/catalog.json from a checkout of an add-on repository.

The catalog is a pre-rendered Supervisor `StoreInfo` (add-ons + repositories), so the router
needs no YAML parser. Only add-ons that declare the target architecture are kept.

    git clone https://github.com/home-assistant/addons && git -C addons checkout b9b856c9
    python3 -I tools/build_catalog.py addons armv7 > files/usr/share/owrt-supervisor/catalog.json

Each entry also carries `spec`: the add-on's parsed config.yaml, used by the supervisor to
create the container (image, ports, map, options, ...). Requires PyYAML (build host only).

The checkout is untrusted input: it is only read, never executed.
"""
import json
import pathlib
import sys

import yaml  # safe_load only

REPO = {
    "slug": "core",
    "name": "Official add-ons (snapshot)",
    "source": "https://github.com/home-assistant/addons",
    "url": "https://github.com/home-assistant/addons",
    "maintainer": "Home Assistant",
}


def main(root, arch):
    addons = []
    for cfg in sorted(pathlib.Path(root).glob("*/config.yaml")):
        c = yaml.safe_load(cfg.read_text())
        if not isinstance(c, dict) or arch not in (c.get("arch") or []) or not c.get("version"):
            continue
        d = cfg.parent
        slug = str(c.get("slug") or d.name)
        addons.append({
            "advanced": False,
            "available": True,
            "build": False,
            "description": str(c.get("description") or ""),
            "homeassistant": c.get("homeassistant"),
            "icon": False,   # icon/logo are served by Supervisor per add-on; not provided here
            "logo": False,
            "name": str(c.get("name") or slug),
            "repository": REPO["slug"],
            "slug": f"{REPO['slug']}_{slug}",
            "stage": str(c.get("stage") or "stable"),
            "update_available": False,
            "url": c.get("url"),
            "version_latest": str(c["version"]),
            "version": None,
            "arch": c.get("arch"),
            "documentation": (d / "DOCS.md").exists(),
            "installed": False,
            "spec": c,
        })
    json.dump({"addons": addons, "repositories": [REPO]}, sys.stdout, indent=1, ensure_ascii=False)
    print()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
