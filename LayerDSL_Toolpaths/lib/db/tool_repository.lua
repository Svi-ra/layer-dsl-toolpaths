--[[--------------------------------------------------------------------------
| lib/db/tool_repository.lua - The tool library.
|
| Owns tools.json: loading, saving, add / update / delete, and lookup by id
| or by name. It deals in plain Lua tables and knows nothing about VCarve -
| turning a tool record into a VCarve Tool object is lib/tooling.lua's job.
|
| That separation is what lets the whole library be tested without VCarve,
| and what would let the same repository back a different CAM front end.
|
| Pure Lua - no VCarve API.
----------------------------------------------------------------------------]]

local ToolRepository = {}
ToolRepository.__index = ToolRepository

local Store, Seed

function ToolRepository.init(store, seed)
   Store = store
   Seed  = seed
   return ToolRepository
end

---------------------------------------------------------------------------
-- construction
---------------------------------------------------------------------------

--- @param config Config  supplies the path; never build one here
function ToolRepository.new(config)
   return setmetatable({
      config = config,
      store  = Store.new(config:path_for("tools"), Seed.tools),
      error  = nil,
   }, ToolRepository)
end

---------------------------------------------------------------------------
-- loading
---------------------------------------------------------------------------

--- Load tools.json, creating it from the seed library if missing.
-- @return true, or false plus a reason
function ToolRepository:load()
   local document, err = self.store:load()
   if document == nil then
      self.error = err
      return false, err
   end

   if document.tools == nil then
      -- A hand-edited file that lost its list is repaired in memory rather
      -- than rejected, so one bad edit does not block a whole run.
      document.tools = {}
   end
   if type(document.tools) ~= "table" then
      self.error = string.format("%s: \"tools\" should be a list",
                                 self.config:path_for("tools"))
      return false, self.error
   end

   self.document = document
   self.error    = nil
   return true
end

--- Load if it has not happened yet.
function ToolRepository:ensure_loaded()
   if self.document == nil then return self:load() end
   return true
end

function ToolRepository:was_created()
   return self.store:was_created()
end

---------------------------------------------------------------------------
-- reading
---------------------------------------------------------------------------

--- Every tool record, in file order.
function ToolRepository:all()
   if not self:ensure_loaded() then return {} end
   return self.document.tools
end

function ToolRepository:count()
   return #self:all()
end

--- Find a tool by its numeric id.
-- @return record, or nil
function ToolRepository:find_by_id(id)
   if id == nil then return nil end
   local wanted = tonumber(id)
   if wanted == nil then return nil end

   for _, tool in ipairs(self:all()) do
      if tonumber(tool.id) == wanted then return tool end
   end
   return nil
end

--- Find a tool by name, ignoring case and surrounding spaces.
-- @return record, or nil
function ToolRepository:find_by_name(name)
   if name == nil then return nil end
   local wanted = tostring(name):lower():gsub("^%s+", ""):gsub("%s+$", "")
   if wanted == "" then return nil end

   for _, tool in ipairs(self:all()) do
      if type(tool.name) == "string" then
         local candidate = tool.name:lower():gsub("^%s+", ""):gsub("%s+$", "")
         if candidate == wanted then return tool end
      end
   end
   return nil
end

--- Find by id or by name, whichever the reference looks like.
--
-- A layer name can say `tool_1` or `tool_EndMill6`, so the reference is
-- resolved by shape: numbers are ids, anything else is a name.
-- @return record, or nil plus a reason
function ToolRepository:find(reference)
   if reference == nil then
      return nil, "no tool given"
   end

   if not self:ensure_loaded() then
      return nil, self.error or "the tool library could not be loaded"
   end

   local found
   if tonumber(reference) ~= nil then
      found = self:find_by_id(reference)
   else
      found = self:find_by_name(reference)
   end

   if found == nil then
      return nil, string.format(
         "no tool %s in %s", ToolRepository.describe_reference(reference),
         self.config:path_for("tools"))
   end
   return found
end

function ToolRepository.describe_reference(reference)
   if tonumber(reference) ~= nil then
      return string.format("with id %s", tostring(reference))
   end
   return string.format("named %q", tostring(reference))
end

