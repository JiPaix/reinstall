#!/bin/sh
# Builds out/adbwifi.apk: the tablet's "Wireless debugging at boot" app.
# Same toolchain, same signing key as Input Home (its build.sh, which downloads
# the toolchain on the first build): see the top of screen/inputhome/build.sh.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/../../screen/inputhome/build.sh" "$here" adbwifi
