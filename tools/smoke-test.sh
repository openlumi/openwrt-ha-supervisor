#!/bin/sh
# Install a built package into a stock OpenWrt rootfs container and check what the install hook did.
#
#   tools/smoke-test.sh <apk|ipk> <openwrt/rootfs image> <expected arch> [docker platform]
#   tools/smoke-test.sh apk openwrt/rootfs:x86-64-25.12.6 amd64
#   tools/smoke-test.sh ipk openwrt/rootfs:armsr-armv8-24.10.2 aarch64 linux/aarch64_generic
#
# The container has no procd/ubus/docker daemon, so this checks packaging, not a running service:
# dependencies resolve from the OpenWrt feeds, the hook runs, the config is written, the service is
# enabled, and the ucode modules load on that release's ucode.
set -eu
KIND="$1"; IMAGE="$2"; EXPECT="$3"; PLATFORM="${4:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
case "$KIND" in
  apk) PKG="$(ls "$DIST"/ha-supervisor-*.apk | head -n 1)" ;;
  ipk) PKG="$(ls "$DIST"/ha-supervisor_*.ipk | head -n 1)" ;;
  *) echo "kind must be apk or ipk" >&2; exit 2 ;;
esac

# shellcheck disable=SC2086
docker run --rm ${PLATFORM:+--platform "$PLATFORM"} \
  -v "$DIST":/dist:ro -e KIND="$KIND" -e EXPECT="$EXPECT" -e PKG="/dist/$(basename "$PKG")" \
  "$IMAGE" sh -c '
set -e
mkdir -p /var/lock /var/run /tmp
if [ "$KIND" = ipk ]; then
	# the rootfs image ships no architecture list: derive it from the packages it contains
	{ echo "arch all 100"; echo "arch noarch 100"
	  grep -h "^Architecture:" /usr/lib/opkg/info/*.control | sort -u | grep -vE "all|noarch" | sed "s/Architecture: /arch /; s/\$/ 200/"
	} >> /etc/opkg.conf
	opkg update >/dev/null 2>&1
	opkg install "$PKG" >/tmp/install.log 2>&1 || { tail -30 /tmp/install.log; echo "install FAILED"; exit 1; }
else
	apk update >/dev/null 2>&1
	apk add --allow-untrusted "$PKG" >/tmp/install.log 2>&1 || { tail -30 /tmp/install.log; echo "install FAILED"; exit 1; }
fi

fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
U() { uci -q get ha-supervisor.main.$1; }
IMG="$(U image)"

if [ "$KIND" = ipk ]; then check "package installed" "opkg list-installed ha-supervisor | grep -q ha-supervisor"
else check "package installed" "apk info -e ha-supervisor"; fi
check "dependencies installed (docker, dockerd, socat)" "command -v docker >/dev/null && command -v dockerd >/dev/null && command -v socat >/dev/null"
check "hook wrote arch=$EXPECT"                 "[ \"\$(U arch)\" = \"$EXPECT\" ]"
check "hook wrote the official image"           "case \"$IMG\" in ghcr.io/home-assistant/home-assistant) true;; *) false;; esac"
check "hook wrote an existing catalog"          "[ -s \"\$(U catalog)\" ] && [ \"\$(U catalog)\" = /usr/share/ha-supervisor/catalog-$EXPECT.json ]"
check "hook generated the API token"            "[ -n \"\$(U token)\" ]"
check "uci-defaults script was consumed"        "[ ! -e /etc/uci-defaults/90-ha-supervisor ]"
check "service enabled at boot"                 "ls /etc/rc.d | grep -q S99ha-supervisor"
check "nft rule for supervisor:80 shipped"       "[ -s /usr/share/nftables.d/chain-pre/dstnat/90-ha-supervisor.nft ]"
check "ingress module and relay tools present"  "[ -s /usr/share/ucode/supervisor/ingress.uc ] && command -v socat >/dev/null"
check "ucode modules load on this release"      "[ \"\$(ha-supervisor addons 2>&1 | head -c 1)\" = \"[\" ]"
T="$(U token)"
check "API handler answers an authorised ping"  "printf \"GET /supervisor/ping HTTP/1.0\r\nAuthorization: Bearer \$T\r\n\r\n\" | ha-supervisor-http | grep -q \"HTTP/1.0 200\""
check "API handler rejects a wrong token"       "printf \"GET /supervisor/ping HTTP/1.0\r\nAuthorization: Bearer nope\r\n\r\n\" | ha-supervisor-http | grep -q \"HTTP/1.0 401\""
[ $fail -eq 0 ] && echo "SMOKE TEST PASSED" || { echo "SMOKE TEST FAILED"; exit 1; }
'
