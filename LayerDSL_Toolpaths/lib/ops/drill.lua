--[[--------------------------------------------------------------------------
| lib/ops/drill.lua - Drilling operation.
|
| See lib/ops/pocket.lua for the module contract.
----------------------------------------------------------------------------]]

return {
   name = "Drill",
   summary = "Plunges at the centre of each closed vector.",

   build = function(params, ctx, deps)
      local Enums, Tooling = deps.enums, deps.tooling
      local warnings = {}

      ------------------------------------------------------------------
      -- Cutter, from the VCarve tool library
      ------------------------------------------------------------------
      local tool, w, err, record = Tooling.from_library{
         reference = params.tool,
         role      = "drill",
         params    = params,
         ctx       = ctx,
      }
      for _, msg in ipairs(w) do warnings[#warnings + 1] = msg end
      if tool == nil then return nil, err, warnings end

      local mismatch = Tooling.check_tool_type(record, params.tool,
                                               "through_drill", "drilling")
      if mismatch then warnings[#warnings + 1] = mismatch end

      ------------------------------------------------------------------
      -- Drill parameters
      ------------------------------------------------------------------
      local drill = DrillParameterData()

      drill.StartDepth = params.start_depth
      drill.CutDepth   = params.depth

      -- Peck drilling. `true` with no value pecks at the tool's stepdown.
      local peck = params.peck
      if peck == true then peck = params.pass_depth end

      drill.DoPeckDrill = (type(peck) == "number" and peck > 0)
      if drill.DoPeckDrill then
         drill.PeckRetractGap = peck
      end

      drill.ProjectToolpath = false

      ------------------------------------------------------------------
      -- Position, geometry selection, and creation
      ------------------------------------------------------------------
      local pos = Tooling.position(params, ctx)

      -- Drilling defaults to circles-only selection (see config.lua), which
      -- keeps stray rectangles on a drill layer from becoming holes.
      local selector = Enums.build_selector(
                          params.layer_name, params.vector_selection, tool.ToolDia)

      local id = ToolpathManager():CreateDrillingToolpath(
                    params.toolpath_name,
                    tool,
                    drill,
                    pos,
                    selector,
                    ctx.create_2d_previews,
                    ctx.interactive_warnings)

      if id == nil then
         return nil, "VCarve could not calculate the drilling toolpath", warnings
      end
      return id, nil, warnings
   end,
}
