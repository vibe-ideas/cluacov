# `cluacov/pchook.so` shipped in repo segfaults on Lua 5.5

- **Affected component**: prebuilt artifact `cluacov/pchook.so` checked into the repo
- **Affected versions**: pre-fix repository state (commit before this doc was added)
- **Severity**: high on the affected platform (immediate process crash)
- **Discovered**: 2026-05-02
- **Reporter**: yeshan333

## Symptom

On Lua 5.5.0 (PUC-Rio, arm64 darwin in the original report), loading the
`pchook.so` that was checked into the repo and calling `pchook.start()` aborts
the process with `EXC_BAD_ACCESS` (exit 139), every time, on the very first
hook setup call.

```
$ lua -e 'package.cpath="./cluacov/?.so;"..package.cpath
          local p=require("cluacov.pchook")
          p.start()'
[1]    57167 segmentation fault  lua -e ...
```

`lldb` backtrace at the moment of crash:

```
* frame #0: lua`aux_rawset + 116
  frame #1: lua`lua_rawsetp + 36
  frame #2: pchook.so`l_start + 44
  frame #3: lua`luaD_precall + 476
```

## Reproduction

Any program that loads the prebuilt `cluacov/pchook.so` from the repo under a
fresh Lua 5.5.0 binary will crash at `pchook.start()`. The simplest is the
snippet above; the regression test
`regression: stable across many start/stop cycles (issue: random crash on simple use)`
in `spec/pchook_spec.lua` exercises the same path 200 times, which crashes
reliably on the affected build.

## Root cause

The crash was **not** caused by the `pchook.c` source code. The source was
correct against Lua 5.5's public API. The problem was the **shipped
`cluacov/pchook.so` binary**: it had been built against headers / a Lua
runtime whose CallInfo / API ABI did not exactly match the Lua 5.5.0 binary
loading it. The very first `lua_rawsetp(L, LUA_REGISTRYINDEX, ...)` inside
`l_start` then dereferenced an invalid address derived from a mismatched
`L->...` layout.

This was confirmed by:

1. Recompiling `pchook.c` from the same source tree against the real
   Lua 5.5.0 headers from `vfox-lua@5.5.0` and re-loading: the crash
   disappeared completely.
2. The freshly built `.so` was 52 KB, while the in-repo one was ~36 KB,
   indicating different toolchain / header sets.

So the failure mode is: *an old binary built against one Lua ABI was being
loaded into a Lua VM with a different ABI*. PUC-Rio's published Lua 5.4 → 5.5
ABI changes are intentional and not source-compatible at the binary level.

## Fix

Two changes:

1. **Replace the in-repo `cluacov/pchook.so`** with one freshly built
   against real Lua 5.5.0 headers (this commit). Same applies to
   `deepbranches.so`, `deepactivelines.so`, and `hook.so` — they should all
   be rebuilt from the matching Lua release headers when the repo's
   "convenience binary" is updated.

2. **Add a regression test** that exercises 200 `start/stop/reset` cycles
   on the *current* loaded `pchook.so`. If a future commit re-introduces a
   wrong-ABI binary, this test will crash CI long before any user notices.

## Recommendation: stop checking prebuilt `.so` files into the repo

The convenience of having a prebuilt `.so` next to the source is outweighed
by the very real risk demonstrated here. We recommend:

- treat `cluacov/*.so` as **build artifacts**, not source;
- `.gitignore` them and provide a tiny `make` / `luarocks make` target
  that builds them against whichever Lua headers the user actually has;
- in CI, build `pchook.so` (and friends) explicitly against each
  supported Lua version before running the spec suite.

If the prebuilt `.so` must remain in-tree (for users without a toolchain),
gate every release on:

```bash
# in CI, for each supported Lua version:
make clean && make LUA_INCLUDE=$(pkg-config --variable=includedir luaX.Y)
busted spec/
```

## Related

- See `2026-05-02-savedpc-off-by-one.md` — discovered while investigating
  the same coverage anomaly on the user's project, but is an independent
  source-level bug.
