local ADDON_NAME, ns = ...
local Dbg = ns.Dbg or function() end

-- ============================================================================
-- MythicPlusHud: in-dungeon status header for an active Mythic+ run.
--
-- A small borderless backdrop that shows everything we want to glance at
-- mid-run on a single line:
--
--   <Dungeon> +<Lvl>   <Affix>/<Affix>/...   <MM:SS>   <%> <N/M>   [skull] B/T
--
-- Conventions:
--   * Forces are shown REMAINING, not done. So a fresh pull reads "100%
--     150/150" and ticks down to "0% 0/150".
--   * Bosses are shown REMAINING, e.g. "1/4" with one boss left.
--   * Affixes get a custom abbreviation: Tyrannical -> "T", Fortified -> "F",
--     and Xal'atath sub-affixes ("Xal'atath's Bargain: Devour") collapse to
--     their last word ("Devour"). Anything else falls back to its raw name.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test-mode state (forward declared so all data fns close over it)
--
-- /sk hudtest flips `testMode` on. While on, GetActiveRun / ReadCriteria /
-- GetElapsedSeconds return synthetic structs instead of querying the game,
-- so we can iterate on layout without entering an actual key. The elapsed
-- clock ticks in real time (GetTime() - testStartTime) so the countdown
-- looks live.
-- ----------------------------------------------------------------------------

local testMode = false
local testStartTime = 0

-- Pre-formatted affix labels short-circuit the GetAffixInfo lookup so test
-- mode doesn't depend on whether the current season actually has a given ID.
local TEST_RUN = {
	mapID = 558,
	level = 12,
	affixLabels = { "T", "Devour" },
	name = "Magisters' Terrace",
	timeLimit = 30 * 60,
}

local TEST_CRIT = {
	forcesQuantity = 27,
	forcesTotal = 150,
	bossesTotal = 4,
	bossesDone = 1,
}

-- ----------------------------------------------------------------------------
-- Affix abbreviation
-- ----------------------------------------------------------------------------

-- Hard overrides (the season-stable ones).
local AFFIX_OVERRIDE = {
	[9]  = "T",     -- Tyrannical
	[10] = "F",     -- Fortified
}

-- Returns the short label to display for `affixID`, or nil if this affix is
-- one we deliberately don't show on the HUD.
--
-- The HUD shows three categories at most: Tyrannical (T), Fortified (F), and
-- the rotating weekly Xal'atath sub-affix ("Xal'atath's Bargain: X" -> "X").
-- Returning nil for everything else filters out:
--   * Xal'atath's Guile     (constant seasonal meta affix)
--   * Lindormi's Guidance   (+12 keystone-hero affix)
--   * any future affixes that don't follow the "<...>: <flavor>" pattern
-- Both Render and ComputeAffixSample skip nil results, so the filter applies
-- to display *and* to slot-width sizing.
local function ShortAffixName(affixID)
	if not affixID or affixID == 0 then return nil end
	if AFFIX_OVERRIDE[affixID] then return AFFIX_OVERRIDE[affixID] end
	local name = C_ChallengeMode.GetAffixInfo(affixID)
	if not name or name == "" then return nil end
	local tail = name:match(":%s*(.+)$")
	if tail then return tail end
	return nil
end

-- ----------------------------------------------------------------------------
-- Dungeon short names (one word per dungeon for the HUD title slot)
--
-- Falls back to the first whitespace-delimited word of the full name if a
-- challengeMapID isn't in the table — keeps the HUD readable when a season
-- introduces a dungeon we haven't curated yet.
-- ----------------------------------------------------------------------------

local SHORT_DUNGEON_NAME = {
	[161] = "Skyreach",   -- Skyreach
	[239] = "Seat",       -- Seat of the Triumvirate
	[402] = "Algethar",   -- Algeth'ar Academy
	[556] = "Pit",        -- Pit of Saron
	[557] = "Spire",      -- Windrunner Spire
	[558] = "Magisters",  -- Magisters' Terrace
	[559] = "Xenas",      -- Nexus-Point Xenas
	[560] = "Maisara",    -- Maisara Caverns
}

