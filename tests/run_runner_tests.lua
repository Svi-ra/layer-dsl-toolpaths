--[[--------------------------------------------------------------------------
| tests/run_runner_tests.lua - Tests for lib/runner.lua.
|
| Exercises the scan -> plan -> execute pipeline against a mock job: which
| layers are picked up, which are skipped and why, toolpath name templating,
| and replacing toolpaths on a re-run.
|
| Run:  lua tests/run_runner_tests.lua      (from the repository root)
----------------------------------------------------------------------------]]

local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
local LIB  = ROOT .. "/LayerDSL_Toolpaths/lib/"

local API  = dofile(ROOT .. "/tests/api_names.lua")
local Mock = dofile(ROOT .. "/tests/mock_vectric.lua")

local Log    = dofile(LIB .. "log.lua")
local Coerce = dofile(LIB .. "coerce.lua")
local Schema = dofile(LIB .. "schema.lua").init(Coerce)
local Parser = dofile(LIB .. "parser.lua").init(Schema, Coerce)
local BaseConfig = dofile(ROOT .. "/LayerDSL_Toolpaths/config.lua")

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

--- Shallow copy of the shipped config, with gadget overrides applied.
local function config_with(gadget_overrides)
   local cfg = {
      defaults   = BaseConfig.defaults,
      operations = BaseConfig.operations,
      gadget     = {},
   }
   for k, v in pairs(BaseConfig.gadget) do cfg.gadget[k] = v end
   for k, v in pairs(gadget_overrides or {}) do cfg.gadget[k] = v end
   return cfg
end

local Helper = dofile(ROOT .. "/tests/db_helper.lua")

-- Tools 1, 2, 3, 4 and 9 come from tests/db_helper.lua; 9 has zero feeds.
local shared_repo, shared_root = Helper.repository("runner")

--- Install the VCarve mock. Tools come from the JSON repository, not here.
local function install(opts)
   Mock.install(API, opts or {})
end

--- Fresh module set bound to the current mock globals.
local function modules()
   local Enums   = dofile(LIB .. "enums.lua")
   local DbMods  = Helper.modules()
   local Tooling = dofile(LIB .. "tooling.lua")
                      .init(Enums, Coerce, DbMods.tool_repository)
   local Factory = dofile(LIB .. "factory.lua").init{ enums = Enums, tooling = Tooling }
   Factory.load_standard(LIB)
   local Runner = dofile(LIB .. "runner.lua").init{
      parser = Parser, factory = Factory, tooling = Tooling, log = Log,
      tool_repository = DbMods.tool_repository,
   }
   return {
      tooling = Tooling, factory = Factory, runner = Runner, db = DbMods,
   }
end

--- Job context wired to the tool repository, as main() builds it.
local function context(m, job, repo)
   local ctx = m.tooling.context(job)
   ctx.create_2d_previews   = true
   ctx.interactive_warnings = false
   ctx.tools = repo or shared_repo
   return ctx
end

---------------------------------------------------------------------------
-- 1. planning picks out exactly the DSL layers
---------------------------------------------------------------------------

