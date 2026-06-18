# pinet

Pinet is a (not yet) parallel interaction nets interpreter, inspired by [Inpla](https://github.com/inpla/inpla). The language is Inpla's dialect.

## How to run

Install zig compiler v0.16, then it's simple:

```
$ zig build
$ zig build test
$ zig build run -- ./tests/list_sorting.in
```

Note that this will compile in debug mode. For release mode use `-Doptimize=ReleaseFast`.

## Current state

Pinet is in early development. Single-threaded evaluation of interaction nets, based on Inpla model, is fully implemented. Here is what is lacking:

- [ ] use and free statements
- [ ] parallel evaluation (using std.Io primitives or hand-written)
- [ ] golden tests using zig build system
- [ ] benchmarking top-level statements
- [ ] advanced memory management (fast and thread-safe slab allocation or normal allocation for agents with arbitrary arity)
- [ ] error handling on all stages
- [ ] research into name chaining (a lot of unnecessary temporary names get created during execution, which leads to increased memory consumption)

# Acknowledgement & Lineage

The project is a ground rewrite in **Zig** of the original C interpreter.

- **Original idea and implementation**: [Inpla](https://github.com/inpla/inpla) made by Shinya Sato.
- **License Note**: The core architecture and design are Copyright (c) 2022 Shinya Sato Released under the MIT license. This derivative work retains the original license terms (see `LICENSE-THIRD-PARTY`).
