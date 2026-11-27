# stable-diffusion.cpp for Android

Cross-compile [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp)
into a shared library for **Android arm64**, with GPU inference through ggml's
Vulkan backend. No server, no API key, no account — the model runs on the phone.

Prebuilt `libstable-diffusion.so` binaries are attached to each
[Release](releases), with SHA-256 checksums.

## Why this exists

ggml has had a Vulkan backend for a long time, and stable-diffusion.cpp builds
fine on Linux, macOS and Windows. Building it **for Android with the NDK** is a
different exercise: two conflicting `libvulkan.so`s, an over-eager linker that
silently deletes the GPU backend, and mobile drivers that need specific knobs
turned off. None of that is documented anywhere. This repo is those answers,
plus a script so you do not rediscover them.

## Quick start

```sh
git clone --recursive https://github.com/sambouli/stable-diffusion-android.git
cd stable-diffusion-android

export ANDROID_NDK_HOME=/path/to/android-ndk-r27c   # r27+
export VULKAN_SDK=/path/to/1.4.321.1                # LunarG SDK, provides glslc

./scripts/build.sh
```

Output: `build/android-arm64-v8a/libstable-diffusion.so`, stripped, plus its
SHA-256 printed at the end.

Variants:

```sh
BACKENDS=cpu ./scripts/build.sh    # CPU only, smaller .so
ABI=x86_64   ./scripts/build.sh    # emulator images
API=28       ./scripts/build.sh    # raise minSdkVersion
```

## Using the library

Link against `sdcpp/include/stable-diffusion.h`, or load it at runtime from
Kotlin and call the C API through a thin JNI shim:

```kotlin
System.load(File(filesDir, "native/libstable-diffusion.so").absolutePath)
```

The header is the contract. One thing it will bite you on: image tensors are
U8 `[C,W,H]` with **dim 0 contiguous** — interleaved RGB, not planar CHW. See
[docs/adreno.md](docs/adreno.md#5-reading-result-tensors).

A worked example of the whole pipeline (weights download, context creation,
generation, tensor decoding, cancellation) lives in
[Klein Studio](https://github.com/sambouli/klein-android), which uses this
engine to run FLUX.2-klein 4B on-device.

## What is pinned where

Upstream code is never copied into this repo — it is submodules at exact
commits, so every build is reproducible:

| Path | Upstream | Pinned commit |
| --- | --- | --- |
| `sdcpp/` | `leejet/stable-diffusion.cpp` | `3b12781fac` |
| `sdcpp/ggml/` | `leejet/ggml` (`sd.cpp` branch) | `eeda9ec48f` |

Local changes live in `patches/` and are applied by the build script before
configuration, keeping the submodule working trees pristine. There is exactly
one: `ggml_vk_debug_enumerate()`, a pre-filter physical-device lister for
diagnostics. It changes no inference behaviour.

## Adreno / Qualcomm

Read [docs/adreno.md](docs/adreno.md) before debugging anything on a Snapdragon
device. It covers verifying the GPU is actually being used, which
`GGML_VK_DISABLE_*` variables to set and when, and one non-obvious trap: OEM
memory killers that terminate foreground apps above ~5.5 GB RSS with no error
at all, and the manifest attribute that gets you out of it.

## Requirements

- Android NDK r27 or newer
- A host Vulkan SDK (only `glslc` and SPIRV-Headers are used, on the build machine)
- CMake ≥ 3.22 and Ninja
- Linux or macOS host

## Licence

The build scripts, patches and documentation in this repository are MIT — see
[LICENSE](LICENSE). The engine itself stays under upstream's MIT licence, with
`LICENSE` retained in `sdcpp/` and `sdcpp/ggml/`.

Model weights are not distributed here. FLUX.2-klein 4B is Apache 2.0 from
Black Forest Labs; check the licence of whatever you download.

## Not affiliated

Not affiliated with leejet/stable-diffusion.cpp or ggml. This is a build
recipe around their work, and all credit for the engine belongs upstream.
