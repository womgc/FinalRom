# Vendored xdelta3 sources

The upstream xdelta3 (VCDIFF) library is vendored in this directory, so the
CMake build defines `XDELTA3_AVAILABLE` and compiles real xdelta patching.

- Source: https://github.com/jmacd/xdelta — the `xdelta3/` directory.
- Version: 3.1.1 (commit `0cccad8`).
- License: Apache-2.0 (see `LICENSE` here).

## What is here, and why

`xdelta3_ffi.c` does a **unity build**: it `#include`s `xdelta3.c`, which in turn
`#include`s the rest of the `xdelta3-*.h` family. So the *whole* header set is
required — not just `xdelta3.h` + `xdelta3.c`:

- `xdelta3.c`, `xdelta3.h`
- `xdelta3-internal.h`, `xdelta3-list.h`, `xdelta3-hash.h`, `xdelta3-cfgs.h`,
  `xdelta3-decode.h`, `xdelta3-blkcache.h`, `xdelta3-merge.h`
- `xdelta3-second.h`, `xdelta3-djw.h`, `xdelta3-fgk.h`, `xdelta3-lzma.h`
  (secondary compressors)
- `xdelta3-main.h`, `xdelta3-test.h` are kept for completeness but are **not**
  compiled (only used under `XD3_MAIN` / `REGRESSION_TEST`, which we never set;
  `xdelta3-main.h` is not even portable to MSVC — it needs `unistd.h`).

## Secondary compression: DJW + LZMA

The build enables both DJW and LZMA secondary compression so patches made with
`-S djw` (the common ROM-patch case) and `-S lzma` both decode. This is
configured in `../CMakeLists.txt`:

- `SECONDARY_DJW=1` — DJW is header-only, no external dependency.
- `HAVE_LZMA_H` — makes `xdelta3.c` set `SECONDARY_LZMA=1` and pull in
  `xdelta3-lzma.h`, which calls liblzma. liblzma (xz) is vendored under
  `../xz/` and linked statically.
- `LZMA_API_STATIC` — required so liblzma's headers don't mark its entrypoints
  `__declspec(dllimport)` (we link the static lib, not a DLL).

## Updating

Re-copy `xdelta3.c` + all `xdelta3*.h` + `LICENSE` from the upstream `xdelta3/`
directory. No edits to the upstream files are needed (all configuration is via
compile definitions in `../CMakeLists.txt`).
