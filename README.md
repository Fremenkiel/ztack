# ztack

ztack is a standalone GUI debugger for Go and Zig programs, written in Zig. Its goal is to find a
bug faster than print statements do.

ztack sets breakpoints, steps through source lines, and shows variables, goroutines, registers,
disassembly and raw memory. It also shows CPU and memory numbers for a program and its child
processes, a flame graph from a sampling profiler, and allocations and leaks. It runs programs
and single Go or Zig tests.

Status: specification. No debugger code exists yet. macOS arm64 comes first, Linux later.

## Build

ztack needs Zig 0.16.0. On macOS, it also needs Xcode or the Command Line Tools, which supply
`debugserver`, `dsymutil` and `codesign`. From milestone M5, the build signs ztack ad-hoc with
the `com.apple.security.cs.debugger` entitlement. A paid developer certificate is not necessary.

```
zig build run
zig build test
```

## Documents

- [Product specification](docs/SPEC.md): goals, features, milestones.
- [Architecture](docs/ARCHITECTURE.md): layers, threads, and how each hard problem is solved.
- [Data model](docs/DATA_MODEL.md): core types, IDs and memory budgets.
- [Style guide](docs/STYLE.md): coding rules, adapted from TigerBeetle.
- [Repository layout](docs/LAYOUT.md): folders, file order, tests and tidy checks.
- [Dependencies](docs/DEPENDENCIES.md): the approved list and the rules to add one.
- [Research notes](docs/RESEARCH.md): the facts and sources behind each decision.

## License

See [LICENSE](LICENSE).
