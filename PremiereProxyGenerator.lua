--[[
================================================================================
  PremiereProxyGenerator.lua
================================================================================
  Version : 1.0.0
  Author  : Steve Harnell / 32Thirteen Productions, LLC
  Purpose : Prepare a DaVinci Resolve Studio project for an Adobe Premiere
            Pro proxy attach workflow.

            Current scope (intentionally minimal):
              * Auto-detect camera negative resolutions in the Media Pool
                (filtered by tolerance band and minimum source width).
              * Compute a fractional proxy resolution (1/2, 1/3, 1/4) with
                aspect preserved and dimensions snapped to nearest even.
              * Apply that as the project / timeline resolution.

            Deferred (was attempted, rejected by Resolve's render API on
            the test build):
              * Render preset generation (codec, audio, filename, timecode).
                Configure the Deliver page manually for now.

  Install paths:
    macOS   : /Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/
              (or per user: ~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/)
    Windows : %PROGRAMDATA%\Blackmagic Design\DaVinci Resolve\Fusion\Scripts\Edit\
              (or per user: %APPDATA%\Blackmagic Design\DaVinci Resolve\Fusion\Scripts\Edit\)
    Linux   : /opt/resolve/Fusion/Scripts/Edit/
              (or per user: ~/.local/share/DaVinciResolve/Fusion/Scripts/Edit/)

  Launch:
    Open the project in DaVinci Resolve Studio (18 or newer), then choose
    Workspace > Scripts > Edit > PremiereProxyGenerator.

  Notes:
    * No external Lua libraries are required. Only the Resolve scripting API
      and the Fusion UI Manager are used.
    * Every Resolve API call is wrapped in pcall and surfaced through the
      bottom status line. Errors never throw to the Resolve console.
    * Some preset resolutions in the CAMERAS table are flagged with a
      VERIFY comment. Confirm those against current manufacturer documentation
      (ARRI, Sony, RED) before using in production.
================================================================================
]]


-- ============================================================================
-- CAMERAS table
-- ============================================================================
-- Each entry: { name = "...", modes = { { label = "...", w = N, h = N }, ... } }
-- Add new cameras or modes by extending this table. Labels are shown to the
-- user in the Step 3 combo box.
-- ============================================================================

local CAMERAS = {
  {
    name = "ARRI Alexa 35",
    modes = {
      { label = "Open Gate 4.6K 3:2", w = 4608, h = 3164 },
      { label = "4.6K 16:9",          w = 4608, h = 2592 },
      { label = "4K 16:9",            w = 3840, h = 2160 },
      { label = "4K 2:1",             w = 4096, h = 2048 },
      { label = "4K 2.39:1",          w = 4096, h = 1716 },
    },
  },
  {
    name = "ARRI Alexa Mini LF",
    modes = {
      { label = "LF Open Gate",  w = 4448, h = 3096 },
      { label = "LF 16:9 UHD",   w = 3840, h = 2160 },
      { label = "LF 2.39:1",     w = 4448, h = 1856 },
    },
  },
  {
    name = "ARRI Alexa 65",
    modes = {
      -- VERIFY: Alexa 65 Open Gate sensor is commonly cited as 6560 x 3102.
      -- Brief uses 6560 x 3100. Confirm with current ARRI documentation.
      { label = "6.5K Open Gate", w = 6560, h = 3100 },
      { label = "5.1K 16:9",      w = 5120, h = 2880 },
      { label = "4.3K 16:9",      w = 4320, h = 2400 },
    },
  },
  {
    name = "Sony Venice 1",
    modes = {
      { label = "6K 3:2",     w = 6048, h = 4032 },
      { label = "6K 17:9",    w = 6048, h = 3194 },
      { label = "6K 2.39:1",  w = 6048, h = 2534 },
      { label = "4K 4:3",     w = 4096, h = 3024 },
      { label = "4K 17:9",    w = 4096, h = 2160 },
    },
  },
  {
    name = "Sony Venice 2",
    modes = {
      { label = "8.6K 3:2",  w = 8640, h = 5760 },
      { label = "8.2K 17:9", w = 8192, h = 4320 },
      { label = "6K 3:2",    w = 6048, h = 4032 },
      { label = "6K 17:9",   w = 6048, h = 3192 },
    },
  },
  {
    name = "RED V-Raptor / V-Raptor [X]",
    modes = {
      -- VERIFY: V-Raptor VV native is commonly cited as 8192 x 4320 (17:9)
      -- and 8192 x 3456 (2.4:1). Confirm against current RED documentation,
      -- especially for the [X] variant which adds global shutter modes.
      { label = "8K VV 17:9",   w = 8192, h = 4320 },
      { label = "8K VV 2.4:1",  w = 8192, h = 3456 },
      { label = "6K S35 17:9",  w = 6144, h = 3240 },
    },
  },
}

