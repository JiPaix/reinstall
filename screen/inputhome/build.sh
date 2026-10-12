#!/bin/sh
# Builds out/inputhome.apk with the bare SDK tools (no Gradle).
#
# Nothing to install: the toolchain is downloaded on the first build into .sdk/
# (gitignored, ~320 MB to fetch, x86_64 Linux) and checked against the sha256
# below. The versions are pinned here, so this checkout and release.yml build
# with the same tools; to move to another one, change its three values.
#
# The APK is signed with $INPUTHOME_KEYSTORE (default
# ~/.local/share/inputhome/debug.keystore), created when missing. Keep that file:
# Android refuses to update an app signed by another key, so a build made with a
# new one has to replace the installed app instead of updating it.
set -eu
cd "$(dirname "$0")"

BT_DIR=build-tools-r37
BT_URL=https://dl.google.com/android/repository/build-tools_r37_linux.zip
BT_SHA=01af179347cbcd9c208b7f8171f7b21f6dd1d2f85bcd15e88caa51d5d7b86060
PLATFORM_DIR=platform-37.0_r02
PLATFORM_URL=https://dl.google.com/android/repository/platform-37.0_r02.zip
PLATFORM_SHA=840b23e827f96e64aea4c89a1194aac3dc5f6bad37edb231c5c795d890330e8d
JDK_DIR=jdk-17.0.20.1_1
JDK_URL=https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/OpenJDK17U-jdk_x64_linux_hotspot_17.0.20.1_1.tar.gz
JDK_SHA=3808d1d15e3ec6bd5b84057fb5d84c33d8a1536a258146bcea2e603fc726e08e

SDK="$PWD/.sdk"
KEYSTORE="${INPUTHOME_KEYSTORE:-${XDG_DATA_HOME:-$HOME/.local/share}/inputhome/debug.keystore}"

# Each archive holds a single top-level directory: it becomes .sdk/<name>. The
# name carries the version, so changing a pin fetches the new one.
fetch_tool() {  # $1 = name under .sdk, $2 = url, $3 = sha256
    [ -d "$SDK/$1" ] && return 0
    tmp="$SDK/.tmp"
    rm -rf "$tmp" && mkdir -p "$tmp/x"
    echo "downloading $1"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/archive" "$2"
    echo "$3  $tmp/archive" | sha256sum -c - >/dev/null 2>&1 \
        || { echo "checksum mismatch for $2" >&2; exit 1; }
    case "$2" in
        *.zip)
            if command -v unzip >/dev/null; then unzip -q "$tmp/archive" -d "$tmp/x"
            else bsdtar -xf "$tmp/archive" -C "$tmp/x"; fi ;;
        *) tar -xzf "$tmp/archive" -C "$tmp/x" ;;
    esac
    mv "$tmp/x"/* "$SDK/$1"
    rm -rf "$tmp"
}
fetch_tool "$BT_DIR" "$BT_URL" "$BT_SHA"
fetch_tool "$PLATFORM_DIR" "$PLATFORM_URL" "$PLATFORM_SHA"
fetch_tool "$JDK_DIR" "$JDK_URL" "$JDK_SHA"

BT="$SDK/$BT_DIR"
JAR="$SDK/$PLATFORM_DIR/android.jar"
# d8 and apksigner are wrappers that run whatever `java` comes first.
export JAVA_HOME="$SDK/$JDK_DIR"
export PATH="$JAVA_HOME/bin:$PATH"

rm -rf out && mkdir -p out/classes
"$BT/aapt2" compile --dir res -o out/res.zip
"$BT/aapt2" link -o out/base.apk --manifest AndroidManifest.xml -I "$JAR" out/res.zip
find src -name '*.java' -exec javac -Xlint:-options -source 8 -target 8 -bootclasspath "$JAR" -d out/classes {} +
find out/classes -name '*.class' -exec "$BT/d8" --min-api 26 --lib "$JAR" --output out {} +
(cd out && jar u0Mf base.apk classes.dex)
"$BT/zipalign" -f 4 out/base.apk out/aligned.apk
if [ ! -f "$KEYSTORE" ]; then
    mkdir -p "$(dirname "$KEYSTORE")"
    keytool -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android \
        -alias inputhome -keyalg RSA -keysize 2048 -validity 10000 -dname CN=inputhome >/dev/null 2>&1 \
        || { echo "keytool could not create $KEYSTORE" >&2; exit 1; }
    chmod 600 "$KEYSTORE"
    echo "created signing key $KEYSTORE"
fi
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --out out/inputhome.apk out/aligned.apk
ls -l out/inputhome.apk
