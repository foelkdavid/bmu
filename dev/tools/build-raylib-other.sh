#!/bin/sh
# Build lib/raylib6.c3l/<target>/ for macOS or Windows: raylib 6.0, static, the platform's own GLFW backend
# (Cocoa / Win32) plus the platform-neutral bmu patches (dev/tools/raylib-*.patch; the glfw-*.patch files are
# Wayland fixes and are not applied). Meant for CI runners on that OS (release builds of the apps):
#   macOS (Xcode command line tools):  dev/tools/build-raylib-other.sh macos [aarch64|x64]   -> macos-<arch>
#                                      (default: the runner's own; x64 on Apple Silicon cross-compiles)
#   Windows (Git Bash, CMake, MSVC):   dev/tools/build-raylib-other.sh windows    -> windows-x64/raylib.lib
# Linux keeps using dev/tools/build-raylib.sh (Wayland only).
set -eu
os=${1:?usage: build-raylib-other.sh macos [aarch64|x64] | windows}
arch=${2:-}
cd "$(dirname "$0")/../.."
REV=dbc56a87da87d973a9c5baa4e7438a9d20121d28   # tag 6.0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q --depth 1 --branch 6.0 https://github.com/raysan5/raylib "$work/raylib"
[ "$(git -C "$work/raylib" rev-parse HEAD)" = "$REV" ] || { echo "raylib 6.0 tag moved"; exit 1; }
for p in dev/tools/raylib-*.patch; do git -C "$work/raylib" apply "$PWD/$p"; done
case "$os" in
macos)
	[ -n "$arch" ] || case "$(uname -m)" in arm64) arch=aarch64 ;; *) arch=x64 ;; esac
	target=macos-$arch
	case "$arch" in aarch64) clang_arch=arm64 ;; x64) clang_arch=x86_64 ;; *) echo "unknown arch: $arch"; exit 1 ;; esac
	make -s -C "$work/raylib/src" -j"$(sysctl -n hw.ncpu)" PLATFORM=PLATFORM_DESKTOP_GLFW RAYLIB_LIBTYPE=STATIC \
		RAYLIB_BUILD_MODE=RELEASE CUSTOM_CFLAGS="-DSUPPORT_FILEFORMAT_JPG=1 -mmacosx-version-min=11.0 -arch $clang_arch"
	mkdir -p "lib/raylib6.c3l/$target"
	cp "$work/raylib/src/libraylib.a" "lib/raylib6.c3l/$target/libraylib.a"
	;;
windows)
	target=windows-x64
	export CL="-DSUPPORT_FILEFORMAT_JPG=1"   # MSVC reads extra compiler options from CL
	cmake -S "$work/raylib" -B "$work/build" -A x64 -DBUILD_EXAMPLES=OFF -DBUILD_SHARED_LIBS=OFF -DPLATFORM=Desktop
	cmake --build "$work/build" --config Release --target raylib
	mkdir -p "lib/raylib6.c3l/$target"
	cp "$(find "$work/build" -name raylib.lib | head -1)" "lib/raylib6.c3l/$target/raylib.lib"
	;;
*) echo "unknown OS: $os"; exit 1 ;;
esac
echo "built lib/raylib6.c3l/$target (raylib 6.0, static)"