local FRACTIONS = {
  { label = "1/2", denom = 2 },
  { label = "1/3", denom = 3 },
  { label = "1/4", denom = 4 },
}

local AUTO_DETECT_LABEL = "Auto-detect from Media Pool"

-- Auto-detect filters. Both apply together: a group must be within the
-- tolerance band of the largest group AND meet the minimum source width to
-- be treated as a camera negative.
--
-- Tolerance is expressed as a percentage of the largest group's pixel count
-- (width times height). 100 == strict, only the single largest group passes.
-- 0 == disabled, every group passes the tolerance check.
local TOLERANCES = {
  { label = "Strict (largest group only)",       percent = 100 },
  { label = "Within 80 percent of largest",      percent = 80  },
  { label = "Within 50 percent of largest",      percent = 50  },
  { label = "No tolerance limit",                percent = 0   },
}

-- Minimum source width in pixels. Anything narrower is treated as a
-- transcoded proxy, thumbnail, or stills export and excluded from the
-- Step 3 dropdown. 0 == disabled.
local MIN_WIDTHS = {
  { label = "No minimum",                value = 0    },
  { label = "3K minimum (3072 px wide)", value = 3072 },
  { label = "4K minimum (3840 px wide)", value = 3840 },
  { label = "5K minimum (5120 px wide)", value = 5120 },
  { label = "6K minimum (6048 px wide)", value = 6048 },
  { label = "8K minimum (8192 px wide)", value = 8192 },
}


-- ============================================================================
-- Pure helper functions
-- ============================================================================

-- Snap an integer to the nearest even value. Ties resolve to the lower even.
local function nearestEven(n)
  local lower = math.floor(n / 2) * 2
  local upper = lower + 2
  if (n - lower) <= (upper - n) then
    return lower
  end
  return upper
end


-- Apply the active fraction (denom) to source dimensions. Returns even ints.
local function calculateProxyResolution(w, h, denom)
  if not (w and h and denom) or denom < 1 then
    return 0, 0
  end
  local pw = nearestEven(w / denom)
  local ph = nearestEven(h / denom)
  if pw < 2 then pw = 2 end
  if ph < 2 then ph = 2 end
  return pw, ph
end


-- Parse strings returned by GetClipProperty("Resolution"), e.g. "4608x3164"
-- or "4608 x 3164" or "4608X3164". Returns w, h on success or nil on failure.
local function parseResolutionString(s)
  if type(s) ~= "string" or s == "" then
    return nil, nil
  end
  local w, h = s:match("(%d+)%s*[xX]%s*(%d+)")
  if w and h then
    return tonumber(w), tonumber(h)
  end
  return nil, nil
end


-- Build a render preset name from the active selections.
local function buildPresetName(camera, mode, fractionLabel)
  local cam = camera or "Source"
  local md  = mode   or "Mode"
  local fr  = fractionLabel or "frac"
  -- Replace characters that some hosts do not like in preset names.
  local clean = function(x)
    x = x:gsub("/", "_")
    x = x:gsub(":", "_")
    return x
  end
  return string.format("Premiere Proxy %s %s %s",
    clean(cam), clean(md), clean(fr))
