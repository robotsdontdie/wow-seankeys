local ADDON_NAME, ns = ...

-- ============================================================================
-- Core: debug log, name helpers, color/icon helpers, score estimation.
-- These have no dependencies on other SeanKeys files and are used everywhere.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Debug log
-- ----------------------------------------------------------------------------

local debugLog = {}
local MAX_DEBUG_LINES = 500

local function Dbg(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do parts[i] = tostring(select(i, ...)) end
	local line = string.format("[%s] %s", date("%H:%M:%S"), table.concat(parts, " "))
	debugLog[#debugLog + 1] = line
	if #debugLog > MAX_DEBUG_LINES then
		table.remove(debugLog, 1)
	end
end

local debugFrame

-- Build-only path; idempotent. Exposed so SeanKeys.lua can pre-build at
-- PLAYER_LOGIN inside securecallfunction (clean execution context for the
-- UISpecialFrames mutation + PortraitFrameTemplate chrome). Without this,
-- the very first /sk debug or /sk levels click would do all that
-- frame-creation work inside whatever click chain triggered it.
local function BuildDebugWindow()
	if debugFrame then return debugFrame end
	local f = CreateFrame("Frame", "SeanKeysDebugFrame", UIParent, "PortraitFrameTemplate")
	tinsert(UISpecialFrames, "SeanKeysDebugFrame")  -- ESC closes
	f:SetSize(640, 440)
	f:SetPoint("CENTER")
	f:SetFrameStrata("MEDIUM")
	-- Highest of the three SeanKeys windows so the debug log can sit above
	-- both the keys and loot windows. PromoteFrameLevels also bumps the
	-- template children so the portrait/close button don't get hidden
	-- behind the keys window. See PromoteFrameLevels in this file for
	-- why a plain SetFrameLevel on the parent is insufficient.
	ns.PromoteFrameLevels(f, 2200)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	if f.SetTitle then f:SetTitle("SeanKeys Debug Log") elseif f.TitleText then f.TitleText:SetText("SeanKeys Debug Log") end
	if f.SetPortraitToAsset then f:SetPortraitToAsset(133743) end -- generic scroll icon
	if f.Inset and f.Inset.Bg then f.Inset.Bg:SetAlpha(0.7) end
	f:Hide()

	local sf = CreateFrame("ScrollFrame", "SeanKeysDebugScroll", f, "UIPanelScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 14, -28)
	sf:SetPoint("BOTTOMRIGHT", -36, 32)

	local eb = CreateFrame("EditBox", nil, sf)
	eb:SetMultiLine(true)
	eb:SetAutoFocus(false)
	eb:SetFontObject(ChatFontNormal)
	eb:SetWidth(560)
	eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
	sf:SetScrollChild(eb)
	f.editBox = eb
	f.scrollFrame = sf

	local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	refresh:SetSize(80, 22)
	refresh:SetPoint("BOTTOMRIGHT", -14, 6)
	refresh:SetText("Refresh")
	refresh:SetScript("OnClick", function() ns.ShowDebugWindow() end)

	local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	clear:SetSize(80, 22)
	clear:SetPoint("RIGHT", refresh, "LEFT", -4, 0)
	clear:SetText("Clear")
	clear:SetScript("OnClick", function()
		wipe(debugLog)
		f.editBox:SetText("")
	end)

	f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.hint:SetPoint("BOTTOMLEFT", 14, 12)
	f.hint:SetText("Select text and press Ctrl+C to copy.")

	debugFrame = f
	return f
end

local function ShowDebugWindow()
	BuildDebugWindow()
	debugFrame.editBox:SetText(table.concat(debugLog, "\n"))
	debugFrame:Show()
	C_Timer.After(0, function()
		-- scroll to bottom after Blizzard recalculates content height
		local sf = debugFrame.scrollFrame
		local maxScroll = sf:GetVerticalScrollRange()
		if maxScroll and maxScroll > 0 then sf:SetVerticalScroll(maxScroll) end
	end)
end

ns.Dbg = Dbg
ns.BuildDebugWindow = BuildDebugWindow
ns.ShowDebugWindow = ShowDebugWindow

-- ----------------------------------------------------------------------------
-- Frame-level promotion
-- ----------------------------------------------------------------------------

-- Lift a frame and every descendant to a controlled, tightly-packed level
-- range starting at `baseLevel` — used to keep all three SeanKeys windows
-- above MEDIUM-strata addon overlays without falling foul of two surprises:
--
-- 1. `PortraitFrameTemplate` builds its child frames (PortraitContainer,
--    CloseButton, NineSliceFrame, TitleContainer) at absolute levels in the
--    2300-2530 range, with slightly different bases per instance. A plain
--    additive offset on the parent leaves the chrome at 4000+ and our
--    later-added rows at parent+1 (~2001). Two SeanKeys windows then
--    interleave: each window's chrome (~4500) covers the other window's
--    content (~2001/~2021) but not each other.
--    Fix: depth-based reassignment — parent at baseLevel, depth-1 children
--    at +10, depth-2 at +20, etc. Spacing windows 100 apart guarantees
--    every level of one window sits cleanly above the previous window.
--
-- 2. Inside the template, `CloseButton` was originally one level above its
--    sibling `NineSliceFrame` (2509 vs 2499) so the X icon rendered on top
--    of the border art. Flattening collapses both to the same level (+10);
--    the border then wins the render-order tiebreaker and the X disappears.
--    Fix: after the depth-based pass, explicitly bump `frame.CloseButton`
--    above the rest of the chrome.
--
-- Both fixes are taint-safe: we only set levels on frames we own, no
-- sibling enumeration (unlike `:Raise()`).
function ns.PromoteFrameLevels(frame, baseLevel)
	if not frame or not frame.GetFrameLevel then return end
	local rootName = frame:GetName() or "(unnamed)"
	Dbg(string.format("PromoteFrameLevels: root=%s baseLevel=%d", rootName, baseLevel))
	local count, maxDepth = 0, 0
	local function recurse(f, depth)
		count = count + 1
		if depth > maxDepth then maxDepth = depth end
		f:SetFrameLevel(baseLevel + depth * 10)
		if f.GetChildren then
			local children = { f:GetChildren() }
			for i = 1, #children do recurse(children[i], depth + 1) end
		end
	end
	recurse(frame, 0)
	-- Lift the close button (and its subtree) above the rest of the chrome
	-- so the X icon isn't covered by the NineSlice border at the same level.
	if frame.CloseButton then
		local closeBase = baseLevel + 50
		local function lift(f, depth)
			f:SetFrameLevel(closeBase + depth * 10)
			if f.GetChildren then
				local children = { f:GetChildren() }
				for i = 1, #children do lift(children[i], depth + 1) end
			end
		end
		lift(frame.CloseButton, 0)
		Dbg(string.format("PromoteFrameLevels: %s.CloseButton -> %d", rootName, closeBase))
	end
	Dbg(string.format("PromoteFrameLevels: %s -> %d frames, max depth %d, max level %d",
		rootName, count, maxDepth, baseLevel + maxDepth * 10))
end

-- Dumps the current frame-level state of a window's entire subtree to the
-- debug log. Use after the window has been built and any other addons have
-- had a chance to muck with levels — helps confirm our promotion stuck.
function ns.DumpFrameLevels(frame)
	if not frame or not frame.GetFrameLevel then
		Dbg("DumpFrameLevels: no frame")
		return
	end
	local rootName = frame:GetName() or "(unnamed)"
	Dbg(string.format("DumpFrameLevels: root=%s strata=%s level=%d",
		rootName, frame:GetFrameStrata(), frame:GetFrameLevel()))
	local count = 0
	local function recurse(f, depth)
		count = count + 1
		local name = f.GetName and f:GetName() or "(unnamed)"
		Dbg(string.format("  %s%s: strata=%s level=%d shown=%s",
			string.rep("  ", depth), name,
			f.GetFrameStrata and f:GetFrameStrata() or "?",
			f.GetFrameLevel and f:GetFrameLevel() or -1,
			tostring(f.IsShown and f:IsShown())))
		if f.GetChildren then
			local children = { f:GetChildren() }
			for i = 1, #children do recurse(children[i], depth + 1) end
		end
	end
	recurse(frame, 0)
	Dbg(string.format("DumpFrameLevels: visited %d frames", count))
end

-- ----------------------------------------------------------------------------
-- Raider.IO URL + copy popup
-- ----------------------------------------------------------------------------

local REGION_SLUG = { [1] = "us", [2] = "kr", [3] = "eu", [4] = "tw", [5] = "cn" }

local function RealmSlug(realm)
	if not realm or realm == "" then return "" end
	return realm:gsub("'", ""):gsub(" ", "-"):lower()
end

local function RaiderIOUrl(fullName)
	if not fullName or fullName == "" then return nil end
	local name, realm = strsplit("-", fullName, 2)
	if not realm or realm == "" then realm = GetRealmName() end
	local region = REGION_SLUG[GetCurrentRegion()] or "us"
	return string.format("https://raider.io/characters/%s/%s/%s", region, RealmSlug(realm), name)
end

StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs["SEANKEYS_COPY_URL"] = {
	text = "Raider.IO URL (Ctrl+C to copy):",
	button1 = OKAY,
	hasEditBox = true,
	editBoxWidth = 350,
	OnShow = function(self, data)
		local eb = self.EditBox or self.editBox
		if eb then
			eb:SetText(data or "")
			eb:HighlightText()
			eb:SetFocus()
		end
	end,
	EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0, whileDead = true, hideOnEscape = true,
}

ns.RaiderIOUrl = RaiderIOUrl

-- ----------------------------------------------------------------------------
-- Name + dungeon + spec/class helpers
-- ----------------------------------------------------------------------------

local function NormalizeName(name)
	if not name or name == "" then return nil end
	return Ambiguate(name, "none")
end

-- Canonical "Name-Realm" form used as the account-wide cache key. Inputs may be
-- short ("Name", same realm) or long ("Name-Realm", cross-realm); we always
-- expand to long form so that alts cached on Realm A can be found from Realm B.
local function FullName(name)
	if not name or name == "" then return nil end
	if name:find("-") then return name end
	local realm = GetNormalizedRealmName()
	if not realm or realm == "" then
		realm = (GetRealmName() or ""):gsub("[%s'%-]", "")
	end
	if realm == "" then return name end
	return name .. "-" .. realm
end

local function GetDungeonName(challengeMapID)
	if not challengeMapID or challengeMapID == 0 then return "(no key)" end
	local name = C_ChallengeMode.GetMapUIInfo(challengeMapID)
	return name or ("Map " .. challengeMapID)
end

local function ClassFromSpec(specID)
	if not specID or specID == 0 then return nil end
	local _, _, _, _, _, class = GetSpecializationInfoByID(specID)
	return class
end

local function SpecName(specID)
	if not specID or specID == 0 then return nil end
	local _, name = GetSpecializationInfoByID(specID)
	return name
end

local function GetClassColor(class)
	if not class then return 0.8, 0.8, 0.8 end
	local c = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
	if c then return c.r, c.g, c.b end
	return 0.8, 0.8, 0.8
end

-- TODO optionally introduce key level colors
local function KeyLevelColor(level)
	return 1.0, 1.0, 1.0
end

local ROLE_TEX = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"
local ROLE_TEXCOORDS = {
	TANK    = {0,      0.296875, 0.34375,  0.640625},
	HEALER  = {0.3125, 0.609375, 0.015625, 0.3125},
	DAMAGER = {0.3125, 0.609375, 0.34375,  0.640625},
}
local function SetRoleIcon(tex, role)
	if not role or role == "NONE" or role == "" then
		tex:Hide()
		return
	end
	local c = ROLE_TEXCOORDS[role]
	if not c then tex:Hide(); return end
	tex:SetTexture(ROLE_TEX)
	tex:SetTexCoord(c[1], c[2], c[3], c[4])
	tex:Show()
end

local function FormatDuration(ms)
	if not ms or ms <= 0 then return "?" end
	local sec = math.floor(ms / 1000)
	return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Lower-bound estimate of the dungeon score awarded for a par-time (just barely)
-- timed run at the given key level. Source: MrMythical M+ score calculator
-- (Midnight S1 formula).
--
--   base = 155 + 15 * (level - 2)
--   plus +15 cumulatively at L>=5, L>=7, L>=10, L>=12 ("breakpoint" affix tiers)
--
-- A time bonus of up to +15 (linear, 0->40% under par) stacks on top of this,
-- so this is a true minimum for a timed completion.
local function EstimateMinTimedScore(level)
	if not level or level < 2 then return 0 end
	local score = 155 + 15 * (level - 2)
	if level >= 5  then score = score + 15 end
	if level >= 7  then score = score + 15 end
	if level >= 10 then score = score + 15 end
	if level >= 12 then score = score + 15 end
	return score
end

ns.NormalizeName = NormalizeName
ns.FullName = FullName
ns.GetDungeonName = GetDungeonName
ns.ClassFromSpec = ClassFromSpec
ns.SpecName = SpecName
ns.GetClassColor = GetClassColor
ns.KeyLevelColor = KeyLevelColor
ns.SetRoleIcon = SetRoleIcon
ns.FormatDuration = FormatDuration
ns.EstimateMinTimedScore = EstimateMinTimedScore
