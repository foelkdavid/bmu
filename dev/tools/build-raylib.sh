#!/bin/sh
# Rebuild lib/raylib6.c3l/linux-x64/libraylib.a: raylib 6.0, static, GLFW with the Wayland backend only
# (no X11, no XWayland). Needs: git, make, cc, pkg-config, wayland-scanner, wayland-devel,
# wayland-protocols, libxkbcommon-devel. Run from anywhere: dev/tools/build-raylib.sh
set -eu
cd "$(dirname "$0")/../.."
REV=dbc56a87da87d973a9c5baa4e7438a9d20121d28   # tag 6.0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q --depth 1 --branch 6.0 https://github.com/raysan5/raylib "$work/raylib"
[ "$(git -C "$work/raylib" rev-parse HEAD)" = "$REV" ] || { echo "raylib 6.0 tag moved"; exit 1; }
make -s -C "$work/raylib/src" -j"$(nproc)" PLATFORM=PLATFORM_DESKTOP_GLFW RAYLIB_LIBTYPE=STATIC RAYLIB_BUILD_MODE=RELEASE \
    GLFW_LINUX_ENABLE_WAYLAND=TRUE GLFW_LINUX_ENABLE_X11=FALSE
cp "$work/raylib/src/libraylib.a" lib/raylib6.c3l/linux-x64/libraylib.a
echo "built lib/raylib6.c3l/linux-x64/libraylib.a (raylib 6.0, GLFW Wayland only)"
