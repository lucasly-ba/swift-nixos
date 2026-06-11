# HACKING — building Swift from source on NixOS, the story and how to continue

This is the **narrative + continuation guide**. `README.md` is the *recipe* (how to
reproduce the working build); this file explains **how we got there**, the **mental model**
for why NixOS fights a from-source Swift build, the **debugging techniques** that worked, and
the **open frontier** so someone (future-you, or a successor) can keep going.

Everything lives in two files only — `flake.nix` (the environment) and `dobuild.sh` (the
build command). **No Swift / LLVM / Foundation source is patched.** The git history has one
commit per fix; read it alongside this doc.

> **Provenance / how to read this.** This document is a **retrospective synthesis**, written
> in a single pass — not a live journal kept from the first build. The work spans several
> sessions; this file was assembled from two contemporaneous records: the **git history**
> (one commit per fix, with detailed messages) and the author's **running working notes**.
> So calibrate trust accordingly: the early build-up (§2, items 1–8 — i386 builtins, include
> ordering, the bootstrap compiler, the curses shim, the bare-clang toolchain, the glibc
> sysroot, C++ interop) is **reconstructed** from those commits and notes; the **Foundation
> deep-dive (§3)** and the **test-suite frontier (§5)** are **first-hand** from the session
> that wrote this. When in doubt, the commit history is the primary source — this doc is the
> map, the commits are the territory.

---

## 1. The mental model: why NixOS breaks the build

Apple's `utils/build-script` assumes a **FHS** Linux (Filesystem Hierarchy Standard):
`/usr/include`, `/usr/lib/gcc`, a system `cc` that knows where glibc/libstdc++/crt objects
live, `libcurses.so`, etc. **NixOS has none of that** — every library is an isolated
`/nix/store/<hash>-<name>` path, and there is no global `/usr`. So the build breaks wherever
a tool assumes FHS. The breakages fall into **five recurring categories**; almost every fix
is an instance of one:

1. **Header search order.** Mixing glibc and libstdc++ headers in the wrong order breaks
   libstdc++'s `#include_next` (it searches *forward* only). The nix cc-wrapper already
   orders them right; our job is to *not* disturb that, and to feed the *unwrapped* compilers
   the headers they're missing — in the right position (`CPLUS_INCLUDE_PATH`/`C_INCLUDE_PATH`,
   which append like `-idirafter`, never `CPATH`).

2. **The bare, freshly-built clang is not a toolchain.** The build compiles its *own* clang,
   then uses that **unwrapped** clang (no nix cc-wrapper) to build the stdlib/runtime. It
   knows no NixOS paths, so it can't find `-lstdc++`, `crt1.o`, etc. We make it complete via
   env: `LIBRARY_PATH` (for `-l` libs), `CCC_OVERRIDE_OPTIONS` (`-B<glibc>` + `--gcc-install-dir`
   for crt objects, which clang finds via toolchain detection, *not* `LIBRARY_PATH`).

3. **Runtime loading (`DT_RUNPATH` vs `RPATH`).** nixpkgs forces non-transitive `DT_RUNPATH`,
   but Swift's build assumes transitive `RPATH` (a tool's rpath finds the *whole* runtime).
   So just-built tools fail to `dlopen` libdispatch/Foundation at runtime. Fix: a complete
   `bootstrapSwift` host toolchain whose `lib/swift/linux` actually contains everything, so
   the `LD_LIBRARY_PATH` build-script bakes is complete.

4. **The Swift `ClangImporter` needs a *sysroot*, not env.** When swiftc compiles an overlay
   (`Glibc`, `CxxStdlib`) it detects the target libc by asking the clang **toolchain** for its
   sysroot-based system includes. It **ignores** `-Xcc -idirafter`, `CPATH`, `C_INCLUDE_PATH`,
   and even `SDKROOT`. The *only* lever is `-sdk <dir>` (or `-isysroot`). Hence we build a
   glibc `swiftSysroot` and pass `-sdk`.

