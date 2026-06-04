# pinet

Pinet is a (not yet) parallel interaction nets interpreter, inspired by Inpla. The language is Inpla's dialect.

## How to run

Install zig compiler v0.16, then it's simple:

```
$ zig build
$ zig build test
$ zig build run
```

Note that this will compile in debug mode. For release mode use `-Doptimize=ReleaseFast`.

## Current state

Pinet is in early development.

### Done

- custom rules
- single-threaded evaluation
- builtins (dups, erasers) using static virtual tables
- number support

### TODO

- args parsing
- golden tests using zig build system
- optional debug printing
- error handling on all stages
- rules for wildcart agents (`Agent() >< any => ...;`)
- lists support
- research into name chaining (a lot of unnecessary temporary names get created during execution, which leads to increased memory consumption)
- multithreading

# Acknowledgement & Lineage

The project is a ground rewrite in **Zig** of the original C interpreter.

- **Original idea and implementation**: [Inpla](https://github.com/inpla/inpla) made by Shinya Sato.
- **License Note**: The core architecture and design are Copyright (c) 2022 Shinya Sato Released under the MIT license. This derivative work retains the original license terms (see `LICENSE-THIRD-PARTY`).
