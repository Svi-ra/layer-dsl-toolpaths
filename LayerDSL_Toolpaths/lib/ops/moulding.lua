--[[--------------------------------------------------------------------------
| lib/ops/moulding.lua - Experimental VCarve Moulding / Swept Profile.
|
| Vectric exposes MouldingToolpath and ToolpathManager:AddToolpath in the API
| name table, but no CreateMouldingToolpath helper like the other operations.
| This module therefore tries the direct object path and reports cleanly if
| this VCarve build refuses it.
----------------------------------------------------------------------------]]

return {
   name = "Moulding",
   summary = "Experimental swept-profile / Moulding toolpath.",

   build = function(params, ctx, deps)
      local Enums, Tooling = deps.enums, deps.tooling
      local warnings = {}
      local function note(x)
         if type(x) == "table" then
            for _, w in ipairs(x) do warnings[#warnings + 1] = w end
         elseif x then
            warnings[#warnings + 1] = x
         end
      end

      local tool, w, err, record = Tooling.from_library{
         reference = params.tool,
         role      = "moulding tool",
         params    = params,
         ctx       = ctx,
      }
      note(w)
      if tool == nil then return nil, err, warnings end
      note(Tooling.check_tool_type(record, params.tool, "ball_nose", "Moulding"))

      if params.profile_layer == nil or params.profile_layer == "" then
         return nil, "Moulding needs profile_layer=<layer name>", warnings
      end

      if rawget(_G, "MouldingToolpath") == nil then
         return nil, "VCarve Lua does not expose MouldingToolpath", warnings
      end

      local rail_selector = Enums.build_selector(
         params.layer_name, params.vector_selection or "open", tool.ToolDia)
      local profile_selector = Enums.build_selector(
         params.profile_layer, "all", tool.ToolDia)
      local pos = Tooling.position(params, ctx)

      local created = false
      local last_err = nil
      local variants = {
         function() return MouldingToolpath(params.toolpath_name, tool, rail_selector, profile_selector, pos) end,
         function() return MouldingToolpath(params.toolpath_name, tool, rail_selector, profile_selector) end,
         function() return MouldingToolpath() end,
      }

      local moulding = nil
      for _, make in ipairs(variants) do
         local ok, value = pcall(make)
         if ok and value ~= nil then
            moulding = value
            created = true
            break
         end
         last_err = value
      end

      if not created then
         return nil, "VCarve refused to construct MouldingToolpath: "
            .. tostring(last_err), warnings
      end

      pcall(function() moulding.Name = params.toolpath_name end)
      pcall(function() moulding.Tool = tool end)
      pcall(function() moulding.Position = pos end)
      pcall(function() moulding:SetString("EditingDialog", "uiExtrudedToolpathForm") end)
      pcall(function() moulding:SetString("ToolpathType", "FinishingToolpath") end)
      pcall(function() moulding:SetString("mcBaseToolpathName", params.toolpath_name) end)

      local manager = ToolpathManager()
      local attempts = {
         function() return manager:AddToolpath(moulding) end,
         function() return manager:AddToolpath(moulding, true) end,
         function() return manager:AddToolpath(params.toolpath_name, moulding) end,
      }

      for _, add in ipairs(attempts) do
         local ok, id = pcall(add)
         if ok and id ~= nil and id ~= false then
            return id, nil, warnings
         end
         last_err = id
      end

      return nil, "VCarve constructed MouldingToolpath but refused AddToolpath: "
         .. tostring(last_err), warnings
   end,
}
