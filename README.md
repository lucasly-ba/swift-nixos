# Build Swift from source on NixOS

A Nix dev shell (`flake.nix`) + build script (`dobuild.sh`) that build the **Swift
compiler from source on NixOS** — which the stock `swift/utils/build-script` cannot do
out of the box, because NixOS has no `/usr/include`, `/usr/lib/gcc`, bare `libcurses.so`,
etc. All the NixOS-specific workarounds live in `flake.nix` (no Swift/LLVM source is
patched).

**Status: it works.** The built `swiftc` compiles, links, and runs real Swift programs:

```
$ swiftc --version
Swift version 6.5-dev (LLVM …, Swift …)
$ echo 'print((1...5).map{$0*$0})' > hi.swift && swiftc hi.swift -o hi && ./hi
[1, 4, 9, 16, 25]
```

Known limitations are listed at the bottom (no Foundation, no C++ interop, and
`build-script` exits non-zero because a *test-only* stdlib variant still fails — the
compiler + standard library themselves are complete and usable).

> This repo is **only the recipe** (flake + script + notes). You fetch Apple's Swift
> source yourself (next section).

---

## 1. Get the Swift source

This was developed/tested against:

- Swift: `swiftlang/swift` `main` @ **`87350fc6de2da3156bb7e893c45d673df4ca3cb7`**
  (snapshot 2026-05-27). Other revisions may need tweaks (some fixes reference current
  file/line locations in the Swift source).
- nixpkgs: pinned in `flake.lock` (gcc 15.2.0 / glibc 2.42 toolchain).

```sh
mkdir swift-workspace && cd swift-workspace
git clone https://github.com/swiftlang/swift.git
( cd swift && git checkout 87350fc6de2da3156bb7e893c45d673df4ca3cb7 )
# Clone the sibling repos (llvm-project, llbuild, cmark, swift-syntax, corelibs, …)
swift/utils/update-checkout --clone
```

Then drop **this repo's** `flake.nix`, `flake.lock`, `dobuild.sh` (and `.gitignore`) into
`swift-workspace/` (the parent of `swift/`). Final layout:

```
swift-workspace/
├── flake.nix          ← from this repo
├── flake.lock         ← from this repo
├── dobuild.sh         ← from this repo
├── swift/             ← apple/swiftlang swift checkout
├── llvm-project/
├── llbuild/  cmark/  swift-syntax/  swift-corelibs-*/  …   ← from update-checkout
└── build/             ← created by the build (large; keep on a roomy filesystem)
```

---

## 2. Build

From `swift-workspace/`:

```sh
nix develop --command bash dobuild.sh
```

`dobuild.sh` runs `utils/build-script` with three NixOS-specific options (these must go
on the build-script command line — the `EXTRA_CMAKE_OPTIONS` env var only reaches LLVM's
CMake, not Swift's):

```sh
utils/build-script --release-debuginfo --debug-swift --sccache \
  "--extra-cmake-options=-DSWIFT_SDK_LINUX_ARCH_x86_64_PATH=$SWIFT_GLIBC_SYSROOT" \
  "--extra-cmake-options=-DSWIFT_ENABLE_EXPERIMENTAL_CXX_INTEROP:BOOL=FALSE" \
  "--extra-cmake-options=-DSWIFT_INCLUDE_TESTS:BOOL=FALSE"
```

`$SWIFT_GLIBC_SYSROOT` is exported by the flake's `shellHook` (a glibc sysroot the
stdlib's clang-importer needs to find libc).

**After editing `flake.nix`** in a way that affects the swift build (e.g. the sysroot),
force a reconfigure (the relevant flags are baked into `build.ninja`):

```sh
rm build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/swift-linux-x86_64/CMakeCache.txt
```

**Disk:** `/` holds `/nix/store` (and `/tmp`); the build dir goes on `/home`. The store
can fill during development — if you hit `ENOSPC`, run `nix-collect-garbage -d`. A full
RelWithDebInfo+debug build needs ~60–100 GB on the build filesystem.

---

## 3. Use the compiler you built

```sh
nix develop
B=build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/swift-linux-x86_64
export LD_LIBRARY_PATH="$B/lib/swift/linux"
"$B/bin/swiftc" hello.swift -o hello && ./hello
```

- **Don't pass `-sdk`** for normal use — the glibc sysroot is only for the stdlib build.
- A `warning: libc not found for 'x86_64-unknown-linux-gnu'` at compile time is harmless.

---

## What was fixed (NixOS-specific)

Each lives in `flake.nix` with inline comments; the git history has one commit per fix.

1. **`#include_next <math.h>` "file not found"** building llbuild — having `glibc.dev` in
   `buildInputs` front-loaded glibc into the C++ include path; clang's dedup then dropped
   the cc-wrapper's correctly-placed copy, so libstdc++'s `<cmath>` couldn't reach glibc.
   Fix: don't add `glibc.dev` as a buildInput; let the wrapper place it.
2. **The just-built (unwrapped) clang that compiles the stdlib** knows no NixOS paths.
   Fixes: `CPLUS_INCLUDE_PATH` (libstdc++ + glibc headers), `LIBRARY_PATH` (`-lstdc++` /
   `-lgcc_s`), and `CCC_OVERRIDE_OPTIONS` (`--gcc-install-dir` + `-B <glibc>` for the crt
   startup objects).
3. **`-lcurses`** — nixpkgs has no bare `libcurses.so`; a `libncursesw` compat shim.
   Plus `CC/CXX=clang` (so llbuild doesn't fall back to g++) and
   `-Wno-unused-command-line-argument` (libdispatch's C is built with `-Werror`).
4. **Bootstrap runtime** — `swiftPackages.Foundation`/`Dispatch` for llbuild, and a
   complete `bootstrapSwift` toolchain so the just-built `swift-frontend` can load
   `libdispatch.so` at runtime (nixpkgs uses non-transitive `DT_RUNPATH`).
5. **stdlib swiftc can't find libc / `SwiftGlibc`** — its clang-importer detects libc via
   the *sysroot's* system includes. Built a glibc `swiftSysroot`, passed as `-sdk
   <sysroot>` via the build-script CLI; `libc.so`/`libm.so` (linker scripts with absolute
   paths) are rewritten with relative names so `ld` doesn't sysroot-prefix them.
6. **Infra** — a `.gitignore` so the Nix flake copies only the recipe files (not the
   60 GB tree), plus disk GC.

---

## Known limitations / contributions welcome

- **No C++ interop overlay (`CxxStdlib`).** Genuine clang/ld conflict on NixOS: the
  compile needs glibc's `libc.so` *inside* the `-sdk` sysroot, but the link breaks with it
  there (`ld` sysroot-prefixes the linker script's absolute paths). Re-enabling it needs
  that resolved (e.g. make the C++ link find glibc *outside* the sysroot first).
- **No Foundation.** Not built (`--skip-build-foundation`). `import Foundation` reports
  "no such module". A 5.10.x Foundation can't just be grafted onto a 6.5-dev compiler
  (incompatible `.swiftmodule` format) — it needs building from source.
- **`build-script` exits non-zero.** Only because the `swift-test-stdlib` *test* variant
  still fails (`SWIFT_INCLUDE_TESTS:BOOL=FALSE` didn't skip it — it's pulled in by
  `--build-stdlib-deployment-targets all`). The compiler + stdlib build fine; this just
  means there's no clean `--install-destdir` toolchain yet.
