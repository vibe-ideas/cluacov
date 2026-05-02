-- luacheck: std +busted
local pchook = require "cluacov.pchook"
local load = loadstring or load -- luacheck: compat

local function load_function(source)
   return assert(load(source))()
end

describe("pchook", function()
   after_each(function()
      pchook.stop()
      pchook.reset()
   end)

   local lua_version = tonumber(_VERSION:match("(%d+%.%d+)"))

   if jit or lua_version < 5.4 then
      pending("pchook requires PUC-Rio Lua 5.4+")
   else
      describe("version", function()
         it("is a string in MAJOR.MINOR.PATCH format", function()
            assert.match("^%d+%.%d+%.%d+$", pchook.version)
         end)
      end)
      describe("start/stop lifecycle", function()
         it("starts and stops without error", function()
            assert.has_no.errors(function()
               pchook.start()
               pchook.stop()
            end)
         end)

         it("can be started multiple times", function()
            assert.has_no.errors(function()
               pchook.start()
               pchook.start()
               pchook.stop()
            end)
         end)
      end)

      describe("get_hits", function()
         it("throws error for non-function argument", function()
            assert.error(function() pchook.get_hits(5) end)
         end)

         it("throws error for C function argument", function()
            assert.error(function() pchook.get_hits(pchook.start) end)
         end)

         it("returns empty hits when nothing was executed", function()
            pchook.start()
            pchook.stop()
            local func = load_function([[
               return function(x) return x end
            ]])
            local result = pchook.get_hits(func)
            assert.is_table(result)
            assert.is_true(#result >= 1)
            for _, entry in ipairs(result) do
               assert.number(entry.linedefined)
               assert.number(entry.sizecode)
               assert.is_table(entry.hits)
            end
         end)

         it("records per-PC hits for executed instructions", function()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            pchook.start()
            func(42)
            pchook.stop()

            local result = pchook.get_hits(func)
            assert.is_true(#result >= 1)
            local top_hits = result[1].hits
            local total = 0
            for _, count in pairs(top_hits) do
               total = total + count
            end
            assert.is_true(total > 0)
         end)

         it("counts multiple executions", function()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            pchook.start()
            func(1)
            func(2)
            func(3)
            pchook.stop()

            local result = pchook.get_hits(func)
            local top_hits = result[1].hits
            local has_count_3 = false
            for _, count in pairs(top_hits) do
               if count >= 3 then has_count_3 = true end
            end
            assert.is_true(has_count_3)
         end)

         it("distinguishes branch target PCs", function()
            local func = load_function([[
               return function(x)
                  if x then
                     return 1
                  else
                     return 2
                  end
               end
            ]])

            pchook.start()
            func(true)
            pchook.stop()

            local deepbranches = require("cluacov.deepbranches")
            local branches = deepbranches.get(func)
            assert.is_true(#branches >= 1)

            local result = pchook.get_hits(func)
            local top_hits = result[1].hits
            local branch = branches[1]

            local t1_hits = top_hits[branch.targets[1].pc] or 0
            local t2_hits = top_hits[branch.targets[2].pc] or 0
            assert.is_true(t1_hits > 0 or t2_hits > 0)
            assert.is_true(t1_hits == 0 or t2_hits == 0)
         end)
      end)

      describe("nested functions", function()
         it("collects hits for nested function protos", function()
            local func = load_function([[
               return function()
                  local function inner(x)
                     return x * 2
                  end
                  return inner(5)
               end
            ]])

            pchook.start()
            func()
            pchook.stop()

            local result = pchook.get_hits(func)
            assert.is_true(#result >= 2)
         end)
      end)

      describe("reset", function()
         it("clears all recorded hits", function()
            local func = load_function([[
               return function(x) return x end
            ]])
            pchook.start()
            func(1)
            pchook.stop()
            pchook.reset()

            local result = pchook.get_hits(func)
            assert.is_true(#result >= 1)
            local total = 0
            for _, entry in ipairs(result) do
               for _, count in pairs(entry.hits) do
                  total = total + count
               end
            end
            assert.equal(0, total)
         end)
      end)

      describe("regression: savedpc-points-to-next-instruction (issue: first-line-of-body shows hit=0)", function()
         -- See docs/bugs/2026-05-02-savedpc-off-by-one.md.
         --
         -- Lua's interpreter calls hooks AFTER advancing savedpc to the next
         -- instruction (see luaG_traceexec in ldebug.c). Before this fix
         -- pchook used `pc = savedpc - code` directly, which attributed each
         -- count to the *next* instruction. Visible symptoms:
         --   * the first line of every function body reported hits = 0
         --   * the next line reported inflated hits (its own + the previous)

         it("attributes hits to the actually-executed PC, not the next one", function()
            -- Per-PC view: every PC that runs at least once must have hits >= 1.
            -- Before the fix, the first PC (always the function body's first
            -- bytecode) had hits = 0.
            local func = load_function([[
               return function(cobj)
                  local t = cobj._type
                  if t ~= "struct" and t ~= "list" and t ~= "map" then
                     error("invalid")
                  end
                  return "ok"
               end
            ]])

            pchook.start()
            for _ = 1, 3 do func({_type = "struct"}) end
            pchook.stop()

            local result = pchook.get_hits(func)
            local first_pc_hits = result[1].hits[0] or 0
            assert.is_true(first_pc_hits >= 1,
               "first instruction (PC=0) of an executed function must have hits >= 1, got " .. first_pc_hits)
         end)

         it("function body first line shows correct hit count (line view)", function()
            -- Line-mapped view of the same regression. The first executable
            -- line inside the function body must be HIT, with the same count
            -- as the if/return that follow it on the same code path.
            local func = load_function([[
               return function(cobj)
                  local t = cobj._type      -- expected: 3 hits
                  if t == "struct" then     -- expected: 3 hits
                     return "ok"            -- expected: 3 hits
                  end
                  return "no"
               end
            ]])

            pchook.start()
            for _ = 1, 3 do func({_type = "struct"}) end
            pchook.stop()

            local lines = pchook.get_line_hits(func)

            -- Find the first line that has a hit count assigned (i.e. is
            -- "active"); it corresponds to `local t = cobj._type`.
            local first_active_line, first_hits
            for line_nr = 1, lines.max do
               if lines[line_nr] then
                  first_active_line = line_nr
                  first_hits = lines[line_nr]
                  break
               end
            end

            assert.is_number(first_active_line)
            assert.is_true(first_hits >= 1,
               "first active line of function body must have hits >= 1, got " ..
               tostring(first_hits) .. " (at line " .. tostring(first_active_line) .. ")")
         end)
      end)

      describe("regression: stable across many start/stop cycles (issue: random crash on simple use)", function()
         -- See docs/bugs/2026-05-02-pchook-startstop-crash.md.
         --
         -- A misbuilt pchook.so against the wrong Lua headers used to
         -- segfault inside the very first lua_rawsetp call in l_start when
         -- loaded by a Lua VM with a different ABI. This regression test
         -- exercises the start/stop path in tight loops; if pchook.so was
         -- built against the wrong headers, this test will reliably crash
         -- the VM long before it finishes.

         it("survives 200 start/run/stop/reset cycles", function()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            for _ = 1, 200 do
               pchook.start()
               func(1)
               pchook.stop()
               pchook.reset()
            end
            assert.is_true(true)  -- if we got here, no segfault
         end)
      end)

      describe("get_line_hits", function()
         it("throws error for non-function argument", function()
            assert.error(function() pchook.get_line_hits(5) end)
         end)

         it("throws error for C function argument", function()
            assert.error(function() pchook.get_line_hits(pchook.start) end)
         end)

         it("returns table with max field", function()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            pchook.start()
            func(1)
            pchook.stop()

            local result = pchook.get_line_hits(func)
            assert.is_table(result)
            assert.is_number(result.max)
            assert.is_true(result.max > 0)
         end)

         it("maps PC hits to line numbers", function()
            local func = load_function([[
               return function(x)
                  local a = x + 1
                  local b = a + 2
                  return b
               end
            ]])
            pchook.start()
            func(10)
            pchook.stop()

            local result = pchook.get_line_hits(func)
            local hit_count = 0
            for k, v in pairs(result) do
               if type(k) == "number" and v > 0 then
                  hit_count = hit_count + 1
               end
            end
            assert.is_true(hit_count >= 2)
         end)

         it("includes lines from nested functions", function()
            local func = load_function([[
               return function()
                  local function inner(x)
                     return x * 2
                  end
                  return inner(5)
               end
            ]])
            pchook.start()
            func()
            pchook.stop()

            local result = pchook.get_line_hits(func)
            local hit_count = 0
            for k, v in pairs(result) do
               if type(k) == "number" and v > 0 then
                  hit_count = hit_count + 1
               end
            end
            assert.is_true(hit_count >= 3)
         end)

         it("returns empty hits for unexecuted function", function()
            pchook.start()
            pchook.stop()
            local func = load_function([[
               return function(x) return x end
            ]])
            local result = pchook.get_line_hits(func)
            assert.is_table(result)
            local hit_count = 0
            for k, v in pairs(result) do
               if type(k) == "number" and v > 0 then
                  hit_count = hit_count + 1
               end
            end
            assert.equal(0, hit_count)
         end)
      end)

      describe("get_all_hits", function()
         it("returns empty table when nothing recorded", function()
            pchook.start()
            pchook.stop()
            pchook.reset()
            local result = pchook.get_all_hits()
            assert.is_table(result)
            assert.equal(0, next(result) and 1 or 0)
         end)

         it("returns per-source per-proto data", function()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            pchook.start()
            func(42)
            pchook.stop()

            local result = pchook.get_all_hits()
            local found = false
            for source, protos in pairs(result) do
               if type(protos) == "table" then
                  for _, entry in ipairs(protos) do
                     if entry.linedefined and entry.sizecode and entry.hits then
                        found = true
                     end
                  end
               end
            end
            assert.is_true(found)
         end)

         it("groups protos by source", function()
            local func = load_function([[
               return function()
                  local function inner(x) return x end
                  return inner(1)
               end
            ]])
            pchook.start()
            func()
            pchook.stop()

            local result = pchook.get_all_hits()
            local total_protos = 0
            for _, protos in pairs(result) do
               if type(protos) == "table" then
                  total_protos = total_protos + #protos
               end
            end
            assert.is_true(total_protos >= 2)
         end)
      end)

      describe("get_all_line_hits", function()
         it("returns empty table when nothing recorded", function()
            pchook.start()
            pchook.stop()
            pchook.reset()
            local result = pchook.get_all_line_hits()
            assert.is_table(result)
            assert.equal(0, next(result) and 1 or 0)
         end)

         it("returns per-source line data with max", function()
            local func = load_function([[
               return function(x)
                  local a = x + 1
                  return a
               end
            ]])
            pchook.start()
            func(10)
            pchook.stop()

            local result = pchook.get_all_line_hits()
            local found = false
            for source, lines in pairs(result) do
               if type(lines) == "table" and lines.max then
                  found = true
                  assert.is_true(lines.max > 0)
               end
            end
            assert.is_true(found)
         end)

         it("aggregates line hits from multiple protos in same source", function()
            local func = load_function([[
               return function()
                  local function inner(x) return x * 2 end
                  return inner(5)
               end
            ]])
            pchook.start()
            func()
            pchook.stop()

            local result = pchook.get_all_line_hits()
            local total_hit = 0
            for _, lines in pairs(result) do
               if type(lines) == "table" then
                  for k, v in pairs(lines) do
                     if type(k) == "number" and v > 0 then
                        total_hit = total_hit + 1
                     end
                  end
               end
            end
            assert.is_true(total_hit >= 3)
         end)
      end)

      describe("tick support", function()
         it("calls save_stats at configured step intervals", function()
            local save_count = 0
            pchook.start({
               savestepsize = 2,
               save_stats = function()
                  save_count = save_count + 1
               end,
            })
            local func = load_function([[
               return function(x)
                  local a = x + 1
                  local b = a + 2
                  local c = b + 3
                  local d = c + 4
                  return d
               end
            ]])
            func(1)
            pchook.stop()
            assert.is_true(save_count >= 2)
         end)

         it("does not call save_stats when tick config is absent", function()
            local save_count = 0
            pchook.start()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            func(42)
            pchook.stop()
            assert.equal(0, save_count)
         end)

         it("still records PC hits when tick is enabled", function()
            pchook.start({
               savestepsize = 100,
               save_stats = function() end,
            })
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            func(42)
            pchook.stop()
            local result = pchook.get_hits(func)
            local total = 0
            for _, entry in ipairs(result) do
               for _, count in pairs(entry.hits) do
                  total = total + count
               end
            end
            assert.is_true(total > 0)
         end)

         it("resets step counter after each save_stats call", function()
            local save_count = 0
            pchook.start({
               savestepsize = 3,
               save_stats = function()
                  save_count = save_count + 1
               end,
            })
            local func = load_function([[
               return function(x)
                  local a = x + 1
                  local b = a + 2
                  local c = b + 3
                  local d = c + 4
                  local e = d + 5
                  local f = e + 6
                  return f
               end
            ]])
            func(1)
            pchook.stop()
            assert.is_true(save_count >= 2)
         end)

         it("stop cleans up tick state for subsequent start without tick", function()
            local save_count = 0
            pchook.start({
               savestepsize = 2,
               save_stats = function()
                  save_count = save_count + 1
               end,
            })
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            func(1)
            pchook.stop()

            save_count = 0
            pchook.start()
            func(1)
            pchook.stop()
            assert.equal(0, save_count)
         end)
      end)
   end
end)
