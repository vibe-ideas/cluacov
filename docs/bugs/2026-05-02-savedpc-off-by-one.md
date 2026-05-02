# PC hits attributed to the next instruction (function-body first line shows hits = 0)

- **Affected component**: `cluacov.pchook` (`src/cluacov/pchook.c`)
- **Affected versions**: `cluacov` 1.0.0 and earlier (Lua 5.4 and 5.5)
- **Severity**: medium (silent data correctness, no crash)
- **Discovered**: 2026-05-02
- **Reporter**: yeshan333 (downstream user, project: gserver/luatricks)
- **Fix**: see commit changing `pc = ci->u.l.savedpc - proto->code` to subtract 1

## Symptom

For a function whose body's first executable statement is a simple expression
(e.g. `local t = obj.field`), the LCOV report consistently shows that line as
**uncovered (`DA:<line>,0`)** even though the function is actually called many
times. The line directly after it appears with a hit count that is the *sum* of
its own real hits and the hits that should have been on the previous line.

A real-world report fragment from a downstream project, with `M.dump_path`
defined at lines 364-370 of `uobj.lua`:

```
DA:364,1     # function M.dump_path(cobj)
DA:365,0     # local t = cobj._type      ← actually executed on every call!
DA:366,1     # if t ~= "struct" and ...
DA:367,0     # error("...")              ← not entered (correct, never invalid)
DA:369,1     # return uobj_core.dump_path(cobj)
DA:370,1     # end
```

Same effect at the per-PC layer reported by `pchook.get_hits`: PC 0 of any
executed Lua function ends up with `hits[0] == nil` (or 0).

## Reproduction

Minimal repro that fits in one file (also captured in `spec/pchook_spec.lua`
under the `regression: savedpc-points-to-next-instruction` describe block):

```lua
local pchook = require("cluacov.pchook")

local fn = assert(load([[
   return function(cobj)
      local t = cobj._type           -- function body, first statement
      if t == "struct" then
         return "ok"
      end
      return "no"
   end
]]))()

pchook.start()
for _ = 1, 3 do fn({_type = "struct"}) end
pchook.stop()

local lines = pchook.get_line_hits(fn)
-- BEFORE FIX: the line of `local t = cobj._type` shows hits = 0
-- AFTER  FIX: it shows hits = 3
for i = 1, lines.max do
   if lines[i] then print(("L%d: HIT(%d)"):format(i, lines[i])) end
end
```

## Root cause

Lua's interpreter advances `savedpc` to point at the **next** instruction
*before* invoking any debug hook. From `lvm.c` / `ldebug.c` in PUC-Rio
Lua 5.4 and 5.5:

```c
/* ldebug.c, luaG_traceexec */
pc++;                          /* reference is always next instruction */
ci->u.l.savedpc = pc;          /* save 'pc' */
...
if (counthook)
   luaD_hook(L, LUA_HOOKCOUNT, -1, 0, 0);   /* call our pchook here */
```

```c
/* ldo.c, luaD_hookcall */
ci->u.l.savedpc++;             /* hooks assume 'pc' is already incremented */
luaD_hook(L, event, -1, 1, p->numparams);
ci->u.l.savedpc--;             /* correct 'pc' */
```

That is, **every Lua hook is invoked with `savedpc` already pointing at the
instruction that will run *next***, not the one that just executed. This is a
deliberate, long-standing convention.

`cluacov.pchook` was using:

```c
pc = (int)(ci->u.l.savedpc - proto->code);
hits[pc]++;
```

So every count was credited to the instruction that had not run yet. As a
result:

1. The **first instruction** of every function (PC = 0) is never the
   "next instruction" of anything inside that function, so its bucket
   stays at 0.
2. Every other instruction's bucket gets the count of the instruction that
   immediately precedes it, on top of (or instead of) its own.

When this is mapped to source lines by `aggregate_all_line_hits`, the visible
shape is exactly the one in the LCOV fragment above.

## Fix

Subtract 1 from the computed PC, and skip the case where `savedpc` still
points at the function's first instruction (we have no executed PC to credit
in that frame yet):

```c
pc = (int)(ci->u.l.savedpc - proto->code) - 1;
if (pc < 0) {
    return;
}
hits[pc]++;
```

The `pc < 0` guard handles the CIST_FRESH situation (count hook fired before
any instruction of a freshly-entered Lua frame has actually executed).

## Why both 5.4 and 5.5 are affected

The `pc++` in `luaG_traceexec` is unchanged between Lua 5.4 and 5.5. The bug
predates Lua 5.5 and reproduces identically on Lua 5.4. The original bug
report happened to be observed on a Lua 5.5 build because that is what the
downstream user was running, but it is not specific to 5.5.

## Verification

After the fix, running the same repro on Lua 5.4.8 and Lua 5.5.0 both
produce:

```
L3: HIT(3)   ← was HIT(0) before
L4: HIT(3)
L7: HIT(3)
```

See `spec/pchook_spec.lua` describe blocks:

- `regression: savedpc-points-to-next-instruction (issue: first-line-of-body shows hit=0)`
  - `attributes hits to the actually-executed PC, not the next one`
  - `function body first line shows correct hit count (line view)`

Both tests pass on Lua 5.4 and 5.5.
