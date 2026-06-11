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

        # COMPLETE host swift toolchain.  When the swift build runs the just-built
        # swift-frontend/swiftc to compile the stdlib, it bakes
        # `LD_LIBRARY_PATH=<host-toolchain>/lib/swift/linux` into its ninja rules.
        # nixpkgs' DT_RUNPATH is non-transitive, so the just-built tools can't
        # resolve transitively-needed runtime libs (libdispatch.so, then Foundation)
        # via rpath; they rely on that LD_LIBRARY_PATH.  But the nixpkgs swift
        # wrapper's lib/swift/linux LACKS libdispatch.so/libFoundation.so (they sit
        # in swiftPackages.Dispatch/Foundation's top-level /lib).  Present a toolchain
        # whose lib/swift/linux ALSO contains those .so's.  The wrapper's bin/ scripts
        # use absolute store paths internally, so symlinking them into a new prefix
        # keeps them working.  Put this first on PATH (shellHook) so build-script
        # detects it as the host toolchain and bakes a COMPLETE LD_LIBRARY_PATH.
        bootstrapSwift = pkgs.runCommandLocal "swift-bootstrap-complete" { } ''
          mkdir -p $out/bin $out/lib/swift/linux $out/lib/swift
          for f in ${pkgs.swift}/bin/*; do ln -s "$f" "$out/bin/"; done
          for d in ${pkgs.swift}/lib/*; do
            n=$(basename "$d"); [ "$n" = swift ] && continue
            ln -s "$d" "$out/lib/$n"
          done
          for d in ${pkgs.swift}/lib/swift/*; do
            n=$(basename "$d"); [ "$n" = linux ] && continue
            ln -s "$d" "$out/lib/swift/$n"
          done
          for f in ${pkgs.swift}/lib/swift/linux/*; do ln -s "$f" "$out/lib/swift/linux/"; done
          # Dispatch ships its .so's in top-level /lib; Foundation in lib/swift/linux.
          for f in ${pkgs.swiftPackages.Dispatch}/lib/*.so;               do ln -sf "$f" "$out/lib/swift/linux/"; done
          for f in ${pkgs.swiftPackages.Foundation}/lib/swift/linux/*.so;  do ln -sf "$f" "$out/lib/swift/linux/"; done
        '';

        # A minimal Linux sysroot (usr/include -> glibc headers, usr/lib -> glibc
        # libs) for the just-built stdlib swiftc.  Swift's ClangImporter detects
        # the target libc by asking the clang TOOLCHAIN for its system include
        # paths (sysroot-based) and checking for inttypes.h/unistd.h/stdint.h — it
        # does NOT consult -Xcc -idirafter.  With the build's `-sdk /`, SysRoot=/,
        # and NixOS has no /usr/include -> "libc not found" -> SwiftGlibc/Glibc
        # overlay fails.  Passing `-Xcc --sysroot=${swiftSysroot}` (which takes
        # precedence in ClangIncludePaths.cpp) puts glibc on the toolchain's system
        # include path so libc is found.
        # Sysroot is ENRICHED with the gcc toolchain too (c++ headers + gcc install
        # dir), so clang's GCC-under-sysroot detection finds BOTH glibc (libc, for the
        # Glibc overlay) AND libstdc++ (for the CxxStdlib C++ overlay) purely via
        # `-sdk ${swiftSysroot}` — no -Xcc --gcc-toolchain needed.  Crucially `-sdk`
        # IS recorded in the emitted .swiftinterface, so the verify-emitted-module-
        # interface recompile also finds the modules (a bare --gcc-toolchain is NOT
        # recorded and fails verification).  Verified: CxxStdlib emit-module builds
        # against this sysroot with no --gcc-toolchain.  Per-entry symlinks (not
        # `cp -as`) so the dirs stay writable to add the c++/gcc entries.
        # usr/lib needs the glibc libs (clang's gcc/libstdc++ detection for the
        # CxxStdlib overlay only succeeds when the sysroot has a usable libc) AND the
        # gcc install dir.  BUT glibc's `libc.so`/`libm.so` are TEXT linker scripts
        # with ABSOLUTE GROUP() paths; inside a sysroot, GNU ld prefixes the sysroot
        # onto them when linking with -sdk/--sysroot ->
        # "cannot open <sysroot>/nix/store/<glibc>/lib/libc.so.6".  Fix: symlink all
        # glibc libs, then OVERWRITE libc.so/libm.so with equivalent scripts that use
        # BARE names, which ld resolves from this same usr/lib (no prefixing).  This
        # satisfies BOTH the overlay compile (libstdc++ found) and the link.
        # GLIBC-ONLY sysroot (headers + libs), used as the stdlib swiftc's `-sdk`.
        # It deliberately does NOT contain gcc's c++ headers.  C++ interop is enabled,
        # but libstdc++ is delivered to swiftc a different way — via `-Xcc
        # --gcc-toolchain=<nix-gcc>` (see dobuild.sh: SWIFT_STDLIB_EXTRA_SWIFT_COMPILE_FLAGS
        # + the Cxx overlay flags).  This is REQUIRED for correctness: if the sysroot
        # ALSO carried c++ headers, libstdc++ would be reachable via TWO paths — the
        # sysroot path (where Swift's ClangImporter injects the `std` clang modulemap)
        # and the real <nix-gcc> path (where textual #includes + the gcc-toolchain
        # resolve).  clang then sees bits/stl_pair.h, parse_numbers.h, … under two file
        # identities and pulls them into BOTH the `std` and `SwiftGlibc` modules ->
        # "included multiple times" / "redefinition of 'piecewise_construct_t'" etc.
        # Keeping c++ out of the sysroot routes ALL libstdc++ resolution through the
        # single <nix-gcc> path (verified in isolation 2026-06-11: import CxxStdlib +
        # Glibc + std.string() compiles cleanly this way; fails with c++ in sysroot).
        #
        # glibc's libc.so/libm.so are kept as their ORIGINAL upstream linker scripts
        # (the Glibc overlay's libc detection wants a real glibc).  Those scripts have
        # ABSOLUTE /nix/store/<glibc>/lib/... GROUP() paths; when the bare clang LINKS
        # a stdlib C++ shared lib (e.g. libswiftRemoteMirror.so) with -sdk (= --sysroot),
        # GNU ld PREFIXES the sysroot onto them -> tries to open
        # <sysroot>/nix/store/<glibc>/lib/libc.so.6 (absent) -> "ld.gold: error: cannot
        # open .../libc.so.6".  FIX (verified in isolation): a SYMLINK FARM — mirror the
        # glibc store dir UNDER the sysroot at its own absolute path, so the prefixed
        # path resolves.  Keeps the original scripts (compile OK) AND makes the link
        # resolve (link OK) without rewriting them.
        swiftSysroot = pkgs.runCommandLocal "swift-sysroot" { } ''
          mkdir -p $out/usr/include $out/usr/lib $out/nix/store
          for f in ${pkgs.glibc.dev}/include/*; do ln -s "$f" $out/usr/include/; done
          for f in ${pkgs.glibc}/lib/*;          do ln -s "$f" $out/usr/lib/; done
          # Symlink farm: make ld's sysroot-prefixed absolute GROUP paths resolve.
          ln -s ${pkgs.glibc} $out/nix/store/$(basename ${pkgs.glibc})
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

            # Make the COMPLETE host swift toolchain (see bootstrapSwift) the one
            # build-script detects, so the LD_LIBRARY_PATH it bakes for running the
            # just-built compiler against the stdlib includes libdispatch.so/Foundation.
            export PATH="${bootstrapSwift}/bin:$PATH"

            # Build with clang, not the gcc stdenv default.  llbuild (built by
            # swift-driver's helper via CMake) uses the environment CC/CXX, and the
            # mkShell gcc stdenv defaults them to gcc/g++ — which chokes on llbuild's
            # clang-only warning flags (-Wbool-conversion, -Wdocumentation, …).
            # Force clang so llbuild (and anything else honouring CC/CXX) matches the
            # rest of the toolchain.  (cmark/llvm/swift set CMAKE_*_COMPILER
            # explicitly, so this only affects the env-driven builds.)
            export CC=clang
            export CXX=clang++

            # The nix clang wrapper always adds --gcc-toolchain=<gcc>, which is
            # "unused during compilation" on -c steps.  swift-corelibs-libdispatch
            # compiles its C with -Werror, turning that into a fatal
            # -Wunused-command-line-argument.  Disable that one warning (it only
            # affects the nix-wrapped clang; pure warning flag, no include-order
            # effect, so it can't disturb the libstdc++ #include_next fix).
            export NIX_CFLAGS_COMPILE="-Wno-unused-command-line-argument''${NIX_CFLAGS_COMPILE:+ $NIX_CFLAGS_COMPILE}"

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
            #
            # Glibc-sysroot for the stdlib overlays: the just-built (unwrapped) swiftc
            # compiles the overlays (Glibc, CxxStdlib, …) with `-sdk /`; its ClangImporter
            # detects the target libc via the clang toolchain's SYSROOT-based system
            # include paths (NOT -Xcc -idirafter / CPATH), so on NixOS (empty /usr/include)
            # it reports "libc not found" and SwiftGlibc/the overlays fail.  Fix: point the
            # Linux SDK path at ${swiftSysroot} so swiftc gets `-sdk ${swiftSysroot}` ->
            # ClangImporter SysRoot=swiftSysroot -> usr/include (glibc) -> libc found
            # (verified: replaying Glibc.o with -sdk ${swiftSysroot} builds it).
            # IMPORTANT: EXTRA_CMAKE_OPTIONS only reaches the LLVM/builtins cmake, NOT the
            # swift compiler's cmake (verified) — so the BUILTINS fix below works, but the
            # SDK-path -D must be passed on the build-script COMMAND LINE instead (which
            # does reach swift cmake, and sticks because SwiftConfigureSDK sets the SDK
            # path with `CACHE ... ` without FORCE).  We export the path for that command:
            #   utils/build-script ... --extra-cmake-options=-DSWIFT_SDK_LINUX_ARCH_x86_64_PATH=$SWIFT_GLIBC_SYSROOT
            export EXTRA_CMAKE_OPTIONS="-DBUILTINS_CMAKE_ARGS=-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON"
            export SWIFT_GLIBC_SYSROOT="${swiftSysroot}"

            # The C++ interop overlay (CxxStdlib) defaults to `-Xcc --gcc-toolchain=/usr`
            # (SwiftConfigureSDK.cmake), empty on NixOS -> "libstdc++ not found" ->
            # "underlying module 'CxxStdlib' not found".  Point --gcc-toolchain at the
            # nix gcc (has libstdc++).  Passed on the build-script CLI via
            # SWIFT_SDK_LINUX_CXX_OVERLAY_SWIFT_COMPILE_FLAGS (verified: replaying
            # CxxStdlib with -Xcc --gcc-toolchain=$SWIFT_GCC_TOOLCHAIN builds it).
            export SWIFT_GCC_TOOLCHAIN="${pkgs.stdenv.cc.cc}"

            # --- Foundation / corelibs augmented sysroot -------------------------
            # Foundation's macros (compiled by the just-built 6.5-dev compiler) import
            # swift-syntax, whose HOST modules were built by the BOOTSTRAP swift 5.10.1
            # and so cannot be loaded -> the compiler REBUILDS swift-syntax from its
            # .swiftinterface in-process.  That rebuild needs a glibc `-sdk` to find
            # SwiftGlibc (NixOS /usr/include is empty; the importer ignores
            # C_INCLUDE_PATH/SDKROOT -- only -sdk/-isysroot work).  But a *plain* glibc
            # -sdk also redirects swiftc's runtime lookup into the sysroot, so the
            # corelibs LINKS can't find swiftrt.o / the swift .so's.  Fix: an AUGMENTED
            # sysroot = glibc (headers + libs + the ld store-farm, all from swiftSysroot)
            # PLUS a symlink to the just-built swift runtime (usr/lib/swift ->
            # build/.../lib/swift), so the SAME -sdk satisfies BOTH the macro compile
            # (SwiftGlibc) and the corelibs links (swiftrt.o + libswift*.so).  Plus
            # libstdc++/libgcc_s so the link's C++ runtime resolves.  Built here in the
            # shellHook (not as a nix derivation) because it must reference the build
            # tree.  dobuild.sh pairs it with `-L $SWIFT_GCC_LIB -Xlinker -rpath-link
            # -Xlinker $SWIFT_GCC_LIB` so ld also resolves libswiftCore's INDIRECT
            # libstdc++.so.6 NEEDED, which --sysroot otherwise hides.
            export SWIFT_GCC_LIB="${pkgs.stdenv.cc.cc.lib}/lib"
            corelibsSdk="$SWIFT_BUILD_ROOT/corelibs-sdk"
            swiftRuntime="$SWIFT_BUILD_ROOT/Ninja-RelWithDebInfoAssert+swift-DebugAssert/swift-linux-x86_64/lib/swift"
            rm -rf "$corelibsSdk"; mkdir -p "$corelibsSdk/usr/lib"
            ln -sfn "${swiftSysroot}/usr/include" "$corelibsSdk/usr/include"
            ln -sfn "${swiftSysroot}/nix" "$corelibsSdk/nix"
            for f in ${swiftSysroot}/usr/lib/*; do ln -sfn "$f" "$corelibsSdk/usr/lib/$(basename "$f")"; done
            for f in ${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so* ${pkgs.stdenv.cc.cc.lib}/lib/libgcc_s.so*; do ln -sfn "$f" "$corelibsSdk/usr/lib/$(basename "$f")"; done
            ln -sfn "$swiftRuntime" "$corelibsSdk/usr/lib/swift"
            export SWIFT_CORELIBS_SDK="$corelibsSdk"
            # The core swift runtime dir (libswiftCore/Synchronization/Concurrency/…).
            # Corelibs EXECUTABLE links (plutil, FoundationNetworking tools) need it on
            # -L + -rpath-link so ld resolves libFoundation.so's INDIRECT NEEDED
            # libswiftSynchronization.so etc. (the -sdk sysroot's usr/lib/swift/linux is
            # NOT in ld's default indirect-dependency search).
            export SWIFT_RUNTIME_LIB="$swiftRuntime/linux"

            echo "Swift 6.5 dev shell — source root: $SWIFT_SOURCE_ROOT"
          '';
        };
      });
}
