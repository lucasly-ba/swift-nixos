# Contributing to Swift — from NixOS

This is a practical, copy-paste guide to **building the Swift compiler from source on NixOS
and contributing a change upstream to [`swiftlang/swift`](https://github.com/swiftlang/swift)**.
It assumes the NixOS build recipe in this repo (`flake.nix` + `dobuild.sh`) is already working
— see [`HACKING.md`](./HACKING.md) for *how* that recipe was built and *why* each piece exists.

If you are new to open source: the thing you actually "contribute" is a small change to the
`swift/` source tree plus a test, sent as a GitHub pull request. Everything NixOS-specific in
this guide is about *building and testing locally* — it never ends up in your PR. A reviewer
cannot tell you built on NixOS.

> **Conventions in this doc**
> - `$ROOT` = this workspace, `~/afs/swift`.
> - `$B`   = the build directory, `build/Ninja-RelWithDebInfoAssert+swift-DebugAssert`.
> - Every command runs inside the Nix dev shell. Either prefix with `nix develop --command`,
>   or run `nix develop` once and stay in the subshell (or let `direnv` enter it automatically).
> - `swift/` is a full checkout of `swiftlang/swift` (its `origin`). `llvm-project/`,
>   `swift-corelibs-foundation/`, etc. are the sibling repos the build needs.

---

## 0. The whole loop in 4 lines

```bash
cd ~/afs/swift
nvim swift/lib/Sema/...                 # 1. edit compiler/stdlib source
nix develop -c ninja -C build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/swift-linux-x86_64 bin/swift-frontend   # 2. incremental rebuild
nix develop -c build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/llvm-linux-x86_64/bin/llvm-lit -s build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/swift-linux-x86_64/test-linux-x86_64/<YourTest>.swift  # 3. run the test
git -C swift commit ... && git -C swift push fork my-branch   # 4. open a PR
```

The rest of this document explains each step.

---

## 1. One-time setup

### 1a. The dev shell
Everything happens inside the Nix dev shell defined by `flake.nix`:

```bash
cd ~/afs/swift
nix develop            # drops you in a shell with the whole NixOS toolchain wired up
```

You can also prefix any single command with `nix develop --command <cmd>` instead of entering
the subshell. If you use `direnv`, the shell is entered automatically when you `cd` in.

### 1b. Confirm the repos are present
```bash
ls swift llvm-project swift-corelibs-foundation swift-corelibs-libdispatch
git -C swift remote -v          # origin -> git@github.com:swiftlang/swift.git
git -C swift branch --show-current   # main
```

### 1c. (For contributing) fork and add your remote
Fork `swiftlang/swift` on GitHub (button top-right → creates `github.com/<you>/swift`), then:

```bash
git -C swift remote add fork git@github.com:<you>/swift.git
git -C swift fetch origin
```

You now have two remotes in `swift/`: `origin` (the real Swift repo, read-only for you) and
`fork` (yours, where you push branches).

---

## 2. Building the full toolchain (first time, ~40 min)

```bash
cd ~/afs/swift
nix develop --command bash dobuild.sh foundation 2>&1 | tee /tmp/swift-build.log
```

`dobuild.sh` wraps `swift/utils/build-script` with the NixOS-specific flags the flake can't
deliver any other way (glibc sysroot, gcc-toolchain for C++ interop, corelibs link flags). A
clean run exits `0`. It builds: the **compiler**, the **standard library**, **C++ interop**
(`CxxStdlib`), **libdispatch**, and **Foundation**.

If you're only changing the compiler or standard library (not Foundation), `./dobuild.sh
compiler` skips libdispatch/Foundation for a faster loop — see the build-target table in
[`README.md`](./README.md) (§2) for which shell + command to use.

> **Run only ONE build at a time.** Two `build-script`/`ninja` runs in the same build dir clobber
> each other. Also watch free space on `/` (the Nix store) — `nix-collect-garbage -d` reclaims it.

Output lands in `$B`. The compiler you just built:

```bash
build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/swift-linux-x86_64/bin/swiftc   # and swift-frontend, etc.
```

### Enabling the test suite
By default `dobuild.sh` sets `SWIFT_INCLUDE_TESTS=FALSE` (faster). To run the lit tests you need
the generated test tree, so build the tests-on variant once:

1. Edit `dobuild.sh`: change `-DSWIFT_INCLUDE_TESTS:BOOL=FALSE` → `TRUE`.
2. Force a reconfigure: `rm build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/swift-linux-x86_64/CMakeCache.txt`
   *(note: this cascades a ~40 min Foundation rebuild — unavoidable, one-time).*
3. Re-run `nix develop --command bash dobuild.sh foundation`.

This generates `$B/swift-linux-x86_64/test-linux-x86_64/`, which mirrors `swift/test/`.

---

## 3. The edit → build → test loop (incremental)

This is your day-to-day cycle. **You do not rebuild from scratch** — `ninja` recompiles only
what changed (and `sccache` caches object files across rebuilds, so a one-file change is often
under a minute).

### Worked example (a real first contribution)
Improve a diagnostic's wording. We changed the "assignment in a condition" error from
`a boolean context` to `a Boolean context` (matching Swift's prose convention):

**1. Edit the compiler** — `swift/include/swift/AST/DiagnosticsSema.def`:
```diff
 ERROR(use_of_equal_instead_of_equality,none,
-      "use of '=' in a boolean context, did you mean '=='?", ())
+      "use of '=' in a Boolean context, did you mean '=='?", ())
```

**2. Update every test that checks that message** (grep finds them):
```bash
grep -rn "boolean context, did you mean" swift/test/
# update the // expected-error {{...}} text in each match
```
(Tests: `Constraints/assignment.swift`, `Constraints/diagnostics.swift`,
`Constraints/result_builder_diags.swift`, `decl/func/operator.swift`.)

**3. Rebuild just the compiler** (~40 s here, thanks to sccache):
```bash
nix develop -c ninja -C build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/swift-linux-x86_64 bin/swift-frontend
```

**4. Run the affected tests:**
```bash
B=build/Ninja-RelWithDebInfoAssert+swift-DebugAssert
nix develop -c $B/llvm-linux-x86_64/bin/llvm-lit -s \
  $B/swift-linux-x86_64/test-linux-x86_64/Constraints/assignment.swift \
  $B/swift-linux-x86_64/test-linux-x86_64/Constraints/diagnostics.swift
