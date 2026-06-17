#!/usr/bin/env bash
# Swift build invocation for NixOS.  Several knobs the flake env can't deliver
# (EXTRA_CMAKE_OPTIONS env does NOT reach the swift cmake) are passed on build-script's
# CLI here.  Run inside the flake dev shell:  nix develop --command bash dobuild.sh
#
# The flake exports:
#   SWIFT_GLIBC_SYSROOT = a GLIBC-ONLY sysroot (headers + libs + a symlink farm; NO
#                         gcc c++ headers; see flake.nix for why that matters)
#   SWIFT_GCC_TOOLCHAIN = the nix gcc prefix (has libstdc++ headers + install dir)
#
# Why each --extra-cmake-options:
#
# 1. SWIFT_SDK_LINUX_ARCH_x86_64_PATH = the glibc sysroot.  The stdlib swiftc compiles
#    the overlays with this as `-sdk`; its ClangImporter detects the target libc from
#    the sysroot's usr/include (glibc), and the bare-clang stdlib C++ links resolve
#    libc via the sysroot too (the symlink farm in the sysroot makes glibc's libc.so
#    linker-script's absolute GROUP paths resolve after ld sysroot-prefixes them).
#
# 2. SWIFT_STDLIB_EXTRA_SWIFT_COMPILE_FLAGS = `-Xcc --gcc-toolchain=<nix-gcc>` plus
#    `-no-verify-emitted-module-interface`.  Appended to EVERY stdlib swiftc compile
#    (SwiftSource.cmake).  The --gcc-toolchain delivers libstdc++ for C++ interop from
#    the single <nix-gcc> path (the same path textual #includes resolve to), so the
#    `std` clang module and SwiftGlibc don't end up with two file identities for the
#    same libstdc++ header (which caused "redefinition of 'piecewise_construct_t'" etc.
#    when libstdc++ was also reachable via the sysroot).  CxxStdlib must be reached via
#    -Xcc, not the CCC_OVERRIDE env: swiftc's ClangImporter detects libstdc++ from its
#    explicit clang args, not the driver env (verified).
#    -no-verify-emitted-module-interface: C++-interop modules (CxxStdlib, Runtime, …)
#    emit a valid binary .swiftmodule, but the driver's automatic interface round-trip
#    re-verification recompiles the .swiftinterface with ONLY `-sdk` (the --gcc-toolchain
#    -Xcc flag is NOT recorded in the interface), so it can't find libstdc++ and fails
#    ("cannot load underlying module for 'CxxStdlib'").  There is no way to embed an
#    -Xcc flag in the interface, so interface verification of C++-interop modules is
#    unsupportable in this NixOS setup; we skip it.  The binary .swiftmodule is the
#    artifact downstream `import` uses, and it is valid (verified: import CxxStdlib +
#    std.string() compiles & runs).
#
# 3. SWIFT_SDK_LINUX_CXX_OVERLAY_SWIFT_COMPILE_FLAGS overrides the CxxStdlib overlay's
#    hardcoded `-Xcc --gcc-toolchain=/usr` default (SwiftConfigureSDK.cmake:371, a
#    CACHE STRING without FORCE, so -D replaces it).  On NixOS /usr is empty; point it
#    at <nix-gcc> too so the overlay's own flag agrees with (2) and never reintroduces
#    /usr.
#
# 4. SWIFT_INCLUDE_TESTS=FALSE: skip building the lit test-suite executables (not needed
#    for a usable toolchain, and faster).  NOTE: swift-test-stdlib still builds and is
#    fine.  RUN ONLY ONE BUILD AT A TIME: overlapping build-script runs in the same
#    build dir clobber each other (that, not a real bug, caused old "swift-test-stdlib
#    failed" reports).
#
# CMake-list values use ';' separators; single-quoted so the ';' survives
# build-script-impl's `eval` (the reason this build command lives in a script file).
# After any swiftSysroot / flake change affecting the swift cmake, delete
# build/Ninja-RelWithDebInfoAssert+swift-DebugAssert/swift-linux-x86_64/CMakeCache.txt
# to force a reconfigure.
#
# --libdispatch --foundation: build swift-corelibs-libdispatch + Foundation from source
# with the just-built 6.5-dev compiler (nixpkgs' prebuilt 5.10.1 Foundation is ABI-
# incompatible with a 6.5-dev compiler, so it can't be grafted and must be built).
#
# --common-swift-flags="-sil-verify-none -sdk $SWIFT_CORELIBS_SDK -L $SWIFT_GCC_LIB
#   -Xlinker -rpath-link -Xlinker $SWIFT_GCC_LIB": THE FIX that makes Foundation build
# under --debug-swift.  Root cause (gdb, 2026-06-11): the swift-syntax HOST modules
# (lib/swift/host/SwiftSyntax.swiftmodule) are compiled by the BOOTSTRAP swift 5.10.1
# (build-script uses the bootstrap as CMAKE_Swift_COMPILER for the main project), so
# Foundation's macros (compiled by the just-built 6.5-dev compiler) can't load that
# 5.10.1 binary module and REBUILD swift-syntax from its .swiftinterface (in-process, on
# a worker thread).  Several NixOS-specific things break that rebuild + the corelibs link;
# the four flags above fix them:
#  1. -sdk $SWIFT_CORELIBS_SDK: the corelibs build passes NO -sdk, so the rebuild's
#     ClangImporter (default SDK "/") can't find SwiftGlibc (NixOS has no /usr/include;
#     the importer ignores C_INCLUDE_PATH/SDKROOT; only -sdk works).  Without it the
#     rebuild fails on `import Glibc` and RETRIES endlessly = the real "hang" (34 min, 0
#     modules).  $SWIFT_CORELIBS_SDK (built in the flake shellHook) is an AUGMENTED
#     sysroot = glibc + a symlink to the just-built swift runtime, because a plain glibc
#     -sdk would redirect swiftc's runtime lookup and the links couldn't find swiftrt.o.
#  2. -sil-verify-none (SILOptions.VerifyNone): skips the assert-only SIL VERIFIER, which
#     exists in this --debug-swift compiler and otherwise grinds for minutes per module.
#  3. -L $SWIFT_GCC_LIB -Xlinker -rpath-link -Xlinker $SWIFT_GCC_LIB: with -sdk, clang
#     gets --sysroot=$SWIFT_CORELIBS_SDK, and ld then can't find libswiftCore.so's INDIRECT
#     libstdc++.so.6 NEEDED (it lives at an absolute /nix/store gcc-lib path outside the
#     sysroot).  These point ld at the gcc lib so the C++ runtime resolves.
#  4. -L $SWIFT_RUNTIME_LIB -Xlinker -rpath-link -Xlinker $SWIFT_RUNTIME_LIB: the corelibs
#     EXECUTABLE links (plutil, FoundationNetworking tools) need the core swift runtime so
#     ld resolves libFoundation.so's INDIRECT libswiftSynchronization.so NEEDED (again the
#     sysroot's usr/lib/swift/linux isn't in ld's default indirect-dependency search).
# All propagate into the in-process interface rebuild.  Verified: emit-module of the 3
# FoundationMacros files + these flags = ~2 min, exit 0, 9 swift-syntax modules built; and
# a -sdk link of an executable succeeds and runs.
# Delivered via build-script-impl `--common-swift-flags`, whose value goes into
# `common_swift_flags()` → the CORELIBS' CMAKE_Swift_FLAGS only, NOT the compiler or the
# stdlib (those stay fully verified and use their own explicit -sdk).  NOTE: the toggles
# are written --foundation=1 --libdispatch=1 (not bare) so build-script's argparse doesn't
# swallow the space-containing --common-swift-flags value as their boolean.  Do NOT also
# pass -disable-sil-ownership-verifier: it sets VerifySILOwnership=false, tripping an
# assert in SemanticARCOpts under -O.  -sil-verify-none alone keeps VerifySILOwnership on.
#
# TO RUN THE TEST SUITE (for contributing): the lit tests need the test targets built.
# Flip the last flag to -DSWIFT_INCLUDE_TESTS:BOOL=TRUE, `rm` the swift CMakeCache.txt to
# reconfigure, and rebuild; OR run lit directly:
#   utils/run-test --build-dir build/Ninja-RelWithDebInfoAssert+swift-DebugAssert <path>
# LLVM_PARALLEL_LINK_JOBS=1: with --release-debuginfo + --debug-swift every link pulls
# GBs of debug info into RAM; the default (one link per core) OOM-kills low-RAM machines
# in the link phase (~1h30 in), often taking the terminal/session with it. Serialise links
# so only one runs at a time.  Bump to 2 if you have plenty of RAM + swap and want it faster.
set -u
cd "$(dirname "$0")/swift"