local function ShortDungeonName(mapID, fullName)
	if mapID and SHORT_DUNGEON_NAME[mapID] then return SHORT_DUNGEON_NAME[mapID] end
	if fullName then
		local first = fullName:match("^(%S+)")
		if first then return first end
	end
	return fullName or "?"
end

-- ----------------------------------------------------------------------------
-- Forces / boss criteria scan
--
-- Modern M+ exposes one weighted-progress criteria (Enemy Forces) plus one
-- non-weighted criteria per boss. We don't care about the order; we just
-- classify and tally.
-- ----------------------------------------------------------------------------

local function ReadCriteria()
	if testMode then return TEST_CRIT end
	local stepInfo = C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo and C_ScenarioInfo.GetScenarioStepInfo()
	if not stepInfo or not stepInfo.numCriteria then return nil end

	local forcesQuantity, forcesTotal
	local bossesTotal, bossesDone = 0, 0

	for i = 1, stepInfo.numCriteria do
		local c = C_ScenarioInfo.GetCriteriaInfo(i)
		if c then
			if c.isWeightedProgress then
				forcesQuantity = c.quantity or 0
				forcesTotal = c.totalQuantity or 0
			else
				bossesTotal = bossesTotal + 1
				if c.completed then bossesDone = bossesDone + 1 end
			end
		end
	end

	return {
		forcesQuantity = forcesQuantity,
		forcesTotal = forcesTotal,
		bossesTotal = bossesTotal,
		bossesDone = bossesDone,
	}
end

-- ----------------------------------------------------------------------------
-- Timer
--
-- WORLD_STATE_TIMER_START fires with the active timer's ID; we cache it and
-- poll GetWorldElapsedTime(timerID) each tick. If we missed the start event
-- (login/reload mid-key), scan a handful of slots looking for an active
-- ChallengeMode timer.
-- ----------------------------------------------------------------------------

local activeTimerID

local function FindActiveTimer()
	for i = 1, 10 do
		local ok, elapsed, timerType = GetWorldElapsedTime(i)
		if ok == 1 and timerType == LE_WORLD_ELAPSED_TIMER_TYPE_CHALLENGE_MODE then
			return i, elapsed
		end
	end
	return nil, 0
end

local function GetElapsedSeconds()
	if testMode then return GetTime() - testStartTime end
	if activeTimerID then
		local ok, elapsed = GetWorldElapsedTime(activeTimerID)
		if ok == 1 and elapsed and elapsed > 0 then return elapsed end
	end
	local id, elapsed = FindActiveTimer()
	if id then activeTimerID = id end
	return elapsed or 0
end

-- ----------------------------------------------------------------------------
-- Active-run detection
-- ----------------------------------------------------------------------------

local function GetActiveRun()
	if testMode then return TEST_RUN end
	local level, affixes = C_ChallengeMode.GetActiveKeystoneInfo()
	local mapID = C_ChallengeMode.GetActiveChallengeMapID()
	if not level or level <= 0 or not mapID then return nil end
	local name, _, timeLimit = C_ChallengeMode.GetMapUIInfo(mapID)
	return {
		mapID = mapID,
		level = level,
		affixes = affixes or {},
		name = name or ("Map " .. mapID),
		timeLimit = timeLimit or 0,
	}
end

-- ----------------------------------------------------------------------------
-- Frame + section layout
--
-- The HUD is a horizontal chain of sections. Each section is an (icon, text)
-- pair, anchored left-to-right with a gap between sections and a tight gap
-- between an icon and its own label. Per-section colors and icons make each
-- chunk of info visually distinct at a glance.
--
-- Section render data lives in `f.sections[key]` (icon Texture + text
-- FontString). `Render` updates the text values, then walks SECTION_ORDER
-- to re-anchor the visible sections and resize the frame to fit.
-- ----------------------------------------------------------------------------