end


-- Sort helper used by the Auto-detect summary so the read-out is stable.
local function sortedKeys(t)
  local keys = {}
  for k, _ in pairs(t) do table.insert(keys, k) end
  table.sort(keys)
  return keys
end


-- ============================================================================
-- Resolve globals (declared early so closures below capture them as upvalues
-- instead of falling through to nil global lookups at call time).
-- ============================================================================

local resolve = Resolve()
if not resolve then
  print("Resolve scripting API is not available. Run this from inside DaVinci Resolve.")
  return
end

local pm   = resolve:GetProjectManager()
local proj = pm and pm:GetCurrentProject() or nil
local mp   = proj and proj:GetMediaPool() or nil


-- ============================================================================
-- Resolve API helpers (each wrapped in pcall by the caller)
-- ============================================================================

-- Push timeline (or project) resolution to match the proxy size.
local function applyProjectSettings(proj, w, h)
  if not proj then return false, "No active project" end
  local okW = proj:SetSetting("timelineResolutionWidth",  tostring(w))
  local okH = proj:SetSetting("timelineResolutionHeight", tostring(h))
  if not (okW and okH) then
    return false, "SetSetting returned false (resolution may not have applied)"
  end
  return true
end



-- Walk every folder of the Media Pool starting at the root and call fn(clip)
-- for every clip found.
local function forEachClip(mp, fn)
  if not mp then return end
  local root = mp:GetRootFolder()
  if not root then return end

  local stack = { root }
  while #stack > 0 do
    local folder = table.remove(stack)
    local clips = folder:GetClipList() or {}
    for _, c in ipairs(clips) do
      fn(c)
    end
    local subs = folder:GetSubFolderList() or {}
    for _, s in ipairs(subs) do
      table.insert(stack, s)
    end
  end
end


-- Group clips by source resolution and tag each group with the camera vendors
-- represented. Returns a table keyed by "WxH" with { count, vendors = {...} }.
local function scanMediaPoolResolutions(mp)
  local groups = {}
  forEachClip(mp, function(clip)
    local res = clip:GetClipProperty("Resolution")
    local cam = clip:GetClipProperty("Camera Type") or ""
    local w, h = parseResolutionString(res)
    if w and h then
      local key = string.format("%d x %d", w, h)
      local g = groups[key]
      if not g then
        g = { w = w, h = h, count = 0, vendors = {} }
        groups[key] = g
      end
      g.count = g.count + 1
      if cam ~= "" then
        local short = cam:match("^(%S+)") or cam
        g.vendors[short] = (g.vendors[short] or 0) + 1
      end
    end
  end)
  return groups
end


-- ============================================================================
-- GUI build
-- ============================================================================

local ui   = fu.UIManager
local disp = bmd.UIDispatcher(ui)

local WIN_ID = "PremiereProxyGenWin"

-- Avoid stacking duplicates if the user re-runs the script.
local existing = ui:FindWindow(WIN_ID)
if existing then
  existing:Show()
  existing:Raise()
  return
end

local function buildCameraNames()
  local names = { AUTO_DETECT_LABEL }
  for _, c in ipairs(CAMERAS) do
    table.insert(names, c.name)
  end
  return names
end

local function buildFractionLabels()
  local out = {}
  for _, f in ipairs(FRACTIONS) do table.insert(out, f.label) end
  return out
end

-- Module-level cache for Auto-detect scan results. Stored here (not on the
-- window) because Fusion UI window objects do not accept arbitrary Lua
-- attribute assignment, and the silent no-op was leaving the mode combo
-- empty after a successful scan.
--
-- rawScanGroups : every resolution group found in the Media Pool.
-- detectCache   : the subset that survives the active filter combos. This
--                 is what feeds the Step 3 dropdown.
local rawScanGroups = {}
local detectCache   = {}

