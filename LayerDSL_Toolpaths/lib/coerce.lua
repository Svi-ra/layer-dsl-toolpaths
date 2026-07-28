--[[--------------------------------------------------------------------------
| lib/coerce.lua - Value coercion primitives used by the parser.
|
| Each coercer takes the raw string from the layer name plus the parameter
| spec, and returns:
|
|     value, nil        on success
|     nil,   "reason"   on failure
|
| Adding a new value TYPE means adding one function to the `Coerce` table and
| naming it from a schema entry's `type` field. No other file changes.
|
| Pure Lua - no VCarve API dependency.
----------------------------------------------------------------------------]]

local Coerce = {}

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function trim(s)
   return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Strip surrounding quotes, if balanced.
local function unquote(s)
   local q = s:match('^"(.*)"$') or s:match("^'(.*)'$")
   return q or s
end

-- Unit suffixes we accept and silently drop. The DSL is unit-less: every
-- length is in job units. Accepting "8mm" avoids a confusing hard failure
-- when someone writes what they mean.
local UNIT_SUFFIX = '%s*[%%]?%s*$'

local function strip_units(s)
   s = s:gsub('"%s*$', "")                                  -- 8"
   s = s:gsub("%s*[Mm][Mm]%s*$", "")                         -- 8mm
   s = s:gsub("%s*[Ii][Nn][Cc][Hh][Ee][Ss]?%s*$", "")        -- 8inch / 8inches
   s = s:gsub("%s*[Ii][Nn]%s*$", "")                         -- 8in
   s = s:gsub("%s*[Dd][Ee][Gg][A-Za-z]*%s*$", "")            -- 90deg
   s = s:gsub("%s*[Rr][Pp][Mm]%s*$", "")                     -- 18000rpm
   s = s:gsub(UNIT_SUFFIX, "")                               -- 45%
   return trim(s)
end

--- Normalise a token for case-insensitive matching: lowercase, and treat
--- '-' and ' ' as '_' so "top-left", "top left" and "top_left" all agree.
function Coerce.normalise_token(s)
   s = trim(tostring(s)):lower()
   s = s:gsub("[%s%-]+", "_")
   return s
end

local normalise_token = Coerce.normalise_token

---------------------------------------------------------------------------
-- range checking, shared by number and integer
---------------------------------------------------------------------------

local function check_range(n, spec)
   if spec.min ~= nil and n < spec.min then
      return nil, string.format("must be >= %s (got %s)", tostring(spec.min), tostring(n))
   end
   if spec.max ~= nil and n > spec.max then
      return nil, string.format("must be <= %s (got %s)", tostring(spec.max), tostring(n))
   end
   return n
end

---------------------------------------------------------------------------
-- coercers
---------------------------------------------------------------------------

function Coerce.number(raw, spec)
   local cleaned = strip_units(unquote(trim(raw)))
   if cleaned == "" then return nil, "expected a number, got an empty value" end
   local n = tonumber(cleaned)
   if n == nil then
      return nil, string.format("expected a number, got %q", raw)
   end
   return check_range(n, spec)
end

function Coerce.integer(raw, spec)
   local n, err = Coerce.number(raw, spec)
   if n == nil then return nil, err end
   if n % 1 ~= 0 then
      return nil, string.format("expected a whole number, got %s", tostring(n))
   end
   -- Keep it a Lua number; VCarve's bindings accept numbers for int fields.
   return n
end

local TRUE_WORDS  = { ["true"]=true,  yes=true, y=true, on=true,  ["1"]=true,  enable=true,  enabled=true }
local FALSE_WORDS = { ["false"]=true, no=true,  n=true, off=true, ["0"]=true,  disable=true, disabled=true }

function Coerce.boolean(raw, spec)
   local t = normalise_token(unquote(raw))
   if TRUE_WORDS[t]  then return true  end
   if FALSE_WORDS[t] then return false end
   return nil, string.format("expected true/false, got %q", raw)
end

function Coerce.string(raw, spec)
   local s = unquote(trim(raw))
   if spec.allow_empty ~= true and s == "" then
      return nil, "expected a value, got an empty string"
   end
   return s
end

--- Enumerated token.
--
-- spec.values maps accepted spelling -> canonical token, e.g.
--     { outside = "outside", out = "outside", ext = "outside" }
--
-- The parser stores the CANONICAL TOKEN (a string), never a VCarve
-- constant. Mapping token -> VCarve enum happens in lib/ops/*.lua, which
-- keeps the parser testable outside VCarve.
function Coerce.enum(raw, spec)
   local t = normalise_token(unquote(raw))
   local canonical = spec.values and spec.values[t]
   if canonical == nil then
      -- Build a stable, de-duplicated list of the canonical choices.
      local seen, choices = {}, {}
      for _, v in pairs(spec.values or {}) do
         if not seen[v] then seen[v] = true; choices[#choices + 1] = v end
      end
      table.sort(choices)
      return nil, string.format("expected one of [%s], got %q",
                                table.concat(choices, ", "), raw)
   end
   return canonical
end

--- A value that may be either a boolean or a number.
--
-- Used by parameters like `lead_in` and `peck`, where a layer name may say
-- either `lead_in=8` (use 8) or `lead_in=true` (use whatever length config
-- already supplies).
--
--   false   -> 0          (feature off; 0 is the universal "off" for these)
--   true    -> ON         (sentinel; parser resolves it against the inherited
--                          config default, see Coerce.ON)
--   number  -> the number
--
-- The sentinel never escapes the parser: Parser.parse() replaces it with a
-- number before returning, so the factory only ever sees numbers.
Coerce.ON = setmetatable({}, { __tostring = function() return "<on>" end })

--- A reference to a tool in tools.json: an id, or a name.
--
-- Numbers become numbers so `tool_1` and `tool_01` mean the same tool;
-- anything else stays a string for lookup by name. The repository resolves
-- whichever it gets.
--
-- In the underscore layer-name syntax a value is a single token, so a name
-- with spaces or underscores cannot be written there - use the id.
function Coerce.tool_ref(raw, spec)
   local text = unquote(trim(raw))
   if text == "" then return nil, "expected a tool id or name" end

   local number = tonumber(text)
   if number ~= nil then
      if number % 1 ~= 0 then
         return nil, string.format("a tool id must be a whole number (got %s)", text)
      end
      if number < 1 then
         return nil, string.format("a tool id must be 1 or more (got %s)", text)
      end
      return number
   end

   return text
end

function Coerce.switch(raw, spec)
   local t = normalise_token(unquote(raw))
   if TRUE_WORDS[t]  then return Coerce.ON end
   if FALSE_WORDS[t] then return 0 end
   return Coerce.number(raw, spec)
end

return Coerce