# Sub-commands wrap the SAME build-script invocation below; see the big comment
# block above for why each flag is there.  `compiler` drops the corelibs
# (--libdispatch/--foundation + the --common-swift-flags block); `foundation`
# keeps the full thing.  No other flag changes between the two.
usage() {
  cat <<'EOF'
Usage: dobuild.sh <command>

  compiler    LLVM + the Swift compiler + the standard library only (no
              libdispatch/Foundation).  Faster loop for compiler/stdlib work.
  foundation  The whole toolchain: compiler + stdlib + C++ interop +
              libdispatch + Foundation (what most people want first).
  all         Alias for 'foundation'.

Run inside the dev shell, e.g.:
  nix develop .#compiler --command bash dobuild.sh compiler
  nix develop .#full     --command bash dobuild.sh foundation
See README.md ("2. Build") and CONTRIBUTING.md for which to pick.
EOF
}

case "${1:-}" in
  compiler)
    exec utils/build-script --release-debuginfo --debug-swift --sccache \
      "--extra-cmake-options=-DLLVM_PARALLEL_LINK_JOBS=1" \
      "--extra-cmake-options=-DSWIFT_SDK_LINUX_ARCH_x86_64_PATH=${SWIFT_GLIBC_SYSROOT}" \
      "--extra-cmake-options=-DSWIFT_STDLIB_EXTRA_SWIFT_COMPILE_FLAGS='-Xcc;--gcc-toolchain=${SWIFT_GCC_TOOLCHAIN};-no-verify-emitted-module-interface'" \
      "--extra-cmake-options=-DSWIFT_SDK_LINUX_CXX_OVERLAY_SWIFT_COMPILE_FLAGS='-Xcc;--gcc-toolchain=${SWIFT_GCC_TOOLCHAIN}'" \
      "--extra-cmake-options=-DSWIFT_INCLUDE_TESTS:BOOL=FALSE"
    ;;
  foundation|all)   # 'all' = foundation for now; extensible later
    exec utils/build-script --release-debuginfo --debug-swift --sccache \
      --libdispatch=1 --foundation=1 \
      "--common-swift-flags=-sil-verify-none -sdk ${SWIFT_CORELIBS_SDK} -L ${SWIFT_GCC_LIB} -Xlinker -rpath-link -Xlinker ${SWIFT_GCC_LIB} -L ${SWIFT_RUNTIME_LIB} -Xlinker -rpath-link -Xlinker ${SWIFT_RUNTIME_LIB}" \
      "--extra-cmake-options=-DLLVM_PARALLEL_LINK_JOBS=1" \
      "--extra-cmake-options=-DSWIFT_SDK_LINUX_ARCH_x86_64_PATH=${SWIFT_GLIBC_SYSROOT}" \
      "--extra-cmake-options=-DSWIFT_STDLIB_EXTRA_SWIFT_COMPILE_FLAGS='-Xcc;--gcc-toolchain=${SWIFT_GCC_TOOLCHAIN};-no-verify-emitted-module-interface'" \
      "--extra-cmake-options=-DSWIFT_SDK_LINUX_CXX_OVERLAY_SWIFT_COMPILE_FLAGS='-Xcc;--gcc-toolchain=${SWIFT_GCC_TOOLCHAIN}'" \
      "--extra-cmake-options=-DSWIFT_INCLUDE_TESTS:BOOL=FALSE"
    ;;
  *)
    usage
    exit 1
    ;;
esac
