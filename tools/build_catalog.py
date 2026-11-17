#!/usr/bin/env python3
"""Render a Supervisor `StoreInfo` catalog for one architecture from a checkout of an add-on repository.

    python3 tools/build_catalog.py <checkout> <arch>  > files/usr/share/owrt-supervisor/catalog-<arch>.json

(`tools/build-catalogs.sh` produces all of them from pinned commits.)

The router has no YAML parser, so the catalog is rendered ahead of time. Every add-on that
declares <arch> is listed. An add-on that needs runtime features this supervisor does not
implement (see UNSUPPORTED) stays in the list but is marked `available: false`, with the
reasons in `unsupported`; installing it is refused instead of producing a broken container.
Each entry also carries `spec`: the parsed config.yaml, used to create the container.

Requires PyYAML (build host only). The checkout is untrusted input: it is only read.
"""
import json
import pathlib
import sys

import yaml  # safe_load only

REPO = {
    "slug": "core",
    "name": "Official add-ons",
    "source": "https://github.com/home-assistant/addons",
    "url": "https://github.com/home-assistant/addons",
    "maintainer": "Home Assistant",
}

# config.yaml keys that change how the container must be run and that we do not implement.
# (backup_pre/post, apparmor, hassio_api, auth_api, watchdog... do not affect running it.)
UNSUPPORTED = [
    "host_network", "host_pid", "host_ipc", "host_uts", "host_dbus", "privileged", "full_access",
    "devices", "usb", "uart", "gpio", "udev", "audio", "video", "kernel_modules", "devicetree",
    "docker_api", "homeassistant_api", "ingress", "tmpfs", "stdin",
]


def has_device_option(node):
    """An option of type device(...): the Supervisor hands the chosen device to the container."""
    if isinstance(node, str):
        return node.startswith("device")
    if isinstance(node, dict):
        return any(has_device_option(v) for v in node.values())
    if isinstance(node, list):
        return any(has_device_option(v) for v in node)
    return False


def unsupported(c):
    bad = [k for k in UNSUPPORTED if c.get(k) not in (None, False, [], {})]
    if has_device_option(c.get("schema")):
        bad.append("device option (device passthrough)")
    if not c.get("image"):
        bad.append("image (add-on is built locally)")
    return bad


def main(root, arch):
    addons = []
    for cfg in sorted(pathlib.Path(root).glob("*/config.yaml")):
        c = yaml.safe_load(cfg.read_text())
        if not isinstance(c, dict) or arch not in (c.get("arch") or []) or not c.get("version"):
            continue
        d = cfg.parent
        slug = str(c.get("slug") or d.name)
        bad = unsupported(c)
        addons.append({
            "advanced": False,
            "available": not bad,
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
            "unsupported": bad,
            "spec": c,
        })
    json.dump({"addons": addons, "repositories": [REPO]}, sys.stdout, indent=1, ensure_ascii=False)
    print()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
