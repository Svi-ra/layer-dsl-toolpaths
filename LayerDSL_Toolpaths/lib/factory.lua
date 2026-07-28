--[[--------------------------------------------------------------------------
| lib/factory.lua - The Toolpath Factory.
|
| Consumes the plain table the parser produced and dispatches on ONE key:
| params.operation. There is no chain of `if layer_name == ...` anywhere in
| this gadget; the dispatch is a dictionary lookup, and registering a new
| operation is a single call to Factory.register.
|
| The factory does not know that layer names exist. It could just as well be
| driven from a CSV, a dialog or a unit test.
----------------------------------------------------------------------------]]

local Factory = {}

Factory.operations = {}

local deps = {}

--- Wire in the modules the operation builders need.
function Factory.init(dependencies)
   deps = dependencies or {}
   return Factory
end

---------------------------------------------------------------------------
-- registration
---------------------------------------------------------------------------

--- Register one operation module.
-- @param module table with `name` (string) and `build` (function)
function Factory.register(module)
   if type(module) ~= "table" then
      error("factory: operation module must be a table")
   end
   if type(module.name) ~= "string" or module.name == "" then
      error("factory: operation module has no name")
   end
   if type(module.build) ~= "function" then
      error(string.format("factory: operation %q has no build function", module.name))
   end
   if Factory.operations[module.name] then
      error(string.format("factory: operation %q is already registered", module.name))
   end
   Factory.operations[module.name] = module
   return Factory
end

--- Load and register the standard operation set.
-- @param lib_path directory holding lib/, with a trailing separator
function Factory.load_standard(lib_path)
   for _, file in ipairs{ "pocket", "profile", "drill", "vcarve", "moulding" } do
      Factory.register(dofile(lib_path .. "ops/" .. file .. ".lua"))
   end
   return Factory
end

function Factory.supports(operation)
   return Factory.operations[operation] ~= nil
end

function Factory.names()
   local out = {}
   for name in pairs(Factory.operations) do out[#out + 1] = name end
   table.sort(out)
   return out
end

---------------------------------------------------------------------------
-- build
---------------------------------------------------------------------------

--- Create one toolpath from one parameter table.
--
-- @param params table  from the parser; must carry `operation`
-- @param ctx    table  job context plus gadget flags
-- @return toolpath_id | nil, error_string, warnings
function Factory.build(params, ctx)
   local module = Factory.operations[params.operation]
   if module == nil then
      return nil, string.format("no factory registered for operation %q",
                                tostring(params.operation)), {}
   end

   -- A failure inside the VCarve API must not take the whole run down: one
   -- bad layer should be reported and the remaining layers still processed.
   local ok, id, err, warnings = pcall(module.build, params, ctx, deps)

   if not ok then
      -- `id` holds the error object when pcall fails.
      return nil, "internal error: " .. tostring(id), {}
   end

   return id, err, warnings or {}
end

return Factory
