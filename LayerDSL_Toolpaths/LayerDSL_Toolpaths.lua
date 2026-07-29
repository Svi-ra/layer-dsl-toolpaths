-- VECTRIC LUA SCRIPT
--[[--------------------------------------------------------------------------
| LayerDSL_Toolpaths.lua - Toolpaths from layer names.
|
| Reads machining parameters embedded in layer names as key=value pairs and
| creates the matching VCarve toolpaths. No fixed layer names: a layer is a
| machining layer because it starts with a known operation, not because it is
| called something in particular.
|
|     Pocket_tool_1_depth_8
|     Profile_side_outside_tool_1_depth_18_tabs_true
|     Drill_tool_4_depth_20_peck_2
|     VCarve_tool_3_flat_3_flat_tool_1
|
| Tools come from the SmartCAM JSON database, not from VCarve's own tool
| database. `tool_1` is an id in tools.json.
|
| Written for VCarve Pro 12.x (verified against 12.5, Lua 5.2.3).
|
| Architecture
| ------------
|     config.lua        global defaults, overridden per layer
|     lib/schema.lua    THE parameter dictionary - the extension point
|     lib/parser.lua    generic key=value parser, returns a plain table
|     lib/factory.lua   dictionary dispatch on params.operation
|     lib/ops/*.lua     one module per operation
|     lib/runner.lua    scan -> plan -> execute
|     lib/sheets.lua    the sheets of a nested job, and how to aim at one
|     lib/db/           the SmartCAM database
|       config.lua        WHERE the database lives - the only such place
|       fileio.lua        disk access
|       json.lua          JSON codec (VCarve ships none)
|       store.lua         one JSON document
|       seed.lua          what a new database contains
|       tool_repository.lua   tools.json: CRUD and lookup
|       database.lua      opens the folder and every document
|
| Adding a parameter is one entry in lib/schema.lua. Adding an operation is
| one module in lib/ops/ plus one name in lib/schema.lua. There is no chain
| of if-statements over layer names anywhere in this gadget.
|
| Licence: same terms as the Vectric gadget samples - use freely, no warranty.
----------------------------------------------------------------------------]]

require "strict"

-- Globals must be declared in the main chunk under strict.lua.
g_version      = "1.0.0"
g_dialog_title = "Layer DSL Toolpaths"
g_gadget_id    = "LayerDSL_Toolpaths"

g_config    = nil
g_modules   = nil
g_database  = nil
g_config_db = nil

---------------------------------------------------------------------------
-- module loading
---------------------------------------------------------------------------

--[[
| VCarve does not put the gadget's own folder on package.path, so `require`
| cannot see sibling files. dofile with the script_path handed to main() is
| the portable way to load them.
]]
function LoadModules(script_path)
   local lib = script_path .. "\\lib\\"

   local function load(name)
      local path = lib .. name .. ".lua"
      local chunk, err = loadfile(path)
      if chunk == nil then
         error(string.format("could not load %s\r\n\r\n%s", path, tostring(err)), 0)
      end
      return chunk()
   end

   local m = {}
   m.log     = load("log")
   m.coerce  = load("coerce")
   m.enums   = load("enums")
   m.schema  = load("schema").init(m.coerce)
   m.parser  = load("parser").init(m.schema, m.coerce)

   -- SmartCAM database: filesystem, JSON, storage location, repositories.
   -- Each layer depends only on the one below it.
   m.fileio          = load("db/fileio")
   m.json            = load("db/json")
   m.db_config       = load("db/config").init(m.fileio)
   m.store           = load("db/store").init(m.fileio, m.json)
   m.seed            = load("db/seed").init(m.json)
   m.tool_repository = load("db/tool_repository").init(m.store, m.seed)
   m.database        = load("db/database").init{
      config          = m.db_config,
      store           = m.store,
      seed            = m.seed,
      tool_repository = m.tool_repository,
   }

   m.sheets  = load("sheets")
   m.tooling = load("tooling").init(m.enums, m.coerce, m.tool_repository)
   m.factory = load("factory").init{ enums = m.enums, tooling = m.tooling }
   m.runner  = load("runner").init(m)

   m.factory.load_standard(lib)
   return m
end

--- Load config.lua, falling back to built-in defaults if it is missing or
--- has a syntax error. A broken config should not brick the gadget.
function LoadConfig(script_path, log)
   local path = script_path .. "\\config.lua"

   local chunk, load_err = loadfile(path)
   if chunk == nil then
      log:warn("config.lua", "could not be loaded (" .. tostring(load_err)
                          .. "); using built-in defaults")
      return { gadget = {}, defaults = {}, operations = {} }
   end

   local ok, result = pcall(chunk)
   if not ok or type(result) ~= "table" then
      log:warn("config.lua", "did not return a table ("
                          .. tostring(result) .. "); using built-in defaults")
      return { gadget = {}, defaults = {}, operations = {} }
   end

   result.gadget     = result.gadget     or {}
   result.defaults   = result.defaults   or {}
   result.operations = result.operations or {}
   return result
end

---------------------------------------------------------------------------
-- confirmation dialog
---------------------------------------------------------------------------

--- The headline above the plan table.
--
-- The plan is a list of LAYERS, and in a nested job each one is machined on
-- every sheet that holds any of its vectors - so the number of rows in the
-- table is not the number of toolpaths that will appear. "Up to", because a
-- layer with nothing on a given sheet is skipped there.
function SummaryLine(counts, sheets)
   local base = string.format("%d toolpath(s) to create, %d layer(s) skipped",
                              counts.build, counts.skip)

   if sheets ~= nil and sheets.count > 1 then
      return string.format(
         "%s - on each of %d sheets, so up to %d toolpaths in all",
         base, sheets.count, counts.build * sheets.count)
   end

   return base
end

--[[
| Show the plan and let the user confirm. Returns:
|    true, options   proceed
|    false, nil      cancelled
|
| Falls back to a plain message box if the HTML dialog cannot be built, so a
| missing or malformed .htm file degrades to "still usable" rather than
| "gadget is broken".
]]
function ConfirmPlan(script_path, plan, config, modules, sheets)
   local gadget = config.gadget

   local options = {
      dry_run              = gadget.dry_run              == true,
      create_2d_previews   = gadget.create_2d_previews   ~= false,
      interactive_warnings = gadget.interactive_warnings ~= false,
      replace_existing     = gadget.replace_existing     == true,
   }

   if gadget.show_dialog == false then
      return true, options
   end

   local counts = { build = 0, skip = 0, existing = 0 }
   for i = 1, #plan do
      if plan[i].skipped then counts.skip = counts.skip + 1
      else counts.build = counts.build + 1 end
      counts.existing = counts.existing + (plan[i].existing or 0)
   end

   local ok, proceed, chosen = pcall(function()
      local html_path = "file:" .. script_path .. "\\LayerDSL_Toolpaths.htm"
      local dialog = HTML_Dialog(false, html_path, 780, 620, g_dialog_title)

      dialog:AddLabelField("GadgetVersion", g_version)
      dialog:AddLabelField("PlanSummary", SummaryLine(counts, sheets))
      dialog:SetInnerHtml("PlanTable", modules.runner.plan_to_html(plan))

      -- Stated up front, whether or not the user acts on it: this is the one
      -- fact that decides whether ticking Replace destroys finished work.
      dialog:AddLabelField("ExistingNote", counts.existing == 0
         and "Nothing in this job currently carries these names."
         or string.format(
            "%d toolpath(s) already in this job carry names this run will use.",
            counts.existing))

      dialog:AddCheckBox("DryRun",          options.dry_run)
      dialog:AddCheckBox("ReplaceExisting", options.replace_existing)
      dialog:AddCheckBox("CreatePreviews",  options.create_2d_previews)
      dialog:AddCheckBox("ShowWarnings",    options.interactive_warnings)

      if not dialog:ShowDialog() then
         return false, nil
      end

      return true, {
         dry_run              = dialog:GetCheckBox("DryRun"),
         replace_existing     = dialog:GetCheckBox("ReplaceExisting"),
         create_2d_previews   = dialog:GetCheckBox("CreatePreviews"),
         interactive_warnings = dialog:GetCheckBox("ShowWarnings"),
      }
   end)

   if not ok then
      --[[
      | The HTML dialog could not be built - most likely a missing or edited
      | .htm file. VCarve's Lua API has no yes/no message box, so there is no
      | way to ask for confirmation here. Creating toolpaths anyway would mean
      | acting without consent, so stop and show the user what WOULD have
      | happened plus how to proceed deliberately.
      ]]
      DisplayMessageBox(string.format(
         "%s v%s\r\n\r\nThe confirmation dialog could not be opened:\r\n%s\r\n\r\n"
         .. "Nothing has been created. This is what would have run:\r\n\r\n%s\r\n\r\n"
         .. "Check that LayerDSL_Toolpaths.htm sits beside the .lua file, or set\r\n"
         .. "    gadget.show_dialog = false\r\n"
         .. "in config.lua to run without confirmation.",
         g_dialog_title, g_version, tostring(proceed),
         modules.runner.plan_to_text(plan)))
      return false, nil
   end

   if not proceed then return false, nil end
   return true, chosen or options
end

---------------------------------------------------------------------------
-- report
---------------------------------------------------------------------------

function ShowReport(log, created, failed, dry_run)
   local headline
   if dry_run then
      headline = "DRY RUN - no toolpaths were created."
   else
      headline = string.format("%d toolpath(s) created, %d failed.", created, failed)
   end

   local detail = log:to_text(log:has_errors() and "warn" or "warn")
   if detail == "" then detail = "No warnings." end

   DisplayMessageBox(string.format(
      "%s v%s\r\n\r\n%s\r\n\r\n%s\r\n\r\n%s",
      g_dialog_title, g_version, headline, log:summary(), detail))
end

---------------------------------------------------------------------------
-- main
---------------------------------------------------------------------------

function main(script_path)

   ------------------------------------------------------------------
   -- Load our own code first, so a packaging mistake reports clearly.
   ------------------------------------------------------------------
   local loaded, modules = pcall(LoadModules, script_path)
   if not loaded then
      DisplayMessageBox("Layer DSL Toolpaths could not start.\r\n\r\n"
                        .. tostring(modules))
      return false
   end
   g_modules = modules

   local log = modules.log.new()

   ------------------------------------------------------------------
   -- Job
   ------------------------------------------------------------------
   local job = VectricJob()
   if not job.Exists then
      DisplayMessageBox("Open or create a job before running this gadget.")
      return false
   end

   g_config = LoadConfig(script_path, log)

   ------------------------------------------------------------------
   -- SmartCAM database
   --
   -- Creates C:\ProgramData\SmartCAM and the five JSON documents on a
   -- first run. Everything below reads tools through this.
   ------------------------------------------------------------------
   g_config_db = modules.db_config.from_settings(g_config.database)

   --[[
   | A database that cannot be WRITTEN is still usable: the gadget reads a
   | tool library and builds toolpaths, neither of which needs to save. Only
   | a file that exists and cannot be understood stops the run.
   ]]
   local database, db_err = modules.database.open(g_config_db, log)
   if database == nil then
      DisplayMessageBox(string.format("%s v%s\r\n\r\n%s",
                                      g_dialog_title, g_version, db_err))
      return false
   end
   g_database = database

   --[[
   | The sheets of a nested job. nil means an unsheeted job or a build with no
   | sheet API, and every path below then behaves exactly as it did before
   | sheets were understood at all.
   ]]
   local sheets = modules.sheets.open(job)
   if sheets ~= nil and sheets.count > 1 then
      log:info("", string.format(
         "job has %d sheets; toolpaths will be created for all of them",
         sheets.count))
   end

   local ctx = modules.tooling.context(job)
   ctx.sheets = sheets
   if ctx.thickness <= 0 then
      DisplayMessageBox("The material block has no thickness.\r\n\r\n"
                        .. "Set the material size before running this gadget.")
      return false
   end

   ------------------------------------------------------------------
   -- Plan
   ------------------------------------------------------------------
   local planned, plan = pcall(modules.runner.plan, job, g_config, ctx, log)
   if not planned then
      DisplayMessageBox("Failed while reading layers.\r\n\r\n" .. tostring(plan))
      return false
   end

   if #plan == 0 then
      DisplayMessageBox(string.format(
         "%s v%s\r\n\r\nNo layers use the DSL naming convention.\r\n\r\n"
         .. "Name a layer after the operation, then add parameters:\r\n\r\n"
         .. "    Pocket|tool=6|depth=8\r\n"
         .. "    Profile|side=outside|tool=6|depth=18|tabs=true\r\n"
         .. "    Drill|tool=5|depth=20|peck=2\r\n"
         .. "    VCarve|tool=90|flat=3\r\n\r\n"
         .. "Recognised operations: %s",
         g_dialog_title, g_version,
         table.concat(modules.factory.names(), ", ")))
      return false
   end

   ------------------------------------------------------------------
   -- Resolve tools against the SmartCAM tool library.
   --
   -- Every referenced tool is checked before anything is created, so the
   -- plan the user confirms is the plan that runs. A missing or unusable
   -- tool skips its layer rather than machining with invented feeds.
   ------------------------------------------------------------------
   ctx.tools = g_database.tools
   modules.runner.annotate_tools(plan, g_database.tools)

   ------------------------------------------------------------------
   -- What is already in the job under these names?
   --
   -- Read-only, and reported rather than acted on. A failure to survey must
   -- not stop a run that is only going to ADD toolpaths, so it degrades to
   -- "unknown" - which the dialog then states as nothing found rather than
   -- claiming a count it does not have.
   ------------------------------------------------------------------
   local surveyed, existing = pcall(modules.runner.survey_existing, plan)
   if not surveyed then
      log:warn("", "could not list the existing toolpaths ("
                   .. tostring(existing) .. ")")
   end

   local unusable = modules.runner.check_tools(plan, g_database.tools, log)

   local buildable = 0
   for i = 1, #plan do
      if not plan[i].skipped then buildable = buildable + 1 end
   end

   if buildable == 0 then
      DisplayMessageBox(string.format(
         "%s v%s\r\n\r\nNothing can be created.\r\n\r\n"
         .. "%d layer(s) reference tools that are missing or unusable in"
         .. "\r\n%s\r\n\r\n%s\r\n\r\n"
         .. "Edit that file to add the tools, or correct the tool "
         .. "references in your layer names.",
         g_dialog_title, g_version, unusable,
         g_config_db:path_for("tools"), log:to_text("warn")))
      return false
   end

   ------------------------------------------------------------------
   -- Confirm
   ------------------------------------------------------------------
   local proceed, options = ConfirmPlan(script_path, plan, g_config, modules, sheets)
   if not proceed then
      return false
   end

   ctx.create_2d_previews   = options.create_2d_previews
   ctx.interactive_warnings = options.interactive_warnings
   ctx.replace_existing     = options.replace_existing == true

   ------------------------------------------------------------------
   -- Execute
   ------------------------------------------------------------------
   local created, failed = 0, 0

   if options.dry_run then
      log:info("", "dry run: " .. #plan .. " layer(s) planned, nothing created")
   else
      local ran, a, b = pcall(modules.runner.execute_sheets,
                              plan, g_config, ctx, log, sheets)
      if not ran then
         DisplayMessageBox("Failed while creating toolpaths.\r\n\r\n" .. tostring(a))
         return false
      end
      created, failed = a, b
      job:Refresh2DView()
   end

   ShowReport(log, created, failed, options.dry_run)

   return failed == 0
end
