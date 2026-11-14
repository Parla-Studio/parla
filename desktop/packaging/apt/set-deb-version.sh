#!/bin/sh
# Sets the version of an existing .deb (jpackage always writes the app version):
#
#   set-deb-version.sh <package.deb> <version>
#
# Jenkins gives every build its own version, e.g. 1.3.0+202611142030.gitabc1234, so apt sees each build as an
# update. The package is unpacked, the Version field in DEBIAN/control is replaced and the package is rebuilt
# in place. Needs dpkg-deb.
set -eu

[ "$#" -eq 2 ] || { echo "usage: set-deb-version.sh <package.deb> <version>" >&2; exit 2; }
DEB=$1
VERSION=$2
[ -f "$DEB" ] || { echo "set-deb-version: $DEB not found" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
dpkg-deb -R "$DEB" "$TMP/pkg"
sed -i "s/^Version:.*/Version: $VERSION/" "$TMP/pkg/DEBIAN/control"
dpkg-deb --build --root-owner-group -Zxz "$TMP/pkg" "$TMP/new.deb" >/dev/null
mv "$TMP/new.deb" "$DEB"
echo "set-deb-version: $(dpkg-deb -f "$DEB" Package) $(dpkg-deb -f "$DEB" Version)"
