# Build Swift from source on NixOS (compiler + C++ interop + Foundation)

**The entry point for contributing to [`swiftlang/swift`](https://github.com/swiftlang/swift)
from NixOS.** The official `build-script` doesn't build on NixOS; this makes the full
from-source contributor loop — build, test, send a PR — work.

A Nix dev shell (`flake.nix`) + build script (`dobuild.sh`) that build the **Swift toolchain
from source on NixOS**. That's the compiler, the standard library, the C++ interop overlay
(`CxxStdlib`), libdispatch, and Foundation — none of which the stock `swift/utils/build-script`
builds on NixOS out of the box, because NixOS has no `/usr/include`, `/usr/lib/gcc`, bare
`libcurses.so`, etc. All the NixOS-specific workarounds live in `flake.nix` + `dobuild.sh`; no
Swift / LLVM / Foundation source is patched.

**Status: it works**, including the **C++ interoperability overlay (`CxxStdlib`)** and
**Foundation**. The built `swiftc` compiles, links, and runs real Swift programs, can
`import CxxStdlib` and call into C++, and `import Foundation`:

> **Heads up:** a bare `swiftc` on your `PATH` is the **bootstrap** compiler Nix uses to
> *build* Swift (`Swift version 5.10.1`), not the one you built. The compiler you build
> lives in the build dir as `$B/bin/swiftc` (`B` is defined in §3). The snippets below use
> that built compiler — that's the only `swiftc` that reports `6.5-dev`.

```
$ B=build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/swift-linux-x86_64
$ "$B/bin/swiftc" --version
Swift version 6.5-dev (LLVM …, Swift …)

$ echo 'print((1...5).map{$0*$0})' > hi.swift && "$B/bin/swiftc" hi.swift -o hi && ./hi
[1, 4, 9, 16, 25]

# C++ interop (needs two -Xcc flags on NixOS — see §3):
$ "$B/bin/swiftc" -cxx-interoperability-mode=default \
    -Xcc --gcc-toolchain=$SWIFT_GCC_TOOLCHAIN -Xcc --sysroot=$SWIFT_GLIBC_SYSROOT \
    -I ./cxxmod main.swift -o demo && ./demo
hello from C++ std::string

# Foundation (built from source; consume via an installed SDK — see §3):
$ echo 'import Foundation; print(UUID(), Date(timeIntervalSince1970: 0))' > f.swift
$ "$B/bin/swiftc" f.swift -o f <flags, see §3> && ./f
9A1CDB09-… 1970-01-01 00:00:00 +0000
```

A clean single `dobuild.sh` run completes with **exit 0 (0 failures)** including Foundation.
The build-system root cause behind the Foundation "hang" (traced with gdb) is documented at
the bottom. **Run only one build at a time** — overlapping `build-script` runs share the
same `build/` dir and
corrupt each other.

> This repo is **only the recipe** (flake + script + notes). You fetch Apple's Swift
> source yourself (next section).

### Where to go next

- **README** (this file) — reproduce the working build.
- **[CONTRIBUTING.md](./CONTRIBUTING.md)** — the edit → build → test → PR loop for contributing
  to `swiftlang/swift`.
- **[HACKING.md](./HACKING.md)** — why NixOS fights a from-source build, the five fix
  categories, and the Foundation gdb debugging story.

---

## 1. Get the Swift source

Built against `swiftlang/swift` `main` HEAD (nixpkgs pinned in `flake.lock` — gcc 15.2.0 /
glibc 2.42). Clone this repo as the workspace, clone Swift into it, then pull the siblings:

```sh
git clone https://github.com/lucasly-ba/swift-nixos.git swift-workspace
cd swift-workspace
git clone https://github.com/swiftlang/swift.git
nix develop --command swift/utils/update-checkout --clone
```

Run `update-checkout` through `nix develop` so the flake's `python3` is on PATH (NixOS has
none, so running it directly gives `env: 'python3': No such file or directory`). Layout:

```
swift-workspace/        ← this repo (swift-nixos), cloned
├── flake.nix flake.lock dobuild.sh .gitignore
├── swift/              ← swiftlang/swift
├── llvm-project/  llbuild/  cmark/  swift-syntax/  …   ← from update-checkout
└── build/             ← created by the build (large; keep on a roomy filesystem)
```

### Keeping the workspace consistent on `main`

- **Re-run `update-checkout` after every `git pull` of `swift/`.** It pins the sibling repos
  (llvm-project, swift-syntax, corelibs, …) to the revisions that match your `swift/` HEAD,
  keeping the workspace internally consistent — the siblings move *with* swift. Run it the
  same way: `nix develop --command swift/utils/update-checkout`.
