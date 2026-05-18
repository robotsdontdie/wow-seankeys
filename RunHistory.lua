local ADDON_NAME, ns = ...

-- ============================================================================
-- RunHistory: persistent record of past M+ runs (capped at MAX_RUNS) and the
-- window that displays them.
--
-- The HUD (MythicPlusHud.lua) drives capture by calling ns.RunHistory.Append
-- whenever a run finalizes (CHALLENGE_MODE_COMPLETED, CHALLENGE_MODE_RESET,
-- or ticker-detected zone-out). We just own storage and presentation.
--
-- Storage lives in SeanKeysDB.runHistory (account-wide). Each entry:
--   {
--     startEpoch, endEpoch,         -- wall-clock seconds (time())
--     duration,                     -- in-key elapsed seconds at finalization
--     mapID, name, level,           -- dungeon identity + key level
--     affixes = { affixID, ... },   -- raw IDs (display names recomputed)
--     timeLimit,                    -- par seconds (for "+N" math)
--     forcesTotal,                  -- mob-count denominator for per-combat %
--     completed,                    -- true if CHALLENGE_MODE_COMPLETED fired
--     onTime,                       -- only meaningful if completed
--     upgradeLevels,                -- +N from completion info (0 if not timed)
--     player,                       -- "Name-Realm" so account-wide list shows owner
--     combats = { { startElapsed, duration, forcesKilled, boss }, ... },
--   }
--
-- Newest entries are appended at the end of the array; the window renders in
-- reverse-iteration order so the latest run sits at the top of the list.
-- ============================================================================

local Dbg = ns.Dbg or function() end

-- ----------------------------------------------------------------------------
-- Persistence
-- ----------------------------------------------------------------------------

local MAX_RUNS = 20

local function Init()
	if not ns.db then return end
	ns.db.runHistory = ns.db.runHistory or {}
end

local function Append(entry)
	if not entry then return end
	if not ns.db then return end
	ns.db.runHistory = ns.db.runHistory or {}
	table.insert(ns.db.runHistory, entry)
	while #ns.db.runHistory > MAX_RUNS do
		table.remove(ns.db.runHistory, 1)
	end
end

-- ----------------------------------------------------------------------------
-- Format helpers
-- ----------------------------------------------------------------------------

local function FormatMMSS(sec)
	if not sec or sec < 0 then sec = 0 end
	sec = math.floor(sec + 0.5)
	return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Short calendar form for list rows ("05/17 14:32"). The history list is
-- account-wide and bounded at 20, so we don't bother with relative ("3 days
-- ago") formatting — the precise stamp is the most useful glance.
local function FormatShortDate(epoch)
	if not epoch or epoch <= 0 then return "?" end
	return date("%m/%d %H:%M", epoch)
end

local function FormatLongDate(epoch)
	if not epoch or epoch <= 0 then return "?" end
	return date("%Y-%m-%d %H:%M", epoch)
end

-- Mirrors MythicPlusHud's affix abbreviation rule:
--   * Tyrannical/Fortified collapse to T/F.
--   * Xal'atath sub-affixes ("Xal'atath's Bargain: Devour") collapse to the
--     last word ("Devour").
--   * Everything else returns nil (filtered out — Xal'atath's Guile etc.).
-- Inlined here rather than imported so RunHistory doesn't take a hard
-- ordering dependency on MythicPlusHud at file-load time.
local AFFIX_OVERRIDE = { [9] = "T", [10] = "F" }
local function ShortAffix(affixID)
	if not affixID or affixID == 0 then return nil end
	if AFFIX_OVERRIDE[affixID] then return AFFIX_OVERRIDE[affixID] end
	local name = C_ChallengeMode and C_ChallengeMode.GetAffixInfo and C_ChallengeMode.GetAffixInfo(affixID)
	if not name or name == "" then return nil end
	local tail = name:match(":%s*(.+)$")
	return tail
end