--- Ids currently in use, sorted.
function ToolRepository:ids()
   local out = {}
   for _, tool in ipairs(self:all()) do
      local id = tonumber(tool.id)
      if id ~= nil then out[#out + 1] = id end
   end
   table.sort(out)
   return out
end

--- The lowest id not yet used.
function ToolRepository:next_id()
   local taken = {}
   for _, id in ipairs(self:ids()) do taken[id] = true end
   local candidate = 1
   while taken[candidate] do candidate = candidate + 1 end
   return candidate
end

---------------------------------------------------------------------------
-- writing
---------------------------------------------------------------------------

--- Add a tool. An absent id is allocated; a duplicate id is refused.
-- @return record, or nil plus a reason
function ToolRepository:add(tool)
   if type(tool) ~= "table" then return nil, "a tool must be a table" end
   if not self:ensure_loaded() then
      return nil, self.error or "the tool library could not be loaded"
   end

   local record = {}
   for key, value in pairs(tool) do record[key] = value end

   if record.id == nil then
      record.id = self:next_id()
   elseif self:find_by_id(record.id) ~= nil then
      return nil, string.format("a tool with id %s already exists",
                                tostring(record.id))
   end

   if record.name == nil or tostring(record.name) == "" then
      record.name = string.format("Tool %s", tostring(record.id))
   end
   if record.tool_number == nil then
      record.tool_number = record.id
   end

   table.insert(self.document.tools, record)

   local ok, err = self:save()
   if not ok then return nil, err end
   return record
end

--- Merge changes into an existing tool.
-- @return record, or nil plus a reason
function ToolRepository:update(id, changes)
   if type(changes) ~= "table" then return nil, "changes must be a table" end

   local record, err = self:find(id)
   if record == nil then return nil, err end

   for key, value in pairs(changes) do
      if key ~= "id" then record[key] = value end
   end

   local ok, save_err = self:save()
   if not ok then return nil, save_err end
   return record
end

--- Remove a tool.
-- @return true, or false plus a reason
function ToolRepository:delete(id)
   if not self:ensure_loaded() then
      return false, self.error or "the tool library could not be loaded"
   end

   local wanted = tonumber(id)
   for index, tool in ipairs(self.document.tools) do
      if wanted ~= nil and tonumber(tool.id) == wanted then
         table.remove(self.document.tools, index)
         return self:save()
      end
   end

   return false, string.format("no tool %s to delete",
                               ToolRepository.describe_reference(id))
end

--- Write the library back to disk.
function ToolRepository:save()
   if self.document == nil then return false, "nothing loaded to save" end
   return self.store:save()
end

---------------------------------------------------------------------------
-- validation
---------------------------------------------------------------------------

local VALID_TYPES = {
   end_mill = true, ball_nose = true, vbit = true, engraving = true,
   through_drill = true, radiused_end_mill = true, radiused_engraving = true,
}

--- Check a record well enough to refuse a dangerous toolpath.
--
-- Feeds are checked because a tool with none would plunge and cut at zero.
-- @return array of problem strings; empty means usable
function ToolRepository.validate(tool)
   local problems = {}

   local function require_positive(field, label)
      local value = tonumber(tool[field])
      if value == nil or value <= 0 then
         problems[#problems + 1] = string.format(
            "%s is missing or not positive (%s)", label, tostring(tool[field]))
      end
   end

   if tool.type ~= nil and not VALID_TYPES[tostring(tool.type)] then
      problems[#problems + 1] = string.format(
         "unknown tool type %q", tostring(tool.type))
   end

   require_positive("diameter",      "diameter")
   require_positive("feed_rate",     "feed_rate")
   require_positive("plunge_rate",   "plunge_rate")
   require_positive("spindle_speed", "spindle_speed")

   if tostring(tool.type) == "vbit" then
      local angle = tonumber(tool.included_angle)
      if angle == nil or angle <= 0 or angle >= 180 then
         problems[#problems + 1] = string.format(
            "included_angle must be between 0 and 180 for a V-bit (%s)",
            tostring(tool.included_angle))
      end
   end

   return problems
end

--- A short label for the plan and the report.
function ToolRepository.describe(tool)
   if tool == nil then return "(no tool)" end
   local diameter = tonumber(tool.diameter)
   local angle    = tonumber(tool.included_angle)

   local parts = { tostring(tool.name or ("Tool " .. tostring(tool.id))) }
   if diameter then parts[#parts + 1] = string.format("%.4g mm", diameter) end
   if angle    then parts[#parts + 1] = string.format("%.4g deg", angle) end
   if tool.feed_rate and tool.spindle_speed then
      parts[#parts + 1] = string.format("%g feed, %g rpm",
                                        tool.feed_rate, tool.spindle_speed)
   end
   return table.concat(parts, ", ")
end

return ToolRepository