- **The flake/`dobuild.sh` fixes are the part you maintain.** The NixOS-specific fixes (the
  `#include_next` glibc ordering, the sysroot, the rpath/`-rpath-link` flags — see *What was
  fixed* below) are tuned against the pinned toolchain (gcc 15.2.0 / glibc 2.42). Building
  newer `main` source against that fixed toolchain is where breakage appears first: the
  question is "did Swift change, or did a toolchain assumption change" — the flake is the
  part you own.

Cheap insurance: when a build comes up clean, note the `swift/` commit hash
(`git -C swift rev-parse HEAD`). If a later `git pull` breaks the build, that gives you a
"this worked" coordinate to `git log` / bisect against.

---

## 2. Build

From `swift-workspace/`:

```sh
nix develop --command bash dobuild.sh foundation
```

### Pick the build that matches what you want to work on

| I want to contribute to...        | Dev shell                | Build command             |
| --------------------------------- | ------------------------ | ------------------------- |
| Compiler (Sema, SIL, diagnostics) | `nix develop .#compiler` | `./dobuild.sh compiler`   |
| Standard library                  | `nix develop .#compiler` | `./dobuild.sh compiler`   |
| Foundation / libdispatch          | `nix develop .#full`     | `./dobuild.sh foundation` |
| C++ interop overlay               | `nix develop .#full`     | `./dobuild.sh foundation` |

`./dobuild.sh compiler` skips Foundation and is the faster loop for compiler/stdlib work.
`./dobuild.sh foundation` builds the whole toolchain (what most people want first). See
CONTRIBUTING.md for the full edit -> rebuild -> test contributor loop.

After a build, sanity-check it with: `nix run .#smoke-test`

`dobuild.sh foundation` wraps `swift/utils/build-script` with the NixOS-specific options the
flake can't deliver any other way — a glibc `-sdk` sysroot for the stdlib's clang-importer, an
`-Xcc --gcc-toolchain` so the C++ interop overlay finds libstdc++, and the corelibs `-sdk` /
link flags that let Foundation build. These **must** go on the build-script command line (the
`EXTRA_CMAKE_OPTIONS` env var only reaches LLVM's CMake, not Swift's). `./dobuild.sh compiler`
is the same minus the libdispatch/Foundation flags.

For the full per-flag rationale, see [HACKING.md](./HACKING.md) (§1, *The build command, flag by
flag*) or the header comment in `dobuild.sh`.

**After editing `flake.nix`** in a way that affects the swift build (e.g. the sysroot),
force a reconfigure (the relevant flags are baked into `build.ninja`):

```sh
rm build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/swift-linux-x86_64/CMakeCache.txt
```

**Disk:** `/` holds `/nix/store` (and `/tmp`); the build dir goes on `/home`. The store
can fill during development — if you hit `ENOSPC`, run `nix-collect-garbage -d`. A full
RelWithDebInfo+debug build needs ~60–100 GB on the build filesystem.

**RAM / "my terminal crashed after ~1h30":** that's the OOM-killer, not a build bug. The
first hour compiles (cheap); then the **link phase** starts, and with `--release-debuginfo`
+ `--debug-swift` each link pulls GBs of debug info into RAM. On a low-RAM laptop the
default (one link per core) blows past memory and the kernel kills processes — sometimes the
terminal/session too. `dobuild.sh` already sets `-DLLVM_PARALLEL_LINK_JOBS=1` to serialise
links. If it still dies, **add swap** — that turns OOM-death into "slow but finishes":

```nix
# configuration.nix — then: sudo nixos-rebuild switch
zramSwap = { enable = true; memoryPercent = 75; };
swapDevices = [ { device = "/swapfile"; size = 16 * 1024; } ];  # 16 GiB
```

Rule of thumb: ~12 GB RAM needs `LLVM_PARALLEL_LINK_JOBS=1` **and** swap; with ≥32 GB you
can raise it to 2–4 to link faster. Confirm a kill with
`journalctl -k -b | grep -i 'oom\|killed process'`.

**Resuming after a crash:** just re-run `nix develop --command bash dobuild.sh foundation`. The build is
incremental (ninja + `--sccache`), so it picks up from the killed step instead of starting
over — don't delete `build/`. (Run it through `nix develop` so the toolchain env is set; a
bare `sh dobuild.sh` outside the dev shell won't work.)

---

## 3. Use the compiler you built

```sh
nix develop
B=build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/swift-linux-x86_64
export LD_LIBRARY_PATH="$B/lib/swift/linux"

# plain Swift — DON'T pass -sdk:
echo 'print("hello from a swiftc I built")' > hello.swift
"$B/bin/swiftc" hello.swift -o hello && ./hello

# C++ interop — pass the gcc-toolchain + sysroot so the importer finds libstdc++:
"$B/bin/swiftc" -cxx-interoperability-mode=default \
  -Xcc --gcc-toolchain="$SWIFT_GCC_TOOLCHAIN" -Xcc --sysroot="$SWIFT_GLIBC_SYSROOT" \
  -I ./cxxmod main.swift -o demo && ./demo
```