5. **Linker resolution under `--sysroot`.** Once you pass `-sdk`, clang adds `--sysroot=<dir>`
   to the **link**, and `ld` then can't find dependencies that live at absolute `/nix/store`
   paths *outside* the sysroot (indirect `NEEDED` libs like `libstdc++.so.6`,
   `libswiftSynchronization.so`). Fix: explicit `-L <dir> -Xlinker -rpath-link -Xlinker <dir>`
   for each, and put what the sysroot must own (glibc, the swift runtime) *inside* it.

If you hit a new wall, first ask: *which of these five is it?* That usually points at the fix.

---

## 2. The journey (the walls, in order)

Condensed; the git log and the inline comments have the full detail. Roughly the order we hit
them building up from nothing:

1. **i386 compiler-rt builtins** fail (no 32-bit headers) → `COMPILER_RT_DEFAULT_TARGET_ONLY`.
2. **`#include_next <math.h>` not found** building llbuild → category 1: do *not* put
   `glibc.dev` in `buildInputs` (it front-loads glibc and inverts the include order).
3. **Bootstrap compiler**: Swift 6.5's stdlib needs a pre-existing Swift ≥5.9 → nixpkgs
   `swift` 5.10.1.
4. **`-lcurses`**: nixpkgs has only `libncursesw` → a compat-shim derivation (and it must
   *mirror* the soname libs, or binaries fail to load at runtime).
5. **Bootstrap runtime / `libdispatch.so` not found at runtime** → category 3, `bootstrapSwift`.
6. **The bare clang building the stdlib** can't find glibc/libstdc++/crt → category 2.
7. **`no such module 'SwiftGlibc'`** building the Glibc overlay → category 4, the `-sdk`
   glibc sysroot. Delivering it was its own saga: env `EXTRA_CMAKE_OPTIONS` only reaches the
   *LLVM* cmake, not swift's; it had to go on the `build-script` **command line**
   (`SWIFT_SDK_LINUX_ARCH_x86_64_PATH`).
8. **C++ interop (`CxxStdlib`)** — a compile-vs-link conflict over glibc's `libc.so` linker
   script inside the sysroot, plus libstdc++ "two file identities". Solved with a glibc-only
   sysroot + a symlink farm + `-Xcc --gcc-toolchain` + `-no-verify-emitted-module-interface`.
9. **Foundation "hangs"** — see §3, the deepest one.

Two infra notes that bit hard: the workspace **must be a git repo** or every `nix develop`
copies the whole ~60 GB tree into the store (fills the disk); and **run only one build at a
time** (overlapping `build-script` runs share `build/` and corrupt each other).

---

## 3. The Foundation deep-dive (how to debug a "hang")

Foundation *appeared* to hang for 30–40 min in the `FoundationMacros` step. The lesson here
is the **method**, which transfers to any future wall:

1. **Is it a hang or a spin?** A blocking deadlock sits at **0 % CPU** in `futex_wait`; a spin
   burns **100 % CPU**. Distinguish a real compile from a pathological spin by **RSS trend**:
   a compile grows memory (allocating AST/SIL); a spin holds it flat. (`cpucheck.sh` /
   `spincheck.sh` in the history did this.)
2. **Get the stack.** `gdb` couldn't *attach* (Yama `ptrace_scope=1` blocks attaching to a
   sibling). Trick: launch the frontend **under** gdb (gdb becomes the parent → allowed):
   `gdb -batch -ex run … --args swift-frontend …`, then `kill -INT` the gdb after warm-up to
   interrupt and `bt`. The backtrace is the ground truth.
3. **What it revealed.** Main thread waiting on a worker; the worker in `SILVerifier`, inside
   `ImplicitModuleInterfaceBuilder` — i.e. the compiler was **rebuilding swift-syntax from its
   `.swiftinterface`**, and the **assert-only SIL verifier** was grinding. *Why* the rebuild?
   The host `swift-syntax` modules were compiled by the **bootstrap 5.10.1** (build-script's
   `CMAKE_Swift_COMPILER`), so the 6.5-dev compiler can't load them and falls back to the
   interface.
