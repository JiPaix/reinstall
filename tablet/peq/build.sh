#!/usr/bin/env bash
# Builds peq.so, the tablet's equalizer (a LADSPA plugin for PulseAudio's
# module-ladspa-sink, see peq.c), into out/. Needs clang and lld only: the
# plugin uses no libc, so no NDK.
#     build.sh          → out/peq.so (Android, 64-bit ARM)
#     build.sh test     → runs peq_test.c on this machine
#     build.sh curve L  → the response of control list L, as android.sh passes it
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out

case "${1:-}" in
  test|curve)
    clang -O2 -Wall -Wextra -o out/peq_test peq_test.c -lm
    shift
    exec out/peq_test "$@" ;;
esac

clang --target=aarch64-linux-android24 -O2 -Wall -Wextra -fPIC -shared \
  -ffreestanding -nostdlib -fno-stack-protector -fvisibility=hidden -fuse-ld=lld \
  -Wl,--no-undefined -Wl,-soname,peq.so -Wl,--hash-style=both \
  -Wl,-z,max-page-size=16384 -Wl,-s \
  -o out/peq.so peq.c
# Nothing for the dynamic linker to find: the one export, no imports.
if readelf -W --dyn-syms out/peq.so | awk '$7 == "UND" && $8 != "" { bad = 1 } END { exit !bad }'; then
  echo "peq.so imports symbols:" >&2
  readelf -W --dyn-syms out/peq.so >&2
  exit 1
fi
echo "out/peq.so"
