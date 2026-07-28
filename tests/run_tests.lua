--[[--------------------------------------------------------------------------
| tests/run_tests.lua - Headless tests for the layer-name DSL.
|
| The parser, schema, coercion and log modules have no VCarve dependency, so
| they can be tested in a plain Lua interpreter:
|
|     lua tests/run_tests.lua            (run from the repository root)
|
| Exits non-zero if any test fails.
----------------------------------------------------------------------------]]

local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
local LIB  = ROOT .. "/LayerDSL_Toolpaths/lib/"

local Log    = dofile(LIB .. "log.lua")
local Coerce = dofile(LIB .. "coerce.lua")
local Schema = dofile(LIB .. "schema.lua").init(Coerce)
local Parser = dofile(LIB .. "parser.lua").init(Schema, Coerce)
local Config = dofile(ROOT .. "/LayerDSL_Toolpaths/config.lua")

---------------------------------------------------------------------------
-- tiny test harness
---------------------------------------------------------------------------

local passed, failed, failures = 0, 0, {}

local function check(name, ok, detail)
   if ok then
      passed = passed + 1
   else
      failed = failed + 1
      failures[#failures + 1] = string.format("%s\n      %s", name, detail or "")
   end
end

local function eq(name, actual, expected)
   check(name, actual == expected,
         string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

local function is_nil(name, actual)
   check(name, actual == nil, "expected nil, got " .. tostring(actual))
end

local function parse(layer, log)
   return Parser.parse(layer, Config, log)
end

---------------------------------------------------------------------------
-- 1. the examples from the specification
---------------------------------------------------------------------------

do
   local p = parse("Pocket|tool=6|depth=8")
   eq("spec/pocket operation", p.operation, "Pocket")
   eq("spec/pocket tool",      p.tool,      6)
   eq("spec/pocket depth",     p.depth,     8)
   eq("spec/pocket inherits strategy from config", p.strategy, "offset")

   -- Tool properties deliberately have NO config default: they belong to
   -- the VCarve tool library, and a default here would override it.
   is_nil("spec/no config stepover", p.stepover)
   is_nil("spec/no config feed",     p.feed)
   is_nil("spec/no config spindle",  p.spindle)
   eq("spec/stepover still overridable",
      parse("Pocket|tool=6|stepover=45").stepover, 45)

   p = parse("Pocket|tool=6|depth=18|stepover=45")
   eq("spec/stepover override", p.stepover, 45)
   eq("spec/depth 18",          p.depth,    18)

   p = parse("Pocket|tool=12|depth=6|allowance=0.2")
   eq("spec/allowance", p.allowance, 0.2)
   eq("spec/tool 12",   p.tool,      12)

   p = parse("Profile|side=outside|tool=6|depth=18")
   eq("spec/profile op",   p.operation, "Profile")
   eq("spec/profile side", p.side,      "outside")

   p = parse("Profile|side=inside|tool=6|depth=10|tabs=true")
   eq("spec/profile inside", p.side, "inside")
   eq("spec/profile tabs",   p.tabs, true)

   p = parse("Drill|tool=5|depth=20|peck=2")
   eq("spec/drill op",   p.operation, "Drill")
   eq("spec/drill peck", p.peck,      2)

   p = parse("VCarve|tool=90|flat=3")
   eq("spec/vcarve op",         p.operation,  "VCarve")
   eq("spec/vcarve angle",      p.tool,       90)
   eq("spec/vcarve flat alias", p.flat_depth, 3)
end

---------------------------------------------------------------------------
-- 2. parameter order is irrelevant
---------------------------------------------------------------------------

do
   local a = parse("Pocket|depth=8|tool=6")
   local b = parse("Pocket|tool=6|depth=8")
   eq("order/identical descriptions", Parser.describe(a), Parser.describe(b))

   local c = parse("Pocket|depth=8|tool=6|stepover=40")
   eq("order/three fields tool",     c.tool,     6)
   eq("order/three fields depth",    c.depth,    8)
   eq("order/three fields stepover", c.stepover, 40)

   -- operation= may appear anywhere
   local d = parse("depth=8|operation=Pocket|tool=6")
   eq("order/operation field late op",    d.operation, "Pocket")
   eq("order/operation field late depth", d.depth,     8)

   local e = parse("Pocket|tool=6|depth=8")
   local f = parse("operation=Pocket|tool=6|depth=8")
   eq("order/bare vs explicit operation", Parser.describe(e), Parser.describe(f))
end

---------------------------------------------------------------------------
-- 3. layer parameters override config defaults
---------------------------------------------------------------------------

do
   local defaults = parse("Pocket|tool=6")
   eq("config/default depth",     defaults.depth,     Config.defaults.depth)
   eq("config/default feed",      defaults.feed,      Config.defaults.feed)
   eq("config/per-op strategy",   defaults.strategy,  Config.operations.Pocket.strategy)

   local overridden = parse("Pocket|tool=6|depth=99|feed=12|strategy=raster")
   eq("config/override depth",    overridden.depth,    99)
   eq("config/override feed",     overridden.feed,     12)
   eq("config/override strategy", overridden.strategy, "raster")

   -- per-operation defaults beat global defaults
   local vc = parse("VCarve")
   eq("config/per-op flat_depth", vc.flat_depth, Config.operations.VCarve.flat_depth)
   is_nil("config/no per-op tabs for vcarve", vc.tabs)
   local pk = parse("Pocket")
   eq("config/global tool number", pk.tool, Config.defaults.tool)
   eq("config/per-op strategy for pocket", pk.strategy,
      Config.operations.Pocket.strategy)
end

---------------------------------------------------------------------------
-- 3b. config values are coerced through the schema
---------------------------------------------------------------------------

do
   -- config.lua writes `last_pass = true`, which reads naturally, but the
   -- factory needs the canonical token. Coercing config through the schema
   -- is what stops a spurious "unsupported profile pass position" warning on
   -- every single pocket.
   local p = parse("Pocket|tool=6|depth=8")
   eq("config-coerce/boolean folds to token", p.last_pass, "last")

   local log = Log.new()
   parse("Pocket|tool=6|depth=8", log)
   eq("config-coerce/clean parse has no warnings", log.counts.warn, 0)

   -- numbers written as numbers stay numbers
   check("config-coerce/depth is a number", type(p.depth) == "number", type(p.depth))
   check("config-coerce/tabs is a boolean",
         type(parse("Profile|tool=6").tabs) == "boolean",
         type(parse("Profile|tool=6").tabs))

   -- an invalid config value is reported once and ignored, not passed through
   Parser.reset()
   local bad = {
      gadget = {},
      defaults = { depth = 5.0, side = "sideways" },
      operations = {},
   }
   log = Log.new()
   local q = Parser.parse("Profile|tool=6", bad, log)
   check("config-coerce/bad config value warned", log.counts.warn >= 1, log:to_text())
   check("config-coerce/bad value not passed through", q.side ~= "sideways",
         tostring(q.side))

   -- and the warning is emitted once, not once per layer
   log = Log.new()
   Parser.parse("Profile|tool=6", bad, log)
   Parser.parse("Profile|tool=8", bad, log)
   Parser.parse("Profile|tool=10", bad, log)
   eq("config-coerce/config warning not repeated", log.counts.warn, 0)
   Parser.reset()

   -- keys that are not DSL parameters pass through untouched, so a custom
   -- operation can read its own settings out of config.lua
   Parser.reset()
   local custom = {
      gadget = {},
      defaults = { my_knob = "hello", depth = 5.0 },
      operations = { Pocket = { my_other_knob = 42 } },
   }
   local c = Parser.parse("Pocket|tool=1", custom, Log.new())
   eq("config-coerce/non-DSL global key preserved", c.my_knob, "hello")
   eq("config-coerce/non-DSL per-op key preserved", c.my_other_knob, 42)
   Parser.reset()
end

---------------------------------------------------------------------------
-- 3c. DXF-safe underscore syntax
--
-- DXF layer names may not contain  < > / \ " : ; ? * | , =  so neither '|'
-- nor '=' survives a DXF round trip. The underscore form has to express
-- everything the classic form does.
---------------------------------------------------------------------------

do
   -- the specification's examples, rewritten DXF-safe
   local p = parse("Pocket_tool_6_depth_8")
   eq("dxf/operation", p.operation, "Pocket")
   eq("dxf/tool",      p.tool,      6)
   eq("dxf/depth",     p.depth,     8)

   p = parse("Pocket_tool_6_depth_18_stepover_45")
   eq("dxf/stepover", p.stepover, 45)
   eq("dxf/depth 18", p.depth,    18)

   p = parse("Pocket_tool_12_depth_6_allowance_0.2")
   eq("dxf/allowance", p.allowance, 0.2)
   eq("dxf/tool 12",   p.tool,      12)

   p = parse("Profile_side_outside_tool_6_depth_18")
   eq("dxf/profile op",   p.operation, "Profile")
   eq("dxf/profile side", p.side,      "outside")
   eq("dxf/profile tool", p.tool,      6)

   p = parse("Profile_side_inside_tool_6_depth_10_tabs_true")
   eq("dxf/profile inside", p.side, "inside")
   eq("dxf/profile tabs",   p.tabs, true)

   p = parse("Drill_tool_5_depth_20_peck_2")
   eq("dxf/drill op",   p.operation, "Drill")
   eq("dxf/drill peck", p.peck,      2)

   p = parse("VCarve_tool_90_flat_3")
   eq("dxf/vcarve op",    p.operation,  "VCarve")
   eq("dxf/vcarve angle", p.tool,       90)
   eq("dxf/vcarve flat",  p.flat_depth, 3)

   -- the underscore form must agree with the classic form exactly
   eq("dxf/equivalent to pipe form",
      Parser.describe(parse("Pocket_tool_6_depth_8")),
      Parser.describe(parse("Pocket|tool=6|depth=8")))
   eq("dxf/equivalent profile",
      Parser.describe(parse("Profile_side_inside_tool_6_depth_10_tabs_true")),
      Parser.describe(parse("Profile|side=inside|tool=6|depth=10|tabs=true")))
end

do -- multi-token KEYS resolve by longest match, not first underscore
   eq("dxf/start_depth key", parse("Pocket_start_depth_2_depth_8").start_depth, 2)
   eq("dxf/start_depth sibling depth", parse("Pocket_start_depth_2_depth_8").depth, 8)
   eq("dxf/pass_depth key",  parse("Pocket_pass_depth_1.5").pass_depth, 1.5)
   eq("dxf/tab_width key",   parse("Profile_tab_width_9").tab_width, 9)
   eq("dxf/cut_direction",   parse("Pocket_cut_direction_conventional").cut_direction,
      "conventional")
   eq("dxf/three token key",
      parse("Profile_keep_start_points_true").keep_start_points, true)
   eq("dxf/vector_selection", parse("Profile_vector_selection_open").vector_selection,
      "open")
end

do -- multi-token VALUES are held together by the enum vocabulary
   eq("dxf/rate_units mm_sec", parse("Pocket_rate_units_mm_sec").rate_units, "mm_sec")
   eq("dxf/rate_units in_min", parse("Pocket_rate_units_in_min").rate_units, "in_min")
   eq("dxf/enum value then key",
      parse("Pocket_rate_units_mm_min_depth_9").rate_units, "mm_min")
   eq("dxf/enum value then key, key wins",
      parse("Pocket_rate_units_mm_min_depth_9").depth, 9)
   eq("dxf/ramp_type zig_zag", parse("Profile_ramp_type_zig_zag").ramp_type, "zigzag")
end

do -- a value that shares its name with a key still parses
   -- `offset` is a Profile key AND a valid `strategy` value
   local p = parse("Pocket_strategy_offset_depth_9")
   eq("dxf/value colliding with key name", p.strategy, "offset")
   eq("dxf/key after colliding value",     p.depth,    9)

   -- `on` is a valid `side` value
   eq("dxf/side on", parse("Profile_side_on_depth_4").side, "on")
   eq("dxf/depth after side on", parse("Profile_side_on_depth_4").depth, 4)

   -- `last` as a last_pass value
   eq("dxf/last_pass last", parse("Pocket_last_pass_last").last_pass, "last")
   eq("dxf/last_pass none", parse("Pocket_last_pass_none").last_pass, "none")
end

do -- multi-token operation aliases
   eq("dxf/v_carve operation", parse("v_carve_tool_60").operation, "VCarve")
   eq("dxf/v_carve tool",      parse("v_carve_tool_60").tool,      60)
   eq("dxf/cutout alias",      parse("cutout_tool_6_depth_8").operation, "Profile")
   eq("dxf/moulding operation", parse("Moulding_tool_11_profile_layer_mouldingprofile").operation, "Moulding")
   eq("dxf/moulding profile layer", parse("Moulding_tool_11_profile_layer_mouldingprofile").profile_layer, "mouldingprofile")
end

do -- unknown parameters still warn without stopping
   local log = Log.new()
   local p = parse("Pocket_tool_6_depth_8_wibble_42", log)
   check("dxf/unknown returns a table", p ~= nil, "parse returned nil")
   eq("dxf/known params survive", p.depth, 8)
   eq("dxf/unknown warned", log.counts.warn, 1)
   eq("dxf/no errors", log.counts.error, 0)
   check("dxf/unknown names the run",
         log:to_text():find("wibble") ~= nil, log:to_text())
end

do -- ordinary layers are never hijacked
   local log = Log.new()
   is_nil("dxf/ignores Milling_path",        parse("Milling_path", log))
   is_nil("dxf/ignores Milling_path_pocket", parse("Milling_path_pocket", log))
   is_nil("dxf/ignores Boundary_",           parse("Boundary_", log))
   is_nil("dxf/ignores Layer_1",             parse("Layer_1", log))

   -- begins with an operation but carries no parameters: a drawing layer
   is_nil("dxf/ignores Pocket_2",      parse("Pocket_2", log))
   is_nil("dxf/ignores Drill_holes",   parse("Drill_holes", log))
   is_nil("dxf/ignores Profile_outer", parse("Profile_outer", log))
   eq("dxf/ignoring is silent", log.counts.warn + log.counts.error, 0)

   -- but a bare operation on its own is unambiguous and still accepted
   eq("dxf/bare operation accepted", parse("Pocket").operation, "Pocket")
   eq("dxf/bare operation uses defaults", parse("Pocket").depth, Config.defaults.depth)
end

do -- the two syntaxes coexist; the separator present decides
   eq("dxf/pipe still wins when present",
      parse("Pocket|start_depth=2|depth=8").start_depth, 2)
   eq("dxf/pipe with underscore assign",
      parse("Pocket|tool_6|depth_8").depth, 8)
   eq("dxf/pipe with underscore assign, tool",
      parse("Pocket|tool_6|depth_8").tool, 6)
   eq("dxf/mixed assigns in one name",
      parse("Pocket|tool=6|depth_8").depth, 8)
end

do -- the syntax is configurable
   Parser.reset()
   local dxf_only = {
      gadget = {}, defaults = Config.defaults, operations = Config.operations,
      syntax = { separators = { "_" }, assigns = { "_" } },
   }
   local p = Parser.parse("Pocket_tool_6_depth_8", dxf_only, Log.new())
   eq("syntax/underscore-only config works", p.depth, 8)

   -- with pipes removed from the config, a pipe name is not a DSL layer
   is_nil("syntax/pipe rejected when not configured",
          Parser.parse("Pocket|tool=6|depth=8", dxf_only, Log.new()))
   Parser.reset()
end

---------------------------------------------------------------------------
-- 4. unknown parameters warn but do not stop
---------------------------------------------------------------------------

do
   local log = Log.new()
   local p = parse("Pocket|tool=6|depth=8|wibble=42|another_bogus=x", log)

   check("unknown/still returns a table", p ~= nil, "parse returned nil")
   eq("unknown/known params survive", p.depth, 8)
   eq("unknown/warning count", log.counts.warn, 2)
   eq("unknown/no errors",     log.counts.error, 0)
   eq("unknown/recorded 1", p.unknown_parameters[1], "wibble")
   eq("unknown/recorded 2", p.unknown_parameters[2], "another_bogus")
   check("unknown/message names the key",
         log:to_text():find("wibble") ~= nil, log:to_text())
end

---------------------------------------------------------------------------
-- 5. bad values warn and fall back to the default
---------------------------------------------------------------------------

do
   local log = Log.new()
   local p = parse("Pocket|tool=6|depth=banana", log)
   eq("badvalue/falls back to config default", p.depth, Config.defaults.depth)
   eq("badvalue/warned", log.counts.warn, 1)

   log = Log.new()
   p = parse("Pocket|tool=6|stepover=500", log)
   eq("badvalue/out of range falls back", p.stepover, Config.operations.Pocket.stepover
                                                       or Config.defaults.stepover)
   eq("badvalue/range warned", log.counts.warn, 1)

   log = Log.new()
   p = parse("Profile|side=sideways", log)
   eq("badvalue/bad enum falls back", p.side, Config.operations.Profile.side)
   check("badvalue/enum lists choices",
         log:to_text():find("inside") ~= nil, log:to_text())
end

---------------------------------------------------------------------------
-- 6. non-DSL layers are ignored silently
---------------------------------------------------------------------------

do
   local log = Log.new()
   is_nil("ignore/plain layer",    parse("Layer 1", log))
   is_nil("ignore/default layer",  parse("Default", log))
   is_nil("ignore/empty",          parse("", log))
   is_nil("ignore/whitespace",     parse("   ", log))
   is_nil("ignore/nil",            parse(nil, log))
   is_nil("ignore/unknown op",     parse("Sandblast|tool=6", log))
   is_nil("ignore/params only",    parse("tool=6|depth=8", log))
   eq("ignore/silent", log.counts.warn + log.counts.error, 0)
end

---------------------------------------------------------------------------
-- 7. aliases, case folding and whitespace
---------------------------------------------------------------------------

do
   eq("alias/rpm -> spindle",       parse("Pocket|rpm=12000").spindle,    12000)
   eq("alias/pover -> stepover",    parse("Pocket|pover=33").stepover,    33)
   eq("alias/flat -> flat_depth",   parse("VCarve|flat=3").flat_depth,    3)
   eq("alias/cut_depth -> depth",   parse("Pocket|cut_depth=7").depth,    7)
   eq("alias/stepdown -> pass_depth", parse("Pocket|stepdown=1.5").pass_depth, 1.5)
   eq("alias/tab_length -> tab_width", parse("Profile|tab_length=9").tab_width, 9)

   eq("case/operation lowercase",   parse("pocket|tool=6").operation, "Pocket")
   eq("case/operation uppercase",   parse("POCKET|tool=6").operation, "Pocket")
   eq("case/key uppercase",         parse("Pocket|DEPTH=8").depth,    8)
   eq("case/enum uppercase",        parse("Profile|side=INSIDE").side, "inside")
   eq("case/op alias cutout",       parse("cutout|tool=6").operation, "Profile")
   eq("case/op alias v_carve",      parse("V-Carve|tool=60").operation, "VCarve")

   eq("space/around separators",    parse("Pocket | tool = 6 | depth = 8 ").depth, 8)
   eq("space/hyphen key folds",     parse("Pocket|start-depth=2").start_depth, 2)
   eq("empty/double separator",     parse("Pocket||depth=8").depth, 8)
   eq("empty/trailing separator",   parse("Pocket|depth=8|").depth, 8)
end

---------------------------------------------------------------------------
-- 8. value coercion detail
---------------------------------------------------------------------------

do
   eq("coerce/bool true",   parse("Profile|tabs=true").tabs,  true)
   eq("coerce/bool yes",    parse("Profile|tabs=yes").tabs,   true)
   eq("coerce/bool 1",      parse("Profile|tabs=1").tabs,     true)
   eq("coerce/bool on",     parse("Profile|tabs=on").tabs,    true)
   eq("coerce/bool false",  parse("Profile|tabs=false").tabs, false)
   eq("coerce/bool no",     parse("Profile|tabs=no").tabs,    false)
   eq("coerce/bool 0",      parse("Profile|tabs=0").tabs,     false)

   eq("coerce/units mm",       parse("Pocket|depth=8mm").depth,     8)
   eq("coerce/units percent",  parse("Pocket|stepover=45%").stepover, 45)
   eq("coerce/units deg",      parse("Profile|ramp_angle=25deg").ramp_angle, 25)

   -- `tool` is a reference, not a measurement, so it is NOT unit-stripped:
   -- a numeric value is an id and anything else is a tool name.
   eq("coerce/tool id is a number",   parse("Pocket|tool=3").tool, 3)
   eq("coerce/tool id ignores zeros", parse("Pocket|tool=03").tool, 3)
   eq("coerce/tool name kept",  parse("Pocket|tool=End Mill 6mm").tool,
      "End Mill 6mm")
   eq("coerce/quoted tool name", parse('Pocket|tool="Big Cutter"').tool,
      "Big Cutter")
   eq("coerce/units rpm",      parse("Pocket|spindle=18000rpm").spindle, 18000)
   eq("coerce/decimal",        parse("Pocket|allowance=0.15").allowance, 0.15)
   eq("coerce/leading dot",    parse("Pocket|allowance=.25").allowance,  0.25)
   eq("coerce/negative allowance", parse("Pocket|allowance=-0.1").allowance, -0.1)
   eq("coerce/quoted",         parse('Pocket|depth="8"').depth, 8)

   -- integers reject fractions
   local log = Log.new()
   parse("Pocket|spindle=1200.5", log)
   eq("coerce/integer rejects fraction", log.counts.warn, 1)

   -- switch: number, true and false
   eq("switch/peck number", parse("Drill|peck=2").peck, 2)
   eq("switch/peck false",  parse("Drill|peck=false").peck, 0)
   eq("switch/lead_in false", parse("Profile|lead_in=false").lead_in, 0)
   eq("switch/lead_in number", parse("Profile|lead_in=8").lead_in, 8)
end

---------------------------------------------------------------------------
-- 9. duplicate keys: last one wins, with a warning
---------------------------------------------------------------------------

do
   local log = Log.new()
   local p = parse("Pocket|depth=5|depth=9", log)
   eq("duplicate/last wins", p.depth, 9)
   eq("duplicate/warned",    log.counts.warn, 1)

   -- a key and its alias also collide
   log = Log.new()
   p = parse("Pocket|depth=5|cut_depth=9", log)
   eq("duplicate/alias last wins", p.depth, 9)
   eq("duplicate/alias warned",    log.counts.warn, 1)
end

---------------------------------------------------------------------------
-- 10. parameters that do not apply to the operation
---------------------------------------------------------------------------

do
   local log = Log.new()
   local p = parse("Pocket|tool=6|side=inside", log)
   eq("applies/value still recorded", p.side, "inside")
   check("applies/warned about no effect",
         log:to_text():find("no effect") ~= nil, log:to_text())
end

---------------------------------------------------------------------------
-- 11. schema integrity
---------------------------------------------------------------------------

do
   check("schema/index built", Schema.by_key ~= nil, "no by_key index")

   -- every parameter named in the specification must resolve
   local required = {
      "operation", "tool", "depth", "start_depth", "cut_direction", "side",
      "allowance", "stepover", "pover", "tabs", "tab_width", "tab_height",
      "lead_in", "lead_out", "ramp", "ramp_angle", "pass_depth", "feed",
      "plunge", "spindle", "rpm", "safe_z", "home_z", "clearance", "peck",
      "strategy", "inside_corner", "last_pass", "roughing", "finishing",
      "flat_depth", "offset", "vector_selection",
   }
   for _, name in ipairs(required) do
      check("schema/knows " .. name, Schema.find(name) ~= nil, "not in schema")
   end

   -- every config default must correspond to a real parameter
   for name in pairs(Config.defaults) do
      check("schema/config default " .. name,
            Schema.find(Coerce.normalise_token(name)) ~= nil,
            "config.defaults." .. name .. " matches no schema parameter")
   end
   for op, tbl in pairs(Config.operations) do
      for name in pairs(tbl) do
         -- config.lua may also carry knobs for custom operations
         local exempt = {}
         if not exempt[name] then
            check("schema/config " .. op .. "." .. name,
                  Schema.find(Coerce.normalise_token(name)) ~= nil,
                  "config.operations." .. op .. "." .. name .. " matches no parameter")
         end
      end
   end

   -- every operation name resolves
   for _, op in ipairs(Schema.operation_names()) do
      check("schema/operation " .. op,
            Schema.find_operation(Coerce.normalise_token(op)) == op, "did not round-trip")
   end
end

---------------------------------------------------------------------------
-- 12. hostile input does not crash the parser
---------------------------------------------------------------------------

do
   local nasty = {
      "Pocket|=8", "Pocket|depth=", "Pocket|=", "Pocket|||||",
      "Pocket|depth=8=9", "Pocket|%|depth=8", "Pocket|depth=8|(", "|",
      "Pocket|depth=-", "Pocket|tool=0", "Pocket|" .. string.rep("x", 5000),
      string.rep("Pocket|depth=1|", 400),
      -- underscore syntax: keys with no value, values with no key,
      -- runs of separators, and a name made entirely of separators
      "Pocket_", "Pocket__", "_Pocket", "Pocket_depth", "Pocket_depth_",
      "Pocket_tool_", "_", "___", "Pocket_start_depth", "Pocket_rate_units",
      "Pocket_8_6_4_2", "Pocket_depth_8_depth", "Pocket_tool_6_" ,
      "Pocket_" .. string.rep("depth_8_", 300),
      "Pocket_" .. string.rep("z_", 2000),
      "VCarve_flat_depth_tool_90",
   }
   for i = 1, #nasty do
      local log = Log.new()
      local ok, err = pcall(parse, nasty[i], log)
      check("hostile/" .. i .. " survives", ok, tostring(err))
   end
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
