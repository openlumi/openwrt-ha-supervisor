#!/bin/sh
# Build an installable apk (apk-tools v3) from files/ using a throw-away Alpine container,
# because OpenWrt's on-device apk has no `mkpkg`.
#
#   tools/build-apk.sh            -> dist/owrt-supervisor-<ver>.apk   (unsigned, arch: noarch)
#   install on the router:  apk add --allow-untrusted ./owrt-supervisor-<ver>.apk
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$ROOT/package/owrt-supervisor/Makefile"
VER="$(sed -n 's/^PKG_VERSION:=//p' "$MK")"
REL="$(sed -n 's/^PKG_RELEASE:=//p' "$MK")"
FULL="$VER-r$REL"
# runtime dependencies = DEPENDS in the OpenWrt Makefile (the "+" prefix dropped)
DEPS="$(sed -n '/^  DEPENDS:=/,/^endef/p' "$MK" | sed 's/^  DEPENDS:=//; /^endef/d' | tr -d '\\\t+' | tr -s ' \n' ' ' | sed 's/ $//')"
OUT="$ROOT/dist"
mkdir -p "$OUT"

# never package a file that does not even compile
"$ROOT/tools/check.sh" "$ROOT"

docker run --rm \
  -v "$ROOT":/src:ro -v "$OUT":/out \
  -e FULL="$FULL" -e DEPS="$DEPS" \
  alpine:latest sh -ec '
    rm -rf /stage && mkdir /stage && cp -R /src/files/. /stage/
    # OpenWrt convention: the package ships its own file list (default_postinst reads it)
    mkdir -p /stage/lib/apk/packages
    (cd /stage && find . -type f ! -path "./lib/apk/packages/*" | sed "s|^\.||" | sort) > /stage/lib/apk/packages/owrt-supervisor.list
    echo /etc/config/owrt-supervisor > /stage/lib/apk/packages/owrt-supervisor.conffiles
    echo "/etc/config/owrt-supervisor $(sha256sum /stage/etc/config/owrt-supervisor | cut -d" " -f1)" \
      > /stage/lib/apk/packages/owrt-supervisor.conffiles_static
    chown -R 0:0 /stage
    find /stage -type d -exec chmod 755 {} +
    find /stage -type f -exec chmod 644 {} +
    chmod 755 /stage/usr/sbin/* /stage/etc/init.d/* /stage/etc/uci-defaults/*
    cp /src/package/apk/post-install /src/package/apk/post-upgrade /src/package/apk/pre-deinstall /tmp/
    chmod 755 /tmp/post-install /tmp/post-upgrade /tmp/pre-deinstall
    apk mkpkg \
      --info "name:owrt-supervisor" \
      --info "version:$FULL" \
      --info "description:Minimal Home Assistant supervisor for OpenWrt (Docker, ucode)" \
      --info "arch:noarch" \
      --info "depends:$DEPS" \
      --script post-install:/tmp/post-install \
      --script post-upgrade:/tmp/post-upgrade \
      --script pre-deinstall:/tmp/pre-deinstall \
      --files /stage \
      --output "/out/owrt-supervisor-$FULL.apk"
    ls -l "/out/owrt-supervisor-$FULL.apk"
  '
echo "built: $OUT/owrt-supervisor-$FULL.apk"
