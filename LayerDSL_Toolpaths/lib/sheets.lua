--[[--------------------------------------------------------------------------
| lib/sheets.lua - The sheets of a nested job, and how to aim at one.
|
| A nested job holds several sheets. Everything the gadget reads is JOB-WIDE -
| the layer manager returns objects from every sheet at once, and so does the
| toolpath list - but toolpath CREATION follows the active sheet, and each
| object and toolpath records which sheet it belongs to. That combination is
| what makes one run over every sheet possible, and it is what this module
| wraps.
|
| Measured against VCarve Pro 12.5, not assumed (tools/Sheet_Diagnostics):
|
|   job.SheetManager        CadSheetManager, or absent in an unsheeted job
|   GetSheetIds()           returns a Lua ITERATOR over sheet ids
|   GetSheetName(id)        names one
|   ActiveSheetId           readable AND writable; assigning it aims creation
|   CadObject.SheetId       which sheet a vector sits on
|   Toolpath.SheetId        which sheet a toolpath belongs to
|
| Sheets are keyed by NAME, never by id
| -------------------------------------
| The id behind ActiveSheetId is an opaque bound type with no __eq, no IsEqual
| and no AsString: two reads of the SAME sheet's id do not compare equal by any
| means the binding offers. Ids can be passed back to VCarve but never compared,
| so every identity test in this module goes through GetSheetName. (The luaUUID
| returned by toolpath creation is a different type that does have AsString and
| IsEqual - easy to confuse, and not usable here.)
|
| The module never raises: a job with no sheet support returns nil from open()
| and the caller carries on exactly as it did before sheets existed.
----------------------------------------------------------------------------]]

local Sheets = {}

-- No sane nested job has more; a cap stops a misbehaving iterator hanging
-- VCarve on what is supposed to be a read.
local MAX_SHEETS = 256

local Handle = {}
Handle.__index = Handle

---------------------------------------------------------------------------
-- reading, defensively
---------------------------------------------------------------------------

--- Read a binding that may be a property or a method. Returns nil on failure.
--
-- Both forms occur in this API and reading the wrong one throws, so neither
-- can be assumed. Fetching a sheet list must never be the thing that kills a
-- run that would otherwise work.
local function read(holder, name)
   local as_property_ok, value = pcall(function() return holder[name] end)
   if as_property_ok and value ~= nil and type(value) ~= "function" then
      return value
   end

   local as_method_ok, result = pcall(function() return holder[name](holder) end)
   if as_method_ok and result ~= nil then return result end

   if as_property_ok then return value end
   return nil
end

--- The name VCarve gives this sheet id, or nil if it is not a sheet id.
local function name_of(manager, id)
   if id == nil then return nil end
   local ok, name = pcall(function() return manager:GetSheetName(id) end)
   if ok and type(name) == "string" and name ~= "" then return name end
   return nil
end

--- Every sheet in the job, in the order VCarve lists them.
--
-- GetSheetIds hands back an iterator function; a table is accepted too, so a
-- future build changing its mind about the shape does not break this.
local function collect(manager)
   local raw = nil
   if not pcall(function() raw = manager:GetSheetIds() end) then return {} end

   local ids = {}

   if type(raw) == "table" then
      pcall(function()
         for _, id in ipairs(raw) do ids[#ids + 1] = id end
      end)
   elseif type(raw) == "function" then
      pcall(function()
         for id in raw do
            ids[#ids + 1] = id
            if #ids >= MAX_SHEETS then break end
         end
      end)
   end

   local sheets = {}
   for index, id in ipairs(ids) do
      local name = name_of(manager, id)
      if name ~= nil then
         sheets[#sheets + 1] = { id = id, name = name, index = index }
      end
   end

   return sheets
end

---------------------------------------------------------------------------
-- opening
---------------------------------------------------------------------------

--- Wrap the job's sheets, or return nil when there is nothing to wrap.
--
-- nil means "carry on as a single-sheet job": either this build has no sheet
-- API, or the job genuinely has one sheet. Callers do not branch on which.
--
-- @return handle | nil
function Sheets.open(job)
   local manager = read(job, "SheetManager")
   if manager == nil then return nil end

   local list = collect(manager)
   if #list == 0 then return nil end

   local handle = setmetatable({
      manager  = manager,
      sheets   = list,
      count    = #list,
      original = read(manager, "ActiveSheetId"),
   }, Handle)

   handle.original_name = name_of(manager, handle.original)
   return handle
end

---------------------------------------------------------------------------
-- the handle
---------------------------------------------------------------------------

function Handle:list()
   return self.sheets
end

--- The name of the sheet VCarve is currently pointed at.
function Handle:active_name()
   return name_of(self.manager, read(self.manager, "ActiveSheetId"))
end

--- Point VCarve at a sheet, and prove it went there.
--
-- The write is verified by reading the active sheet's NAME back, because the
-- ids cannot be compared. Nothing downstream should create a toolpath on the
-- strength of an unverified switch: that is precisely how a toolpath would end
-- up on the wrong sheet.
--
-- @return true | false, reason
function Handle:activate(sheet)
   if sheet == nil then return false, "no sheet given" end

   -- Already there: nothing to prove, and no reason to disturb the UI.
   if self:active_name() == sheet.name then return true end

   local ok, err = pcall(function() self.manager.ActiveSheetId = sheet.id end)
   if not ok then
      return false, string.format("VCarve refused the switch (%s)", tostring(err))
   end

   local now = self:active_name()
   if now ~= sheet.name then
      return false, string.format(
         "asked for %q but the active sheet is %s",
         sheet.name, now and string.format("%q", now) or "unreadable")
   end

   return true
end

--- Put the active sheet back where the user left it.
function Handle:restore()
   if self.original == nil then return false, "nothing to restore to" end

   local ok, err = pcall(function() self.manager.ActiveSheetId = self.original end)
   if not ok then
      return false, string.format("could not restore the active sheet (%s)",
                                  tostring(err))
   end
   return true
end

--- How many objects on this layer sit on the named sheet?
--
-- The layer manager is job-wide, so a layer that looks populated may hold
-- nothing at all for the sheet being machined. Asking VCarve to build a
-- toolpath from no vectors is a failure with a confusing message, so the
-- caller uses this to skip that layer for that sheet instead.
function Handle:objects_on(layer, sheet_name)
   if layer == nil or sheet_name == nil then return 0 end

   local count = 0
   pcall(function()
      local pos = layer:GetHeadPosition()
      while pos ~= nil do
         local object
         object, pos = layer:GetNext(pos)
         if object ~= nil then
            local ok, id = pcall(function() return object.SheetId end)
            if ok and name_of(self.manager, id) == sheet_name then
               count = count + 1
            end
         end
      end
   end)

   return count
end

--- Which sheet does this toolpath belong to? nil when it will not say.
--
-- This is what makes replacing a toolpath safe in a nested job: the toolpath
-- list spans every sheet, so a name match alone says nothing about whether a
-- toolpath belongs to the sheet being worked on.
function Handle:sheet_of(toolpath)
   if toolpath == nil then return nil end

   local ok, id = pcall(function() return toolpath.SheetId end)
   if not ok then return nil end

   return name_of(self.manager, id)
end

return Sheets
