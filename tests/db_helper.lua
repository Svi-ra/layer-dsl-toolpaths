--[[--------------------------------------------------------------------------
| tests/db_helper.lua - Build a SmartCAM database in a throwaway folder.
|
| The repository tests exercise real file IO, because that is where the
| interesting failures live: missing folders, malformed JSON, partial writes.
| Everything lands under the system temp directory and is removed afterwards,
| so a test run never touches C:\ProgramData\SmartCAM.
----------------------------------------------------------------------------]]

local Helper = {}

local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
local LIB  = ROOT .. "/LayerDSL_Toolpaths/lib/"

Helper.LIB = LIB

--- Load a fresh, fully wired database module set.
function Helper.modules()
   local m = {}
   m.fileio          = dofile(LIB .. "db/fileio.lua")
   m.json            = dofile(LIB .. "db/json.lua")
   m.config          = dofile(LIB .. "db/config.lua").init(m.fileio)
   m.store           = dofile(LIB .. "db/store.lua").init(m.fileio, m.json)
   m.seed            = dofile(LIB .. "db/seed.lua").init(m.json)
   m.tool_repository = dofile(LIB .. "db/tool_repository.lua").init(m.store, m.seed)
   m.database        = dofile(LIB .. "db/database.lua").init{
      config          = m.config,
      store           = m.store,
      seed            = m.seed,
      tool_repository = m.tool_repository,
   }
   -- Each test gets a clean view of the filesystem; ensure_directory
   -- remembers outcomes per run, which would otherwise leak between tests.
   m.fileio.reset_directory_cache()
   return m
end

local counter = 0

--- A unique temp folder path. Not created; that is the code under test's job.
function Helper.temp_root(label)
   counter = counter + 1
   local base = os.getenv("TEMP") or os.getenv("TMP") or "."
   return string.format("%s\\smartcam_test_%d_%d_%s",
                        base, os.time(), counter, label or "db")
end

--- Remove a test folder and everything the gadget may have put in it.
function Helper.cleanup(root)
   local names = {
      "tools.json", "machines.json", "materials.json",
      "presets.json", "settings.json",
   }
   for _, name in ipairs(names) do
      os.remove(root .. "\\" .. name)
      os.remove(root .. "\\" .. name .. ".bak")
      os.remove(root .. "\\" .. name .. ".tmp")
   end
   os.remove(root .. "\\.smartcam_write_test")
   -- rmdir only succeeds when the folder is empty, which is the point
   pcall(os.execute, 'rmdir "' .. root .. '" 2>nul')
end

--- Write raw text into a database file, to simulate hand editing.
function Helper.write_raw(m, root, name, text)
   local path = root .. "\\" .. name
   return m.fileio.write(path, text)
end

--- A small, valid tool library used by most tests.
function Helper.tools_json()
   return [[
{
  "schema": 1,
  "tools": [
    {
      "id": 1, "name": "End Mill 6mm", "type": "end_mill", "units": "mm",
      "diameter": 6.0, "tool_number": 1,
      "stepdown": 2.0, "stepover": 2.4,
      "feed_rate": 220.0, "plunge_rate": 75.0, "spindle_speed": 10000,
      "rate_units": "mm_min"
    },
    {
      "id": 2, "name": "End Mill 12mm", "type": "end_mill", "units": "mm",
      "diameter": 12.0, "tool_number": 2,
      "stepdown": 3.0, "stepover": 4.8,
      "feed_rate": 180.0, "plunge_rate": 60.0, "spindle_speed": 12000,
      "rate_units": "mm_min"
    },
    {
      "id": 3, "name": "V-Bit 60", "type": "vbit", "units": "mm",
      "diameter": 12.0, "included_angle": 60.0, "tool_number": 3,
      "stepdown": 3.0, "stepover": 4.0, "clear_stepover": 4.0,
      "feed_rate": 150.0, "plunge_rate": 50.0, "spindle_speed": 16000,
      "rate_units": "mm_min"
    },
    {
      "id": 4, "name": "Drill 5mm", "type": "through_drill", "units": "mm",
      "diameter": 5.0, "tool_number": 4,
      "stepdown": 5.0, "stepover": 1.0,
      "feed_rate": 100.0, "plunge_rate": 40.0, "spindle_speed": 8000,
      "rate_units": "mm_min"
    },
    {
      "id": 5, "name": "V-Bit 90 degree", "type": "vbit", "units": "mm",
      "diameter": 12.0, "included_angle": 90.0, "tool_number": 5,
      "stepdown": 3.0, "stepover": 4.0, "clear_stepover": 3.5,
      "feed_rate": 150.0, "plunge_rate": 50.0, "spindle_speed": 16000,
      "rate_units": "mm_min"
    },
    {
      "id": 11, "name": "Ball Nose 8mm", "type": "ball_nose", "units": "mm",
      "diameter": 8.0, "tool_number": 11,
      "stepdown": 3.0, "stepover": 2.0,
      "feed_rate": 150.0, "plunge_rate": 50.0, "spindle_speed": 16000,
      "rate_units": "mm_min"
    },
    {
      "id": 9, "name": "No Feeds", "type": "end_mill", "units": "mm",
      "diameter": 6.0, "tool_number": 9,
      "stepdown": 2.0, "stepover": 2.4,
      "feed_rate": 0, "plunge_rate": 0, "spindle_speed": 0,
      "rate_units": "mm_min"
    }
  ]
}
]]
end

--- A ready-to-use repository over the standard test library.
-- @return repository, root, modules
function Helper.repository(label, tools_text)
   local m    = Helper.modules()
   local root = Helper.temp_root(label)

   m.fileio.ensure_directory(root)
   Helper.write_raw(m, root, "tools.json", tools_text or Helper.tools_json())

   local config = m.config.new(root)
   local repo   = m.tool_repository.new(config)
   repo:load()

   return repo, root, m
end

return Helper
