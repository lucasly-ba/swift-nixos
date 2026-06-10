{
  description = "Swift compiler development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        llvm = pkgs.llvmPackages_20;

        # llbuild's CMake (FindCurses) links the tools with a bare `-lcurses`,
        # but nixpkgs ncurses only ships libncursesw.so (+ a libncurses.so
        # symlink), not libcurses.so -> `cannot find -lcurses`.  Provide a compat
        # package whose lib/ MIRRORS all of ncurses' libs AND adds libcurses.so.
        # As a buildInput its lib dir lands on both NIX_LDFLAGS (-L, so the link
        # finds -lcurses) AND the linked binaries' RUNPATH.  It must therefore
        # also contain libncursesw.so.6 itself: the `-lcurses` link records
        # NEEDED=libncursesw.so.6 (ncursesw's soname), so the SAME RUNPATH dir has
        # to satisfy that at runtime, else binaries fail to load with
        # "libncursesw.so.6: cannot open shared object file".
        cursesCompat = pkgs.runCommandLocal "curses-compat" { } ''
          mkdir -p $out/lib
          ln -s ${pkgs.ncurses}/lib/* $out/lib/
          ln -s ${pkgs.ncurses}/lib/libncursesw.so $out/lib/libcurses.so
        '';
      in {
        devShells.default = pkgs.mkShell {
          name = "swift-dev";

          packages = with pkgs; [
            # Build system
            cmake
            ninja
            pkg-config

            # NOTE: glibc.dev is deliberately NOT a buildInput.  As a buildInput
            # the stdenv prepends `-isystem ${glibc.dev}/include` to the FRONT of
            # the C++ include path; clang then dedups and drops the cc-wrapper's
            # correctly-placed *trailing* glibc, leaving glibc before gcc's
            # libstdc++ headers and breaking libstdc++'s `#include_next <math.h>`
            # (-> "'math.h' file not found" when compiling llbuild's <cmath>).
            # The bare compiler-rt clang still gets glibc via C_INCLUDE_PATH in
            # the shellHook, which references the store path directly.

            # Bootstrap Swift compiler (≥5.9 required to compile swift-syntax and
            # the stdlib's macro plugins).  nixpkgs 5.10.1 is pre-built in the
            # Hydra cache so this just downloads a binary, it does not rebuild Swift.
            swift

            # The bootstrap swift (5.10.1) ships only the core stdlib modules, NOT
            # Foundation/Dispatch.  llbuild's Swift bindings (llbuildSwift) do
            # `import Foundation`, so add them: the swift-wrapper setup-hook adds
            # each buildInput's lib/swift dir to NIX_SWIFTFLAGS_COMPILE (-I) and
            # NIX_LDFLAGS (-L), making the modules visible to the build's swiftc.
            swiftPackages.Foundation
            swiftPackages.Dispatch

            # Provides libcurses.so for llbuild's `-lcurses` link (see let block).
            cursesCompat

            # Bootstrap compiler (clang is required; swift is optional if already built)
            llvm.clang
            llvm.llvm
            llvm.lld

            # Python (build-script + utils)
            (python3.withPackages (ps: with ps; [ six ]))

            # Required libraries
            libedit
            libxml2
            zlib
            icu
            util-linux   # provides libuuid / uuid.h
            curl
            sqlite

            # Optional but common
            cmark
            swig
            rsync
            git

            # Debugging / tooling
            gdb
            ccache
          ];

          shellHook = ''
            export SWIFT_SOURCE_ROOT="$(pwd)"
            export SWIFT_BUILD_ROOT="$(pwd)/build"

            # Prefer ccache if available
            if command -v ccache &>/dev/null; then
              export CMAKE_C_COMPILER_LAUNCHER=ccache
              export CMAKE_CXX_COMPILER_LAUNCHER=ccache
            fi

            # --- libc header visibility on NixOS ---------------------------------
            # Two different compilers need glibc headers and neither finds them by
            # default; CPATH must stay unset because it breaks C++ #include_next.
            unset CPATH

            # 1. The freshly-built, *non*-nix-wrapped clang (build/.../bin/clang)
            #    compiles compiler-rt's builtins AND the Swift stdlib/runtime C
            #    sources.  It ignores NIX_CFLAGS_COMPILE but honours C_INCLUDE_PATH
            #    (C-only, so it can't disturb C++ include_next).
            export C_INCLUDE_PATH="${pkgs.glibc.dev}/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"

            # 1b. That same bare clang also compiles the stdlib/runtime *C++* sources
            #     (CommandLine.cpp, Demangler.cpp, …) and so needs gcc's libstdc++
            #     headers (algorithm, cstdint) + glibc (inttypes.h via #include_next).
            #     CPLUS_INCLUDE_PATH is appended after the system dirs (like
            #     -idirafter), so it preserves include_next ordering (unlike CPATH).
            #     Order: libstdc++, libstdc++/<triple>, then glibc.  Verified this
            #     does NOT disturb the nix-wrapped clang (its copies dedup first).
            export CPLUS_INCLUDE_PATH="${pkgs.stdenv.cc.cc}/include/c++/${pkgs.stdenv.cc.cc.version}:${pkgs.stdenv.cc.cc}/include/c++/${pkgs.stdenv.cc.cc.version}/${pkgs.stdenv.hostPlatform.config}:${pkgs.glibc.dev}/include''${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"

            # 1c. The bare clang also *links* the stdlib/runtime shared libraries
            #     (e.g. libswiftRemoteMirror.so) with -fuse-ld=gold, and unwrapped
            #     it has no -L for gcc/glibc, so it can't find -lstdc++/-lgcc_s/
            #     -lgcc nor the crt startup objects (crti.o/Scrt1.o/crtbeginS.o).
            #     clang searches LIBRARY_PATH for both -l libs AND crt files, so
            #     point it at: gcc-lib (libstdc++ + libgcc_s), gcc's target dir
            #     (libgcc.a + crtbegin/crtend), and glibc (crt1/crti/crtn + libc).
            #     These links are plain ninja commands (not `cmake -E env`-wrapped),
            #     so the shell's LIBRARY_PATH reaches them.
            export LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.stdenv.cc.cc}/lib/gcc/${pkgs.stdenv.hostPlatform.config}/${pkgs.stdenv.cc.cc.version}:${pkgs.glibc}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"

            # 1d. LIBRARY_PATH covers -l libs, but clang locates the crt startup
            #     objects (crt1/crti/crtn/crtbegin/crtend) via its GCC-toolchain
            #     detection and the sysroot, NOT LIBRARY_PATH -- and the bare clang
            #     detects no toolchain on NixOS (sysroot is "/", which is empty).
            #     CCC_OVERRIDE_OPTIONS injects driver flags into EVERY clang call:
            #       --gcc-install-dir=<gcc>/lib/gcc/<triple>/<ver>  -> gcc crtbegin/
            #         crtend + libgcc + libstdc++ headers/libs, correctly ordered;
            #       -B<glibc>/lib                                   -> glibc's
            #         crt1/crti/crtn/Scrt1.o.
            #     ('+' appends the arg.)  Verified this does not regress the
            #     nix-wrapped clang (it already has a consistent gcc/glibc).
            export CCC_OVERRIDE_OPTIONS="+-B${pkgs.glibc}/lib +--gcc-install-dir=${pkgs.stdenv.cc.cc}/lib/gcc/${pkgs.stdenv.hostPlatform.config}/${pkgs.stdenv.cc.cc.version}"

            # 2. The nix-wrapped clang (llbuild, swift-driver, …) must NOT have
            #    glibc forced onto the FRONT of its include path.  The cc-wrapper
            #    already places glibc AFTER gcc's libstdc++ headers, which is
            #    exactly where libstdc++'s '#include_next <math.h>' needs it.
            #    Any front-loaded glibc (a glibc.dev buildInput's '-isystem', or an
            #    '-idirafter' that clang dedups against the front copy) inverts that
            #    order and makes <cmath>/<cstdlib> fail to find math.h/stdlib.h.
            #    Verified 2026-06-10: with no front glibc, llbuild's Atomic.cpp
            #    (the real TU, '-I llbuild/include' so <cmath> is actually pulled)
            #    compiles cleanly.  So we add NOTHING to NIX_CFLAGS_COMPILE here.

            # On NixOS, 32-bit system headers are not at standard paths; skip i386
            # builtins entirely — not needed for Swift development on x86_64.
            # BUILTINS_CMAKE_ARGS is forwarded directly into the builtins ExternalProject.
            export EXTRA_CMAKE_OPTIONS="-DBUILTINS_CMAKE_ARGS=-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON"

            echo "Swift 6.5 dev shell — source root: $SWIFT_SOURCE_ROOT"
          '';
        };
      });
}
