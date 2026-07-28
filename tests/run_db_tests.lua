--[[--------------------------------------------------------------------------
| tests/run_db_tests.lua - Tests for the SmartCAM database layer.
|
| Config, FileIO, Store, Seed, Database and ToolRepository, against real files
| in a throwaway folder under TEMP. Nothing here touches
| C:\ProgramData\SmartCAM.
|
| Run:  lua tests/run_db_tests.lua      (from the repository root)
----------------------------------------------------------------------------]]

local ROOT   = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
local Helper = dofile(ROOT .. "/tests/db_helper.lua")

local passed, failed, failures = 0, 0, {}

local function check(name, ok, detail)
   if ok then passed = passed + 1
   else
      failed = failed + 1
      failures[#failures + 1] = string.format("%s\n      %s", name, detail or "")
   end
end

local function eq(name, actual, expected)
   check(name, actual == expected,
         string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

---------------------------------------------------------------------------
-- 1. Config: the single source of paths
---------------------------------------------------------------------------

do
   local m = Helper.modules()

   local default = m.config.new()
   eq("config/default root", default:root_path(), "C:\\ProgramData\\SmartCAM")
   eq("config/tools path", default:path_for("tools"),
      "C:\\ProgramData\\SmartCAM\\tools.json")
   eq("config/settings path", default:path_for("settings"),
      "C:\\ProgramData\\SmartCAM\\settings.json")

   -- all five documents are known
   local names = m.config.document_names()
   eq("config/five documents", #names, 5)
   eq("config/name 1", names[1], "machines")
   eq("config/name 2", names[2], "materials")
   eq("config/name 3", names[3], "presets")
   eq("config/name 4", names[4], "settings")
   eq("config/name 5", names[5], "tools")

   -- relocating is a one-line change, which is the whole point
   local share = m.config.new("\\\\server\\cnc\\SmartCAM")
   eq("config/network root", share:root_path(), "\\\\server\\cnc\\SmartCAM")
   eq("config/network tools path", share:path_for("tools"),
      "\\\\server\\cnc\\SmartCAM\\tools.json")

   -- trailing separators are trimmed rather than doubling up
   eq("config/trailing slash trimmed",
      m.config.new("C:\\Data\\SmartCAM\\"):path_for("tools"),
      "C:\\Data\\SmartCAM\\tools.json")

   -- empty falls back to the default rather than writing to the drive root
   eq("config/empty falls back", m.config.new(""):root_path(),
      "C:\\ProgramData\\SmartCAM")
   eq("config/nil falls back", m.config.new(nil):root_path(),
      "C:\\ProgramData\\SmartCAM")

   local ok = pcall(function() return default:path_for("nonsense") end)
   check("config/unknown document rejected", not ok, "expected an error")

   -- from_settings honours the config.lua table
   local from = m.config.from_settings{ path = "D:\\Shared\\CAM",
                                        use_environment = false }
   eq("config/from_settings path", from:root_path(), "D:\\Shared\\CAM")
end

---------------------------------------------------------------------------
-- 2. FileIO
---------------------------------------------------------------------------

do
   local m = Helper.modules()
   local F = m.fileio

   eq("fileio/join", F.join("C:\\Data", "SmartCAM", "tools.json"),
      "C:\\Data\\SmartCAM\\tools.json")
   eq("fileio/join trims separators", F.join("C:\\Data\\", "\\SmartCAM"),
      "C:\\Data\\SmartCAM")
   eq("fileio/join skips empties", F.join("C:\\Data", "", "x.json"),
      "C:\\Data\\x.json")
   eq("fileio/dirname", F.dirname("C:\\Data\\SmartCAM\\tools.json"),
      "C:\\Data\\SmartCAM")

   local root = Helper.temp_root("fileio")
   eq("fileio/missing dir not writable", F.directory_is_writable(root), false)

   local made, err = F.ensure_directory(root)
   check("fileio/creates the directory", made, tostring(err))
   eq("fileio/now writable", F.directory_is_writable(root), true)

   -- creating twice is not an error
   check("fileio/idempotent", F.ensure_directory(root), "second call failed")

   --[[
   | The write probe is the test that matters, because writing is what the
   | database does. os.rename(path, path) was tried as a cheaper existence
   | check and rejected: it returns FALSE for a directory that is merely
   | busy, so a perfectly good folder would read as missing.
   ]]
   local ok_probe = F.directory_is_writable(root)
   eq("fileio/probe succeeds on a good folder", ok_probe, true)
   eq("fileio/probe cleans up after itself",
      F.file_exists(F.join(root, "smartcam_write_test.tmp")), false)

   local no_dir, missing_why = F.directory_is_writable(F.join(root, "nope"))
   eq("fileio/probe fails on a missing folder", no_dir, false)
   check("fileio/probe gives a reason", missing_why ~= nil, "no reason given")

   -- A failure has to say what was actually tried, not just "check
   -- permissions" - being unable to name the cause is its own bug.
   local blocked, why = F.ensure_directory("Q:\\smartcam_no_such_drive")
   eq("fileio/unavailable drive refused", blocked, false)
   check("fileio/failure lists what was tried",
         (why or ""):find("What was tried") ~= nil, tostring(why))
   check("fileio/failure mentions mkdir", (why or ""):find("mkdir") ~= nil,
         tostring(why))
   check("fileio/failure suggests config.lua",
         (why or ""):find("config.lua") ~= nil, tostring(why))

   local path = root .. "\\sample.txt"
   eq("fileio/file missing", F.file_exists(path), false)

   check("fileio/writes", F.write(path, "hello"), "write failed")
   eq("fileio/file exists", F.file_exists(path), true)
   eq("fileio/reads back", F.read(path), "hello")

   -- a rewrite keeps the previous version
   check("fileio/rewrites", F.write(path, "second"), "rewrite failed")
   eq("fileio/new content", F.read(path), "second")
   eq("fileio/backup kept", F.read(path .. ".bak"), "hello")
   eq("fileio/no temp left behind", F.file_exists(path .. ".tmp"), false)

   local missing, read_err = F.read(root .. "\\nope.txt")
   check("fileio/missing read reports", missing == nil and read_err ~= nil,
         tostring(missing))

   -- writing into a missing subfolder creates it
   local nested = root .. "\\a\\b\\c.txt"
   check("fileio/creates parents", F.write(nested, "deep"), "nested write failed")
   eq("fileio/nested content", F.read(nested), "deep")

   os.remove(path); os.remove(path .. ".bak"); os.remove(nested)
   pcall(os.execute, 'rmdir /s /q "' .. root .. '" 2>nul')
end

---------------------------------------------------------------------------
-- 2b. VCarve's stricter io.open
---------------------------------------------------------------------------

do
   --[[
   | VCarve's embedded Lua rejects the bare "r" and "w" modes that stock Lua
   | accepts, raising `bad argument #2 to 'open' (invalid mode)`. That killed
   | the gadget on its first run, before the database folder was created.
   |
   | This replaces io.open with one that behaves the way VCarve's does, so a
   | bare mode anywhere in FileIO fails the suite instead of only failing on
   | the user's machine.
   ]]
   local real_open = io.open
   local seen_modes = {}

   io.open = function(path, mode)
      seen_modes[#seen_modes + 1] = tostring(mode)
      if mode ~= "rb" and mode ~= "wb" and mode ~= "ab" then
         error(string.format("bad argument #2 to 'open' (invalid mode)"), 2)
      end
      return real_open(path, mode)
   end

   local ok, err = pcall(function()
      local m    = Helper.modules()
      local root = Helper.temp_root("strictio")

      -- the exact call that failed on the user's machine
      eq("strictio/missing dir reports false",
         m.fileio.directory_is_writable(root), false)

      local made, made_err = m.fileio.ensure_directory(root)
      check("strictio/creates the directory", made, tostring(made_err))

      local path = root .. "\\sample.txt"
      check("strictio/file_exists on a missing file",
            m.fileio.file_exists(path) == false, "reported present")
      check("strictio/writes", m.fileio.write(path, "hello"), "write failed")
      eq("strictio/reads back", m.fileio.read(path), "hello")
      check("strictio/rewrites", m.fileio.write(path, "second"), "rewrite failed")
      eq("strictio/backup kept", m.fileio.read(path .. ".bak"), "hello")

      -- a whole database opens cleanly under the strict rules
      local db, db_err = m.database.open(m.config.new(root), nil)
      check("strictio/database opens", db ~= nil, tostring(db_err))
      eq("strictio/five files created", db and #db:created_files(), 5)
      eq("strictio/tools usable", db and db.tools:count(), 4)

      m.fileio.remove(path)
      m.fileio.remove(path .. ".bak")
      Helper.cleanup(root)
   end)

   io.open = real_open

   check("strictio/no error escaped", ok, tostring(err))

   -- and prove the guard was actually exercised
   check("strictio/io.open was called", #seen_modes > 0, "never opened a file")
   local bad = {}
   for _, mode in ipairs(seen_modes) do
      if mode ~= "rb" and mode ~= "wb" and mode ~= "ab" then
         bad[#bad + 1] = mode
      end
   end
   check("strictio/only binary modes used", #bad == 0,
         "bare modes reached io.open: " .. table.concat(bad, ", "))
end

---------------------------------------------------------------------------
-- 3. Database creation on a fresh install
---------------------------------------------------------------------------

do
   local m    = Helper.modules()
   local root = Helper.temp_root("fresh")
   local config = m.config.new(root)

   local db, err = m.database.open(config, nil)
   check("fresh/opens", db ~= nil, tostring(err))

   if db then
      eq("fresh/created five files", #db:created_files(), 5)

      for _, name in ipairs(m.config.document_names()) do
         eq("fresh/" .. name .. ".json exists",
            m.fileio.file_exists(config:path_for(name)), true)
      end

      -- the seeded library is usable straight away
      eq("fresh/seeded tools", db.tools:count(), 4)
      local first = db.tools:find_by_id(1)
      check("fresh/tool 1 present", first ~= nil, "no tool with id 1")
      eq("fresh/tool 1 has feeds", first and first.feed_rate, 220.0)

      -- every seeded tool must be usable, or a fresh install cannot cut
      for _, tool in ipairs(db.tools:all()) do
         local problems = m.tool_repository.validate(tool)
         check("fresh/seed tool " .. tostring(tool.id) .. " is valid",
               #problems == 0, table.concat(problems, "; "))
      end

      -- opening again creates nothing new
      local again = m.database.open(m.config.new(root), nil)
      check("fresh/second open", again ~= nil, "reopen failed")
      eq("fresh/nothing recreated", again and #again:created_files(), 0)
   end

   Helper.cleanup(root)
end

---------------------------------------------------------------------------
-- 3b. A host that forbids writing entirely
---------------------------------------------------------------------------

do
   --[[
   | VCarve's sandbox rejects every write mode: io.open(path, "w") AND
   | io.open(path, "wb") both raise `invalid mode`, though both are legal in
   | stock Lua 5.2.3.
   |
   | Reading a tool library and building toolpaths does not need writing, so
   | this must still work. Making saving a precondition for reading was a
   | bug that stopped the gadget starting at all.
   ]]
   local real_open = io.open
   io.open = function(path, mode)
      if mode ~= "rb" then
         error("bad argument #2 to 'open' (invalid mode)", 2)
      end
      return real_open(path, mode)
   end

   local ok, err = pcall(function()
      -- 1. Nothing on disk at all: falls back to the seeded library in memory
      local m    = Helper.modules()
      local root = Helper.temp_root("readonly")

      local db, db_err = m.database.open(m.config.new(root), nil)
      check("readonly/still opens", db ~= nil, tostring(db_err))
      if db then
         eq("readonly/reports read only", db:is_read_only(), true)
         eq("readonly/nothing recorded as created", #db:created_files(), 0)
         eq("readonly/seeded tools usable", db.tools:count(), 4)

         local tool = db.tools:find_by_id(1)
         check("readonly/tool 1 resolvable", tool ~= nil, "no tool 1")
         eq("readonly/tool has real feeds", tool and tool.feed_rate, 220.0)

         check("readonly/warns about placeholders",
               (db.warning or ""):find("PLACEHOLDER") ~= nil,
               tostring(db.warning))
         check("readonly/warning points at config.lua",
               (db.warning or ""):find("config.lua") ~= nil, tostring(db.warning))
      end
   end)
   io.open = real_open
   check("readonly/no error escaped", ok, tostring(err))
end

do
   -- 2. A real tools.json on disk, but writing forbidden: the user's own
   --    library must be read and used, not replaced by placeholders.
   local m    = Helper.modules()
   local root = Helper.temp_root("readonly2")
   m.fileio.ensure_directory(root)
   Helper.write_raw(m, root, "tools.json", Helper.tools_json())

   local real_open = io.open
   io.open = function(path, mode)
      if mode ~= "rb" then
         error("bad argument #2 to 'open' (invalid mode)", 2)
      end
      return real_open(path, mode)
   end

   local ok, err = pcall(function()
      local fresh = Helper.modules()
      local db, db_err = fresh.database.open(fresh.config.new(root), nil)
      check("readonly2/opens", db ~= nil, tostring(db_err))
      if db then
         eq("readonly2/reads the real library", db.tools:count(), 6)
         local tool = db.tools:find_by_name("End Mill 12mm")
         check("readonly2/finds the user's tool", tool ~= nil, "not found")
         eq("readonly2/uses the user's feed", tool and tool.feed_rate, 180.0)

         -- tools.json was readable, so only the OTHER documents are stubs
         eq("readonly2/still flagged read only", db:is_read_only(), true)
      end
   end)

   io.open = real_open
   check("readonly2/no error escaped", ok, tostring(err))
   Helper.cleanup(root)
end

---------------------------------------------------------------------------
-- 4. ToolRepository: lookup
---------------------------------------------------------------------------

do
   local repo, root = Helper.repository("lookup")

   eq("repo/count", repo:count(), 6)

   local by_id = repo:find_by_id(1)
   check("repo/find_by_id", by_id ~= nil, "id 1 not found")
   eq("repo/find_by_id name", by_id and by_id.name, "End Mill 6mm")
   eq("repo/find_by_id numeric string", repo:find_by_id("1"), by_id)
   eq("repo/find_by_id missing", repo:find_by_id(99), nil)

   local by_name = repo:find_by_name("End Mill 6mm")
   eq("repo/find_by_name", by_name, by_id)
   eq("repo/find_by_name is case insensitive",
      repo:find_by_name("end mill 6MM"), by_id)
   eq("repo/find_by_name trims", repo:find_by_name("  End Mill 6mm  "), by_id)
   eq("repo/find_by_name missing", repo:find_by_name("Nope"), nil)

   -- find() picks the right lookup from the shape of the reference
   eq("repo/find by id", repo:find(3), repo:find_by_id(3))
   eq("repo/find by name", repo:find("V-Bit 60"), repo:find_by_id(3))

   local missing, err = repo:find(42)
   check("repo/find missing explains", missing == nil and err ~= nil, tostring(err))
   check("repo/error names the file", (err or ""):find("tools.json") ~= nil, err)

   local by_bad_name, name_err = repo:find("Nonexistent")
   check("repo/missing name explains",
         by_bad_name == nil and (name_err or ""):find("named") ~= nil, name_err)

   -- ids and next_id
   local ids = repo:ids()
   eq("repo/ids count", #ids, 6)
   eq("repo/ids sorted", ids[1] .. "," .. ids[6], "1,9")
   eq("repo/next free id", repo:next_id(), 6)

   Helper.cleanup(root)
end

---------------------------------------------------------------------------
-- 5. ToolRepository: add, update, delete
---------------------------------------------------------------------------

do
   local repo, root, m = Helper.repository("crud")

   -- add with an explicit id
   local added, err = repo:add{
      id = 7, name = "Ball Nose 3mm", type = "ball_nose", units = "mm",
      diameter = 3.0, stepdown = 1.0, stepover = 0.6,
      feed_rate = 200, plunge_rate = 60, spindle_speed = 18000,
      rate_units = "mm_min",
   }
   check("crud/add", added ~= nil, tostring(err))
   eq("crud/count after add", repo:count(), 7)
   eq("crud/added is findable", repo:find_by_id(7), added)
   eq("crud/tool_number defaulted", added and added.tool_number, 7)

   -- and it is on disk, not just in memory
   local reopened = m.tool_repository.new(m.config.new(root))
   reopened:load()
   local persisted = reopened:find_by_id(7)
   check("crud/add persisted", persisted ~= nil, "not written to disk")
   eq("crud/persisted name", persisted and persisted.name, "Ball Nose 3mm")

   -- add without an id allocates the lowest free one
   local auto = repo:add{ name = "Auto", diameter = 1.0,
                          feed_rate = 100, plunge_rate = 50, spindle_speed = 9000 }
   check("crud/auto id", auto ~= nil, "add returned nil")
   eq("crud/auto id value", auto and auto.id, 6)

   -- duplicate ids are refused
   local dup, dup_err = repo:add{ id = 1, name = "Clash" }
   check("crud/duplicate refused", dup == nil and dup_err ~= nil, tostring(dup))
   check("crud/duplicate explains", (dup_err or ""):find("already exists") ~= nil,
         tostring(dup_err))

   -- update merges, and cannot change the id
   local updated, upd_err = repo:update(1, { feed_rate = 250, notes = "faster" })
   check("crud/update", updated ~= nil, tostring(upd_err))
   eq("crud/update applied", updated and updated.feed_rate, 250)
   eq("crud/update kept other fields", updated and updated.diameter, 6.0)
   eq("crud/update added field", updated and updated.notes, "faster")

   local id_change = repo:update(1, { id = 99 })
   eq("crud/id not changed", id_change and id_change.id, 1)

   local no_such, upd_missing = repo:update(1234, { feed_rate = 1 })
   check("crud/update missing refused", no_such == nil and upd_missing ~= nil,
         tostring(no_such))

   -- update by name works too
   local by_name = repo:update("Drill 5mm", { spindle_speed = 9000 })
   eq("crud/update by name", by_name and by_name.spindle_speed, 9000)

   -- delete
   local removed = repo:delete(7)
   check("crud/delete", removed, "delete returned false")
   eq("crud/gone", repo:find_by_id(7), nil)

   local gone_twice, del_err = repo:delete(7)
   check("crud/delete missing refused", not gone_twice and del_err ~= nil,
         tostring(del_err))

   -- deletion persisted
   local after = m.tool_repository.new(m.config.new(root))
   after:load()
   eq("crud/delete persisted", after:find_by_id(7), nil)
   eq("crud/others survived", after:find_by_id(1) ~= nil, true)

   Helper.cleanup(root)
end

---------------------------------------------------------------------------
-- 6. ToolRepository: validation
---------------------------------------------------------------------------

do
   local V = Helper.modules().tool_repository.validate

   local good = { type = "end_mill", diameter = 6, feed_rate = 200,
                  plunge_rate = 60, spindle_speed = 12000 }
   eq("validate/good tool", #V(good), 0)

   local function problems_for(changes)
      local tool = {}
      for k, v in pairs(good) do tool[k] = v end
      for k, v in pairs(changes) do tool[k] = v end
      return V(tool)
   end

   check("validate/zero feed", #problems_for{ feed_rate = 0 } > 0, "accepted")
   check("validate/zero plunge", #problems_for{ plunge_rate = 0 } > 0, "accepted")
   check("validate/zero spindle", #problems_for{ spindle_speed = 0 } > 0, "accepted")
   check("validate/zero diameter", #problems_for{ diameter = 0 } > 0, "accepted")

   -- an absent field, not a zero one. `feed_rate = nil` inside a table
   -- constructor stores nothing, so the key has to be left out entirely.
   check("validate/missing feed",
         #V{ type = "end_mill", diameter = 6, plunge_rate = 60,
             spindle_speed = 12000 } > 0, "accepted a tool with no feed rate")
   check("validate/empty record", #V{} > 0, "accepted an empty record")
   check("validate/negative feed", #problems_for{ feed_rate = -5 } > 0, "accepted")
   check("validate/unknown type", #problems_for{ type = "laser_sword" } > 0,
         "accepted")

   -- V-bits need a sane included angle
   check("validate/vbit without angle",
         #problems_for{ type = "vbit" } > 0, "accepted")
   check("validate/vbit with 0 degrees",
         #problems_for{ type = "vbit", included_angle = 0 } > 0, "accepted")
   check("validate/vbit with 180 degrees",
         #problems_for{ type = "vbit", included_angle = 180 } > 0, "accepted")
   eq("validate/vbit with 60 degrees",
      #problems_for{ type = "vbit", included_angle = 60 }, 0)

   -- the message says what is wrong
   local said = table.concat(problems_for{ feed_rate = 0 }, " ")
   check("validate/names the field", said:find("feed_rate") ~= nil, said)
end

---------------------------------------------------------------------------
-- 7. Damaged and hand-edited files
---------------------------------------------------------------------------

do
   local m    = Helper.modules()
   local root = Helper.temp_root("broken")
   m.fileio.ensure_directory(root)

   -- malformed JSON must be reported, never silently replaced: overwriting
   -- someone's tool library because of a stray comma would be worse than
   -- refusing to run.
   Helper.write_raw(m, root, "tools.json", '{ "tools": [ { "id": 1, } ] }')
   local repo = m.tool_repository.new(m.config.new(root))
   local ok, err = repo:load()
   check("broken/malformed refused", not ok, "load succeeded on bad JSON")
   check("broken/says not valid JSON", (err or ""):find("not valid JSON") ~= nil, err)
   check("broken/names the file", (err or ""):find("tools.json") ~= nil, err)
   eq("broken/file untouched",
      m.fileio.read(root .. "\\tools.json"), '{ "tools": [ { "id": 1, } ] }')

   -- an empty file is treated as a fresh start, since that is what a failed
   -- write or a manual truncation looks like
   Helper.write_raw(m, root, "tools.json", "")
   local empty_repo = m.tool_repository.new(m.config.new(root))
   local empty_ok = empty_repo:load()
   check("broken/empty file reseeded", empty_ok, "empty file was not recovered")
   check("broken/reseeded has tools", empty_repo:count() > 0, "no tools seeded")

   -- a document missing its list is repaired in memory
   Helper.write_raw(m, root, "tools.json", '{ "schema": 1 }')
   local no_list = m.tool_repository.new(m.config.new(root))
   check("broken/missing list loads", no_list:load(), "load failed")
   eq("broken/missing list is empty", no_list:count(), 0)
   local seeded = no_list:add{ name = "First", diameter = 6, feed_rate = 100,
                               plunge_rate = 50, spindle_speed = 10000 }
   check("broken/can add to repaired file", seeded ~= nil, "add failed")

   -- a list of the wrong type is refused rather than guessed at
   Helper.write_raw(m, root, "tools.json", '{ "tools": "not a list" }')
   local wrong = m.tool_repository.new(m.config.new(root))
   local wrong_ok, wrong_err = wrong:load()
   check("broken/wrong type refused", not wrong_ok, "accepted a string as tools")
   check("broken/wrong type explains",
         (wrong_err or ""):find("should be a list") ~= nil, tostring(wrong_err))

   Helper.cleanup(root)
end

---------------------------------------------------------------------------
-- 8. Round tripping preserves the library
---------------------------------------------------------------------------

do
   local repo, root, m = Helper.repository("roundtrip")

   local before = m.fileio.read(root .. "\\tools.json")
   repo:save()
   local after = m.fileio.read(root .. "\\tools.json")

   -- reformatted, but the same tools with the same values
   local a = m.json.decode(before)
   local b = m.json.decode(after)
   eq("roundtrip/same tool count", #a.tools, #b.tools)

   for i = 1, #a.tools do
      eq("roundtrip/tool " .. i .. " id", b.tools[i].id, a.tools[i].id)
      eq("roundtrip/tool " .. i .. " name", b.tools[i].name, a.tools[i].name)
      eq("roundtrip/tool " .. i .. " feed", b.tools[i].feed_rate, a.tools[i].feed_rate)
      eq("roundtrip/tool " .. i .. " dia", b.tools[i].diameter, a.tools[i].diameter)
   end

   -- saving twice produces identical bytes
   repo:save()
   eq("roundtrip/stable output", m.fileio.read(root .. "\\tools.json"), after)

   Helper.cleanup(root)
end

---------------------------------------------------------------------------
-- report
---------------------------------------------------------------------------

print(string.format("\n  %d passed, %d failed\n", passed, failed))
if failed > 0 then
   for i = 1, #failures do print("  FAIL  " .. failures[i]) end
   os.exit(1)
end
os.exit(0)
