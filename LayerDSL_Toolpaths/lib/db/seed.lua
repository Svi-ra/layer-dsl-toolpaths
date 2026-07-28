--[[--------------------------------------------------------------------------
| lib/db/seed.lua - What each database file contains when first created.
|
| The seed tool library is deliberately small and obviously placeholder. It
| exists so the gadget can run end to end on a fresh install and so the file
| shows its own format; it is not a claim about anyone's real cutters.
|
| Every seeded tool carries real, conservative feeds so nothing plunges at
| zero, and every one should be checked before it cuts anything.
|
| Pure Lua - no VCarve API.
----------------------------------------------------------------------------]]

local Seed = {}

local Json

function Seed.init(json)
   Json = json
   return Seed
end

--- Bumped when the on-disk shape changes in a way that needs migration.
Seed.SCHEMA_VERSION = 1

---------------------------------------------------------------------------
-- tools.json
---------------------------------------------------------------------------

--[[
| Tool fields
| -----------
|   id             integer  unique; this is what `tool_1` in a layer refers to
|   name           string   shown in the plan and the report
|   type           string   end_mill | ball_nose | vbit | engraving |
|                           through_drill | radiused_end_mill
|   units          string   "mm" or "inch" - the units of THIS tool's sizes
|   diameter       number   cutter diameter
|   included_angle number   V-bits and engraving tools
|   tip_radius     number   radiused end mills and radiused engraving tools
|   flat_diameter  number   engraving tools
|   tool_number    integer  what the post processor emits; defaults to id
|   stepdown       number   cut depth per pass
|   stepover       number   distance, not a percentage
|   clear_stepover number   clearance-pass stepover, V-bits
|   feed_rate      number   in rate_units
|   plunge_rate    number   in rate_units
|   spindle_speed  integer  rpm
|   rate_units     string   mm_sec | mm_min | m_min | in_sec | in_min | ft_min
|   notes          string   free text
]]
function Seed.tools()
   return {
      schema = Seed.SCHEMA_VERSION,
      notes  = "SmartCAM tool library. Check every tool before cutting.",
      tools  = Json.array{
         {
            id = 1, name = "End Mill 6mm", type = "end_mill", units = "mm",
            diameter = 6.0, tool_number = 1,
            stepdown = 2.0, stepover = 2.4,
            feed_rate = 220.0, plunge_rate = 75.0, spindle_speed = 10000,
            rate_units = "mm_min",
            notes = "Placeholder - replace with your own cutter.",
         },
         {
            id = 2, name = "End Mill 12mm", type = "end_mill", units = "mm",
            diameter = 12.0, tool_number = 2,
            stepdown = 3.0, stepover = 4.8,
            feed_rate = 180.0, plunge_rate = 60.0, spindle_speed = 12000,
            rate_units = "mm_min",
            notes = "Placeholder - typically the roughing tool.",
         },
         {
            id = 3, name = "V-Bit 90 degree", type = "vbit", units = "mm",
            diameter = 12.0, included_angle = 90.0, tool_number = 3,
            stepdown = 3.0, stepover = 4.0, clear_stepover = 4.0,
            feed_rate = 150.0, plunge_rate = 50.0, spindle_speed = 16000,
            rate_units = "mm_min",
            notes = "Placeholder - the angle here decides the carve shape.",
         },
         {
            id = 4, name = "Drill 5mm", type = "through_drill", units = "mm",
            diameter = 5.0, tool_number = 4,
            stepdown = 5.0, stepover = 1.0,
            feed_rate = 100.0, plunge_rate = 40.0, spindle_speed = 8000,
            rate_units = "mm_min",
            notes = "Placeholder - used by Drill layers.",
         },
      },
   }
end

---------------------------------------------------------------------------
-- machines.json
---------------------------------------------------------------------------

function Seed.machines()
   return {
      schema   = Seed.SCHEMA_VERSION,
      machines = Json.array{
         {
            id = 1, name = "Default", units = "mm",
            max_x = 1200.0, max_y = 1200.0, max_z = 150.0,
            safe_z = 5.0, clearance = 2.0,
            supports_tool_change = true,
            notes = "Placeholder machine.",
         },
      },
   }
end

---------------------------------------------------------------------------
-- materials.json
---------------------------------------------------------------------------

function Seed.materials()
   return {
      schema    = Seed.SCHEMA_VERSION,
      materials = Json.array{
         { id = 1, name = "MDF",      notes = "" },
         { id = 2, name = "Plywood",  notes = "" },
         { id = 3, name = "Hardwood", notes = "" },
         { id = 4, name = "Acrylic",  notes = "" },
      },
   }
end

---------------------------------------------------------------------------
-- presets.json
---------------------------------------------------------------------------

--[[
| A preset is a named bundle of DSL parameters. It is stored here so named
| cutting recipes can be shared between jobs and machines.
]]
function Seed.presets()
   return {
      schema  = Seed.SCHEMA_VERSION,
      presets = Json.array{
         {
            id = 1, name = "pocket_rough",
            operation = "Pocket",
            parameters = { tool = 2, stepover = 45, strategy = "offset" },
            notes = "Placeholder preset.",
         },
      },
   }
end

---------------------------------------------------------------------------
-- settings.json
---------------------------------------------------------------------------

function Seed.settings()
   return {
      schema           = Seed.SCHEMA_VERSION,
      units            = "mm",
      active_machine   = 1,
      active_material  = 1,
      default_tool     = 1,
      created_by       = "LayerDSL_Toolpaths",
      notes            = "SmartCAM database settings.",
   }
end

---------------------------------------------------------------------------
-- lookup
---------------------------------------------------------------------------

--- Seed function for a logical document name.
function Seed.for_document(name)
   local builders = {
      tools     = Seed.tools,
      machines  = Seed.machines,
      materials = Seed.materials,
      presets   = Seed.presets,
      settings  = Seed.settings,
   }
   return builders[name]
end

return Seed