local win = disp:AddWindow({
  ID          = WIN_ID,
  WindowTitle = "Premiere Proxy Generator",
  Geometry    = { 200, 100, 680, 640 },
  Spacing     = 8,
},
ui:VGroup{
  ID = "root",
  Spacing = 8,

  -- Step 1
  ui:Label{ ID = "Step1Label", Text = "Step 1: Proxy fraction (applied to source resolution)" },
  ui:HGroup{
    Weight = 0,
    ui:ComboBox{ ID = "FractionCombo", Weight = 1 },
  },

  -- Step 2
  ui:Label{ ID = "Step2Label", Text = "Step 2: Camera (or auto-detect from Media Pool)" },
  ui:HGroup{
    Weight = 0,
    ui:ComboBox{ ID = "CameraCombo", Weight = 1 },
  },

  -- Step 3
  ui:Label{ ID = "Step3Label", Text = "Step 3: Source mode and resulting proxy resolution" },
  ui:HGroup{
    Weight = 0,
    ui:ComboBox{ ID = "ModeCombo", Weight = 1 },
  },

  -- Auto-detect summary (visible only when auto-detect is selected).
  -- Initial Hidden state is overridden by updateAutoDetectVisibility() once
  -- the window is shown.
  ui:Label{ ID = "DetectLabel", Text = "Detected resolutions in Media Pool:" },
  ui:TextEdit{
    ID         = "DetectBox",
    ReadOnly   = true,
    Text       = "",
    PlaceholderText = "Choose 'Auto-detect from Media Pool' to scan.",
    MinimumSize = { 600, 90 },
    MaximumSize = { 16777215, 130 },
  },
  -- Auto-detect filters. Hidden alongside the rest of the auto-detect block
  -- when a manual camera is picked.
  ui:HGroup{
    Weight = 0,
    Spacing = 8,
    ui:VGroup{
      Weight = 1,
      ui:Label{ ID = "ToleranceLabel", Text = "Tolerance band" },
      ui:ComboBox{ ID = "ToleranceCombo", Weight = 1 },
    },
    ui:VGroup{
      Weight = 1,
      ui:Label{ ID = "MinWidthLabel", Text = "Minimum source width" },
      ui:ComboBox{ ID = "MinWidthCombo", Weight = 1 },
    },
  },

  -- Action buttons. Render preset generation was removed; this script
  -- currently only applies the timeline resolution. Configure codec /
  -- audio / filename on the Deliver page manually for now.
  ui:HGroup{
    Weight = 0,
    Spacing = 8,
    ui:Button{ ID = "ApplyButton",  Text = "Apply Project Resolution" },
    ui:Button{ ID = "CancelButton", Text = "Close" },
  },

  -- Status line
  ui:Label{
    ID = "StatusLabel",
    Text = "Ready.",
    Alignment = { AlignLeft = true, AlignVCenter = true },
  },
})

local itm = win:GetItems()


-- ============================================================================
-- Initial population
-- ============================================================================

itm.FractionCombo:AddItems(buildFractionLabels())
itm.FractionCombo.CurrentIndex = 1   -- default 1/3 (best balance per the brief)

itm.CameraCombo:AddItems(buildCameraNames())
itm.CameraCombo.CurrentIndex = 0     -- default to Auto-detect from Media Pool

local function labelsOf(t)
  local out = {}
  for _, e in ipairs(t) do table.insert(out, e.label) end
  return out
end

itm.ToleranceCombo:AddItems(labelsOf(TOLERANCES))
itm.ToleranceCombo.CurrentIndex = 1  -- default: within 80 percent of largest

itm.MinWidthCombo:AddItems(labelsOf(MIN_WIDTHS))
itm.MinWidthCombo.CurrentIndex = 3   -- default: 5K minimum


-- ============================================================================
-- Selection state and Mode combo refresh
-- ============================================================================

-- When auto-detect is active, modeEntries holds detected resolutions instead
-- of camera presets. Each entry: { label = "...", w = N, h = N, count = N }.
local modeEntries = {}

local function setStatus(msg)
  itm.StatusLabel.Text = msg or ""
end

