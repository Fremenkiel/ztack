# Dependencies

ztack keeps dependencies to a short, approved list. Each dependency on the list has a reason, a
version and a license. A dependency that is not on this list is not allowed.

## Approved

| Dependency | Use | License | How it builds |
|---|---|---|---|
| Zig 0.16.0 | Compiler and standard library. | MIT | `zig/download.sh` |
| zgui (Dear ImGui, docking) | User interface. | MIT | `build.zig.zon` |
| SDL3 or GLFW | Window, input, graphics context. M0 picks one. | zlib | `build.zig.zon` |
| Capstone 6.0 pre-release | Disassembly for arm64 and x86_64. | BSD-3-Clause | `vendor/capstone/` |

External programs that ztack calls but does not ship:

| Program | Use | Source |
|---|---|---|
| `debugserver` | Process control on macOS. | Xcode or the Command Line Tools. |
| `dsymutil` | Makes a `.dSYM` bundle for Zig binaries. | Xcode or the Command Line Tools. |
| `codesign` | Signs ztack ad-hoc with the debugger entitlement (from M5). | macOS. |
| `zig` | Building Zig programs and tests to debug. | The user installation. |
| `go` | Building Go programs and tests to debug. | The user installation. |

The fallback user interface is `dvui` on SDL3. If the M0 GUI spike shows that zgui does not meet
the targets in `SPEC.md`, `dvui` replaces zgui on this list.

## Rules

- Every dependency builds from source through `build.zig`. ztack needs no system library except
  the operating system frameworks.
- Every dependency in `build.zig.zon` has a fixed URL and hash.
- Vendored C code lives in `vendor/<name>/` with its license file. Write down the upstream
  version and commit in `vendor/<name>/VERSION`.
- Capstone 6.0 has no final release yet. Pin a pre-release commit, and update to 6.0.0 in a
  dedicated change after it releases. Capstone files that come from LLVM use Apache-2.0 with the
  LLVM exception. Keep both license files in `vendor/capstone/`.
- The tidy rules and `STYLE.md` do not apply to `vendor/`.
- Wrap each dependency in one module. Only `src/ui/` imports zgui. Only `src/disasm/` imports
  Capstone. Then a dependency can change without changes to the rest of the code.
- Prefer the Zig standard library. ztack uses `std.compress.flate` for zlib data, not a separate
  zlib.

## Add a dependency

1. Write down the problem, and why the standard library or a few hundred lines of ztack code do
   not solve it.
2. Make sure that the dependency builds with Zig 0.16.0 from `build.zig`, with no system install.
3. Make sure that the license is MIT, BSD, zlib, Apache-2.0 or similar.
4. Add a row to the table above in the same change.

## Zig version

ztack pins Zig 0.16.0. Zig 0.17.0 released in October 2026. If zgui (or dvui) supports a new
version, ztack can update. Do the update in one dedicated change that touches `zig/download.sh`,
the version assertion in `build.zig`, and `minimum_zig_version` in `build.zig.zon`.
