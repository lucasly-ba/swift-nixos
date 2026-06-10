#!/usr/bin/env bash
# Swift build invocation with the NixOS glibc+gcc sysroot that must be delivered via
# build-script's CLI (EXTRA_CMAKE_OPTIONS env does NOT reach the swift cmake).
# The enriched swiftSysroot (exported as SWIFT_GLIBC_SYSROOT by the flake shellHook)
# carries both libc and libstdc++, so a single `-sdk <sysroot>` fixes the Glibc and
# CxxStdlib stdlib overlays (and their .swiftinterface verification).
# Run inside the flake dev shell:  nix develop --command bash dobuild.sh
set -u
cd "$(dirname "$0")/swift"
# C++ interop overlay (CxxStdlib) is DISABLED: on NixOS its clang-module compile
# needs glibc's libc.so script IN the -sdk sysroot, but the bare-clang link breaks
# with it there (sysroot-prefixing) — a hard conflict (see memory note).  Everything
# else (compiler, stdlib, Glibc overlay, runtime, dispatch) builds; we skip C++
# interop to get a working swiftc.  Revisit if/when C++ interop is needed.
# SWIFT_INCLUDE_TESTS=FALSE: skip the test-only stdlib variant (swift-test-stdlib),
# which fails in the test build and is not part of a usable toolchain.
exec utils/build-script --release-debuginfo --debug-swift --sccache \
  "--extra-cmake-options=-DSWIFT_SDK_LINUX_ARCH_x86_64_PATH=${SWIFT_GLIBC_SYSROOT}" \
  "--extra-cmake-options=-DSWIFT_ENABLE_EXPERIMENTAL_CXX_INTEROP:BOOL=FALSE" \
  "--extra-cmake-options=-DSWIFT_INCLUDE_TESTS:BOOL=FALSE"
