--[[--------------------------------------------------------------------------
| tests/mock_vectric.lua - A recording stand-in for the VCarve Lua API.
|
| Lets the operation modules and the factory run outside VCarve. Every
| property write and method call is recorded, and - the point of the exercise
| - checked against tests/api_names.lua, which is extracted straight from the
| shipped VCarveProTrialEdition.exe.
|
| Tools are NOT mocked as a database any more: the gadget builds them from
| SmartCAM JSON records, so what is checked here is that the right VCarve
| properties get the right values.
|
| So a typo like `tool.VBitAngle` (which is what Vectric's own samples use;
| the real binding is `VBit_Angle`) fails the test instead of silently
| producing a wrong toolpath.
----------------------------------------------------------------------------]]

local Mock = {}

local API_NAMES   -- injected by Mock.install

Mock.violations   = {}   -- property/method names not present in the real API
Mock.created      = {}   -- toolpath creation calls, in order
Mock.objects      = {}   -- every mock object created, by class
Mock.recalculated = {}   -- ids passed to RecalculateToolpath, in order
Mock.recalculated_all = {} -- ids swept up by RecalculateAllToolpaths
Mock.toolpaths    = {}   -- the job's toolpath list, as the manager sees it

local function violation(class, kind, name)
   Mock.violations[#Mock.violations + 1] =
      string.format("%s.%s (%s) is not a real VCarve binding", class, name, kind)
end

---------------------------------------------------------------------------
-- recording object
---------------------------------------------------------------------------

--- Create an object that records writes and validates every name it sees.
-- @param class     string  class name, for error messages
-- @param constants table   class constants readable as fields
local function recorder(class, constants)
   local store = { __class = class, __set = {}, __calls = {} }

   local methods = {}

   local proxy = setmetatable({}, {
      __index = function(_, key)
         if store[key] ~= nil then return store[key] end
         if methods[key] then return methods[key] end
         if constants and constants[key] ~= nil then return constants[key] end

         -- An unknown READ is usually a method call; hand back a recorder.
         if API_NAMES[key] == nil then
            violation(class, "method", key)
         end
         local fn = function(_, ...)
            store.__calls[#store.__calls + 1] = { name = key, args = { ... } }
            return true
         end
         methods[key] = fn
         return fn
      end,

      __newindex = function(_, key, value)
         if API_NAMES[key] == nil then
            violation(class, "property", key)
         end
         store.__set[key] = value
         store[key] = value
      end,
   })

   Mock.objects[class] = Mock.objects[class] or {}
   Mock.objects[class][#Mock.objects[class] + 1] = store

   return proxy, store
end

Mock.recorder = recorder

--- A class that is both callable (constructor) and holds constants.
local function class_with_constants(name, constant_names, ctor)
   local constants = {}
   for _, c in ipairs(constant_names or {}) do
      if API_NAMES[c] == nil then violation(name, "constant", c) end
      constants[c] = name .. "." .. c   -- a distinguishable sentinel
   end

   return setmetatable({}, {
      __index = function(_, key)
         if constants[key] ~= nil then return constants[key] end
         violation(name, "constant", key)
         return name .. ".<unknown:" .. tostring(key) .. ">"
      end,
      __call = function(_, ...)
         if ctor then return ctor(...) end
         return (recorder(name, constants))
      end,
   })
end

---------------------------------------------------------------------------
-- install
---------------------------------------------------------------------------

--- Define the VCarve globals. Call before exercising the gadget modules.
-- @param api_names table  from tests/api_names.lua
-- @param opts      table  { thickness = ..., in_mm = ... }
function Mock.install(api_names, opts)
   API_NAMES = api_names
   opts = opts or {}

   Mock.violations   = {}
   Mock.created      = {}
   Mock.objects      = {}
   Mock.recalculated = {}
   Mock.recalculated_all = {}

   local thickness = opts.thickness or 18.0

   ------------------------------------------------------------------
   -- Tool
   ------------------------------------------------------------------
   Tool = class_with_constants("Tool", {
      "BALL_NOSE", "END_MILL", "RADIUSED_END_MILL", "VBIT", "ENGRAVING",
      "RADIUSED_ENGRAVING", "THROUGH_DRILL", "DIAMOND_DRAG",
      "MM_SEC", "MM_MIN", "METRES_MIN", "INCHES_SEC", "INCHES_MIN", "FEET_MIN",
   }, function(name, tool_type)
      local proxy, store = recorder("Tool")
      store.__name = name
      store.__type = tool_type
      return proxy
   end)

   ------------------------------------------------------------------
   -- Parameter data objects
   ------------------------------------------------------------------
   ProfileParameterData = class_with_constants("ProfileParameterData", {
      "CLIMB_DIRECTION", "CONVENTIONAL_DIRECTION",
      "PROFILE_OUTSIDE", "PROFILE_INSIDE", "PROFILE_ON",
      "PROFILE_NORMAL", "PROFILE_MALE_INLAY", "PROFILE_FEMALE_INLAY",
   })

   PocketParameterData = class_with_constants("PocketParameterData", {
      "PROFILE_NONE", "PROFILE_FIRST", "PROFILE_LAST",
      "POCKET_NORMAL", "POCKET_INLAY",
   })

   RampingData = class_with_constants("RampingData", {
      "RAMP_ZIG_ZAG", "RAMP_SPIRAL", "CONSTRAIN_DISTANCE", "CONSTRAIN_ANGLE",
   })

   LeadInOutData = class_with_constants("LeadInOutData", {
      "LINEAR_LEAD", "CIRCULAR_LEAD",
   })

   DrillParameterData  = class_with_constants("DrillParameterData", {})
   VCarveParameterData = class_with_constants("VCarveParameterData", {})
   GeometrySelector    = class_with_constants("GeometrySelector", {})
   ToolpathPosData     = class_with_constants("ToolpathPosData", {})

   ------------------------------------------------------------------
   -- MaterialBlock
   ------------------------------------------------------------------
   MaterialBlock = class_with_constants("MaterialBlock", {
      "BLC", "BRC", "TRC", "TLC", "CENTRE",
      "Z_TOP", "Z_CENTRE", "Z_BOTTOM", "X_AXIS", "Y_AXIS",
      "SINGLE_SIDED", "DOUBLE_SIDED", "ROTARY",
   }, function()
      return {
         Thickness = thickness,
         InMM      = opts.in_mm ~= false,
         MaterialBox = {
            BLC = { x = 0.0, y = 0.0, z = 0.0 },
            TRC = { x = 600.0, y = 400.0, z = thickness },
         },
      }
   end)

   ------------------------------------------------------------------
   -- ToolpathManager
   ------------------------------------------------------------------
   local CREATORS = {
      CreatePocketingToolpath = {
         "name", "tool", "area_clear_tool", "pocket_data",
         "pos_data", "selector", "previews", "interactive" },
      CreateProfilingToolpath = {
         "name", "tool", "profile_data", "ramping_data", "lead_data",
         "pos_data", "selector", "previews", "interactive" },
      CreateDrillingToolpath = {
         "name", "tool", "drill_data", "pos_data",
         "selector", "previews", "interactive" },
      CreateVCarvingToolpath = {
         "name", "tool", "area_clear_tool", "vcarve_data", "pocket_data",
         "pos_data", "selector", "previews", "interactive" },
   }

   --[[
   | The toolpath LIST, shared by every ToolpathManager() handle - because the
   | real one is, and the runner takes a fresh handle in several places.
   |
   | Modelling it for real is what makes the recalculation route testable: the
   | runner looks the new toolpath up again after creating it, first by the id
   | creation returned and then, if the build will not accept that id, by name.
   | A manager whose list is permanently empty cannot tell those apart.
   ]]
   Mock.toolpaths = {}

   ToolpathManager = class_with_constants("ToolpathManager", {}, function()
      local manager = {}

      for method, names in pairs(CREATORS) do
         if API_NAMES[method] == nil then
            violation("ToolpathManager", "method", method)
         end
         manager[method] = function(_, ...)
            local args = { ... }
            local call = { method = method, argc = select("#", ...) }
            for i, key in ipairs(names) do call[key] = args[i] end
            Mock.created[#Mock.created + 1] = call

            if call.argc ~= #names then
               Mock.violations[#Mock.violations + 1] = string.format(
                  "%s called with %d arguments, expected %d",
                  method, call.argc, #names)
            end

            local id = "uuid-" .. #Mock.created
            -- Creation APPENDS, which is the whole basis of the runner's
            -- "last toolpath of this name is the new one" fallback.
            Mock.toolpaths[#Mock.toolpaths + 1] = { Name = call.name, __id = id }
            return id
         end
      end

      manager.ToolpathWithNameExists = function(_, name)
         for _, t in ipairs(Mock.toolpaths) do
            if t.Name == name then return true end
         end
         return false
      end

      manager.GetHeadPosition = function()
         return #Mock.toolpaths > 0 and 1 or nil
      end

      manager.GetNext = function(_, pos)
         local toolpath = Mock.toolpaths[pos]
         if pos >= #Mock.toolpaths then return toolpath, nil end
         return toolpath, pos + 1
      end

      manager.DeleteToolpath = function(_, toolpath)
         for i, t in ipairs(Mock.toolpaths) do
            if t == toolpath then
               table.remove(Mock.toolpaths, i)
               return true
            end
         end
         return false
      end

      --[[
      | id -> POSITION -> Toolpath -> recalculate, the documented route. A
      | POSITION is opaque in VCarve, so an index stands in for one.
      |
      | opts.no_find models the build Sheet_Diagnostics measured, where the id
      | creation returns is NOT the `UUID const&` these take and the call
      | raises. The runner has to fall back to the name and still get there.
      |
      | opts.no_recalculate removes the lot, modelling a build that cannot
      | recalculate from script at all.
      ]]
      if not opts.no_recalculate then
         for _, name in ipairs{ "Find", "GetAt", "RecalculateToolpath",
                                "RecalculateAllToolpaths" } do
            if API_NAMES[name] == nil then
               violation("ToolpathManager", "method", name)
            end
         end

         if not opts.no_find then
            manager.Find = function(_, id)
               for i, t in ipairs(Mock.toolpaths) do
                  if t.__id == id then return i end
               end
               return nil
            end
            manager.GetAt = function(_, pos) return Mock.toolpaths[pos] end
         end

         manager.RecalculateToolpath = function(_, toolpath)
            if opts.recalculate_fails then return false end
            Mock.recalculated[#Mock.recalculated + 1] = toolpath.__id
            return true
         end

         manager.RecalculateAllToolpaths = function()
            if opts.recalculate_all_fails then return nil end
            for _, t in ipairs(Mock.toolpaths) do
               Mock.recalculated_all[#Mock.recalculated_all + 1] = t.__id
            end
            return "recalculated " .. #Mock.toolpaths .. " toolpath(s)"
         end
      end

      return manager
   end)

   ------------------------------------------------------------------
   -- Message boxes
   ------------------------------------------------------------------
   Mock.messages = {}
   DisplayMessageBox = function(text) Mock.messages[#Mock.messages + 1] = text end
   MessageBox        = DisplayMessageBox
end

---------------------------------------------------------------------------
-- Job / layer mocks, for testing lib/runner.lua
---------------------------------------------------------------------------

--- Build a fake VectricJob whose LayerManager walks the given layers.
--
-- @param specs array of { name = ..., objects = n, visible = bool,
--                         system = bool, bitmap = bool }
function Mock.job(specs)
   local layers = {}

   for i, spec in ipairs(specs) do
      local count = spec.objects == nil and 1 or spec.objects
      layers[i] = {
         Name          = spec.name,
         IsSystemLayer = spec.system == true,
         IsBitmapLayer = spec.bitmap == true,
         Visible       = spec.visible ~= false,
         -- A POSITION is opaque; a plain integer models it fine here.
         GetHeadPosition = function() return count > 0 and 1 or nil end,
         GetNext = function(_, pos)
            if pos >= count then return {}, nil end
            return {}, pos + 1
         end,
      }
   end

   local manager = {
      Count           = #layers,
      GetHeadPosition = function() return #layers > 0 and 1 or nil end,
      GetNext = function(_, pos)
         local layer = layers[pos]
         if pos >= #layers then return layer, nil end
         return layer, pos + 1
      end,
      FindLayerWithName = function(_, name)
         for _, layer in ipairs(layers) do
            if layer.Name == name then return layer end
         end
         return nil
      end,
   }

   local refreshed = { count = 0 }

   return {
      Exists       = true,
      InMM         = true,
      LayerManager = manager,
      Refresh2DView = function() refreshed.count = refreshed.count + 1 end,
      __refreshed  = refreshed,
      __layers     = layers,
   }
end

--- Replace ToolpathManager with one that reports the named toolpaths as
--- already existing, so replace_existing behaviour can be tested.
function Mock.seed_existing_toolpaths(names)
   local remaining = {}
   for _, name in ipairs(names) do
      remaining[#remaining + 1] = { Name = name }
   end

   Mock.deleted = {}

   local previous = ToolpathManager
   ToolpathManager = setmetatable({}, { __call = function()
      local manager = previous()

      manager.ToolpathWithNameExists = function(_, name)
         for _, t in ipairs(remaining) do
            if t.Name == name then return true end
         end
         return false
      end

      manager.GetHeadPosition = function() return #remaining > 0 and 1 or nil end
      manager.GetNext = function(_, pos)
         local toolpath = remaining[pos]
         if pos >= #remaining then return toolpath, nil end
         return toolpath, pos + 1
      end
      manager.DeleteToolpath = function(_, toolpath)
         for i, t in ipairs(remaining) do
            if t == toolpath then
               table.remove(remaining, i)
               Mock.deleted[#Mock.deleted + 1] = t.Name
               return true
            end
         end
         return false
      end

      return manager
   end })
end

--- The single creation call recorded, or nil.
function Mock.only_created()
   if #Mock.created ~= 1 then return nil end
   return Mock.created[1]
end

--- Property values written to a mock object proxy's backing store.
function Mock.written(store) return store.__set end

--- All objects of a class created since install.
function Mock.instances(class) return Mock.objects[class] or {} end

--- The most recently created object of a class.
function Mock.last(class)
   local list = Mock.objects[class] or {}
   return list[#list]
end

return Mock
