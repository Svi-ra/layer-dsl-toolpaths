--[[--------------------------------------------------------------------------
| lib/db/database.lua - Opens the SmartCAM database.
|
| Creates the folder and any missing document, then hands back the
| repositories. One place to call at startup, so the entry point does not
| have to know how many files there are.
|
| Pure Lua - no VCarve API.
----------------------------------------------------------------------------]]

local Database = {}
Database.__index = Database

local Config, Store, Seed, ToolRepository

function Database.init(modules)
   Config         = modules.config
   Store          = modules.store
   Seed           = modules.seed
   ToolRepository = modules.tool_repository
   return Database
end

---------------------------------------------------------------------------
-- opening
---------------------------------------------------------------------------

--- Open the database, creating whatever is missing.
--
-- @param config Config
-- @param log    Log     may be nil
-- @return Database, or nil plus a reason
--[[
| Opening is deliberately forgiving about WRITING and strict about READING.
|
| A folder that cannot be created is not fatal. The gadget's job is to read a
| tool library and build toolpaths; a host that forbids writing - a locked
| down machine, a read-only share, a restricted script sandbox - can still do
| all of that from files that are already there, or from the seeded defaults
| held in memory. Refusing to start in that situation was a bug: it made
| saving a precondition for reading.
|
| What IS fatal is a file that exists but cannot be understood. Guessing at
| the contents of somebody's tool library is never right.
]]
function Database.open(config, log)
   local self = setmetatable({
      config    = config,
      log       = log,
      stores    = {},
      created   = {},
      read_only = {},
   }, Database)

   -- Best effort. The reason is kept for the warning below rather than
   -- being turned into a hard failure.
   local root_ok, root_err = config:ensure_root()

   -- Every document is opened so a fresh install ends up with the whole set,
   -- not just the file this particular run happened to need.
   for _, name in ipairs(Config.document_names()) do
      local store = Store.new(config:path_for(name), Seed.for_document(name))
      local document, load_err = store:load()

      if document == nil then
         return nil, string.format(
            "the SmartCAM database could not be opened.\r\n\r\n%s", load_err)
      end

      self.stores[name] = store
      if store:was_created() then
         self.created[#self.created + 1] = Config.DOCUMENTS[name]
      end
      if store:is_read_only() then
         self.read_only[#self.read_only + 1] = Config.DOCUMENTS[name]
      end
   end

   self.tools = ToolRepository.new(config)
   local tools_ok, tools_err = self.tools:load()
   if not tools_ok then
      return nil, string.format(
         "the tool library could not be read.\r\n\r\n%s", tools_err)
   end

   if log and #self.created > 0 then
      log:info("", string.format("created %s in %s",
         table.concat(self.created, ", "), config:root_path()))
   end

   if #self.read_only > 0 then
      self.warning = string.format(
         "The SmartCAM database could not be written, so %s %s not saved and "
         .. "the built-in PLACEHOLDER tools are being used.\r\n\r\n%s\r\n\r\n"
         .. "Toolpaths can still be created, but check every tool before "
         .. "cutting, and set a writable location in the `database` section "
         .. "of config.lua.",
         table.concat(self.read_only, ", "),
         #self.read_only == 1 and "was" or "were",
         tostring(root_ok and "" or root_err))

      if log then log:warn("", self.warning) end
   end

   return self
end

--- True when nothing can be saved back to disk.
function Database:is_read_only()
   return #self.read_only > 0
end

---------------------------------------------------------------------------
-- access
---------------------------------------------------------------------------

--- The raw document for a logical name, or nil.
function Database:document(name)
   local store = self.stores[name]
   if store == nil then return nil end
   return store:load()
end

--- Files this run had to create. Empty on an established install.
function Database:created_files()
   return self.created
end

function Database:describe()
   return self.config:describe()
end

return Database
