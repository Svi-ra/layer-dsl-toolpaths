--[[--------------------------------------------------------------------------
| tests/run_api_tests.lua - Integration tests for the toolpath factory.
|
| Runs the real operation modules against a recording mock of the VCarve API
| (tests/mock_vectric.lua) and asserts:
|
|   * every property and method name touched exists in the shipped VCarve
|     binary (tests/api_names.lua, extracted by tools/extract_api_names.py)
|   * each Create*Toolpath is called with the documented argument count and
|     argument ORDER
|   * DSL parameters actually reach the VCarve objects
|
| Run:  lua tests/run_api_tests.lua      (from the repository root)
----------------------------------------------------------------------------]]

local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
local LIB  = ROOT .. "/LayerDSL_Toolpaths/lib/"

local API   = dofile(ROOT .. "/tests/api_names.lua")
local Mock  = dofile(ROOT .. "/tests/mock_vectric.lua")

local Log    = dofile(LIB .. "log.lua")
local Coerce = dofile(LIB .. "coerce.lua")
local Schema = dofile(LIB .. "schema.lua").init(Coerce)
local Parser = dofile(LIB .. "parser.lua").init(Schema, Coerce)
local Config = dofile(ROOT .. "/LayerDSL_Toolpaths/config.lua")

---------------------------------------------------------------------------
-- harness
---------------------------------------------------------------------------

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
-- build one toolpath through the real factory + ops
---------------------------------------------------------------------------

local Helper = dofile(ROOT .. "/tests/db_helper.lua")

--[[
| Tools now come from a real tools.json in a throwaway folder, built by
| tests/db_helper.lua. Ids 1, 2, 3, 4 and 9 are defined there; 9 deliberately
| has zero feeds so the refusal path can be exercised.
]]
local shared_repo, shared_root = Helper.repository("api")

local function build(layer_name, opts)
   opts = opts or {}
   Mock.install(API, opts)

   -- The modules that touch the VCarve API must be loaded AFTER the globals
   -- exist, because enums.lua resolves constants lazily but tooling.lua
   -- captures nothing at load time.
   local Enums   = dofile(LIB .. "enums.lua")
   local DbMods  = Helper.modules()
   local Tooling = dofile(LIB .. "tooling.lua")
                      .init(Enums, Coerce, DbMods.tool_repository)
   local Factory = dofile(LIB .. "factory.lua").init{ enums = Enums, tooling = Tooling }
   Factory.load_standard(LIB)

   local params = Parser.parse(layer_name, Config, Log.new())
   if params == nil then return nil, "layer name did not parse" end
   params.toolpath_name = params.layer_name

   local ctx = Tooling.context({ InMM = true })
   ctx.create_2d_previews   = true
   ctx.interactive_warnings = false
   ctx.tools = opts.tools or shared_repo

   local id, err, warnings = Factory.build(params, ctx)
   return { id = id, err = err, warnings = warnings, params = params }
end

--- Fail the current group if the mock saw a name VCarve does not have.
local function assert_clean_api(label)
   check(label .. "/only real API names used", #Mock.violations == 0,
         table.concat(Mock.violations, "\n      "))
end

---------------------------------------------------------------------------
-- 1. Pocket
---------------------------------------------------------------------------