local function AffixDisplay(entry)
	if not entry or not entry.affixes then return "-" end
	local labels = {}
	for _, id in ipairs(entry.affixes) do
		local s = ShortAffix(id)
		if s then labels[#labels + 1] = s end
	end
	return (#labels > 0) and table.concat(labels, "/") or "-"
end

-- Status text + color for the run's outcome. Used in both the list and the
-- detail panel so the color encoding is consistent.
local function StatusInfo(entry)
	if not entry.completed then
		return "abandoned", 1.00, 0.40, 0.40
	end
	if entry.onTime then
		local upg = entry.upgradeLevels or 0
		if upg > 0 then return string.format("timed +%d", upg), 0.30, 1.00, 0.30 end
		return "timed", 0.30, 1.00, 0.30
	end
	return "over time", 1.00, 0.70, 0.30
end

-- ----------------------------------------------------------------------------
-- Window construction
--
-- Single PortraitFrameTemplate window split into:
--   * Left pane: vertical stack of run rows (newest first), clickable to
--     select. Stripe alpha alternates; selected row gets a tinted background.
--     20 max rows is also our storage cap, so no scroll needed.
--   * Right pane: detail view for the selected run — title with affixes, a
--     status/duration line, then a combat list (newest combat at top, capped
--     at MAX_COMBAT_ROWS).
--
-- Frame-strata level 2300 puts us above the keys (2000), loot (2100), and
-- debug (2200) windows, matching the "later-opened sits on top" intuition.
-- ----------------------------------------------------------------------------

local historyFrame
local selectedRunIdx  -- 1-based index into ns.db.runHistory (nil = none)
local runRows = {}
local combatRows = {}
local deathRows = {}

-- Forward decl so the OnEnter closure inside BuildCombatRow (defined below)
-- can capture this upvalue. The actual function body is assigned further
-- down once its dependencies (ClassRGB, FormatMMSS) are also in scope.
local ShowEntryCombatDeathsTooltip

local WINDOW_W           = 760
local WINDOW_H           = 700
local LEFT_PANE_W        = 360
local LEFT_PANE_X        = 14
local RIGHT_PANE_X       = LEFT_PANE_X + LEFT_PANE_W + 8
local PANES_TOP_Y        = -64
local PANES_BOTTOM_PAD   = 40   -- room for the Close button
local RUN_ROW_HEIGHT     = 22
local MAX_RUN_ROWS       = MAX_RUNS
local COMBAT_ROW_HEIGHT  = 16
local MAX_COMBAT_ROWS    = 20  -- truncated past this with a "+N more" hint
local DEATH_ROW_HEIGHT   = 14
local MAX_DEATH_ROWS     = 14  -- same truncation hint pattern

-- Per-row column geometry for combat rows (mirrors MythicPlusHud's expanded
-- panel so the visual identity carries over). x offsets are relative to the
-- row's LEFT.
local C_NAME_X          = 4
local C_NAME_W          = 64
local C_SKULL_X         = 72
local C_FORCES_ICON_X   = 88
local C_FORCES_KILLED_W = 22
local C_FORCES_PCT_W    = 40
local C_TIME_ICON_X     = 180
local C_TIME_START_W    = 38
local C_TIME_DUR_W      = 50
-- Death cell mirrors MythicPlusHud's expanded panel layout (same x).
local C_DEATH_ICON_X    = 296
local C_DEATH_COUNT_W   = 20
local C_ICON_GAP        = 3
local C_PAREN_GAP       = 3
local CELL_ICON_SIZE    = 11

local SKULL_TEX  = "Interface\\TARGETINGFRAME\\UI-TargetingFrame-Skull"
local FORCES_TEX = "Interface\\Icons\\INV_Sword_04"
local TIME_TEX   = "Interface\\Icons\\INV_Misc_PocketWatch_01"

local FORCES_RGB = { 0.40, 0.95, 0.50 }
local AFFIX_RGB  = { 1.00, 0.65, 0.40 }
local DEATHS_RGB = { 1.00, 0.40, 0.40 }

local RenderRunsList, RenderDetail  -- forward decls

local function SelectRun(idx)
	selectedRunIdx = idx
	if RenderRunsList then RenderRunsList() end
	if RenderDetail then RenderDetail() end
end

local function BuildRunRow(parent, slot)
	-- Button so clicks select the row.
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(LEFT_PANE_W - 4, RUN_ROW_HEIGHT)
	row:RegisterForClicks("LeftButtonUp")

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(RUN_ROW_HEIGHT - 4, RUN_ROW_HEIGHT - 4)
	row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.name:SetWidth(168)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	-- Status takes a fixed slot; color set in render.
	row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.status:SetPoint("LEFT", row, "LEFT", 200, 0)
	row.status:SetWidth(76)
	row.status:SetJustifyH("LEFT")
	row.status:SetWordWrap(false)

	row.date = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.date:SetPoint("RIGHT", row, "RIGHT", -6, 0)
	row.date:SetWidth(76)
	row.date:SetJustifyH("RIGHT")

	row:SetScript("OnClick", function(self)
		if self.entryIdx then SelectRun(self.entryIdx) end
	end)

	row:Hide()
	return row
end

local function BuildCombatRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(COMBAT_ROW_HEIGHT)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetPoint("LEFT", C_NAME_X, 0)
	row.name:SetWidth(C_NAME_W)
	row.name:SetJustifyH("LEFT")
	row.name:SetTextColor(0.78, 0.78, 0.78, 1)

	row.skull = row:CreateTexture(nil, "OVERLAY")
	row.skull:SetTexture(SKULL_TEX)
	row.skull:SetSize(CELL_ICON_SIZE, CELL_ICON_SIZE)
	row.skull:SetPoint("LEFT", C_SKULL_X, 0)
	row.skull:Hide()

	row.forcesIcon = row:CreateTexture(nil, "OVERLAY")
	row.forcesIcon:SetTexture(FORCES_TEX)
	row.forcesIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	row.forcesIcon:SetSize(CELL_ICON_SIZE, CELL_ICON_SIZE)
	row.forcesIcon:SetPoint("LEFT", C_FORCES_ICON_X, 0)

	row.forcesKilled = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.forcesKilled:SetPoint("LEFT", row.forcesIcon, "RIGHT", C_ICON_GAP, 0)
	row.forcesKilled:SetWidth(C_FORCES_KILLED_W)
	row.forcesKilled:SetJustifyH("RIGHT")
	row.forcesKilled:SetTextColor(FORCES_RGB[1], FORCES_RGB[2], FORCES_RGB[3], 1)

	row.forcesPct = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.forcesPct:SetPoint("LEFT", row.forcesKilled, "RIGHT", C_PAREN_GAP, 0)
	row.forcesPct:SetWidth(C_FORCES_PCT_W)
	row.forcesPct:SetJustifyH("LEFT")
	row.forcesPct:SetTextColor(FORCES_RGB[1], FORCES_RGB[2], FORCES_RGB[3], 1)

	row.timeIcon = row:CreateTexture(nil, "OVERLAY")
	row.timeIcon:SetTexture(TIME_TEX)
	row.timeIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	row.timeIcon:SetSize(CELL_ICON_SIZE, CELL_ICON_SIZE)
	row.timeIcon:SetPoint("LEFT", C_TIME_ICON_X, 0)

	row.timeStart = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.timeStart:SetPoint("LEFT", row.timeIcon, "RIGHT", C_ICON_GAP, 0)
	row.timeStart:SetWidth(C_TIME_START_W)
	row.timeStart:SetJustifyH("RIGHT")
	row.timeStart:SetTextColor(1, 1, 1, 1)

	row.timeDur = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.timeDur:SetPoint("LEFT", row.timeStart, "RIGHT", C_PAREN_GAP, 0)
	row.timeDur:SetWidth(C_TIME_DUR_W)
	row.timeDur:SetJustifyH("LEFT")
	row.timeDur:SetTextColor(1, 1, 1, 1)

	-- Death cell mirrors the HUD panel: red-tinted skull + count, hidden when
	-- the combat had no deaths. Attribution is by elapsed-time window so the
	-- count matches whatever the HUD showed live.
	row.deathIcon = row:CreateTexture(nil, "OVERLAY")
	row.deathIcon:SetTexture(SKULL_TEX)
	row.deathIcon:SetVertexColor(1.00, 0.35, 0.35, 1)
	row.deathIcon:SetSize(CELL_ICON_SIZE, CELL_ICON_SIZE)
	row.deathIcon:SetPoint("LEFT", C_DEATH_ICON_X, 0)
	row.deathIcon:Hide()

	row.deathCount = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.deathCount:SetPoint("LEFT", row.deathIcon, "RIGHT", C_ICON_GAP, 0)
	row.deathCount:SetWidth(C_DEATH_COUNT_W)
	row.deathCount:SetJustifyH("LEFT")
	row.deathCount:SetTextColor(DEATHS_RGB[1], DEATHS_RGB[2], DEATHS_RGB[3], 1)
	row.deathCount:Hide()

	-- Hover area covering icon + count. RenderDetail stashes the entry, the
	-- combat, and its 1-based index on the row so the tooltip handler
	-- resolves the per-combat death list at hover time.
	row.deathHover = CreateFrame("Frame", nil, row)
	row.deathHover:SetPoint("LEFT",   row.deathIcon,  "LEFT",   0, 0)
	row.deathHover:SetPoint("RIGHT",  row.deathCount, "RIGHT",  0, 0)
	row.deathHover:SetPoint("TOP",    row.deathIcon,  "TOP",    0, 2)
	row.deathHover:SetPoint("BOTTOM", row.deathIcon,  "BOTTOM", 0, -2)
	row.deathHover:EnableMouse(true)
	row.deathHover:SetScript("OnEnter", function(self)
		local r = self:GetParent()
		ShowEntryCombatDeathsTooltip(self, r._entry, r._combat, r._combatIdx)
	end)
	row.deathHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row.deathHover:Hide()

	row:Hide()
	return row
end

-- Counts deaths in `entry` that fall within combat `c`'s elapsed-time window
-- [startElapsed, startElapsed + duration]. Same math as MythicPlusHud's
-- DeathsInCombat so the live HUD and saved history attribute identically.
local function DeathsInCombat(entry, c)
	if not entry or not entry.deaths or not c then return 0 end
	local startE = c.startElapsed or 0
	local endE   = startE + (c.duration or 0)
	local n = 0
	for _, d in ipairs(entry.deaths) do
		if d.elapsed and d.elapsed >= startE and d.elapsed <= endE then
			n = n + 1
		end
	end
	return n
end

-- A single row in the deaths subsection: class-colored name on the left,
-- elapsed time on the right. Two fontstrings only; no icon since the section
-- header already carries the red-skull identity.
local D_NAME_X    = 4
local D_NAME_W    = 180
local D_TIME_W    = 56

local function BuildDeathRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(DEATH_ROW_HEIGHT)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", D_NAME_X, 0)
	row.name:SetWidth(D_NAME_W)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row.time = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.time:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
	row.time:SetWidth(D_TIME_W)
	row.time:SetJustifyH("LEFT")

	row:Hide()
	return row
end

-- Class-color hex prefix for a death name. Falls back to a neutral grey when
-- the saved class is missing (unknown spec, lookup miss at death time).
local function ClassColorPrefix(class)
	if not class then return "|cffcccccc" end
	local c = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
	if not c then return "|cffcccccc" end
	return string.format("|cff%02x%02x%02x", math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255))
end

-- RGB triple for GameTooltip color args (class-keyed). Mirrors the prefix
-- helper above but in numeric form for AddDoubleLine / AddLine call sites.
local function ClassRGB(class)
	if not class then return 0.80, 0.80, 0.80 end
	local c = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
	if not c then return 0.80, 0.80, 0.80 end
	return c.r, c.g, c.b
end

-- Tooltip helper for the per-combat death icon. Lists each death whose
-- elapsed timestamp falls inside the combat's [start, start+duration]
-- window, in chronological order, class-colored. Assigned (not declared)
-- so the forward-decl upvalue at top-of-file gets bound, letting
-- BuildCombatRow's OnEnter closure reach it.
ShowEntryCombatDeathsTooltip = function(anchor, entry, combat, combatIdx)
	if not entry or not combat then return end
	GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
	GameTooltip:AddLine(string.format("Deaths in Combat %d", combatIdx or 0), 1, 0.82, 0)
	local ds = entry.deaths or {}
	local startE = combat.startElapsed or 0
	local endE   = startE + (combat.duration or 0)
	local any = false
	for _, d in ipairs(ds) do
		if d.elapsed and d.elapsed >= startE and d.elapsed <= endE then
			local r, g, b = ClassRGB(d.class)
			GameTooltip:AddDoubleLine(d.name or "?", FormatMMSS(d.elapsed), r, g, b, 1, 1, 1)
			any = true
		end
	end
	if not any then GameTooltip:AddLine("(no deaths)", 0.7, 0.7, 0.7) end
	GameTooltip:Show()
end

local function BuildHistoryFrame()
	if historyFrame then return historyFrame end

	-- Anonymous + parented to the container. Same pattern as the other
	-- SeanKeys windows; ESC routes through the container's OnHide.
	local f = CreateFrame("Frame", nil, ns.GetContainer(), "PortraitFrameTemplate")
	ns.RegisterWindow(f)
	f:SetSize(WINDOW_W, WINDOW_H)
	f:SetPoint("CENTER")
	f:SetFrameStrata("MEDIUM")
	-- 2300 keeps this above the keys (2000), loot (2100), and debug (2200)
	-- windows. PromoteFrameLevels is the depth-based collapser that prevents
	-- template chrome from sticking up into the next window's range.
	ns.PromoteFrameLevels(f, 2300)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	if f.SetTitle then f:SetTitle("SeanKeys Run History")
	elseif f.TitleText then f.TitleText:SetText("SeanKeys Run History") end
	if f.SetPortraitToAsset then f:SetPortraitToAsset(525134)
	elseif f.portrait then f.portrait:SetTexture(525134) end
	if f.Inset and f.Inset.Bg then f.Inset.Bg:SetAlpha(0.7) end
	f:Hide()

	-- Left pane: run rows + section header
	local leftHdr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	leftHdr:SetPoint("TOPLEFT", LEFT_PANE_X, -44)
	leftHdr:SetText("|cffffcc00RUNS|r")
	f.leftHdr = leftHdr

	f.runListEmpty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.runListEmpty:SetPoint("TOPLEFT", LEFT_PANE_X + 8, PANES_TOP_Y)
	f.runListEmpty:SetText("(no runs recorded yet)")
	f.runListEmpty:Hide()

	for i = 1, MAX_RUN_ROWS do
		runRows[i] = BuildRunRow(f, i)
	end

	-- Right pane: detail view
	local rightHdr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	rightHdr:SetPoint("TOPLEFT", RIGHT_PANE_X, -44)
	rightHdr:SetText("|cffffcc00DETAIL|r")
	f.rightHdr = rightHdr

	-- A separator between the two panes (subtle vertical gold line, matching
	-- the section dividers in the main list).
	local divider = f:CreateTexture(nil, "ARTWORK")
	divider:SetWidth(1)
	divider:SetPoint("TOPLEFT", LEFT_PANE_X + LEFT_PANE_W + 3, -44)
	divider:SetPoint("BOTTOMLEFT", LEFT_PANE_X + LEFT_PANE_W + 3, PANES_BOTTOM_PAD)
	divider:SetColorTexture(0.6, 0.5, 0.2, 0.4)

	local detail = CreateFrame("Frame", nil, f)
	detail:SetPoint("TOPLEFT", RIGHT_PANE_X, PANES_TOP_Y)
	detail:SetPoint("BOTTOMRIGHT", -14, PANES_BOTTOM_PAD)
	f.detail = detail

	detail.title = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	detail.title:SetPoint("TOPLEFT", 0, 0)
	detail.title:SetJustifyH("LEFT")
	detail.title:SetWordWrap(false)

	detail.affixes = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	detail.affixes:SetPoint("TOPLEFT", 0, -20)
	detail.affixes:SetJustifyH("LEFT")
	detail.affixes:SetTextColor(AFFIX_RGB[1], AFFIX_RGB[2], AFFIX_RGB[3], 1)

	detail.meta = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	detail.meta:SetPoint("TOPLEFT", 0, -38)
	detail.meta:SetJustifyH("LEFT")

	detail.status = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	detail.status:SetPoint("TOPLEFT", 0, -54)
	detail.status:SetJustifyH("LEFT")

	detail.combatsHdr = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	detail.combatsHdr:SetPoint("TOPLEFT", 0, -78)
	detail.combatsHdr:SetText("|cffffcc00COMBATS|r")

	detail.combatsTopY = -94  -- top y of the first combat row inside `detail`

	for i = 1, MAX_COMBAT_ROWS do
		combatRows[i] = BuildCombatRow(detail)
	end

	detail.empty = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	detail.empty:SetPoint("TOPLEFT", 8, detail.combatsTopY)
	detail.empty:SetText("(no combats recorded for this run)")
	detail.empty:Hide()

	-- "+N more combats" hint shown when the run had more combats than fit
	-- in MAX_COMBAT_ROWS. RenderDetail positions it just under the last
	-- visible combat row.
	detail.combatsMore = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	detail.combatsMore:SetJustifyH("LEFT")
	detail.combatsMore:Hide()

	-- Deaths subsection: header (red), pre-built rows, and an empty-state
	-- hint. RenderDetail anchors the header just below the combats block
	-- and stacks the rows under it.
	detail.deathsHeader = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	detail.deathsHeader:SetText("|cffff6666DEATHS|r")
	detail.deathsHeader:Hide()

	for i = 1, MAX_DEATH_ROWS do
		deathRows[i] = BuildDeathRow(detail)
	end

	detail.deathsEmpty = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	detail.deathsEmpty:SetText("(no deaths)")
	detail.deathsEmpty:Hide()

	detail.deathsMore = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	detail.deathsMore:SetJustifyH("LEFT")
	detail.deathsMore:Hide()

	-- Close button (the template provides one in the corner, but a labeled
	-- one at the bottom-right is more discoverable).
	local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	close:SetSize(80, 22)
	close:SetPoint("BOTTOMRIGHT", -14, 10)
	close:SetText("Close")
	close:SetScript("OnClick", function() f:Hide() end)

	historyFrame = f
	ns.runHistoryFrame = f
	return f
end

-- ----------------------------------------------------------------------------
-- Rendering
-- ----------------------------------------------------------------------------

RenderRunsList = function()
	if not historyFrame then return end
	local history = (ns.db and ns.db.runHistory) or {}
	local n = #history

	if n == 0 then
		historyFrame.runListEmpty:Show()
	else
		historyFrame.runListEmpty:Hide()
	end

	for i = 1, MAX_RUN_ROWS do
		local row = runRows[i]
		-- Newest first: list slot i shows array index (n - i + 1).
		local idx = n - i + 1
		if idx >= 1 then
			local entry = history[idx]
			row.entryIdx = idx
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", historyFrame, "TOPLEFT", LEFT_PANE_X, PANES_TOP_Y - (i - 1) * RUN_ROW_HEIGHT)

			row.name:SetText(string.format("%s |cffffd000+%d|r", entry.name or "?", entry.level or 0))
			row.date:SetText(FormatShortDate(entry.endEpoch))

			local status, r, g, b = StatusInfo(entry)
			row.status:SetText(status)
			row.status:SetTextColor(r, g, b, 1)

			if entry.mapID then
				local _, _, _, tex = C_ChallengeMode.GetMapUIInfo(entry.mapID)
				if tex then
					row.icon:SetTexture(tex)
					row.icon:Show()
				else
					row.icon:Hide()
				end
			else
				row.icon:Hide()
			end

			if selectedRunIdx == idx then
				row.bg:SetColorTexture(0.30, 0.40, 0.70, 0.40)
			else
				row.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.06 or 0.02)
			end
			row:Show()
		else
			row.entryIdx = nil
			row:Hide()
		end
	end
