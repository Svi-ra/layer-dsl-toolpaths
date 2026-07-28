--[[--------------------------------------------------------------------------
| lib/parser.lua - The layer-name DSL parser.
|
| Grammar
| -------
|     layer      := operation ( SEP field )*
|     field      := key '=' value
|     operation  := IDENT                     -- or a field: operation=Pocket
|     SEP        := '|'
|
| Everything after the operation is an unordered set of key=value pairs, so
| these are all the same toolpath:
|
|     Pocket|tool=6|depth=8
|     Pocket|depth=8|tool=6
|     operation=Pocket|depth=8|tool=6
|
| Rules
| -----
|   * Parameter ORDER is irrelevant.
|   * Keys and enum values are case-insensitive; '-' and ' ' fold to '_'.
|   * An UNKNOWN key produces a warning and is skipped. It never aborts.
|   * A known key with a BAD value produces a warning and falls back to the
|     configured default. It never aborts.
|   * A layer whose first field is not a known operation is not a DSL layer:
|     parse() returns nil and logs nothing. Non-machining layers are ignored.
|
| Pure Lua - no VCarve API dependency. This is what makes the DSL testable
| outside VCarve; see tests/run_tests.lua.
----------------------------------------------------------------------------]]

local Parser = {}

--[[
| Default syntax. Overridable from config.lua under `syntax`.
|
| DXF layer names cannot contain  < > / \ " : ; ? * | , =  so BOTH of the
| original delimiters are illegal in an exported DXF. The underscore forms
| below exist for that case; see Parser.SYNTAX_NOTE.
]]
Parser.SEPARATORS = { "|", "_" }   -- field separators, in preference order
Parser.ASSIGNS    = { "=", "_" }   -- key/value separators, in preference order

Parser.MAX_FIELD_CHARS = 4096   -- guards against pathological layer names

-- Kept for callers that referenced the old single-character constants.
Parser.SEPARATOR = "|"
Parser.ASSIGN    = "="

local Schema, Coerce

--- Wire in the schema and coercion modules.
function Parser.init(schema, coerce)
   Schema = schema
   Coerce = coerce
   return Parser
end

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function trim(s)
   return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split on the separator without using patterns, so a separator that is a
