--[[--------------------------------------------------------------------------
| lib/db/store.lua - A JSON document on disk.
|
| The seam between lib/db/fileio.lua (bytes) and the repositories (meaning).
| It knows how to load, seed and save one JSON file, and nothing about what
| the file contains.
|
| A failed load never throws and never silently substitutes an empty
| database: it reports the problem and leaves the file alone, because
| overwriting a tool library the user has spent time on would be worse than
| refusing to run.
|
| Pure Lua - no VCarve API.
----------------------------------------------------------------------------]]

local Store = {}
Store.__index = Store

local FileIO, Json

function Store.init(fileio, json)
   FileIO = fileio
   Json   = json
   return Store
end

---------------------------------------------------------------------------
-- construction
---------------------------------------------------------------------------

--- @param path     string    full path to the JSON file
-- @param defaults function  returns the document to write when none exists
function Store.new(path, defaults)
   return setmetatable({
      path     = path,
      defaults = defaults or function() return {} end,
      document = nil,
      loaded   = false,
      created  = false,
   }, Store)
end

---------------------------------------------------------------------------
-- loading
---------------------------------------------------------------------------

--[[
| No file yet, so seed one.
|
| If it cannot be written the seed is kept IN MEMORY and the store is marked
| read-only rather than failing. Being unable to save is not a reason to be
| unable to run: the gadget's job is to read a tool library and build
| toolpaths, and a host that forbids writing can still do all of that.
]]
function Store:start_fresh()
   local document = self.defaults()
   local ok, err = self:write(document)

   self.document = document
   self.loaded   = true

   if ok then
      self.created = true
   else
      self.read_only   = true
      self.write_error = err
   end

   return document
end

--- Load the document, creating the file from defaults if it is missing.
-- @return document, or nil plus a reason
function Store:load()
   if self.loaded then return self.document end

   if not FileIO.file_exists(self.path) then
      return self:start_fresh()
   end

   local text, read_err = FileIO.read(self.path)
   if text == nil then return nil, read_err end

   -- An empty file is treated as missing rather than as a parse error;
   -- that is what an interrupted write or a manual truncation looks like.
   if text:match("^%s*$") then
      return self:start_fresh()
   end

   local document, decode_err = Json.decode(text)
   if document == nil then
      return nil, string.format("%s is not valid JSON: %s", self.path, decode_err)
   end
   if type(document) ~= "table" then
      return nil, string.format("%s should contain a JSON object", self.path)
   end

   self.document = document
   self.loaded   = true
   return document
end

--- Discard the cached document so the next load re-reads the file.
function Store:reload()
   self.loaded   = false
   self.document = nil
   return self:load()
end

---------------------------------------------------------------------------
-- saving
---------------------------------------------------------------------------

--- Encode and write a document.
-- @return true, or false plus a reason
function Store:write(document)
   local text, encode_err = Json.encode(document)
   if text == nil then
      return false, string.format("could not encode %s: %s", self.path, encode_err)
   end
   return FileIO.write(self.path, text)
end

--- Save the in-memory document back to disk.
function Store:save()
   if self.document == nil then return false, "nothing loaded to save" end
   return self:write(self.document)
end

--- Was the file created by this run rather than already present?
function Store:was_created()
   return self.created == true
end

--- True when the document exists only in memory because it could not be
--- written. Reads work; saves will not stick.
function Store:is_read_only()
   return self.read_only == true
end

--- Why the document could not be written, if it could not.
function Store:why_read_only()
   return self.write_error
end

return Store