4. **The fixes** (all to the **corelibs only**, via `--common-swift-flags` — never the
   compiler/stdlib, which stay fully verified):
   - `-sil-verify-none` — skip the assert verifier (NOT `-disable-sil-ownership-verifier`,
     which asserts in `SemanticARCOpts` under `-O`).
   - `-sdk $SWIFT_CORELIBS_SDK` — category 4: the rebuild needs glibc to find `SwiftGlibc`.
     Without it the rebuild *retries forever* — that, not the verifier, was the real "hang".
   - An **augmented sysroot** (`$SWIFT_CORELIBS_SDK`, built in the shellHook because it must
     point at the build tree): glibc **+ a symlink to the just-built swift runtime**, so one
     `-sdk` serves both the compile (`SwiftGlibc`) and the links (`swiftrt.o`).
   - `-L $SWIFT_GCC_LIB …` and `-L $SWIFT_RUNTIME_LIB …` (`-rpath-link`) — category 5: indirect
     `libstdc++.so.6` and `libswiftSynchronization.so` `NEEDED`s.
   - Delivered with toggles `--foundation=1 --libdispatch=1` (bare `--foundation` makes
     argparse swallow the space-containing flag value).

A **build dir is not a consumable SDK**: to *use* Foundation, `ninja … install` the corelibs
into a `DESTDIR` (assembles the `dispatch`/`_FoundationCShims` module maps), then point swiftc
at it. And the swiftc *invocation* must not have the new Foundation on `LD_LIBRARY_PATH` —
swiftc itself links the bootstrap Foundation (ABIs differ); bake the new one into the
program's rpath instead.

---

## 4. A debugging playbook (transferable)

- **Reproduce one step in isolation.** Pull the exact failing command from `build.ninja`
  (or `/proc/<pid>/cmdline` of a running frontend), run it by hand, and bisect flags. Most
  fixes were found this way in ~2 min instead of a 40 min build.
- **`swiftc -### file.swift`** prints the real frontend + clang link invocations without
  running them — diff with/without a flag to see exactly what it changes (this is how the
  `--sysroot` link breakage was pinned).
- **`build-script --dry-run`** shows the cmake configure lines — use it to confirm a flag
  actually reaches the sub-project's `CMAKE_*_FLAGS` before committing to a long build.
- **`readelf -d` / `patchelf --print-needed`** on a `.so` shows its `NEEDED` libs — the way
  to find indirect link dependencies (category 5).
- **Watch the right things:** CPU% + RSS trend (hang vs spin vs slow), module-cache `.lock`
  vs completed `.swiftmodule` files, and root `/` disk (the store fills, not `/home`).

---

## 5. The frontier — how to continue

What works today: **compiler + stdlib + C++ interop + libdispatch + Foundation**, all from
source, `dobuild.sh` exits 0. Open items, roughly in priority for *contributing*:

1. **Run the test suite (`check-swift` / lit).** This is the real gap before you can validate
   a compiler change like an Ubuntu contributor. `dobuild.sh` sets `SWIFT_INCLUDE_TESTS=FALSE`;
   flip it to `TRUE`, `rm` the swift `CMakeCache.txt`, rebuild, then run a small slice first,
   e.g. `utils/run-test --build-dir build/Ninja-RelWithDebInfoAssert+swift-DebugAssert
   swift/test/Parse`. Expect NixOS-specific issues in tests that compile+link (they need the
   dev-shell env; some may assume FHS paths or `RUN:` lines with system tools). Getting a
   green lit slice = the "I can develop Swift on NixOS like on Ubuntu" milestone.
2. **The clean Foundation fix.** Make the build compile `swift-syntax` with the just-built
   6.5-dev compiler so its binary modules load directly — then *none* of the §3 corelibs
   flags are needed (no `.swiftinterface` rebuild, no verifier, no augmented sysroot). This is
   the "correct" fix; the current one is a (working) workaround.
3. **Auto-assemble a relocatable toolchain.** Add `--install-swift`/`--install-foundation`/
   `--install-libdispatch` (+ destdir) to `dobuild.sh` so the build produces a consumable SDK
   directly, instead of the manual `ninja … install` in `README` §3.
4. **Upstream caveats.** NixOS is not an officially supported build platform; CI runs
   Ubuntu/macOS. Treat a local green build as necessary, not sufficient — always rely on CI
   for a PR.

If you pick up #1 and hit a wall, apply §1's "which of the five categories is this?" and §4's
playbook. That's the whole method.