local function currentFraction()
  local i = itm.FractionCombo.CurrentIndex + 1
  return FRACTIONS[i] or FRACTIONS[2]
end

local function isAutoDetect()
  return itm.CameraCombo.CurrentIndex == 0
end

local function currentCameraName()
  if isAutoDetect() then return "Auto" end
  local i = itm.CameraCombo.CurrentIndex
  local entry = CAMERAS[i] -- camera index 1..N matches combo index 1..N
  return entry and entry.name or "Source"
end

local function currentCameraEntry()
  if isAutoDetect() then return nil end
  return CAMERAS[itm.CameraCombo.CurrentIndex]
end


-- Repopulate the mode combo. Called whenever Step 1 or Step 2 changes, or
-- after an auto-detect scan finishes.
local function refreshModeCombo()
  itm.ModeCombo:Clear()
  modeEntries = {}

  local frac = currentFraction()

  if isAutoDetect() then
    -- Pull from the module-level cache populated by runAutoDetect().
    local keys = sortedKeys(detectCache)
    for _, k in ipairs(keys) do
      local g = detectCache[k]
      local pw, ph = calculateProxyResolution(g.w, g.h, frac.denom)
      local label = string.format("%d x %d  (%d clips)  ->  Proxy %d x %d",
        g.w, g.h, g.count, pw, ph)
      table.insert(modeEntries, { label = label, w = g.w, h = g.h, count = g.count })
    end
    if #modeEntries == 0 then
      itm.ModeCombo:AddItem("No clips scanned yet. Re-select 'Auto-detect' to scan.")
    else
      for _, e in ipairs(modeEntries) do
        itm.ModeCombo:AddItem(e.label)
      end
    end
  else
    local cam = currentCameraEntry()
    if cam then
      for _, m in ipairs(cam.modes) do
        local pw, ph = calculateProxyResolution(m.w, m.h, frac.denom)
        local label = string.format("%s (%d x %d)  ->  Proxy %d x %d",
          m.label, m.w, m.h, pw, ph)
        itm.ModeCombo:AddItem(label)
        table.insert(modeEntries, { label = label, w = m.w, h = m.h })
      end
    end
  end

  if #modeEntries > 0 then
    itm.ModeCombo.CurrentIndex = 0
  end
end


-- Show or hide the auto-detect summary widgets. Uses :Show()/:Hide() methods
-- because the .Hidden property assignment is unreliable on some Resolve builds
-- (the layout does not always reflow when the property is toggled directly).
local function updateAutoDetectVisibility()
  local show = isAutoDetect()
  local widgets = {
    itm.DetectLabel, itm.DetectBox,
    itm.ToleranceLabel, itm.ToleranceCombo,
    itm.MinWidthLabel,  itm.MinWidthCombo,
  }
  for _, w in ipairs(widgets) do
    if show then w:Show() else w:Hide() end
  end
end


-- Filter scan results to plausible camera negatives. Two checks apply:
--   1. Tolerance band: pixel count must be at least (tolerancePercent / 100)
--      of the largest group's pixel count. 100 == strict (only the largest
--      group passes). 0 == disabled.
--   2. Minimum source width: width must be at least minWidthPx. 0 == disabled.
-- Anything that fails either check is returned in the ignored table so the
-- summary panel can show what was excluded and why.
local function filterToCameraNegs(groups, tolerancePercent, minWidthPx)
  local kept, ignored = {}, {}
  local maxPixels = 0
  for _, g in pairs(groups) do
    local px = (g.w or 0) * (g.h or 0)
    if px > maxPixels then maxPixels = px end
  end

  local pctThreshold = 0
  if tolerancePercent and tolerancePercent > 0 and maxPixels > 0 then
    pctThreshold = math.floor(maxPixels * (tolerancePercent / 100))
  end

  for k, g in pairs(groups) do
    local px = (g.w or 0) * (g.h or 0)
    local reasons = {}
    if pctThreshold > 0 and px < pctThreshold then
      table.insert(reasons, "below tolerance")
    end
    if minWidthPx and minWidthPx > 0 and (g.w or 0) < minWidthPx then
      table.insert(reasons, string.format("under %d px wide", minWidthPx))
    end
    if #reasons == 0 then
      kept[k] = g
    else
      g.ignoreReason = table.concat(reasons, ", ")
      ignored[k] = g
    end
  end
  return kept, ignored