end

RenderDetail = function()
	if not historyFrame then return end
	local detail = historyFrame.detail
	local history = (ns.db and ns.db.runHistory) or {}
	local entry = selectedRunIdx and history[selectedRunIdx]

	if not entry then
		detail.title:SetText("|cff888888(select a run)|r")
		detail.affixes:SetText("")
		detail.meta:SetText("")
		detail.status:SetText("")
		detail.empty:Hide()
		detail.combatsMore:Hide()
		detail.deathsHeader:Hide()
		detail.deathsEmpty:Hide()
		detail.deathsMore:Hide()
		for i = 1, MAX_COMBAT_ROWS do combatRows[i]:Hide() end
		for i = 1, MAX_DEATH_ROWS do deathRows[i]:Hide() end
		return
	end

	detail.title:SetText(string.format("%s |cffffd000+%d|r", entry.name or "?", entry.level or 0))
	detail.affixes:SetText("Affixes: " .. AffixDisplay(entry))

	local owner = entry.player or "?"
	detail.meta:SetText(string.format("%s    |cffaaaaaa%s|r", FormatLongDate(entry.endEpoch), owner))

	local status, r, g, b = StatusInfo(entry)
	local totalDeaths = entry.deaths and #entry.deaths or 0
	detail.status:SetText(string.format("%s   |cffffffff%s|r   |cffff6666%d %s|r",
		status, FormatMMSS(entry.duration), totalDeaths, (totalDeaths == 1) and "death" or "deaths"))
	detail.status:SetTextColor(r, g, b, 1)

	local combats = entry.combats or {}
	local tl = entry.timeLimit or 0
	local forcesTotal = entry.forcesTotal or 0
	local shown = 0
	for i = #combats, 1, -1 do
		shown = shown + 1
		if shown > MAX_COMBAT_ROWS then break end
		local c = combats[i]
		local row = combatRows[shown]
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT",  detail, "TOPLEFT",  0, detail.combatsTopY - (shown - 1) * COMBAT_ROW_HEIGHT)
		row:SetPoint("TOPRIGHT", detail, "TOPRIGHT", 0, detail.combatsTopY - (shown - 1) * COMBAT_ROW_HEIGHT)

		row.name:SetText("Combat " .. i)

		if c.boss then row.skull:Show() else row.skull:Hide() end

		-- Prefer the per-combat forcesTotal that was snapshotted at the time
		-- of that combat — the run-level forcesTotal can be 0 on entries
		-- captured before the snap-time max-cache fix landed.
		local killed = c.forcesKilled or 0
		local total  = c.forcesTotal or forcesTotal or 0
		row.forcesKilled:SetText(tostring(killed))
		if total > 0 then
			local pct = math.floor((killed / total) * 100 + 0.5)
			row.forcesPct:SetText(string.format("(%d%%)", pct))
		else
			row.forcesPct:SetText("")
		end

		local timeRemAtStart = math.max(0, tl - (c.startElapsed or 0))
		row.timeStart:SetText(FormatMMSS(timeRemAtStart))
		row.timeDur:SetText(string.format("(%s)", FormatMMSS(c.duration or 0)))

		row._entry     = entry
		row._combat    = c
		row._combatIdx = i

		local nDeaths = DeathsInCombat(entry, c)
		if nDeaths > 0 then
			row.deathCount:SetText(tostring(nDeaths))
			row.deathIcon:Show()
			row.deathCount:Show()
			row.deathHover:Show()
		else
			row.deathIcon:Hide()
			row.deathCount:Hide()
			row.deathHover:Hide()
		end

		row:Show()
	end
	for i = shown + 1, MAX_COMBAT_ROWS do combatRows[i]:Hide() end

	if shown == 0 then detail.empty:Show() else detail.empty:Hide() end

	-- Compute the y just below the last combat row (or the empty hint).
	local combatsEndY = detail.combatsTopY - shown * COMBAT_ROW_HEIGHT
	if shown == 0 then combatsEndY = detail.combatsTopY - COMBAT_ROW_HEIGHT end

	-- "+N more combats" hint when the run had more than MAX_COMBAT_ROWS.
	local extraCombats = #combats - shown
	if extraCombats > 0 then
		detail.combatsMore:ClearAllPoints()
		detail.combatsMore:SetPoint("TOPLEFT", 8, combatsEndY)
		detail.combatsMore:SetText(string.format("(+%d earlier combats not shown)", extraCombats))
		detail.combatsMore:Show()
		combatsEndY = combatsEndY - DEATH_ROW_HEIGHT
	else
		detail.combatsMore:Hide()
	end

	-- DEATHS header anchored just below the combats block, with a small gap.
	local deathsHeaderY = combatsEndY - 6
	detail.deathsHeader:ClearAllPoints()
	detail.deathsHeader:SetPoint("TOPLEFT", 0, deathsHeaderY)
	detail.deathsHeader:Show()

	local deathRowsTopY = deathsHeaderY - 14
	local deaths = entry.deaths or {}

	if #deaths == 0 then
		detail.deathsEmpty:ClearAllPoints()
		detail.deathsEmpty:SetPoint("TOPLEFT", 8, deathRowsTopY)
		detail.deathsEmpty:Show()
		detail.deathsMore:Hide()
		for i = 1, MAX_DEATH_ROWS do deathRows[i]:Hide() end
		return
	end
	detail.deathsEmpty:Hide()

	-- Deaths rendered in chronological order (earliest at top). They're
	-- already chronological in `entry.deaths` since the HUD appends in
	-- time order. Truncate at MAX_DEATH_ROWS with a "+N more" footer.
	local dShown = 0
	for i = 1, #deaths do
		dShown = dShown + 1
		if dShown > MAX_DEATH_ROWS then break end
		local d = deaths[i]
		local row = deathRows[dShown]
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT",  detail, "TOPLEFT",  0, deathRowsTopY - (dShown - 1) * DEATH_ROW_HEIGHT)
		row:SetPoint("TOPRIGHT", detail, "TOPRIGHT", 0, deathRowsTopY - (dShown - 1) * DEATH_ROW_HEIGHT)
		row.name:SetText(string.format("%s%s|r", ClassColorPrefix(d.class), d.name or "?"))
		row.time:SetText(FormatMMSS(d.elapsed or 0))
		row:Show()
	end
	for i = dShown + 1, MAX_DEATH_ROWS do deathRows[i]:Hide() end

	local extraDeaths = #deaths - dShown
	if extraDeaths > 0 then
		detail.deathsMore:ClearAllPoints()
		detail.deathsMore:SetPoint("TOPLEFT", 8, deathRowsTopY - dShown * DEATH_ROW_HEIGHT)
		detail.deathsMore:SetText(string.format("(+%d more)", extraDeaths))
		detail.deathsMore:Show()
	else
		detail.deathsMore:Hide()
	end
end

local function Show()
	-- securecallfunction wrap on first build: the lazy PortraitFrameTemplate
	-- creation happens on whatever click chain triggered Show, which is
	-- exactly the kind of context where SeanKeys-tainted state can leak into
	-- the template's chrome registration. Same defensive pattern as the
	-- other lazily-built SeanKeys windows.
	if not historyFrame then securecallfunction(BuildHistoryFrame) end
	if not historyFrame then return end

	-- Default selection: most recent run (last array slot).
	local history = (ns.db and ns.db.runHistory) or {}
	if not selectedRunIdx or not history[selectedRunIdx] then
		selectedRunIdx = (#history > 0) and #history or nil
	end

	RenderRunsList()
	RenderDetail()
	ns.GetContainer():Show()
	historyFrame:Show()
end

ns.RunHistory = {
	Init   = Init,
	Append = Append,
}
ns.ShowRunHistory = Show