- A `warning: libc not found for 'x86_64-unknown-linux-gnu'` at compile time is harmless.
- Without the two `-Xcc` flags, C++ interop fails with *"cannot load underlying module for
  'CxxStdlib'"* — on NixOS the importer can't find libstdc++ on its own.

### `import Foundation`

The build produces `libFoundation.so` + `Foundation.swiftmodule`, but a raw build dir is
not a consumable SDK. Install the corelibs once to assemble the proper module layout
(module maps for `dispatch`, `_FoundationCShims`, `CoreFoundation`, …):

```sh
SDK=$PWD/foundation-sdk
DESTDIR=$SDK ninja -C build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/libdispatch-linux-x86_64 install
DESTDIR=$SDK ninja -C build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/foundation-linux-x86_64 install
SDKLIB=$SDK/usr/lib/swift

export LD_LIBRARY_PATH="$B/lib/swift/linux"          # core runtime only (swiftc keeps its own Foundation)
"$B/bin/swiftc" hello.swift -o hello \
  -sdk "$SWIFT_CORELIBS_SDK" -L "$SWIFT_GCC_LIB" -Xlinker -rpath-link -Xlinker "$SWIFT_GCC_LIB" \
  -L "$B/lib/swift/linux" -Xlinker -rpath-link -Xlinker "$B/lib/swift/linux" \
  -I "$SDKLIB/linux" -I "$SDKLIB" -L "$SDKLIB/linux" \
  -Xlinker -rpath -Xlinker "$B/lib/swift/linux" -Xlinker -rpath -Xlinker "$SDKLIB/linux"
./hello   # e.g.  import Foundation; print(UUID(), JSONSerialization…) — works
```

- `LD_LIBRARY_PATH` for the **swiftc invocation** must NOT include the new Foundation:
  `swiftc` (via `libllbuildSwift`) links the *bootstrap* Foundation and the ABIs differ —
  bake the new Foundation into the program's **rpath** instead, as above.

---

## What was fixed (NixOS-specific)

Each lives in `flake.nix` with inline comments; the git history has one commit per fix.

1. **`#include_next <math.h>` "file not found"** building llbuild — having `glibc.dev` in
   `buildInputs` front-loaded glibc into the C++ include path; clang's dedup then dropped
   the cc-wrapper's correctly-placed copy, so libstdc++'s `<cmath>` couldn't reach glibc.
   Fix: don't add `glibc.dev` as a buildInput; let the wrapper place it.
