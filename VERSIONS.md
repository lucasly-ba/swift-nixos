# Verified builds

Each row is a (Swift commit + nixpkgs pin) combination that has been confirmed to build
end-to-end on NixOS. Other revisions may need tweaks (some fixes reference current
file/line locations in the Swift source).

| Swift commit | nixpkgs rev | GCC | glibc | Components | Date |
| --- | --- | --- | --- | --- | --- |
| 87350fc6de2d | a799d3e3 | 15.2.0 | 2.42 | compiler + stdlib + C++ interop + libdispatch + Foundation | 2026-05-27 |

## Adding an entry
When you confirm a new Swift commit builds with `./dobuild.sh foundation` (exit 0), add a
row. The nixpkgs rev lives in flake.lock under nodes.nixpkgs.locked.rev.
