#!/usr/bin/env bash
# Build stable-diffusion.cpp as a GPU-accelerated shared library for Android arm64.
#
#   ./scripts/build.sh                      # CPU + Vulkan backend
#   BACKENDS=cpu ./scripts/build.sh         # CPU only (smaller .so)
#   VK_FP16=0 ./scripts/build.sh            # Vulkan without fp16 compute
#
# Requirements
#   - Android NDK r27+ (set ANDROID_NDK_HOME, or edit NDK below)
#   - Vulkan SDK with glslc (set VULKAN_SDK, e.g. /path/to/1.4.321.1)
#     Only the host SDK's compiler and headers are used; the .so links against
#     the NDK's libvulkan.so stub and resolves real symbols from the driver.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NDK="${ANDROID_NDK_HOME:-$HOME/android-dev/sdk/ndk/27.0.12077973}"
ABI="${ABI:-arm64-v8a}"
API="${API:-26}"
BACKENDS="${BACKENDS:-vulkan cpu}"
VK_FP16="${VK_FP16:-1}"
OUT="$ROOT/build/android-$ABI"

[[ -d "$NDK" ]] || { echo "NDK not found at $NDK (set ANDROID_NDK_HOME)"; exit 1; }

# Local engine patches (kept out of the submodule so upstream stays pristine).
for p in "$ROOT"/patches/*.patch; do
  [[ -e $p ]] || continue
  ( cd "$ROOT/sdcpp/ggml" && git apply --check "$p" 2>/dev/null && git apply "$p" ) \
    || echo "note: $(basename "$p") already applied or not applicable"
done

extra=()
if [[ " $BACKENDS " == *" vulkan "* ]]; then
  : "${VULKAN_SDK:?VULKAN_SDK must point at a LunarG SDK install (needs glslc)}"
  # LunarG tarballs sometimes nest the layout one level down under the arch.
  if [[ ! -x "$VULKAN_SDK/bin/glslc" && -x "$VULKAN_SDK/x86_64/bin/glslc" ]]; then
    VULKAN_SDK="$VULKAN_SDK/x86_64"
  fi
  # Locate the SPIRV-Headers CMake config package that ggml-vulkan requires.
  SPIRV_HDR_DIR="$(find "$VULKAN_SDK" -maxdepth 5 -type d -name SPIRV-Headers \
                    -path "*/share/cmake/*" 2>/dev/null | head -1)"
  [[ -n "$SPIRV_HDR_DIR" ]] || { echo "no SPIRV-Headers cmake package under $VULKAN_SDK"; exit 1; }

  # Host SDK supplies glslc + SPIRV-Headers; the *link* target is the NDK stub.
  # Vulkan entry points resolve from the vendor driver at runtime, so the link
  # step must tolerate undefined vk* symbols (-Wl,-z,undefs).
  extra+=(
    -DGGML_VULKAN=ON
    -DSPIRV-Headers_DIR="$SPIRV_HDR_DIR"
    -DCMAKE_PREFIX_PATH="$SPIRV_HDR_DIR;$VULKAN_SDK"
    -DVulkan_GLSLC_EXECUTABLE="$VULKAN_SDK/bin/glslc"
    -DVulkan_INCLUDE_DIR="$VULKAN_SDK/include"
    -DVulkan_LIBRARY="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/$API/libvulkan.so"
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--undefined-version -Wl,-z,undefs"
  )
else
  extra+=(-DGGML_VULKAN=OFF)
fi

# GGML_OPENMP=OFF: OpenMP would add a libomp.so NEEDED entry that is absent
# from the device sysroot, making System.load() fail at runtime.
#
# Two prefix maps because ggml is a *nested* submodule: mapping $ROOT alone
# leaves sdcpp/ggml sources carrying absolute build-machine paths in the .so.
PREFIX_MAP="-ffile-prefix-map=$ROOT=. -ffile-prefix-map=$ROOT/sdcpp/ggml=ggml"

rm -rf "$OUT/CMakeCache.txt"
cmake -S "$ROOT" -B "$OUT" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API" -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DSD_BUILD_SHARED_LIBS=ON -DSD_BUILD_EXAMPLES=OFF \
  -DGGML_OPENMP=OFF \
  -DSD_WEBP=OFF -DSD_WEBM=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_C_FLAGS="$PREFIX_MAP" \
  -DCMAKE_CXX_FLAGS="$PREFIX_MAP" \
  -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$ROOT=. -ffile-prefix-map=$ROOT/sdcpp/ggml=ggml" \
  "${extra[@]}"

cmake --build "$OUT" -j"$(nproc)"

SO="$(find "$OUT" -name 'libstable-diffusion.so' | head -1)"
[[ -f "$SO" ]] || { echo "build produced no libstable-diffusion.so"; exit 1; }
STRIP="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
"$STRIP" "$SO" -o "$SO.stripped" && mv "$SO.stripped" "$SO"

echo
ls -l "$SO"
sha256sum "$SO"
echo
echo "Load it from Kotlin with System.load(absolutePath), then call the sd_* C API"
echo "(see include/stable-diffusion.h). JNI users: rename the SONAME to match your"
echo "System.loadLibrary(\"...\") name before shipping."