do
   local r = build("Pocket_tool_1_depth_8_stepover_45_allowance_0.2")
   assert_clean_api("pocket")
   check("pocket/created", r.id ~= nil, tostring(r.err))

   -- A well-formed layer must build silently. This catches enum tokens that
   -- fail to resolve and quietly fall back to a default.
   eq("pocket/no spurious warnings", #r.warnings, 0)

   local call = Mock.only_created()
   check("pocket/one creation call", call ~= nil, "expected exactly one call")
   eq("pocket/right method", call.method, "CreatePocketingToolpath")
   eq("pocket/argument count", call.argc, 8)
   eq("pocket/no rougher by default", call.area_clear_tool, nil)
   eq("pocket/previews flag", call.previews, true)
   eq("pocket/interactive flag", call.interactive, false)

   local pocket = Mock.written(Mock.last("PocketParameterData"))
   eq("pocket/CutDepth",   pocket.CutDepth,   8)
   eq("pocket/StartDepth", pocket.StartDepth, 0.0)
   eq("pocket/Allowance",  pocket.Allowance,  0.2)
   eq("pocket/climb",      pocket.CutDirection, "ProfileParameterData.CLIMB_DIRECTION")
   eq("pocket/offset strategy", pocket.DoRasterClearance, false)
   eq("pocket/profile pass last", pocket.ProfilePassType,
      "PocketParameterData.PROFILE_LAST")

   -- The toolpath must carry a tool built from the tools.json record.
   local store   = Mock.last("Tool")
   local written = Mock.written(store)
   eq("pocket/named from the record", store.__name, "End Mill 6mm")
   eq("pocket/type from the record",  store.__type, "Tool.END_MILL")
   eq("pocket/diameter from json",    written.ToolDia, 6.0)
   eq("pocket/feed from json",        written.FeedRate, 220.0)
   eq("pocket/plunge from json",      written.PlungeRate, 75.0)
   eq("pocket/spindle from json",     written.SpindleSpeed, 10000)
   eq("pocket/stepdown from json",    written.Stepdown, 2.0)
   eq("pocket/tool number from json", written.ToolNumber, 1)
   eq("pocket/rate units from json",  written.RateUnits, "Tool.MM_MIN")
   eq("pocket/units flag", written.InMM, true)

   -- stepover WAS explicit in the layer name, so it overrides, resolved
   -- against the record's real diameter
   eq("pocket/stepover is 45% of json diameter", written.Stepover, 6.0 * 0.45)
end

do -- config.lua must not override the tool record
   local r = build("Pocket_tool_2_depth_8")
   assert_clean_api("pocket-nolayer")
   local store   = Mock.last("Tool")
   local written = Mock.written(store)
   eq("record-wins/tool 2 chosen", store.__name, "End Mill 12mm")
   eq("record-wins/feed from json", written.FeedRate, 180.0)
   eq("record-wins/stepdown from json", written.Stepdown, 3.0)
   eq("record-wins/stepover from json", written.Stepover, 4.8)
end

do -- an explicit layer value beats the library
   local r = build("Pocket_tool_1_depth_8_feed_500_pass_depth_1.25_spindle_24000")
   assert_clean_api("pocket-override")
   local written = Mock.written(Mock.last("Tool"))
   eq("override/feed",       written.FeedRate, 500)
   eq("override/pass_depth", written.Stepdown, 1.25)
   eq("override/spindle",    written.SpindleSpeed, 24000)
   eq("override/plunge still from json", written.PlungeRate, 75.0)
end

do -- raster strategy and two-tool roughing
   local r = build("Pocket_tool_1_depth_8_strategy_raster_roughing_true_roughing_tool_2")
   assert_clean_api("pocket-rough")
   check("pocket-rough/created", r.id ~= nil, tostring(r.err))

   local call = Mock.only_created()
   check("pocket-rough/has area clear tool", call.area_clear_tool ~= nil, "nil rougher")

   local pocket = Mock.written(Mock.last("PocketParameterData"))
   eq("pocket-rough/raster on", pocket.DoRasterClearance, true)
   eq("pocket-rough/UseAreaClearTool", pocket.UseAreaClearTool, true)

   local tools = Mock.instances("Tool")
   eq("pocket-rough/two tools built", #tools, 2)
   eq("pocket-rough/finisher is tool 1", tools[1].__name, "End Mill 6mm")
   eq("pocket-rough/rougher is tool 2",  tools[2].__name, "End Mill 12mm")
end

do -- a roughing tool no bigger than the finisher is refused, not silently used
   local r = build("Pocket_tool_2_depth_8_roughing_true_roughing_tool_1")
   check("pocket-badrough/still created", r.id ~= nil, tostring(r.err))
   eq("pocket-badrough/no rougher attached", Mock.only_created().area_clear_tool, nil)
   check("pocket-badrough/warned", #r.warnings > 0, "expected a warning")
end

do -- roughing without a tool number warns instead of inventing one
   local r = build("Pocket_tool_1_depth_8_roughing_true")
   check("pocket-norough/still created", r.id ~= nil, tostring(r.err))
   eq("pocket-norough/no rougher", Mock.only_created().area_clear_tool, nil)
   check("pocket-norough/warned", #r.warnings > 0, "expected a warning")
end

---------------------------------------------------------------------------
-- 2. Profile
---------------------------------------------------------------------------

do
   local r = build("Profile_side_outside_tool_1_depth_18")
   assert_clean_api("profile")
   check("profile/created", r.id ~= nil, tostring(r.err))

   local call = Mock.only_created()
   eq("profile/right method", call.method, "CreateProfilingToolpath")
   eq("profile/argument count", call.argc, 9)

   local profile = Mock.written(Mock.last("ProfileParameterData"))
   eq("profile/CutDepth", profile.CutDepth, 18)
   eq("profile/side outside", profile.ProfileSide,
      "ProfileParameterData.PROFILE_OUTSIDE")
   eq("profile/tabs off", profile.UseTabs, false)

   local leads = Mock.written(Mock.last("LeadInOutData"))
   eq("profile/lead in off by default", leads.DoLeadIn, false)

   local ramping = Mock.written(Mock.last("RampingData"))
   eq("profile/ramping off by default", ramping.DoRamping, false)
end

do -- inside + tabs
   local r = build("Profile_side_inside_tool_1_depth_10_tabs_true")
   assert_clean_api("profile-tabs")

   local profile = Mock.written(Mock.last("ProfileParameterData"))
   eq("profile-tabs/side inside", profile.ProfileSide,
      "ProfileParameterData.PROFILE_INSIDE")
   eq("profile-tabs/UseTabs", profile.UseTabs, true)
   eq("profile-tabs/TabLength", profile.TabLength, Config.operations.Profile.tab_width)
   eq("profile-tabs/TabThickness", profile.TabThickness,
      Config.operations.Profile.tab_height)
   eq("profile-tabs/3d tabs", profile.Use3dTabs, true)
end

do -- leads and ramping
   local r = build("Profile_tool_1_depth_10_lead_in_8_lead_out_8_"
                   .. "lead_type_linear_ramp_20_ramp_angle_15")
   assert_clean_api("profile-leads")

   local leads = Mock.written(Mock.last("LeadInOutData"))
   eq("profile-leads/DoLeadIn", leads.DoLeadIn, true)
   eq("profile-leads/DoLeadOut", leads.DoLeadOut, true)
   eq("profile-leads/LeadLength", leads.LeadLength, 8)
   eq("profile-leads/linear type", leads.LeadType, "LeadInOutData.LINEAR_LEAD")

   local ramping = Mock.written(Mock.last("RampingData"))
   eq("profile-leads/DoRamping", ramping.DoRamping, true)
   eq("profile-leads/angle constraint", ramping.RampConstraint,
      "RampingData.CONSTRAIN_ANGLE")
   eq("profile-leads/RampAngle", ramping.RampAngle, 15)
end

do -- finishing forces zero allowance
   local r = build("Profile_tool_1_depth_10_allowance_0.5_finishing_true")
   local profile = Mock.written(Mock.last("ProfileParameterData"))
   eq("profile-finish/allowance zeroed", profile.Allowance, 0.0)
end

do -- a V-bit profile without explicit side runs on the vector, not outside
   local r = build("Profile_tool_5_depth_2.7")
   assert_clean_api("profile-vbit-default-on")
   check("profile-vbit-default-on/created", r.id ~= nil, tostring(r.err))
   eq("profile-vbit-default-on/no mismatch warning", #r.warnings, 0)

   local profile = Mock.written(Mock.last("ProfileParameterData"))
   eq("profile-vbit-default-on/side on", profile.ProfileSide,
      "ProfileParameterData.PROFILE_ON")

   local selector = Mock.written(Mock.last("GeometrySelector"))
   eq("profile-vbit-default-on/selects open", selector.SelectOpen, true)
   eq("profile-vbit-default-on/selects closed", selector.SelectClosed, true)
end

---------------------------------------------------------------------------
-- 3. Drill
---------------------------------------------------------------------------

do
   local r = build("Drill_tool_4_depth_20_peck_2")
   assert_clean_api("drill")
   check("drill/created", r.id ~= nil, tostring(r.err))

   local call = Mock.only_created()
   eq("drill/right method", call.method, "CreateDrillingToolpath")
   eq("drill/argument count", call.argc, 7)

   local drill = Mock.written(Mock.last("DrillParameterData"))
   eq("drill/CutDepth", drill.CutDepth, 20)
   eq("drill/DoPeckDrill", drill.DoPeckDrill, true)
   eq("drill/PeckRetractGap", drill.PeckRetractGap, 2)

   local tool = Mock.last("Tool")
   eq("drill/named from the record", tool.__name, "Drill 5mm")
   eq("drill/type from the record", tool.__type, "Tool.THROUGH_DRILL")
   eq("drill/diameter from json", Mock.written(tool).ToolDia, 5.0)
end

do -- peck=false disables pecking
   local r = build("Drill_tool_4_depth_20_peck_false")
   local drill = Mock.written(Mock.last("DrillParameterData"))
   eq("drill-nopeck/DoPeckDrill", drill.DoPeckDrill, false)
end

---------------------------------------------------------------------------
-- 4. VCarve
---------------------------------------------------------------------------

do
   local r = build("VCarve_tool_3_flat_3_flat_tool_1")
   assert_clean_api("vcarve")
   check("vcarve/created", r.id ~= nil, tostring(r.err))

   local call = Mock.only_created()
   eq("vcarve/right method", call.method, "CreateVCarvingToolpath")
   eq("vcarve/argument count", call.argc, 9)
   check("vcarve/has clearance tool", call.area_clear_tool ~= nil, "nil clearance tool")

   local vcarve = Mock.written(Mock.last("VCarveParameterData"))
   eq("vcarve/DoFlatBottom", vcarve.DoFlatBottom, true)
   eq("vcarve/FlatDepth", vcarve.FlatDepth, 3)
   eq("vcarve/UseAreaClearTool", vcarve.UseAreaClearTool, true)

   -- The V-bit and the clearance end mill both come from tools.json.
   local tools = Mock.instances("Tool")
   eq("vcarve/vbit is tool 3",  tools[1].__name, "V-Bit 60")
   eq("vcarve/vbit type",       tools[1].__type, "Tool.VBIT")
   eq("vcarve/clear tool is 1", tools[2].__name, "End Mill 6mm")

   --[[
   | The included angle comes from the JSON record and is written to
   | VBit_Angle. Vectric's own samples write `VBitAngle`, which is not a real
   | binding, so the angle silently stays at its default and the carve comes
   | out wrong. tests/api_names.lua is what makes that failure visible.
   ]]
   eq("vcarve/angle from json", tools[1].__set.VBit_Angle, 60.0)
   check("vcarve/VBitAngle NOT used", tools[1].__set.VBitAngle == nil,
         "wrote to VBitAngle, which is not a real binding")
end

do -- pure v-carve, no flat bottom
   local r = build("VCarve_tool_3")
   assert_clean_api("vcarve-pure")

   local vcarve = Mock.written(Mock.last("VCarveParameterData"))
   eq("vcarve-pure/DoFlatBottom", vcarve.DoFlatBottom, false)
   eq("vcarve-pure/UseAreaClearTool", vcarve.UseAreaClearTool, false)
   eq("vcarve-pure/no clearance tool", Mock.only_created().area_clear_tool, nil)
   eq("vcarve-pure/angle from json",
      Mock.instances("Tool")[1].__set.VBit_Angle, 60.0)
   eq("vcarve-pure/only one tool built", #Mock.instances("Tool"), 1)
end

do -- a tool with no V-bit angle is refused before reaching VCarve
   -- tool 1 is an end mill, so it has no included angle
   local r = build("VCarve_tool_1_flat_3_flat_tool_1")
   eq("vcarve-notvbit/not created", r.id, nil)
   check("vcarve-notvbit/explained",
         (r.err or ""):find("angle") ~= nil, tostring(r.err))
   eq("vcarve-notvbit/no API call", #Mock.created, 0)
end

do -- a flat bottom with no clearance tool number is refused
   local r = build("VCarve_tool_3_flat_3")
   eq("vcarve-noflattool/not created", r.id, nil)
   check("vcarve-noflattool/explained",
         (r.err or ""):find("flat_tool") ~= nil, tostring(r.err))
end

---------------------------------------------------------------------------
-- 4b. Tool library safety
---------------------------------------------------------------------------

do -- a tool id that is not in tools.json never reaches VCarve
   local r = build("Pocket_tool_7_depth_8")
   eq("missing/not created", r.id, nil)
   check("missing/explained", (r.err or ""):find("no tool") ~= nil, tostring(r.err))
   check("missing/names the file", (r.err or ""):find("tools.json") ~= nil,
         tostring(r.err))
   eq("missing/no API call", #Mock.created, 0)
   eq("missing/no tool built", #Mock.instances("Tool"), 0)
end

do -- a tool referenced by name that does not exist
   local r = build("Pocket|tool=Nonexistent|depth=8")
   eq("missingname/not created", r.id, nil)
   check("missingname/explained", (r.err or ""):find("named") ~= nil, tostring(r.err))
end

do -- a tool referenced by NAME resolves, which is why find_by_name exists
   local r = build("Pocket|tool=End Mill 12mm|depth=8")
   assert_clean_api("byname")
   check("byname/created", r.id ~= nil, tostring(r.err))
   eq("byname/right tool", Mock.last("Tool").__name, "End Mill 12mm")
   eq("byname/diameter", Mock.written(Mock.last("Tool")).ToolDia, 12.0)
end

do
   --[[
   | A tool record with zero feeds would plunge and cut at zero. The record
   | is validated BEFORE anything is built, so this is refused outright
   | rather than patched per layer - a broken record should be fixed in
   | tools.json, not worked around in a layer name.
   ]]
   local r = build("Pocket_tool_9_depth_8")
   eq("zerofeed/not created", r.id, nil)
   check("zerofeed/names the field",
         (r.err or ""):find("feed_rate") ~= nil, tostring(r.err))
   eq("zerofeed/no API call", #Mock.created, 0)
   eq("zerofeed/no tool built", #Mock.instances("Tool"), 0)

   -- and a layer-name override does not paper over it
   local still = build("Pocket_tool_9_depth_8_feed_200_plunge_80_spindle_12000")
   eq("zerofeed/override does not bypass validation", still.id, nil)
end

do -- using the wrong type of tool warns but still builds
   local r = build("Drill_tool_1_depth_10")   -- an end mill used for drilling
   check("wrongtype/still created", r.id ~= nil, tostring(r.err))
   check("wrongtype/warned", #r.warnings > 0, "expected a tool type warning")
   local joined = table.concat(r.warnings, " ")
   check("wrongtype/names the tool", joined:find("tool 1") ~= nil, joined)
   check("wrongtype/names the type", joined:find("end mill") ~= nil, joined)
end

do -- two layers using the same tool get independent Tool objects
   build("Pocket_tool_1_depth_8")
   local first = Mock.last("Tool")
   build("Pocket_tool_1_depth_20_feed_999")
   local second = Mock.last("Tool")

   check("sharing/distinct objects", first ~= second,
         "the same Tool object was reused; overrides would leak between layers")
   eq("sharing/first untouched by the second", first.__set.FeedRate, 220.0)
   eq("sharing/second overridden", second.__set.FeedRate, 999)
end

do -- an inch tool sets InMM false, so geometry is not silently 25x wrong
   local repo = Helper.repository("inch", [[
{ "tools": [ { "id": 1, "name": "Imperial", "type": "end_mill",
               "units": "inch", "diameter": 0.25, "stepdown": 0.1,
               "stepover": 0.1, "feed_rate": 60, "plunge_rate": 20,
               "spindle_speed": 16000, "rate_units": "in_min" } ] }
]])
   local r = build("Pocket_tool_1_depth_0.5", { tools = repo })
   assert_clean_api("inch")
   check("inch/created", r.id ~= nil, tostring(r.err))
   local written = Mock.written(Mock.last("Tool"))
   eq("inch/InMM is false", written.InMM, false)
   eq("inch/diameter kept", written.ToolDia, 0.25)
   eq("inch/rate units", written.RateUnits, "Tool.INCHES_MIN")
end

---------------------------------------------------------------------------
-- 5. Geometry selector wiring
---------------------------------------------------------------------------

do
   build("Pocket_tool_1_depth_8")
   local selector = Mock.written(Mock.last("GeometrySelector"))
   eq("selector/filter activated", selector.GeometryFilterUsed, true)
   eq("selector/restricted to layers", selector.OnlyOnLayers, true)
   eq("selector/closed vectors", selector.SelectClosed, true)
   eq("selector/mixed groups allowed", selector.MixedGroupsOk, true)

   build("Drill_tool_4_depth_10")
   local drill_selector = Mock.written(Mock.last("GeometrySelector"))
   eq("selector/drill selects circles", drill_selector.SelectCircles, true)

   build("Profile_tool_1_depth_8_vector_selection_open")
   local open_selector = Mock.written(Mock.last("GeometrySelector"))
   eq("selector/open vectors", open_selector.SelectOpen, true)
   eq("selector/open excludes closed", open_selector.SelectClosed, false)
end

---------------------------------------------------------------------------
-- 6. Position data
---------------------------------------------------------------------------

do
   build("Pocket_tool_1_depth_8_safe_z_7_clearance_3")
   local pos = Mock.written(Mock.last("ToolpathPosData"))
   eq("pos/SafeZGap", pos.SafeZGap, 7)
   eq("pos/StartZGap", pos.StartZGap, 3)

   local calls = Mock.last("ToolpathPosData").__calls
   local saw_home, saw_ensure = false, false
   for _, c in ipairs(calls) do
      if c.name == "SetHomePosition"  then saw_home   = true end
      if c.name == "EnsureHomeZIsSafe" then saw_ensure = true end
   end
   check("pos/home position set", saw_home, "SetHomePosition was never called")
   check("pos/home z made safe", saw_ensure, "EnsureHomeZIsSafe was never called")
end

---------------------------------------------------------------------------
-- 7. A failing operation is contained, not fatal
---------------------------------------------------------------------------

do
   Mock.install(API, {})
   local Enums   = dofile(LIB .. "enums.lua")
   local Tooling = dofile(LIB .. "tooling.lua").init(Enums)
   local Factory = dofile(LIB .. "factory.lua").init{ enums = Enums, tooling = Tooling }

   Factory.register{
      name  = "Exploding",
      build = function() error("boom") end,
   }

   local id, err = Factory.build({ operation = "Exploding" }, {})
   eq("contain/no toolpath", id, nil)
   check("contain/reported as internal error",
         (err or ""):find("internal error") ~= nil, tostring(err))

   local id2, err2 = Factory.build({ operation = "NoSuchThing" }, {})
   eq("contain/unregistered op returns nil", id2, nil)
   check("contain/unregistered explained",
         (err2 or ""):find("no factory registered") ~= nil, tostring(err2))
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