end


-- Read the active filter combo selections.
local function currentTolerancePercent()
  local i = itm.ToleranceCombo.CurrentIndex + 1
  return (TOLERANCES[i] or TOLERANCES[1]).percent
end

local function currentMinWidthPx()
  local i = itm.MinWidthCombo.CurrentIndex + 1
  return (MIN_WIDTHS[i] or MIN_WIDTHS[1]).value
end


-- Re-run the filter against the cached raw scan, repaint the summary panel,
-- and refresh the Step 3 dropdown. Cheap, so it runs whenever a filter combo
-- changes without requiring another Media Pool walk.
local function applyDetectFilters()
  if not next(rawScanGroups) then
    -- Nothing scanned yet. Leave the placeholder text in place.
    detectCache = {}
    refreshModeCombo()
    return
  end

  local kept, ignored = filterToCameraNegs(
    rawScanGroups, currentTolerancePercent(), currentMinWidthPx())
  detectCache = kept

  local function describe(g, key, suffix)
    local vendorBits = {}
    for v, c in pairs(g.vendors) do
      table.insert(vendorBits, string.format("%s x%d", v, c))
    end
    table.sort(vendorBits)
    local vendorStr = #vendorBits > 0
      and ("  (" .. table.concat(vendorBits, ", ") .. ")") or ""
    local tail = suffix and ("  [" .. suffix .. "]") or ""
    return string.format("  %s  ,  %d clips%s%s", key, g.count, vendorStr, tail)
  end

  local lines = { "Camera negatives (used for proxy generation):" }
  local keptKeys = sortedKeys(kept)
  if #keptKeys == 0 then
    table.insert(lines, "  (none passed the active filters)")
  else
    for _, k in ipairs(keptKeys) do
      table.insert(lines, describe(kept[k], k))
    end
  end

  if next(ignored) then
    table.insert(lines, "")
    table.insert(lines, "Ignored (likely transcoded proxies, thumbnails, or stills):")
    for _, k in ipairs(sortedKeys(ignored)) do
      table.insert(lines, describe(ignored[k], k, ignored[k].ignoreReason))
    end
  end
  itm.DetectBox.Text = table.concat(lines, "\n")

  refreshModeCombo()

  local keptCount, ignoredCount = 0, 0
  for _ in pairs(kept)    do keptCount    = keptCount    + 1 end
  for _ in pairs(ignored) do ignoredCount = ignoredCount + 1 end
  if keptCount == 0 then
    setStatus("Auto-detect: no groups passed the filters. Loosen tolerance or lower the minimum width.")
  elseif ignoredCount > 0 then
    setStatus(string.format(
      "Auto-detect kept %d camera-neg resolution(s); ignored %d group(s).",
      keptCount, ignoredCount))
  else
    setStatus(string.format("Auto-detect found %d camera-neg resolution(s).", keptCount))
  end
end


-- Walk the Media Pool, cache the raw scan, then apply the current filters.
local function runAutoDetect()
  if not mp then
    itm.DetectBox.Text = "Media Pool is not available. Open a project first."
    setStatus("Auto-detect skipped: no Media Pool.")
    return
  end
  local ok, groupsOrErr = pcall(scanMediaPoolResolutions, mp)
  if not ok then
    itm.DetectBox.Text = "Scan failed: " .. tostring(groupsOrErr)
    setStatus("Auto-detect error.")
    return
  end
  rawScanGroups = groupsOrErr or {}

  if not next(rawScanGroups) then
    itm.DetectBox.Text = "No clips with a readable Resolution property were found."
    detectCache = {}
    refreshModeCombo()
    return
  end

  applyDetectFilters()
end


