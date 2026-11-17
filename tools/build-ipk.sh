#!/bin/sh
# Build an opkg package (.ipk) from files/ for OpenWrt releases that still use opkg (<= 24.10).
#
#   tools/build-ipk.sh            -> dist/ha-supervisor_<ver>-<rel>_all.ipk
#   install on the router:  opkg install ./ha-supervisor_<ver>-<rel>_all.ipk
#
# Same layout as OpenWrt's ipkg-build: a gzip'ed tar with ./debian-binary, ./control.tar.gz and
# ./data.tar.gz. Runs in a throw-away Alpine container for GNU tar (uid/gid 0 on any host).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$ROOT/package/ha-supervisor/Makefile"
VER="$(sed -n 's/^PKG_VERSION:=//p' "$MK")"
REL="$(sed -n 's/^PKG_RELEASE:=//p' "$MK")"
# opkg wants comma-separated depends; the Makefile has "+pkg" tokens
DEPS="$(sed -n '/^  DEPENDS:=/,/^endef/p' "$MK" | sed 's/^  DEPENDS:=//; /^endef/d' | tr -d '\\\t+' | tr -s ' \n' ' ' | sed 's/ $//; s/ /, /g')"
OUT="$ROOT/dist"
mkdir -p "$OUT"

# never package a file that does not even compile
"$ROOT/tools/check.sh" "$ROOT"

docker run --rm \
  -v "$ROOT":/src:ro -v "$OUT":/out \
  -e VER="$VER" -e REL="$REL" -e DEPS="$DEPS" \
  alpine:latest sh -ec '
    apk add --no-cache tar >/dev/null
    W=/work; rm -rf $W; mkdir -p $W/data $W/control
    cp -R /src/files/. $W/data/
    chown -R 0:0 $W/data
    find $W/data -type d -exec chmod 755 {} +
    find $W/data -type f -exec chmod 644 {} +
    chmod 755 $W/data/usr/sbin/* $W/data/etc/init.d/* $W/data/etc/uci-defaults/*

    SIZE=$(find $W/data -type f -exec wc -c {} + | tail -n 1 | tr -s " " | cut -d" " -f2)
    cat > $W/control/control <<CTL
Package: ha-supervisor
Version: $VER-$REL
Depends: $DEPS
SourceName: ha-supervisor
Section: utils
Architecture: all
Installed-Size: $SIZE
Description: Minimal Home Assistant supervisor for OpenWrt (Docker, ucode)
CTL
    echo /etc/config/ha-supervisor > $W/control/conffiles
    cp /src/package/apk/post-install $W/control/postinst
    cp /src/package/apk/pre-deinstall $W/control/prerm
    chmod 755 $W/control/postinst $W/control/prerm

    T="tar --numeric-owner --owner=0 --group=0"
    (cd $W/data && $T -czf $W/data.tar.gz .)
    (cd $W/control && $T -czf $W/control.tar.gz .)
    echo "2.0" > $W/debian-binary
    F="ha-supervisor_$VER-${REL}_all.ipk"
    (cd $W && $T -cf - ./debian-binary ./data.tar.gz ./control.tar.gz | gzip -n > /out/$F)
    ls -l /out/$F
  '
echo "built: $OUT/ha-supervisor_$VER-${REL}_all.ipk"
