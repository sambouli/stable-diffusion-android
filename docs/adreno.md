# Adreno / Qualcomm notes

Everything here was found the hard way on a RedMagic (Nubia NX819J, SM8975,
**Adreno 850**), but the failure modes are driver-generic enough that they are
worth knowing before you debug them yourself.

## 1. Confirm you actually got the GPU

Do not trust that inference is on the GPU. Two independent checks:

```sh
# kernel-side busy counter; climbs to ~100% during generation, back to 0 after
adb shell cat /sys/class/kgsl/kgsl-3d0/gpubusy
```

The Adreno driver also logs its client on instance creation — filter logcat for:

```
AdrenoVK-0: Application Name : ggml-vulkan
```

If you do not see that line, you are running on CPU and any benchmark you took
is meaningless. `ggml_vk_get_device_count()` only reports devices the backend
*accepted*; `patches/0001-ggml-vulkan-debug-enumerate.patch` adds
`ggml_vk_debug_enumerate()`, which lists every physical device with its type
and vendor *before* filtering — that is what distinguishes "no GPU" from "the
backend picked the wrong one".

## 2. Environment knobs that matter on mobile drivers

All read by `ggml-vulkan.cpp` at device-create time, so set them **before**
creating the context (`setenv()` in JNI init works):

| Variable | Why you may need it on Adreno |
| --- | --- |
| `GGML_VK_DISABLE_COOPMAT` / `_COOPMAT2` | Cooperative-matrix paths have crashed or hung on these drivers. Biggest single stability win. |
| `GGML_VK_DISABLE_GRAPH_OPTIMIZE` | Avoids driver-side graph optimisation bugs around descriptor sets. |
| `GGML_VK_DISABLE_F16` | fp16 compute is measurably faster but some drivers produce subtly wrong results with it. A/B this first when output looks *almost* right. |
| `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM` | See the memory-killer note below. |

Suggested order of experimentation: correctness first with everything disabled,
then re-enable one at a time and re-check both speed **and** output.

## 3. The OEM memory killer

This cost more time than any GPU bug. RedMagic/ZTE ROMs run a process killer
(`hpk`) that terminates apps above roughly 5.5 GB RSS **even in the
foreground**. In logcat it looks like:

```
ActivityManager: Killing com.example.app (adj 0): hpk
```

Note `adj 0` — the app is in the foreground and it still dies. Nothing in your
app can catch this; there is no exception, no callback, no ANR dialog.

Workaround that worked: declare the app as a game in the manifest.

```xml
<application android:appCategory="game" ... >
```

That exempts it from `hpk`. Peak RSS during FLUX.2-klein 4B generation was
~9.3 GB and it survived. This is an OEM-specific hack, not portable advice —
but if your app vanishes mid-generation with no error and your model is
multi-gigabyte, check for a vendor killer before blaming your code.

## 4. Build-time gotchas (the actual reason this repo exists)

- **Two different `libvulkan.so`.** You need the *host* LunarG SDK for
  `glslc` and SPIRV-Headers (shader compilation runs on the build machine), and
  the *NDK stub* for linking (the real implementation comes from the vendor
  driver at runtime). Pointing both at the same one fails confusingly.
- **Undefined `vk*` symbols.** The NDK stub does not export everything ggml
  calls. NDK adds `-Wl,--no-undefined` by default, so override the linker flags
  with `-Wl,-z,undefs`.
- **The linker silently drops the Vulkan backend.** It registers itself via a
  static initialiser in a static archive, so `--gc-sections` can remove it and
  you get a working-looking .so with no GPU path. Force it:
  `-Wl,--whole-archive ... -lggml-vulkan -Wl,--no-whole-archive -Wl,-no-gc-sections`.
- **Stripping matters.** Unstripped the library is ~110 MB; stripped ~80 MB. If
  you plan to distribute it as a download rather than bundling it in the APK
  (Telegram bots cap at 50 MB, and Play has its own limits), ship the stripped
  one and pin its SHA-256.

## 5. Reading result tensors

Not Adreno-specific, but it will cost you a day if you get it wrong:
`sd_result_get_image()` returns U8 `[C,W,H]` with **dim 0 contiguous**, i.e.
element `(x,y,k)` at `k + C*x + C*W*y` — byte-for-byte interleaved RGB. It is
*not* PyTorch-style planar CHW. The header says "contiguous dimension first";
read that literally. A planar read gives fine-grid colour noise while everything
else reports success.