do
   install()
   local m = modules()

   local job = Mock.job{
      { name = "Pocket_tool_1_depth_8" },
      { name = "Layer 1" },                              -- not a DSL layer
      { name = "Profile_side_outside_tool_1_depth_18" },
      { name = "Dimensions" },                           -- not a DSL layer
      { name = "Drill_tool_1_depth_20_peck_2" },
      { name = "VCarve_tool_3" },
   }

   local log  = Log.new()
   local ctx  = context(m, job)
   local plan = m.runner.plan(job, config_with{}, ctx, log)

   eq("plan/four DSL layers found", #plan, 4)
   eq("plan/first is pocket",  plan[1].params.operation, "Pocket")
   eq("plan/second is profile",plan[2].params.operation, "Profile")
   eq("plan/third is drill",   plan[3].params.operation, "Drill")
   eq("plan/fourth is vcarve", plan[4].params.operation, "VCarve")
   eq("plan/nothing skipped",  plan[1].skipped, nil)
   eq("plan/no errors", log.counts.error, 0)
end

---------------------------------------------------------------------------
-- 2. layers that cannot be machined are skipped with a reason
---------------------------------------------------------------------------

do
   install()
   local m = modules()

   local job = Mock.job{
      { name = "Pocket_tool_1_depth_8", objects = 0 },        -- empty
      { name = "Profile_tool_1_depth_8", visible = false },   -- hidden
      { name = "Drill_tool_1_depth_8" },                      -- fine
      { name = "Pocket_tool_1_depth_8", system = true },      -- system layer
      { name = "VCarve_tool_3", bitmap = true },             -- bitmap layer
   }

   local log  = Log.new()
   local ctx  = context(m, job)
   local plan = m.runner.plan(job, config_with{}, ctx, log)

   eq("skip/system and bitmap layers never enter the plan", #plan, 3)
   eq("skip/empty layer skipped",  plan[1].skipped, true)
   eq("skip/empty reason",         plan[1].reason,  "layer is empty")
   eq("skip/hidden layer skipped", plan[2].skipped, true)
   eq("skip/hidden reason",        plan[2].reason,  "layer is hidden")
   eq("skip/good layer kept",      plan[3].skipped, nil)
   check("skip/warned about both", log.counts.warn >= 2, log:to_text())

   -- and skipped entries never reach the factory
   local created, errored = m.runner.execute(plan, config_with{}, ctx, log)
   eq("skip/only the usable layer built", created, 1)
   eq("skip/no failures", errored, 0)
   eq("skip/one API call", #Mock.created, 1)
end

---------------------------------------------------------------------------
-- 3. empty_layer_is_error promotes the warning
---------------------------------------------------------------------------

do
   install()
   local m = modules()
   local job = Mock.job{ { name = "Pocket_tool_1_depth_8", objects = 0 } }

   local log = Log.new()
   local ctx = context(m, job)
   m.runner.plan(job, config_with{ empty_layer_is_error = true }, ctx, log)

   eq("empty-strict/raised as error", log.counts.error, 1)
end

---------------------------------------------------------------------------
-- 3b. optional layer-name length check
---------------------------------------------------------------------------

do
   install()
   local m = modules()
   -- 34 characters, over the 31-char cap of pre-AC1015 DXF
   local long_name = "Pocket_tool_1_depth_18_stepover_45"
   local job = Mock.job{ { name = long_name } }
   local ctx = context(m, job)

   local log = Log.new()
   m.runner.plan(job, config_with{ max_layer_name_length = 0 }, ctx, log)
   eq("length/check disabled by default", log.counts.warn, 0)

   log = Log.new()
   local plan = m.runner.plan(job, config_with{ max_layer_name_length = 31 },
                              ctx, log)
   eq("length/warns when over the limit", log.counts.warn, 1)
   check("length/warning quotes the length",
         log:to_text():find("34 characters") ~= nil, log:to_text())
   eq("length/still planned, not skipped", plan[1].skipped, nil)

   -- the DXF-safe rewrite of the same layer fits
   install()
   m = modules()
   local short = Mock.job{ { name = "Pocket_tool_1_depth_18_stepover_45" } }
   log = Log.new()
   local ctx2 = context(m, short)
   local plan2 = m.runner.plan(short, config_with{ max_layer_name_length = 40 },
                               ctx2, log)
   eq("length/underscore form parses", plan2[1].params.stepover, 45)
   eq("length/no warning under limit", log.counts.warn, 0)
end

---------------------------------------------------------------------------
-- 3c. tool numbers: collection, mapping and skipping
---------------------------------------------------------------------------

do -- which tool numbers a plan needs
   install()
   local m = modules()
   local job = Mock.job{
      { name = "Pocket_tool_1_depth_8" },
      { name = "Profile_tool_2_depth_8" },
      { name = "Pocket_tool_1_depth_4" },                 -- same tool again
      { name = "VCarve_tool_3_flat_2_flat_tool_1" },
      { name = "Pocket_tool_2_depth_9_roughing_true_roughing_tool_1" },
   }
   local ctx  = context(m, job)
   local plan = m.runner.plan(job, config_with{}, ctx, Log.new())

   local needed = m.runner.required_tools(plan)
   eq("tools/distinct count", #needed, 3)
   eq("tools/sorted 1", needed[1], 1)
   eq("tools/sorted 2", needed[2], 2)
   eq("tools/sorted 3", needed[3], 3)
end

do -- roughing_tool only counts when roughing is actually on
   install()
   local m = modules()
   local job = Mock.job{
      { name = "Pocket_tool_1_depth_8_roughing_tool_2" },  -- roughing is off
   }
   local ctx  = context(m, job)
   local plan = m.runner.plan(job, config_with{}, ctx, Log.new())
   local needed = m.runner.required_tools(plan)
   eq("tools/ignores idle roughing_tool", #needed, 1)
   eq("tools/only the pocket tool", needed[1], 1)
end

do -- a tool missing from tools.json skips its layer; the others still run
   install()
   local m = modules()
   local job = Mock.job{
      { name = "Pocket_tool_1_depth_8" },
      { name = "Profile_tool_77_depth_8" },   -- no such tool in tools.json
      { name = "Drill_tool_1_depth_8" },
   }
   local log  = Log.new()
   local ctx  = context(m, job)
   local plan = m.runner.plan(job, config_with{}, ctx, log)

   local skipped = m.runner.check_tools(plan, ctx.tools, log)
   eq("missing/one layer skipped", skipped, 1)
   eq("missing/marked skipped", plan[2].skipped, true)
   check("missing/reason names the tool",
         (plan[2].reason or ""):find("77", 1, true) ~= nil, plan[2].reason)
   eq("missing/logged as an error", log.counts.error, 1)

   local created, errored = m.runner.execute(plan, config_with{}, ctx, log)
   eq("missing/others still built", created, 2)
   eq("missing/no failures", errored, 0)
   eq("missing/two API calls", #Mock.created, 2)
end

do -- a tool that exists but has no feeds is refused up front, not at build
   install()
   local m = modules()
   local job = Mock.job{
      { name = "Pocket_tool_9_depth_8" },   -- tool 9 has zero feeds
      { name = "Pocket_tool_1_depth_8" },
   }
   local log  = Log.new()
   local ctx  = context(m, job)
   local plan = m.runner.plan(job, config_with{}, ctx, log)

   local skipped = m.runner.check_tools(plan, ctx.tools, log)
   eq("zerofeed/one layer skipped", skipped, 1)
   eq("zerofeed/marked skipped", plan[1].skipped, true)
   check("zerofeed/reason names the field",
         (plan[1].reason or ""):find("feed_rate") ~= nil, plan[1].reason)

   local created = m.runner.execute(plan, config_with{}, ctx, log)
   eq("zerofeed/only the good layer built", created, 1)
end

do -- the plan is annotated with the resolved tool, for the dialog
   install()
   local m = modules()
   local job = Mock.job{ { name = "Pocket_tool_2_depth_8" } }
   local ctx  = context(m, job)
   local plan = m.runner.plan(job, config_with{}, ctx, Log.new())

   m.runner.annotate_tools(plan, ctx.tools)
   check("annotate/label present", plan[1].tool_label ~= nil, "no tool_label")
   check("annotate/label names the tool",
         (plan[1].tool_label or ""):find("End Mill 12mm", 1, true) ~= nil,
         tostring(plan[1].tool_label))
end

---------------------------------------------------------------------------
-- 4. toolpath name templating
---------------------------------------------------------------------------

do
   install()
   local m = modules()
   local job = Mock.job{ { name = "Pocket_tool_1_depth_8" } }
   local ctx = context(m, job)

   local plan = m.runner.plan(job, config_with{ toolpath_name = "{layer}" },
                              ctx, Log.new())
   eq("name/default is the layer name",
      plan[1].params.toolpath_name, "Pocket_tool_1_depth_8")

   plan = m.runner.plan(job,
      config_with{ toolpath_name = "{index}. {operation} T{tool} @ {depth}mm" },
      ctx, Log.new())
   eq("name/template expanded",
      plan[1].params.toolpath_name, "1. Pocket T1 @ 8mm")

   plan = m.runner.plan(job, config_with{ toolpath_name = "{nonsense}" },
                        ctx, Log.new())
   eq("name/unknown placeholder left alone", plan[1].params.toolpath_name, "{nonsense}")

   plan = m.runner.plan(job, config_with{ toolpath_name = "   " }, ctx, Log.new())
   eq("name/blank falls back to layer name",
      plan[1].params.toolpath_name, "Pocket_tool_1_depth_8")
end

---------------------------------------------------------------------------
-- 5. re-running replaces toolpaths instead of duplicating them
---------------------------------------------------------------------------

do
   install()
   Mock.seed_existing_toolpaths{ "Pocket_tool_1_depth_8", "Pocket_tool_1_depth_8" }
   local m = modules()

   local job = Mock.job{ { name = "Pocket_tool_1_depth_8" } }
   local log = Log.new()
   local ctx = context(m, job)

   local plan = m.runner.plan(job, config_with{ replace_existing = true }, ctx, log)
   local created = m.runner.execute(plan, config_with{ replace_existing = true },
                                    ctx, log)

   eq("replace/created one", created, 1)
   eq("replace/deleted both duplicates", #Mock.deleted, 2)
   check("replace/logged the replacement",
         log:to_text("info"):find("replaced 2") ~= nil, log:to_text("info"))
end

do -- replace_existing = false leaves them alone
   install()
   Mock.seed_existing_toolpaths{ "Pocket_tool_1_depth_8" }
   local m = modules()

   local job = Mock.job{ { name = "Pocket_tool_1_depth_8" } }
   local log = Log.new()
   local ctx = context(m, job)
   local cfg = config_with{ replace_existing = false }

   m.runner.execute(m.runner.plan(job, cfg, ctx, log), cfg, ctx, log)
   eq("no-replace/nothing deleted", #Mock.deleted, 0)
end

---------------------------------------------------------------------------
-- 6. one failing layer does not stop the rest
---------------------------------------------------------------------------

do
   install()
   local m = modules()

   -- 200 degrees is rejected by the VCarve op before it calls the API
   local job = Mock.job{
      { name = "Pocket_tool_1_depth_8" },
      { name = "VCarve_tool_1_flat_3_flat_tool_1" },
      { name = "Drill_tool_1_depth_8" },
   }

   local log = Log.new()
   local ctx = context(m, job)

   local cfg = config_with{}
   local created, errored = m.runner.execute(m.runner.plan(job, cfg, ctx, log),
                                             cfg, ctx, log)

   eq("resilience/two succeeded", created, 2)
   eq("resilience/one failed",    errored, 1)
   eq("resilience/error logged",  log.counts.error, 1)
   check("resilience/error names the layer",
         log:to_text():find("VCarve_tool_1_flat_3", 1, true) ~= nil, log:to_text())
end

---------------------------------------------------------------------------
-- 7. report rendering
---------------------------------------------------------------------------

do
   install()
   local m = modules()
   local job = Mock.job{
      { name = "Pocket_tool_1_depth_8_bogus_key_1" },
      { name = "Profile_tool_1_depth_8", objects = 0 },
   }
   local ctx  = context(m, job)
   local plan = m.runner.plan(job, config_with{}, ctx, Log.new())

   local html = m.runner.plan_to_html(plan)
   check("report/html has a table", html:find("<table") ~= nil, html)
   check("report/html lists the layer",
         html:find("Pocket_tool_1_depth_8", 1, true) ~= nil, html)
   check("report/html shows the tool number", html:find("T1") ~= nil, html)
   check("report/html flags unknown key", html:find("bogus_key") ~= nil, html)
   check("report/html marks the skip", html:find("is%-skipped") ~= nil, html)

   local text = m.runner.plan_to_text(plan)
   check("report/text lists operations", text:find("Pocket") ~= nil, text)
   check("report/text marks the skip",   text:find("%[skip%]") ~= nil, text)

   local empty = m.runner.plan_to_html({})
   check("report/empty plan explained", empty:find("naming convention") ~= nil, empty)
end

---------------------------------------------------------------------------
-- 8. HTML escaping - layer names are user input
---------------------------------------------------------------------------

do
   install()
   local m = modules()
   local job = Mock.job{ { name = "Pocket_tool_1_depth_8_note_<script>x</script>" } }
   local ctx  = context(m, job)
   local plan = m.runner.plan(job, config_with{}, ctx, Log.new())
   local html = m.runner.plan_to_html(plan)

   check("escape/no raw script tag", html:find("<script>") == nil, html)
   check("escape/entities used",     html:find("&lt;script&gt;") ~= nil, html)
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