2. **The just-built (unwrapped) clang that compiles the stdlib** knows no NixOS paths.
   Fixes via `LIBRARY_PATH` (`-lstdc++` / `-lgcc_s`) and `CCC_OVERRIDE_OPTIONS`, which
   injects `--gcc-install-dir` (libstdc++ headers + libs + crt), `-B <glibc>` (glibc crt
   startup objects) and `-idirafter <glibc>/include` (glibc C headers, placed last so
   libstdc++'s `#include_next <math.h>`/`<stdlib.h>` resolves to them). Headers are *not*
   delivered via `CPLUS_INCLUDE_PATH` — that injects like `-isystem`, which `-nostdinc++`
   does **not** suppress, so it leaked gcc's `include/c++` into compiler-rt's sanitizers
   and (under gcc 15) broke them with "redefinition of 'array'". `--gcc-install-dir` *is*
   suppressed by `-nostdinc++`, so compiler-rt stays clean.
3. **`-lcurses`** — nixpkgs has no bare `libcurses.so`; a `libncursesw` compat shim.
   Plus `CC/CXX=clang` (so llbuild doesn't fall back to g++) and
   `-Wno-unused-command-line-argument` (libdispatch's C is built with `-Werror`).
4. **Bootstrap runtime** — `swiftPackages.Foundation`/`Dispatch` for llbuild, and a
   complete `bootstrapSwift` toolchain so the just-built `swift-frontend` can load
   `libdispatch.so` at runtime (nixpkgs uses non-transitive `DT_RUNPATH`).
5. **stdlib swiftc can't find libc / `SwiftGlibc`** — its clang-importer detects libc via
   the *sysroot's* system includes. Built a glibc `swiftSysroot`, passed as `-sdk
   <sysroot>` via the build-script CLI.
6. **C++ interop (`CxxStdlib`)** — two coupled problems, both solved in `flake.nix` +
   `dobuild.sh`:
   - *Link vs. compile conflict.* The overlay's clang-module compile wants glibc's real
     `libc.so` linker script inside the `-sdk` sysroot, but the bare-clang C++ link then
     breaks because `ld` sysroot-prefixes that script's absolute `GROUP()` paths. Fix: keep
     the original `libc.so` and add a **symlink farm** mirroring the glibc store dir *under*
     the sysroot at its own absolute path, so the prefixed path resolves — satisfying both.
   - *libstdc++ delivery.* Don't put gcc's c++ headers in the sysroot (that gives libstdc++
     two file identities → `redefinition of 'piecewise_construct_t'`). Instead deliver it
     via `-Xcc --gcc-toolchain=<nix-gcc>` on every stdlib swiftc, plus
     `-no-verify-emitted-module-interface` (the interface round-trip re-verify can't record
     an `-Xcc` flag, so it would fail to find libstdc++).
7. **Infra** — a `.gitignore` so the Nix flake copies only the recipe files (not the
   60 GB tree), plus disk GC.
8. **Foundation under `--debug-swift`** — building Foundation from source revealed a
   five-layer problem, all fixed via `--common-swift-flags` + an augmented sysroot built in
   the shellHook (`$SWIFT_CORELIBS_SDK`), see *Building Foundation* below.

---

## Building Foundation (and how a gdb backtrace cracked the "hang")

`import Foundation` **works** (`dobuild.sh` passes `--foundation=1 --libdispatch=1`). Getting
there meant building Foundation from source with the just-built compiler — a 5.10.x
Foundation can't be grafted onto a 6.5-dev compiler (incompatible `.swiftmodule` ABI). That
build first *appeared to hang* for 30+ minutes in the `FoundationMacros` step. A **gdb**
backtrace (taking the frontend's stack from a worker thread) showed it was **not** the type
checker — it was the **SIL verifier**, while the compiler **rebuilt swift-syntax from its
`.swiftinterface`**. Root cause: the host `swift-syntax` modules were compiled by the
**bootstrap Swift 5.10.1** (build-script's `CMAKE_Swift_COMPILER`), so the 6.5-dev compiler
can't load them and rebuilds from the interface. On NixOS that rebuild — and the resulting
corelibs links — break five different ways. The fix delivers four flags to the **corelibs
only** (via `--common-swift-flags`, never the compiler/stdlib), plus an augmented sysroot:

1. **`-sil-verify-none`** — skip the assert-only SIL verifier that grinds for minutes per
   swift-syntax module. (Do *not* add `-disable-sil-ownership-verifier`: it trips an assert
   in `SemanticARCOpts` under `-O`.)
2. **`-sdk $SWIFT_CORELIBS_SDK`** — the interface rebuild needs a sysroot to find
   `SwiftGlibc` (NixOS `/usr/include` is empty; the importer ignores `C_INCLUDE_PATH`/
   `SDKROOT`). Without it the rebuild retries forever — the real "hang".
3. **augmented sysroot** — a plain glibc `-sdk` redirects swiftc's runtime lookup, so links
   can't find `swiftrt.o`. `$SWIFT_CORELIBS_SDK` (built in the shellHook) is glibc **plus a
   symlink to the just-built Swift runtime**, so one `-sdk` serves both the compile and the
   links.
4. **`-L $SWIFT_GCC_LIB -Xlinker -rpath-link …`** — with `-sdk`, `ld` can't find
   `libswiftCore.so`'s indirect `libstdc++.so.6` NEEDED (an absolute `/nix/store` path
   outside the sysroot). Point `ld` at the gcc lib.
5. **`-L $SWIFT_RUNTIME_LIB -Xlinker -rpath-link …`** — likewise so the corelibs *executable*
   links (`plutil`, FoundationNetworking) resolve `libFoundation.so`'s indirect
   `libswiftSynchronization.so` NEEDED.

The toggles are written `--foundation=1 --libdispatch=1` (not bare) so build-script's
argparse doesn't swallow the space-containing `--common-swift-flags` value.

A future cleaner fix is to make the build compile `swift-syntax` with the just-built 6.5-dev
compiler, so its binary modules load directly and no `.swiftinterface` rebuild happens.

---

## Status summary

| Component                         | State                                    |
|-----------------------------------|------------------------------------------|
| Swift compiler + core stdlib      | ✅ builds, runs real programs            |
| C++ interop overlay (`CxxStdlib`) | ✅ builds, verified `import CxxStdlib`    |
| libdispatch                       | ✅ builds                                |
| Foundation                        | ✅ builds, verified `import Foundation` (Date/JSON/UUID/NSString…) |
| Relocatable installed toolchain   | ⚠️ assemble with `ninja … install DESTDIR=…` (see *import Foundation*) |

A clean single `dobuild.sh` run builds the compiler, the stdlib, the C++ interop overlay,
libdispatch **and Foundation**, exiting 0 (0 failures) in ~40 min on a warm cache.
