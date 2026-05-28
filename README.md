# pINet

Pinet is a parallel interaction nets interpreter, inspired by Inpla. The language is Inpla's dialect.

## How to run

Install zig compiler, then it's simple:

```sh
$ zig build
$ zig build test
$ zig build run
```

Note that this will compile in debug mode. For release mode use `-Doptimize=ReleaseFast`.

## Current state

Pinet is in early development

### Done

- custom rules

### TODO

- args parsing
- golden tests
- optional debug printing
- integer support
- rules for any (Agent() >< a)
- lists support
- builtins (dups, erasers)
- multithreading

# Acknowledgement & Lineage

The project is a ground rewrite in **Zig** of the original C interpreter.

- **Original idea and implementation**: [Inpla](https://github.com/inpla/inpla) made by Shinya Sato.
- **License Note**: The core architecture and design are Copyright (c) 2022 Shinya Sato Released under the MIT license. This derivative work retains the original license terms (see `LICENSE-THIRD-PARTY`).
