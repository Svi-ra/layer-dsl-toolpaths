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
      sheets = dofile(LIB .. "sheets.lua"),
   }
end

---------------------------------------------------------------------------
-- A job with sheets, shaped like the real one
--
-- Faithful to what tools/Sheet_Diagnostics measured on VCarve 12.5:
--   * sheet ids are opaque and CANNOT be compared - no __eq, no IsEqual - so
--     anything that matches them by identity must fail here too
--   * GetSheetIds returns an ITERATOR, not a table
--   * the layer manager is JOB-WIDE: every layer lists the objects of every
--     sheet, and each object records its own sheet
---------------------------------------------------------------------------

--- @param sheet_names array of names, first one active
-- @param layer_specs array of { name = ..., objects = { "Sheet 1", ... } }
local function sheet_job(sheet_names, layer_specs)
   local ids = {}
   for i, name in ipairs(sheet_names) do
      -- A fresh table per id, and deliberately no __eq: comparing two of these
      -- is always false, exactly as the real binding behaves.
      ids[i] = { __sheet = name }
   end

   local function id_named(name)
      for i, sheet in ipairs(sheet_names) do
         if sheet == name then return ids[i] end
      end
      return nil
   end

   local manager = {
      ActiveSheetId  = ids[1],
      NumberOfSheets = #ids,
      GetSheetName = function(_, id)
         if type(id) == "table" and id.__sheet then return id.__sheet end
         error("No matching overload found: GetSheetName(UUID const&)", 0)
      end,
      GetSheetIds = function()
         local i = 0
         return function()
            i = i + 1
            return ids[i]
         end
      end,
   }

   local layers = {}
   for i, spec in ipairs(layer_specs) do
      local objects = {}
      for j, sheet_name in ipairs(spec.objects or {}) do
         objects[j] = { SheetId = id_named(sheet_name) }
      end

      layers[i] = {
         Name          = spec.name,
         IsSystemLayer = false,
         IsBitmapLayer = false,
         Visible       = spec.visible ~= false,
         GetHeadPosition = function() return #objects > 0 and 1 or nil end,
         GetNext = function(_, pos)
            local object = objects[pos]
            if pos >= #objects then return object, nil end
            return object, pos + 1
         end,
      }
   end

   local job = {
      Exists       = true,
      InMM         = true,
      SheetManager = manager,
      LayerManager = {
         GetHeadPosition = function() return #layers > 0 and 1 or nil end,
         GetNext = function(_, pos)
            local layer = layers[pos]
            if pos >= #layers then return layer, nil end
            return layer, pos + 1
         end,
      },
      Refresh2DView = function() end,
   }

   return job, manager
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
-- 5. existing toolpaths are surveyed and reported, never deleted unasked
--
-- The multi-sheet regression lives here. Toolpaths are named after their
-- layer, and after nesting the same layer names exist on every sheet, so
-- name-matched deletion on a sheet-2 run destroys sheet 1's finished
-- toolpaths. A run must ADD unless the user explicitly asked otherwise.
---------------------------------------------------------------------------

