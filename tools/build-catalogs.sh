#!/bin/sh
# Regenerate files/usr/share/ha-supervisor/catalog-<arch>.json from the upstream add-on repo.
#
#   armv7          frozen snapshot: upstream dropped armv7 in 2026, the add-ons and their
#                  homeassistant/armv7-addon-* images still exist at this commit
#   aarch64/amd64  upstream as of the pinned commit (the full list, not a subset)
#
# Bump the refs below to refresh. Set ADDONS_REPO to reuse an existing clone.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNAPSHOT_ARMV7=b9b856c91568bd5ae97f22e6f25326a57c08470c   # 2025-11-24, last with armv7
UPSTREAM=f46a10207c7606bc3785d028f63fbf8ac3e973bf   # 2026-11-15
OUT="$ROOT/files/usr/share/ha-supervisor"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

REPO="${ADDONS_REPO:-$WORK/addons.git}"
[ -d "$REPO" ] || git clone --quiet https://github.com/home-assistant/addons "$REPO"
python3 -m venv "$WORK/venv" && "$WORK/venv/bin/pip" install -q pyyaml >/dev/null 2>&1

render() {   # <ref> <arch>
  mkdir -p "$WORK/src-$2" && git -C "$REPO" archive "$1" | tar -x -C "$WORK/src-$2"
  # run from a neutral dir, the checkout is data only
  (cd / && "$WORK/venv/bin/python" "$ROOT/tools/build_catalog.py" "$WORK/src-$2" "$2" home-assistant/addons "$(git -C "$REPO" rev-parse "$1")") > "$OUT/catalog-$2.json"
  echo "catalog-$2.json: $("$WORK/venv/bin/python" -c "import json;d=json.load(open('$OUT/catalog-$2.json'))['addons'];print(len(d),'add-ons,',sum(a['available'] for a in d),'installable')")"
}
render "$SNAPSHOT_ARMV7" armv7
render "$UPSTREAM" aarch64
render "$UPSTREAM" amd64