-- ============================================================================
-- Action implementations
-- ============================================================================

-- Apply settings for one (camera, mode, fraction) tuple. Currently this
-- only pushes the timeline resolution onto the project. Render preset
-- generation was removed because Resolve's render-settings API kept
-- rejecting the dict on this build; revisit later if needed.
--
-- Returns ok, diagnostic.
local function applyOne(cameraName, mode, fraction)
  local pw, ph = calculateProxyResolution(mode.w, mode.h, fraction.denom)

  local pcOk, settingsOk, settingsErr = pcall(applyProjectSettings, proj, pw, ph)
  if not pcOk then
    return false, "applyProjectSettings raised: " .. tostring(settingsOk)
  end
  if settingsOk == false then
    return false, "applyProjectSettings failed: " .. tostring(settingsErr)
  end

  return true, string.format("Timeline resolution set to %d x %d", pw, ph)
end


-- Driver for the Apply button. Sets project resolution and saves preset(s).
-- No deliver-page side effects, no render queue interaction.
local function doApply()
  if not proj then
    setStatus("No active project. Open a project in Resolve and try again.")
    return
  end

  local fraction = currentFraction()

  if isAutoDetect() then
    if #modeEntries == 0 then
      setStatus("Auto-detect has no resolutions. Re-select 'Auto-detect from Media Pool' to scan first.")
      return
    end

    -- For auto-detect, multiple resolutions may be present. We can only set
    -- one timeline resolution at a time, so apply the entry the user picked
    -- in Step 3 regardless of the multi-preset checkbox.
    local idx = itm.ModeCombo.CurrentIndex + 1
    local e = modeEntries[idx]
    if not e then setStatus("Pick a detected resolution from the Step 3 list."); return end
    local fakeMode = { label = string.format("Auto %dx%d", e.w, e.h), w = e.w, h = e.h }
    local ok, diag = applyOne("Auto", fakeMode, fraction)
    if ok then setStatus(diag) else setStatus("Failed: " .. tostring(diag)) end
    return
  end

  -- Manual camera + mode path.
  local cam = currentCameraEntry()
  if not cam then setStatus("Pick a camera in Step 2."); return end
  local idx = itm.ModeCombo.CurrentIndex + 1
  local mode = cam.modes[idx]
  if not mode then setStatus("Pick a source mode in Step 3."); return end

  local ok, diag = applyOne(cam.name, mode, fraction)
  if ok then setStatus(diag) else setStatus("Failed: " .. tostring(diag)) end
end


-- ============================================================================
-- Event wiring
-- ============================================================================

win.On.FractionCombo.CurrentIndexChanged = function(ev)
  refreshModeCombo()
end

win.On.CameraCombo.CurrentIndexChanged = function(ev)
  updateAutoDetectVisibility()
  if isAutoDetect() then
    runAutoDetect()
  else
    refreshModeCombo()
  end
end

win.On.ToleranceCombo.CurrentIndexChanged = function(ev)
  if isAutoDetect() then applyDetectFilters() end
end

win.On.MinWidthCombo.CurrentIndexChanged = function(ev)
  if isAutoDetect() then applyDetectFilters() end
end

win.On.ApplyButton.Clicked = function(ev)
  doApply()
end

win.On.CancelButton.Clicked = function(ev)
  disp:ExitLoop()
end

win.On[WIN_ID].Close = function(ev)
  disp:ExitLoop()
end


-- ============================================================================
-- Show window and run event loop
-- ============================================================================

updateAutoDetectVisibility()

if not proj then
  setStatus("No project is open. Settings will not apply until you open one.")
elseif not mp then
  setStatus("Project is open but the Media Pool is unavailable.")
end

win:Show()

-- Run the initial auto-detect scan after Show() so the user sees a populated
-- summary and a populated Step 3 combo on first paint, since auto-detect is
-- now the default Step 2 selection.
if isAutoDetect() and mp then
  runAutoDetect()
else
  refreshModeCombo()
end

disp:RunLoop()
win:Hide()