# -> Passed: 2 (100.00%)
```

If you mismatch the message and the test, the test **fails** (`expected-error` not found) — that
is the test doing its job. That round-trip *is* the contributor loop.

### Which ninja target to rebuild
| You changed…                          | Rebuild target                                  |
|---------------------------------------|-------------------------------------------------|
| Compiler (`swift/lib/**`, `*.def`)    | `bin/swift-frontend`                             |
| Standard library (`stdlib/public/core/**`) | `swiftCore-linux-x86_64` (or `libswiftCore.so`) |
| Everything / unsure                   | re-run `dobuild.sh foundation` (full, slow but always correct) |

All targets: `nix develop -c ninja -C $B/swift-linux-x86_64 -t targets`.

---

## 4. Running the test suite

`llvm-lit` is the test runner. Point it at a single file, a directory, or many.

```bash
B=build/Ninja-RelWithDebInfoAssert+swift-DebugAssert
LIT="$B/llvm-linux-x86_64/bin/llvm-lit"
T="$B/swift-linux-x86_64/test-linux-x86_64"

nix develop -c $LIT -s $T/Constraints/assignment.swift   # one file (-s = short summary)
nix develop -c $LIT -s $T/Parse                           # a whole suite
nix develop -c $LIT -a $T/Constraints/assignment.swift   # -a = show full output (debugging)
nix develop -c $LIT -j8 $T/Parse $T/Sema                  # parallel, multiple suites
```

**Test categories:**
- **Non-executable** (typecheck / parse / SIL / `-verify`) — the bulk of compiler & stdlib work.
  These all pass on NixOS out of the box.
- **Executable** (build + *run* a binary, often `import StdlibUnittest`) — these pass on NixOS too,
  thanks to `SWIFT_DRIVER_TEST_OPTIONS` exported by the flake (see `HACKING.md` §5). You don't set
  anything; the dev shell already has it.

Current local results: `Parse` 252/252, `Interpreter` 257/260 (the 3 known exceptions are
documented in `HACKING.md` §5 and don't affect normal work).

---

## 5. Writing a test

Every bug fix / feature needs a test, placed under `swift/test/` next to similar ones. A test is a
`.swift` file with `RUN:` lines (what to run) and checks. Two common shapes:

**A diagnostic / typecheck test** (`-verify`): the compiler's emitted diagnostics must match inline
`// expected-error`/`// expected-warning` annotations.
```swift
// RUN: %target-typecheck-verify-swift
func f() {
  var i = 0
  if i = 6 {}   // expected-error {{use of '=' in a Boolean context, did you mean '=='?}}
}
```

**An executable test** (compiles, runs, and matches stdout with `FileCheck`):
```swift
// RUN: %target-run-simple-swift | %FileCheck %s
// REQUIRES: executable_test
print("hello")   // CHECK: hello
```

Run it the same way as any other test (§4). Useful substitutions: `%target-typecheck-verify-swift`,
`%target-run-simple-swift`, `%target-build-swift`, `%FileCheck`, `%s` (this file), `%t` (temp dir).

---

## 6. Trying your compiler on a scratch program

```bash
B=build/Ninja-RelWithDebInfoAssert+swift-DebugAssert
cat > /tmp/hi.swift <<'EOF'
print("built from source on NixOS:", (1...5).map { $0 * $0 })
EOF
nix develop -c env LD_LIBRARY_PATH=$B/swift-linux-x86_64/lib/swift/linux \
  $B/swift-linux-x86_64/bin/swiftc /tmp/hi.swift -o /tmp/hi && /tmp/hi
```
(The `LD_LIBRARY_PATH` points the runtime at your freshly-built stdlib. The harmless
`libc not found` warning is expected on NixOS.) For `import Foundation` / C++ interop usage, see
the `README`/`HACKING.md` notes on the corelibs flags.

---

## 7. Submitting a pull request to `swiftlang/swift`

The code change lives in the `swift/` subdirectory (that's the `swiftlang/swift` repo). Your PR
only ever contains changes to *that* repo — never `flake.nix`, `dobuild.sh`, or anything NixOS.

### 7a. Branch, commit, push
```bash
git -C swift checkout main && git -C swift pull origin main   # start fresh
git -C swift checkout -b improve-equal-diagnostic             # a topic branch

# ...make your edits + test...

git -C swift add -A
git -C swift commit            # see message conventions below
git -C swift push fork improve-equal-diagnostic               # push to YOUR fork
```

### 7b. Commit message conventions (from Swift's CONTRIBUTING)
- Title: concise, blank line, then body. Prefix with a component tag, e.g.
  `[Sema] Capitalize "Boolean" in the assignment-in-condition diagnostic`.
- Body: the full reasoning. Link the issue you're fixing (`Fixes #NNNNN`).
- New source files need the Swift.org Apache-2.0 copyright header (copy it from a neighboring file).
- **Note for this repo:** commits here are authored by your own git identity — no Co-Authored-By
  trailers.

### 7c. Open the PR
GitHub will show a "Compare & pull request" banner after you push. Open it against
`swiftlang/swift` `main`. Fill in what changed and why; link the issue.

### 7d. CI — how it actually runs
- Swift's CI runs on **Apple's infrastructure (Ubuntu + macOS)**, *not* your machine. Your local
  NixOS quirks are invisible to it.
- CI is triggered by a comment from someone with commit access:

  | Comment                                        | What it does                              |
  |------------------------------------------------|-------------------------------------------|
  | `@swift-ci Please smoke test`                  | Incremental build + core tests (fast, the usual first pass) |
  | `@swift-ci Please test`                        | Full validation build across platforms/arches |
  | `@swift-ci Please smoke test Linux platform`   | Linux only                                |
  | `@swift-ci Please smoke test macOS platform`   | macOS only                                |
  | `@swift-ci Please clean test`                  | Full, non-incremental (workspace wiped)   |

- **As a newcomer you usually can't self-trigger** `@swift-ci` (it needs commit access). Your
  reviewer/maintainer comments it for you. That's normal — just ping politely if your PR sits.
- Commit access itself is granted after ~5 non-trivial merged PRs (email code-owners@forums.swift.org).

### 7e. Review
Iterate on feedback; don't assume silent approval — wait for an explicit ✅. Ping non-urgent PRs
about weekly. Reviewing others' PRs builds goodwill.

### Where to find work
- **Good first issues:** https://github.com/swiftlang/swift/contribute
- Discuss anything language/stdlib-shaped on the **Swift Forums** before coding; large
  language/stdlib changes go through **Swift Evolution**.
- Read `swift/docs/FirstPullRequest.md` and swift.org/getting-started.

---

## 8. NixOS specifics & gotchas (things Ubuntu/macOS users never hit)

- **One build at a time** in `$B` — concurrent `ninja`/`build-script` runs corrupt the build dir.
- **Watch `/` (the Nix store), not just `/home`.** Each `nix develop` and the build consume store
  space; `/` filling to 100% looks like random errors. `nix-collect-garbage -d` frees it.
- **Editing `flake.nix`** requires re-entering the shell (`direnv reload`, or a fresh `nix develop`).
- **The bare build-clang** (`$B/llvm-linux-x86_64/bin/clang`) has no NixOS toolchain knowledge; the
  flake feeds it crt/gcc/glibc via `CCC_OVERRIDE_OPTIONS` and the test harness via
  `SWIFT_DRIVER_TEST_OPTIONS`. You normally don't touch these — but if you build/link by hand and
  get `cannot find Scrt1.o` or a startup `SIGSEGV`, that's the missing toolchain/dynamic-linker
  wiring (HACKING.md §5 explains it in full).
- **`import Foundation` / C++ interop** at the command line need the corelibs flags (`-sdk`,
  `-Xcc --gcc-toolchain`, rpath-link) — see `README`/`HACKING.md`. Plain Swift needs none of this.

---

## 9. You vs. someone on Ubuntu/macOS — what's different, what isn't

**Identical (the part that matters for contributing):**
- The `swift/` source, the git history, the branch/commit/PR mechanics, the test files and how you
  run `llvm-lit`, the diagnostics, the SIL, the behavior of the compiler you build.
- The PR you open and the CI that judges it. **CI never runs on your machine** (yours or an Ubuntu
  user's) — it runs on Apple's Ubuntu+macOS fleet. Your reviewer can't tell which distro you used.
- The "local green is necessary, not sufficient — trust CI" rule applies to everyone.

**Different (all of it about *local build/test plumbing*, none of it in your PR):**
| Topic                | Ubuntu / macOS (supported)                          | NixOS (this repo)                                        |
|----------------------|-----------------------------------------------------|----------------------------------------------------------|
| Build command        | `./swift/utils/build-script` directly               | `nix develop -c bash dobuild.sh` (wraps build-script with NixOS flags) |
| C/C++ toolchain      | system gcc/glibc in `/usr`, clang finds them        | nothing in `/usr`; the flake injects glibc/gcc/sysroot   |
| Dynamic linker       | `/lib64/ld-linux` is real glibc                     | `/lib64/ld-linux` is `nix-ld`; we force the nix glibc loader |
| Bootstrap compiler   | downloaded Swift snapshot toolchain                 | nixpkgs `swift 5.10.1`                                    |
| Dependencies         | `apt`/Homebrew packages                             | pinned in `flake.nix` (reproducible)                     |
| Test suite           | executable tests pass as-is                         | pass via `SWIFT_DRIVER_TEST_OPTIONS`; 3 niche tests still fail (LTO + 2 C-interop, HACKING.md §5) |
| Support status       | officially supported, CI-covered                    | **not** an official platform — local-only failures can be environment, not your code |

**The one practical asymmetry:** because NixOS isn't a CI platform, occasionally CI may flag
something you can't reproduce locally (e.g. one of the 3 unsupported-test categories). When that
happens, reason from the CI logs rather than local repro. It's a minor tax, not a blocker — and for
the vast majority of compiler/stdlib work (diagnostics, parser/sema, stdlib additions) you have a
faithful, fast local loop that's at parity with an Ubuntu contributor.

---

Happy hacking. Start with a `good first issue`, run the loop in §3 once on it, and open that PR.