--- magic character still works if someone changes Parser.SEPARATOR.
local function split(text, sep)
   local out, start = {}, 1
   local sep_len = #sep
   while true do
      local i = string.find(text, sep, start, true)   -- plain find
      if i == nil then
         out[#out + 1] = string.sub(text, start)
         break
      end
      out[#out + 1] = string.sub(text, start, i - 1)
      start = i + sep_len
   end
   return out
end

---------------------------------------------------------------------------
-- defaults chain
---------------------------------------------------------------------------

--- Merge the default layers for one operation, lowest precedence first:
---   schema `default` fields  <  config.defaults  <  config.operations[op]
--
-- Config values are run through the same coercion as layer values. That
-- matters: config.lua may naturally say `last_pass = true`, but the factory
-- needs the canonical token "last". Coercing here means config.lua can use
-- whichever spelling reads best, and a typo in config.lua is reported
-- instead of silently reaching VCarve as a wrong value.
local function build_defaults(config, operation, log)
   local merged = {}

   for i = 1, #Schema.PARAMS do
      local spec = Schema.PARAMS[i]
      if spec.default ~= nil then merged[spec.key] = spec.default end
   end

   local function overlay(source, origin)
      if type(source) ~= "table" then return end
      for name, value in pairs(source) do
         -- Config files may legitimately use aliases too.
         local spec = Schema.find(Coerce.normalise_token(name))

         if spec == nil then
            -- Not a DSL parameter. Users put their own knobs in config.lua
            -- for custom operations to read, so pass them through untouched.
            merged[name] = value
         else
            local coerced, err = Coerce[spec.type](tostring(value), spec)
            if coerced == nil then
               if log then
                  log:warn(origin, string.format(
                     "%s = %s is not valid (%s); ignoring it",
                     name, tostring(value), err))
               end
            else
               merged[spec.key] = coerced
            end
         end
      end
   end

   overlay(config and config.defaults, "config.defaults")
   if config and config.operations then
      overlay(config.operations[operation], "config.operations." .. operation)
   end

   return merged
end

--[[
| Coercing the config on every layer would repeat the same warnings once per
| layer, so results are memoised per (config table, operation). Weak keys let
| a config table be collected normally.
]]
local defaults_cache = setmetatable({}, { __mode = "k" })

local function cached_defaults(config, operation, log)
   local key = config or defaults_cache
   local per_config = defaults_cache[key]
   if per_config == nil then
      per_config = {}
      defaults_cache[key] = per_config
   end
   if per_config[operation] == nil then
      per_config[operation] = build_defaults(config, operation, log)
   end
   return per_config[operation]
end

--- Shallow copy, so callers can mutate their own parameter table freely.
local function copy(source)
   local out = {}
   for key, value in pairs(source) do out[key] = value end
   return out
end

Parser.build_defaults = build_defaults

--- Drop memoised config defaults. Call if config.lua is reloaded in-process.
function Parser.reset()
   defaults_cache = setmetatable({}, { __mode = "k" })
end

---------------------------------------------------------------------------
-- syntax selection
---------------------------------------------------------------------------

local function contains(text, needle)
   return string.find(text, needle, 1, true) ~= nil
end

local function list_or(config, field, fallback)
   local configured = config and config.syntax and config.syntax[field]
   if type(configured) == "table" and #configured > 0 then return configured end
   return fallback
end

--- Decide how to read one layer name.
--
-- The first configured separator that actually occurs wins, so one job can
-- mix conventions: pipes on hand-made layers, underscores on DXF imports.
--
-- @return separator, assign, token_mode
local function choose_syntax(name, config)
   local separators = list_or(config, "separators", Parser.SEPARATORS)
   local assigns    = list_or(config, "assigns",    Parser.ASSIGNS)

   local separator
   for i = 1, #separators do
      if contains(name, separators[i]) then separator = separators[i]; break end
   end
   separator = separator or separators[1]

   -- Assignment characters still usable once the separator is chosen. Each
   -- field picks from this list independently, so "Pocket|tool=6|depth_8"
   -- works: one field assigns with '=', the next with '_'.
   local usable, separator_is_assign = {}, false
   for i = 1, #assigns do
      if assigns[i] == separator then
         separator_is_assign = true
      else
         usable[#usable + 1] = assigns[i]
      end
   end

   -- Token mode: the separator doubles as the assignment character, so key
   -- and value boundaries have to come from the schema, not punctuation.
   -- Only when no other assignment character actually appears in the name.
   local token_mode = false
   if separator_is_assign then
      token_mode = true
      for i = 1, #usable do
         if contains(name, usable[i]) then token_mode = false; break end
      end
   end

   if #usable == 0 then usable = { "=" } end

   return separator, usable, token_mode
end

---------------------------------------------------------------------------
-- schema-driven token matching (underscore syntax)
---------------------------------------------------------------------------

local function join(tokens, from, to)
   return table.concat(tokens, "_", from, to)
end

--- Longest schema key starting at token `from`. Returns spec, span or nil.
local function match_key(tokens, from)
   local last = math.min(from + Schema.max_key_tokens - 1, #tokens)
   for to = last, from, -1 do
      local spec = Schema.find(Coerce.normalise_token(join(tokens, from, to)))
      if spec ~= nil then return spec, to - from + 1 end
   end
   return nil
end

--- Longest operation name starting at token `from`.
local function match_operation(tokens, from)
   local last = math.min(from + Schema.max_operation_tokens - 1, #tokens)
   for to = last, from, -1 do
      local op = Schema.find_operation(Coerce.normalise_token(join(tokens, from, to)))
      if op ~= nil then return op, to - from + 1 end
   end
   return nil
end

--- How many tokens make up the value for `spec`, starting at token `from`.
--
-- Type-directed, which is what keeps the underscore form unambiguous:
--   enum    the longest run that is a VALID value, so strategy_raster stops
--           at "raster" instead of swallowing a following raster_angle key
--   string  greedy up to the next recognised key
--   other   exactly one token; numbers and booleans never contain '_'
--
-- Always at least one token, so a value that happens to share a name with a
-- key (strategy=offset, and `offset` is also a Profile key) still works.
local function value_span(tokens, from, spec)
   if from > #tokens then return 0 end

   if spec.type == "enum" then
      local last = math.min(from + Schema.max_enum_tokens - 1, #tokens)
      for to = last, from, -1 do
         if Coerce.enum(join(tokens, from, to), spec) ~= nil then
            return to - from + 1
         end
      end
      return 1   -- invalid; let the coercer report it
   end

   if spec.type == "string" then
      local to = from
      while to < #tokens and match_key(tokens, to + 1) == nil do to = to + 1 end
      return to - from + 1
   end

   return 1
end

---------------------------------------------------------------------------
-- field splitting
---------------------------------------------------------------------------

--- Split "key=value" into its two halves.
--
-- Each field chooses its own assignment character from `assigns`, in
-- preference order, so one layer name may mix them. With an unambiguous
-- character this is a plain find; with '_' it is the longest-key match
-- again, so "start_depth_2" splits into start_depth and 2.
--
-- Returns key, value, or nil if the field carries no assignment at all.
local function split_field(field, assigns)
   for i = 1, #assigns do
      local assign = assigns[i]
      local at = string.find(field, assign, 1, true)

      if at ~= nil then
         if assign ~= "_" then
            return trim(string.sub(field, 1, at - 1)),
                   trim(string.sub(field, at + #assign))
         end

         local tokens = split(field, "_")
         local spec, span = match_key(tokens, 1)
         if spec == nil then
            -- Unknown key: split at the first underscore so the caller can
            -- still name it in the warning.
            return trim(string.sub(field, 1, at - 1)),
                   trim(string.sub(field, at + 1))
         end
         return join(tokens, 1, span), join(tokens, span + 1, #tokens)
      end
   end
   return nil
end

---------------------------------------------------------------------------
-- parse
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- stage 1: turn a layer name into { operation, fields = {{key, value}, ...} }
---------------------------------------------------------------------------

--- Does this field carry any of the usable assignment characters?
local function has_assign(field, assigns)
   for i = 1, #assigns do
      if contains(field, assigns[i]) then return true end
   end
   return false
end

--- Delimited syntax: Pocket|tool=6|depth=8
local function scan_delimited(raw, separator, assigns, layer_name, log)
   local fields = split(raw, separator)

   -- The operation is either the first bare field, or an explicit
   -- operation=... field anywhere, so order really is irrelevant.
   local operation, operation_index

   local first = trim(fields[1] or "")
   if first ~= "" and not has_assign(first, assigns) then
      operation = Schema.find_operation(Coerce.normalise_token(first))
      if operation == nil then return nil end
      operation_index = 1
   end

   local pairs_out, malformed = {}, {}

   for i = 1, #fields do
      local field = trim(fields[i])

      if field == "" then
         -- Tolerate "Pocket||depth=8" and a trailing separator.
      elseif i == operation_index and not has_assign(field, assigns) then
         -- The bare operation token; already consumed.
      else
         local key, value = split_field(field, assigns)

         if key == nil or trim(key) == "" then
            malformed[#malformed + 1] = field
         elseif Coerce.normalise_token(key) == "operation" then
            local named = Schema.find_operation(Coerce.normalise_token(value))
            if named ~= nil then
               operation = named
            elseif operation == nil then
               return nil
            elseif log then
               log:warn(layer_name, string.format(
                  "unknown operation %q; using %q from the first field",
                  value, operation))
            end
         else
            pairs_out[#pairs_out + 1] = { key, value }
         end
      end
   end

   if operation == nil then return nil end
   return operation, pairs_out, malformed
end

--- Underscore syntax: Pocket_tool_6_depth_8
--
-- No punctuation distinguishes keys from values, so the schema does it:
-- longest known key at each position, then a type-directed value span.
local function scan_tokens(raw, separator, layer_name, log)
   local tokens = {}
   for _, piece in ipairs(split(raw, separator)) do
      piece = trim(piece)
      if piece ~= "" then tokens[#tokens + 1] = piece end
   end
   if #tokens == 0 then return nil end

   local operation, span = match_operation(tokens, 1)
   if operation == nil then return nil end

   local pairs_out, unmatched = {}, {}
   local i = span + 1

   while i <= #tokens do
      local spec, key_span = match_key(tokens, i)

      if spec == nil then
         -- Collect the unrecognised run so it can be reported as one item.
         local from = i
         repeat i = i + 1
         until i > #tokens or match_key(tokens, i) ~= nil
         unmatched[#unmatched + 1] = join(tokens, from, i - 1)
      else
         local key = join(tokens, i, i + key_span - 1)
         i = i + key_span

         if Coerce.normalise_token(key) == "operation" then
            local named = Schema.find_operation(Coerce.normalise_token(tokens[i] or ""))
            if named ~= nil then operation = named end
            i = i + 1
         else
            local vspan = value_span(tokens, i, spec)
            if vspan == 0 then
               unmatched[#unmatched + 1] = key   -- key with nothing after it
            else
               pairs_out[#pairs_out + 1] = { key, join(tokens, i, i + vspan - 1) }
               i = i + vspan
            end
         end
      end
   end

   --[[
   | Guard against hijacking ordinary layers. "Pocket_2" and "Drill_holes"
   | begin with an operation name but carry no parameters, so they are far
   | more likely to be someone's drawing layer than a machining instruction.
   | A bare "Pocket" is still accepted - that one is unambiguous.
   ]]
   if #pairs_out == 0 and #unmatched > 0 then return nil end

   return operation, pairs_out, {}, unmatched
end

---------------------------------------------------------------------------
-- parse
---------------------------------------------------------------------------

--- Parse a layer name into a machining parameter table.
--
-- @param layer_name string  the raw layer name
-- @param config     table   the config.lua table (may be nil)
-- @param log        Log     diagnostics sink (may be nil)
-- @return table of parameters, or nil if this is not a DSL layer
function Parser.parse(layer_name, config, log)
   if type(layer_name) ~= "string" then return nil end

   local raw = trim(layer_name)
   if raw == "" then return nil end
   if #raw > Parser.MAX_FIELD_CHARS then
      if log then log:warn(layer_name, "layer name is too long to parse; skipped") end
      return nil
   end

   ------------------------------------------------------------------
   -- Stage 1: extract the operation and the raw key/value pairs.
   ------------------------------------------------------------------
   local separator, assigns, token_mode = choose_syntax(raw, config)

   local operation, fields, malformed, unmatched
   if token_mode then
      operation, fields, malformed, unmatched =
         scan_tokens(raw, separator, layer_name, log)
   else
      operation, fields, malformed =
         scan_delimited(raw, separator, assigns, layer_name, log)
   end

   -- Not a machining layer. Stay silent: ordinary drawing layers,
   -- "Layer 1", "Milling_path", template layers and so on all land here.
   if operation == nil then return nil end

   ------------------------------------------------------------------
   -- Stage 2: seed from config, then apply the layer's own parameters.
   ------------------------------------------------------------------
   local inherited = cached_defaults(config, operation, log)

   local params = copy(inherited)
   params.operation  = operation
   params.layer_name = layer_name

   local seen, unknown = {}, {}

   for _, field in ipairs(malformed or {}) do
      if log then
         log:warn(layer_name, string.format(
            "ignoring malformed field %q (expected key%svalue)", field, assigns[1]))
      end
   end

   -- REQUIREMENT: unknown parameters warn but never stop.
   for _, name in ipairs(unmatched or {}) do
      unknown[#unknown + 1] = name
      if log then
         log:warn(layer_name, string.format("unknown parameter %q ignored", name))
      end
   end

   for _, pair in ipairs(fields) do
      local key, value = pair[1], pair[2]
      local spec = Schema.find(Coerce.normalise_token(key))

      if spec == nil then
         unknown[#unknown + 1] = key
         if log then
            log:warn(layer_name, string.format("unknown parameter %q ignored", key))
         end
      else
         if seen[spec.key] and log then
            log:warn(layer_name, string.format(
               "parameter %q given more than once; using the last value", spec.key))
         end

         local coerced, err = Coerce[spec.type](value, spec)

         if coerced == nil then
            if log then
               log:warn(layer_name, string.format(
                  "%s: %s - keeping default %s",
                  spec.key, err, tostring(params[spec.key])))
            end
         else
            if spec.applies_to and not spec.applies_to[operation] and log then
               log:warn(layer_name, string.format(
                  "%s has no effect on a %s toolpath", spec.key, operation))
            end
            params[spec.key] = coerced
            seen[spec.key]   = true
         end
      end
   end

   ------------------------------------------------------------------
   -- Pass 3: resolve `switch` sentinels so the factory sees only numbers.
   ------------------------------------------------------------------
   for key, value in pairs(params) do
      if value == Coerce.ON then
         local fallback = inherited[key]
         if type(fallback) == "number" and fallback > 0 then
            params[key] = fallback
         else
            params[key] = true   -- "on, length not specified"; ops pick a sane value
            if log then
               log:info(layer_name, string.format(
                  "%s enabled without a value; the operation will choose one", key))
            end
         end
      end
   end

   --[[
   | Which keys the LAYER NAME set, as opposed to inheriting from config.lua.
   |
   | This matters once tools come from the VCarve library. The library tool
   | is authoritative for feeds, speeds, stepdown and stepover, so a config
   | default must NOT overwrite it - but an explicit `feed_200` on the layer
   | must. `explicit` is how the operations tell those two cases apart.
   ]]
   params.explicit           = seen
   params.unknown_parameters = unknown
   return params
end

---------------------------------------------------------------------------
-- introspection, used by the report and the tests
---------------------------------------------------------------------------

--- Render a parameter table as a stable, sorted, single-line string.
function Parser.describe(params)
   if params == nil then return "<not a DSL layer>" end
   local keys = {}
   for key, value in pairs(params) do
      local t = type(value)
      if key ~= "layer_name" and key ~= "unknown_parameters"
         and (t == "number" or t == "string" or t == "boolean") then
         keys[#keys + 1] = key
      end
   end
   table.sort(keys)
   local buf = {}
   for i = 1, #keys do
      buf[#buf + 1] = keys[i] .. "=" .. tostring(params[keys[i]])
   end
   return table.concat(buf, " ")
end

return Parser