do -- the shipped default deletes nothing
   install()
   Mock.seed_existing_toolpaths{ "Pocket_tool_1_depth_8" }
   local m = modules()

   local job = Mock.job{ { name = "Pocket_tool_1_depth_8" } }
   local log = Log.new()
   local ctx = context(m, job)
   local cfg = config_with{}   -- as shipped, no override

   local plan = m.runner.plan(job, cfg, ctx, log)
   m.runner.survey_existing(plan)
   local created = m.runner.execute(plan, cfg, ctx, log)

   eq("default/created one", created, 1)
   eq("default/deleted nothing", #Mock.deleted, 0)
   check("default/reported what it left alone",
         log:to_text("warn"):find("left alone", 1, true) ~= nil, log:to_text("warn"))
end

do -- survey counts every duplicate, and discloses in both renderings
   install()
   Mock.seed_existing_toolpaths{
      "Pocket_tool_1_depth_8", "Pocket_tool_1_depth_8", "Something else" }
   local m = modules()

   local job = Mock.job{ { name = "Pocket_tool_1_depth_8" } }
   local ctx = context(m, job)
   local plan = m.runner.plan(job, config_with{}, ctx, Log.new())

   local total = m.runner.survey_existing(plan)
   eq("survey/total counts only planned names", total, 2)
   eq("survey/per entry", plan[1].existing, 2)

   check("survey/shown in the dialog table",
         m.runner.plan_to_html(plan):find("2 already named this", 1, true) ~= nil,
         m.runner.plan_to_html(plan))
   check("survey/shown in the text plan",
         m.runner.plan_to_text(plan):find("already carry this name", 1, true) ~= nil,
         m.runner.plan_to_text(plan))
end

do -- an unsurveyed plan still executes; disclosure is optional, not required
   install()
   Mock.seed_existing_toolpaths{ "Pocket_tool_1_depth_8" }
   local m = modules()

   local job = Mock.job{ { name = "Pocket_tool_1_depth_8" } }
   local ctx = context(m, job)
   local cfg = config_with{}

   local created = m.runner.execute(m.runner.plan(job, cfg, ctx, Log.new()),
                                    cfg, ctx, Log.new())
   eq("unsurveyed/created one", created, 1)
   eq("unsurveyed/deleted nothing", #Mock.deleted, 0)
end

do -- the dialog's choice wins over config.lua, in both directions
   install()
   Mock.seed_existing_toolpaths{ "Pocket_tool_1_depth_8", "Pocket_tool_1_depth_8" }
   local m = modules()

   local job = Mock.job{ { name = "Pocket_tool_1_depth_8" } }
   local log = Log.new()
   local ctx = context(m, job)
   ctx.replace_existing = true

   local cfg = config_with{ replace_existing = false }
   local plan = m.runner.plan(job, cfg, ctx, log)
   m.runner.survey_existing(plan)
   local created = m.runner.execute(plan, cfg, ctx, log)

   eq("opt-in/created one", created, 1)
   eq("opt-in/deleted both duplicates", #Mock.deleted, 2)
   check("opt-in/logged the deletion as a warning",
         log:to_text("warn"):find("deleted 2", 1, true) ~= nil, log:to_text("warn"))
end

do -- ...and off at the dialog beats on in config.lua
   install()
   Mock.seed_existing_toolpaths{ "Pocket_tool_1_depth_8" }
   local m = modules()

   local job = Mock.job{ { name = "Pocket_tool_1_depth_8" } }
   local ctx = context(m, job)
   ctx.replace_existing = false

   local cfg = config_with{ replace_existing = true }
   m.runner.execute(m.runner.plan(job, cfg, ctx, Log.new()), cfg, ctx, Log.new())
   eq("opt-out/deleted nothing", #Mock.deleted, 0)
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
-- 9. sheets: reading them, and aiming at one
---------------------------------------------------------------------------

do -- a job without sheets is simply not a sheeted job
   install()
   local m = modules()
   eq("sheets/no manager -> nil", m.sheets.open(Mock.job{}), nil)
end

do
   install()
   local m = modules()
   local job, manager = sheet_job({ "Sheet 1", "Sheet 2" }, {
      { name = "Pocket_tool_1_depth_8", objects = { "Sheet 1", "Sheet 2", "Sheet 2" } },
   })

   local sheets = m.sheets.open(job)
   check("sheets/opened", sheets ~= nil, "nil handle")
   eq("sheets/counted", sheets.count, 2)
   eq("sheets/iterator drained", #sheets:list(), 2)
   eq("sheets/named in order", sheets:list()[2].name, "Sheet 2")
   eq("sheets/active read", sheets:active_name(), "Sheet 1")

   -- Switching is verified by NAME, because ids cannot be compared at all.
   local ok = sheets:activate(sheets:list()[2])
   check("sheets/activate reports success", ok, "activate returned false")
   eq("sheets/activate really switched", sheets:active_name(), "Sheet 2")

   eq("sheets/restore returns to the original", (function()
      sheets:restore()
      return sheets:active_name()
   end)(), "Sheet 1")

   -- Per-sheet geometry, the thing the layer manager will not tell you.
   local layer = job.LayerManager:GetNext(1)
   eq("sheets/objects on sheet 1", sheets:objects_on(layer, "Sheet 1"), 1)
   eq("sheets/objects on sheet 2", sheets:objects_on(layer, "Sheet 2"), 2)
   eq("sheets/objects on a sheet that is not there",
      sheets:objects_on(layer, "Sheet 9"), 0)

   -- A switch VCarve does not honour must be reported, never assumed.
   manager.GetSheetName = function() return "Sheet 1" end
   local moved, why = sheets:activate(sheets:list()[2])
   check("sheets/unhonoured switch is caught", not moved, "activate claimed success")
   check("sheets/and says why", (why or ""):find("Sheet 2", 1, true) ~= nil,
         tostring(why))
end

---------------------------------------------------------------------------
-- 10. one run, every sheet
---------------------------------------------------------------------------

do -- a toolpath per sheet, from one plan
   install()
   local m = modules()
   local job = sheet_job({ "Sheet 1", "Sheet 2" }, {
      { name = "Pocket_tool_1_depth_8", objects = { "Sheet 1", "Sheet 2" } },
   })

   local sheets = m.sheets.open(job)
   local log, ctx = Log.new(), context(m, job)
   local cfg = config_with{}

   local plan = m.runner.plan(job, cfg, ctx, log)
   local created, failed = m.runner.execute_sheets(plan, cfg, ctx, log, sheets)

   eq("all-sheets/created one per sheet", created, 2)
   eq("all-sheets/none failed", failed, 0)
   eq("all-sheets/two calls to VCarve", #Mock.created, 2)
   eq("all-sheets/active sheet restored", sheets:active_name(), "Sheet 1")
   check("all-sheets/report names the sheets",
         log:to_text("info"):find('sheet "Sheet 2"', 1, true) ~= nil,
         log:to_text("info"))
end

do -- a layer with nothing on a sheet is skipped THERE, not everywhere
   install()
   local m = modules()
   local job = sheet_job({ "Sheet 1", "Sheet 2" }, {
      { name = "Pocket_tool_1_depth_8", objects = { "Sheet 1" } },
   })

   local sheets = m.sheets.open(job)
   local log, ctx = Log.new(), context(m, job)
   local cfg = config_with{}

   local created = m.runner.execute_sheets(
      m.runner.plan(job, cfg, ctx, log), cfg, ctx, log, sheets)

   eq("sparse/built only where there is geometry", created, 1)
   check("sparse/said so", log:to_text("info"):find("nothing on sheet", 1, true) ~= nil,
         log:to_text("info"))
end

do -- one unreachable sheet does not cost the others
   install()
   local m = modules()
   local job, manager = sheet_job({ "Sheet 1", "Sheet 2" }, {
      { name = "Pocket_tool_1_depth_8", objects = { "Sheet 1", "Sheet 2" } },
   })

   local sheets = m.sheets.open(job)
   -- Sheet 2 refuses to become active.
   local names = manager.GetSheetName
   manager.GetSheetName = function(self, id)
      local name = names(self, id)
      return name == "Sheet 2" and "Sheet 1" or name
   end

   local log, ctx = Log.new(), context(m, job)
   local cfg = config_with{}
   local created, failed = m.runner.execute_sheets(
      m.runner.plan(job, cfg, ctx, log), cfg, ctx, log, sheets)

   eq("unreachable/still built the reachable sheet", created, 1)
   eq("unreachable/counted the failure", failed, 1)
   check("unreachable/named the skipped sheet",
         log:to_text("error"):find("skipped entirely", 1, true) ~= nil,
         log:to_text("error"))
end

do -- an unsheeted job takes the old path unchanged
   install()
   local m = modules()
   local job = Mock.job{ { name = "Pocket_tool_1_depth_8" } }
   local log, ctx = Log.new(), context(m, job)
   local cfg = config_with{}

   local created = m.runner.execute_sheets(
      m.runner.plan(job, cfg, ctx, log), cfg, ctx, log, nil)
   eq("unsheeted/built once", created, 1)
end

---------------------------------------------------------------------------
-- 11. replacement is scoped to the sheet being machined
--
-- The original bug: running on sheet 2 deleted sheet 1's finished toolpaths,
-- because the toolpath list is job-wide and the names are identical.
---------------------------------------------------------------------------

do
   install()
   local m = modules()
   local job = sheet_job({ "Sheet 1", "Sheet 2" }, {
      { name = "Pocket_tool_1_depth_8", objects = { "Sheet 1", "Sheet 2" } },
   })

   local sheets = m.sheets.open(job)
   local list = sheets:list()

   -- Two toolpaths, one per sheet, sharing a name - which VCarve allows.
   Mock.seed_existing_toolpaths{ "Pocket_tool_1_depth_8", "Pocket_tool_1_depth_8" }

   -- Give each one a sheet, the way a real toolpath carries SheetId.
   local manager = ToolpathManager()
   local pos, index = manager:GetHeadPosition(), 0
   while pos ~= nil do
      local toolpath
      toolpath, pos = manager:GetNext(pos)
      index = index + 1
      toolpath.SheetId = list[index] and list[index].id or list[1].id
   end

   local log, ctx = Log.new(), context(m, job)
   ctx.sheets           = sheets
   ctx.sheet_name       = "Sheet 2"
   ctx.replace_existing = true

   local cfg  = config_with{}
   local plan = m.runner.plan(job, cfg, ctx, log)
   m.runner.execute(plan, cfg, ctx, log)

   eq("scoped-replace/removed only this sheet's", #Mock.deleted, 1)
   check("scoped-replace/left the other sheet alone",
         log:to_text("info"):find("belonging to other sheets", 1, true) ~= nil,
         log:to_text("info"))
end

do -- a toolpath that will not say which sheet it is on is never deleted
   install()
   local m = modules()
   local job = sheet_job({ "Sheet 1", "Sheet 2" }, {
      { name = "Pocket_tool_1_depth_8", objects = { "Sheet 1" } },
   })

   local sheets = m.sheets.open(job)
   Mock.seed_existing_toolpaths{ "Pocket_tool_1_depth_8" }   -- no SheetId set

   local log, ctx = Log.new(), context(m, job)
   ctx.sheets           = sheets
   ctx.sheet_name       = "Sheet 1"
   ctx.replace_existing = true

   local cfg = config_with{}
   m.runner.execute(m.runner.plan(job, cfg, ctx, log), cfg, ctx, log)

   eq("unattributed/not deleted", #Mock.deleted, 0)
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