local f
local PADDING_X, PADDING_Y = 10, 6
local SECTION_GAP = 10        -- between sections
local ICON_TEXT_GAP = 2       -- between an icon and its own label
local ICON_SIZE = 14

local SECTION_ORDER = { "dungeon", "affixes", "timer", "forces", "bosses" }

-- Per-section visual config.
--   * `icon` is a static texture path. Sections with no `icon` and no
--     `dynamicIcon` render text only (no leading icon).
--   * `dynamicIcon` means the icon's texture is set per-Render from live
--     run data (the dungeon section uses C_ChallengeMode.GetMapUIInfo's
--     portrait texture so the icon matches the active dungeon).
--   * `crop` strips the standard icon border for Interface\Icons textures
--     (they're 64x64 with a border); `false` for UI textures that already
--     display cleanly at their native crop.
local SECTION_DEFS = {
	dungeon = {
		dynamicIcon = true,
		color = { 1.00, 0.82, 0.00 }, -- gold
		crop  = true,
	},
	affixes = {
		-- no icon — the affix labels speak for themselves
		color = { 1.00, 0.65, 0.40 }, -- coral
	},
	timer = {
		icon  = "Interface\\Icons\\INV_Misc_PocketWatch_01",
		color = { 1.00, 1.00, 1.00 }, -- white default; Render overrides per-tick
		crop  = true,
	},
	forces = {
		icon  = "Interface\\Icons\\INV_Sword_04",
		color = { 0.40, 0.95, 0.50 }, -- light green
		crop  = true,
	},
	bosses = {
		icon  = "Interface\\TARGETINGFRAME\\UI-TargetingFrame-Skull",
		color = { 0.85, 0.65, 1.00 }, -- light violet
		crop  = false,
	},
}

-- Worst-case sample strings per section. BuildFrame renders each into the
-- corresponding FontString, measures the resulting pixel width, and locks
-- that as the section's slot width. This keeps the layout stable across
-- value changes (timer ticking, forces dropping) without us having to guess
-- pixel widths from the font's char metrics.
--
-- Pick samples that bound the realistic max for each slot — they don't have
-- to match real content character-for-character, just be at least as wide.
--
-- The affixes sample is derived dynamically from C_MythicPlus.GetCurrentAffixes
-- (see ComputeAffixSample below) so we size to *this season's actual* affix
-- string rather than a hypothetical superset.
local SECTION_SAMPLES = {
	dungeon = "Magisters +30",  -- longest curated short name + plausible top level
	timer   = "59:59",          -- MM:SS (we clamp negatives to 0:00)
	forces  = "100% 999/999",   -- full pull
	bosses  = "9/9",            -- bosses-remaining/bosses-total
}

-- Used until C_MythicPlus.GetCurrentAffixes is populated (usually right after
-- login). "Ascendant" is the longest of the four Xal'atath sub-affixes, so
-- this sample never under-sizes the affix slot even if data is late.
local AFFIX_SAMPLE_FALLBACK = "T/F/Ascendant"

local SLOT_PADDING = 2  -- a couple px of safety added to each measurement

-- Build the affix-section sample from the live weekly affix list. Keys at
-- high enough levels carry both Tyrannical AND Fortified, so we prepend
-- both T and F and then append every non-T/F affix we get back from the API.
local function ComputeAffixSample()
	if not (C_MythicPlus and C_MythicPlus.GetCurrentAffixes) then
		Dbg("MPlusHud.ComputeAffixSample: no C_MythicPlus.GetCurrentAffixes API; using fallback")
		return AFFIX_SAMPLE_FALLBACK
	end
	local affixes = C_MythicPlus.GetCurrentAffixes()
	Dbg(string.format("MPlusHud.ComputeAffixSample: GetCurrentAffixes returned %s entries",
		affixes and tostring(#affixes) or "nil"))
	if not affixes or #affixes == 0 then
		Dbg("  -> empty/nil; using fallback " .. AFFIX_SAMPLE_FALLBACK)
		return AFFIX_SAMPLE_FALLBACK
	end

	local labels = { "T", "F" }
	local sawNonTF = false
	for i, info in ipairs(affixes) do
		local id = info.id or info[1]
		local label = ShortAffixName(id)
		Dbg(string.format("  affix[%d]: id=%s label=%s", i, tostring(id), tostring(label)))
		if label and label ~= "T" and label ~= "F" then
			labels[#labels + 1] = label
			sawNonTF = true
		end
	end
	if not sawNonTF then
		Dbg("  no non-T/F label found; using fallback " .. AFFIX_SAMPLE_FALLBACK)
		return AFFIX_SAMPLE_FALLBACK
	end
	local sample = table.concat(labels, "/")
	Dbg("  -> sample=" .. sample)
	return sample
end

-- Set a section's text to `sample`, measure it, and lock that as the
-- section's slot width. Safe to call after BuildFrame at any time — used
-- both at build (initial measurement) and on MYTHIC_PLUS_CURRENT_AFFIX_UPDATE
-- (re-measure the affixes slot once real affix data arrives).
local function MeasureSection(key, sample)
	local s = f and f.sections and f.sections[key]
	if not s or not s.text then
		Dbg("MPlusHud.MeasureSection: no section for key=" .. tostring(key))
		return
	end
	s.text:SetText(sample or "")
	local strW = s.text:GetStringWidth() or 0
	s.slotWidth = math.ceil(strW + SLOT_PADDING)
	s.text:SetWidth(s.slotWidth)
	s.text:SetText("")
	Dbg(string.format("MPlusHud.MeasureSection: key=%s sample=%q stringWidth=%.1f slotWidth=%d",
		key, sample or "", strW, s.slotWidth))
end

local function BuildFrame()
	if f then return f end

	f = CreateFrame("Frame", "SeanKeysMPlusHud", UIParent, "BackdropTemplate")
	tinsert(UISpecialFrames, "SeanKeysMPlusHud")
	f:SetFrameStrata("MEDIUM")
	f:SetSize(420, 28)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetBackdrop({
		bgFile = "Interface/Tooltips/UI-Tooltip-Background",
		edgeFile = nil,
		insets = { left = 0, right = 0, top = 0, bottom = 0 },
	})
	f:SetBackdropColor(0, 0, 0, 0.55)
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		ns.db = ns.db or {}
		ns.db.mpHudPos = { point = point, relPoint = relPoint, x = x, y = y }
	end)

	-- Apply saved position (or default top-center) once the frame exists.
	local pos = ns.db and ns.db.mpHudPos
	if pos and pos.point then
		f:ClearAllPoints()
		f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
	else
		f:ClearAllPoints()
		f:SetPoint("TOP", UIParent, "TOP", 0, -180)
	end

	f.sections = {}
	for _, key in ipairs(SECTION_ORDER) do
		local def = SECTION_DEFS[key]
		local s = {}

		if def.icon or def.dynamicIcon then
			s.icon = f:CreateTexture(nil, "OVERLAY")
			s.icon:SetSize(ICON_SIZE, ICON_SIZE)
			if def.icon then s.icon:SetTexture(def.icon) end
			if def.crop then s.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
		end

		s.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		s.text:SetWordWrap(false)
		s.text:SetNonSpaceWrap(false)
		s.text:SetJustifyH("LEFT")
		s.text:SetJustifyV("MIDDLE")
		s.text:SetTextColor(def.color[1], def.color[2], def.color[3], 1)

		f.sections[key] = s
	end

	-- Measure each section's worst-case sample to lock in a slot width.
	-- Done after all sections exist so the affixes one can re-measure later
	-- (on MYTHIC_PLUS_CURRENT_AFFIX_UPDATE) via the same code path.
	for _, key in ipairs(SECTION_ORDER) do
		local sample = (key == "affixes") and ComputeAffixSample() or (SECTION_SAMPLES[key] or "")
		MeasureSection(key, sample)
	end

	f:Hide()
	return f
end

-- ----------------------------------------------------------------------------
-- Render
-- ----------------------------------------------------------------------------

local function FormatMMSS(sec)
	if not sec or sec < 0 then sec = 0 end
	sec = math.floor(sec + 0.5)
	return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Timer color: white default, amber inside the last 20% of par, red over par.
local function TimerRGB(remaining, timeLimit)
	if not remaining or remaining <= 0 then return 1.00, 0.31, 0.31 end
	if timeLimit and timeLimit > 0 and remaining < timeLimit * 0.2 then
		return 1.00, 0.82, 0.38
	end
	return 1.00, 1.00, 1.00
end

local function Render()
	if not f then return end
	local run = GetActiveRun()
	if not run then
		f:Hide()
		return
	end

	-- Dungeon
	local dungeonStr = string.format("%s +%d", ShortDungeonName(run.mapID, run.name), run.level)

	-- Affixes
	local affixParts = {}
	if run.affixLabels then
		-- Pre-formatted labels (test mode) bypass GetAffixInfo entirely.
		for _, label in ipairs(run.affixLabels) do
			affixParts[#affixParts + 1] = label
		end
	else
		for _, affixID in ipairs(run.affixes or {}) do
			local s = ShortAffixName(affixID)
			if s then affixParts[#affixParts + 1] = s end
		end
	end
	local affixStr = #affixParts > 0 and table.concat(affixParts, "/") or "-"

	-- Timer (countdown)
	local elapsed = GetElapsedSeconds()
	local remaining = (run.timeLimit or 0) - elapsed
	local timerStr = FormatMMSS(remaining)
	local tr, tg, tb = TimerRGB(remaining, run.timeLimit)

	-- Forces + bosses (remaining)
	local crit = ReadCriteria()
	local forcesStr = "?"
	local bossesStr, hasBosses
	if crit then
		local q, t = crit.forcesQuantity or 0, crit.forcesTotal or 0
		if t > 0 then
			local pctRemain = math.max(0, 1 - (q / t)) * 100
			local countRemain = math.max(0, t - q)
			forcesStr = string.format("%d%% %d/%d", math.floor(pctRemain + 0.5), countRemain, t)
		end
		local bossTotal = crit.bossesTotal or 0
		if bossTotal > 0 then
			local bossRemaining = math.max(0, bossTotal - (crit.bossesDone or 0))
			bossesStr = string.format("%d/%d", bossRemaining, bossTotal)
			hasBosses = true
		end
	end

	-- Push values to the section fontstrings.
	f.sections.dungeon.text:SetText(dungeonStr)
	f.sections.affixes.text:SetText(affixStr)
	f.sections.timer.text:SetText(timerStr)
	f.sections.timer.text:SetTextColor(tr, tg, tb, 1)
	f.sections.forces.text:SetText(forcesStr)

	-- Dungeon icon follows the active dungeon. Cached so we only hit
	-- GetMapUIInfo and SetTexture when the map actually changes.
	local dungeonIcon = f.sections.dungeon.icon
	if dungeonIcon and run.mapID and run.mapID ~= f._dungeonIconMapID then
		local _, _, _, tex = C_ChallengeMode.GetMapUIInfo(run.mapID)
		if tex then
			dungeonIcon:SetTexture(tex)
			dungeonIcon:Show()
		else
			dungeonIcon:Hide()
		end
		f._dungeonIconMapID = run.mapID
	end

	if hasBosses then
		f.sections.bosses.text:SetText(bossesStr)
		f.sections.bosses.icon:Show()
		f.sections.bosses.text:Show()
	else
		f.sections.bosses.text:SetText("")
		f.sections.bosses.icon:Hide()
		f.sections.bosses.text:Hide()
	end

	-- Layout: walk sections left-to-right at their measured slot widths so
	-- internal text changes don't shift neighbors. Sections without an icon
	-- (e.g. affixes) skip the icon span and start with text directly.
	local x = PADDING_X
	for _, key in ipairs(SECTION_ORDER) do
		local s = f.sections[key]
		if s.text:IsShown() then
			local slotW = s.slotWidth or 80
			s.text:ClearAllPoints()
			if s.icon and s.icon:IsShown() then
				s.icon:ClearAllPoints()
				s.icon:SetPoint("LEFT", f, "LEFT", x, 0)
				s.text:SetPoint("LEFT", s.icon, "RIGHT", ICON_TEXT_GAP, 0)
				x = x + ICON_SIZE + ICON_TEXT_GAP + slotW + SECTION_GAP
			else
				s.text:SetPoint("LEFT", f, "LEFT", x, 0)
				x = x + slotW + SECTION_GAP
			end
		end
	end

	-- Frame width is also fixed (sum of slot widths + gaps + padding) so the
	-- background doesn't breathe with the content either.
	f:SetWidth(math.max(120, x - SECTION_GAP + PADDING_X))
	f:SetHeight(math.max(20, ICON_SIZE + PADDING_Y * 2))

	if not f:IsShown() then f:Show() end
end

-- ----------------------------------------------------------------------------
-- Ticker
-- ----------------------------------------------------------------------------

local ticker
local function StopTicker()
	if ticker then ticker:Cancel(); ticker = nil end
end

local function StartTicker()
	if ticker then return end
	ticker = C_Timer.NewTicker(0.5, function()
		if not GetActiveRun() then
			StopTicker()
			if f then f:Hide() end
			return
		end
		Render()
	end)
end

-- ----------------------------------------------------------------------------
-- Public + events
-- ----------------------------------------------------------------------------

local function Refresh()
	BuildFrame()
	if GetActiveRun() then
		StartTicker()
		Render()
	else
		StopTicker()
		if f then f:Hide() end
	end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("CHALLENGE_MODE_START")
boot:RegisterEvent("CHALLENGE_MODE_RESET")
boot:RegisterEvent("CHALLENGE_MODE_COMPLETED")
boot:RegisterEvent("WORLD_STATE_TIMER_START")
boot:RegisterEvent("WORLD_STATE_TIMER_STOP")
boot:RegisterEvent("SCENARIO_UPDATE")
boot:RegisterEvent("SCENARIO_CRITERIA_UPDATE")
boot:RegisterEvent("ZONE_CHANGED_NEW_AREA")
boot:RegisterEvent("MYTHIC_PLUS_CURRENT_AFFIX_UPDATE")
boot:SetScript("OnEvent", function(_, event, arg1)
	if event == "WORLD_STATE_TIMER_START" then
		activeTimerID = arg1
	elseif event == "WORLD_STATE_TIMER_STOP" then
		if activeTimerID == arg1 then activeTimerID = nil end
	elseif event == "MYTHIC_PLUS_CURRENT_AFFIX_UPDATE" then
		-- Re-size the affix slot now that real affix data is available.
		Dbg("MPlusHud: MYTHIC_PLUS_CURRENT_AFFIX_UPDATE -> remeasuring affix slot")
		MeasureSection("affixes", ComputeAffixSample())
	end
	Refresh()
end)

-- ----------------------------------------------------------------------------
-- /sk hudtest
-- ----------------------------------------------------------------------------

local function ToggleTest()
	testMode = not testMode
	if testMode then
		testStartTime = GetTime()
		BuildFrame()
		StartTicker()
		Render()
	else
		StopTicker()
		Refresh() -- falls back to real-state check; hides if not in a key
	end
	return testMode
end

ns.MPlusHud = {
	Refresh = Refresh,
	ToggleTest = ToggleTest,
}
