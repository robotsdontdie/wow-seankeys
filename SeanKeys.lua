local ADDON_NAME, ns = ...

-- ============================================================================
-- SeanKeys: cross-protocol keystone + spec aggregator with teleport UI.
--
-- Keystone protocols:
--   * LibKeystone ("LibKS")       - DBM, BigWigs, MDT, Keystone Hero, etc.
--   * LibOpenRaid ("LRS")          - Details, Plater, OmniCD (read-only)
--   * AstralKeys saved table       - read _G.AstralKeys directly
--
-- Spec / role:
--   * LibSpecialization ("LibSpec") - embedded; auto-broadcast + receive
--     Same library DBM/BigWigs use, so a single payload reaches everyone.
-- ============================================================================

local LKS = LibStub("LibKeystone", true)
local LSP = LibStub("LibSpecialization", true)

-- Current-season + recent teleport spells. [challengeMapID] = spellID.
local TELEPORT_SPELL_BY_CHALLENGEMAP = {
	-- Midnight Season 1 (12.0.x)
	[161] = 159898,  -- Skyreach
	[239] = 1254551, -- Seat of the Triumvirate
	[402] = 393273,  -- Algeth'ar Academy
	[556] = 1254555, -- Pit of Saron
	[557] = 1254400, -- Windrunner Spire
	[558] = 1254572, -- Magisters' Terrace
	[559] = 1254563, -- Nexus-Point Xenas
	[560] = 1254559, -- Maisara Caverns
	-- TWW S3 leftovers
	[542] = 1237215, -- Eco-Dome Al'dani
	[391] = 354465,  -- Halls of Atonement
	[525] = 1216786, -- Operation: Floodgate
	[503] = 445414,  -- The Dawnbreaker
	[499] = 445444,  -- Priory of the Sacred Flame
	[505] = 445417,  -- Ara-Kara, City of Echoes
	[392] = 367416,  -- Tazavesh, the Veiled Market
}

local db
local keys = {}                  -- normalizedName -> { level, mapID, rating, source, lastSeen, class, specID, role }
local selfDungeonBest = {}       -- challengeMapID -> { level, timed, mapScore }
local rows = {}
local mainFrame
local pendingButtonUpdates = {}  -- secure attribute updates queued for combat end

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
local function ShowDebugWindow()
	if not debugFrame then
		local f = CreateFrame("Frame", "SeanKeysDebugFrame", UIParent, "PortraitFrameTemplate")
		f:SetSize(640, 440)
		f:SetPoint("CENTER")
		f:SetFrameStrata("MEDIUM")
		f:SetToplevel(true)
		f:SetMovable(true)
		f:EnableMouse(true)
		f:SetClampedToScreen(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		if f.SetTitle then f:SetTitle("SeanKeys Debug Log") elseif f.TitleText then f.TitleText:SetText("SeanKeys Debug Log") end
		if f.SetPortraitToAsset then f:SetPortraitToAsset(133743) end -- generic scroll icon
		if f.Inset and f.Inset.Bg then f.Inset.Bg:SetAlpha(0.7) end

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
		refresh:SetScript("OnClick", function() ShowDebugWindow() end)

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
	end
	debugFrame.editBox:SetText(table.concat(debugLog, "\n"))
	debugFrame:Show()
	debugFrame:Raise()
	C_Timer.After(0, function()
		-- scroll to bottom after Blizzard recalculates content height
		local sf = debugFrame.scrollFrame
		local maxScroll = sf:GetVerticalScrollRange()
		if maxScroll and maxScroll > 0 then sf:SetVerticalScroll(maxScroll) end
	end)
end

ns.ShowDebugWindow = ShowDebugWindow
ns.Dbg = Dbg

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

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

local function NormalizeName(name)
	if not name or name == "" then return nil end
	return Ambiguate(name, "none")
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

local function KeyLevelColor(level)
	if not level or level < 2 then return 0.6, 0.6, 0.6 end
	if C_ChallengeMode and C_ChallengeMode.GetKeystoneLevelRarityColor then
		local col = C_ChallengeMode.GetKeystoneLevelRarityColor(level)
		if col then return col.r, col.g, col.b end
	end
	if level >= 20 then return 1.0, 0.5, 0.0
	elseif level >= 16 then return 0.64, 0.21, 0.93
	elseif level >= 10 then return 0.0, 0.44, 0.87
	else return 0.12, 1.0, 0.0 end
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

-- ----------------------------------------------------------------------------
-- Data store
-- ----------------------------------------------------------------------------

local function GetOrCreate(name)
	local entry = keys[name]
	if not entry then
		entry = { level = 0, mapID = 0, rating = 0, lastSeen = GetTime() }
		keys[name] = entry
	end
	return entry
end

local function UpsertKey(playerName, level, mapID, rating, source, class)
	local name = NormalizeName(playerName)
	if not name then return end
	local entry = GetOrCreate(name)
	level = level or 0
	mapID = mapID or 0

	local existingHasKey = (entry.level or 0) > 0
	local newHasKey = level > 0
	-- Don't overwrite a real key with a zero from a different source.
	if existingHasKey and not newHasKey and entry.source ~= source then
		-- skip key fields, but still refresh lastSeen
	else
		entry.level = level
		entry.mapID = mapID
		if rating and rating > 0 then entry.rating = rating end
		entry.source = source
	end
	entry.lastSeen = GetTime()
	if class and not entry.class then entry.class = class end

	if mainFrame and mainFrame:IsShown() then ns.Refresh() end
end

local function UpsertSpec(playerName, specID, role)
	local name = NormalizeName(playerName)
	if not name then return end
	local entry = GetOrCreate(name)
	if specID and specID > 0 then
		entry.specID = specID
		local cls = ClassFromSpec(specID)
		if cls then entry.class = cls end
	end
	if role and role ~= "" then entry.role = role end
	entry.lastSeen = GetTime()

	if mainFrame and mainFrame:IsShown() then ns.Refresh() end
end

-- ----------------------------------------------------------------------------
-- Protocol subscriptions
-- ----------------------------------------------------------------------------

local addonObject = {}

if LKS then
	LKS.Register(addonObject, function(level, mapID, rating, sender, channel)
		UpsertKey(sender, level, mapID, rating, "LibKeystone")
	end)
end

if LSP then
	-- callback signature: (specID, role, position, playerName, talents)
	local function OnSpec(specID, role, _, playerName)
		UpsertSpec(playerName, specID, role)
	end
	LSP.RegisterGroup(addonObject, OnSpec)
	LSP.RegisterGuild(addonObject, OnSpec)
end

local openRaidLib
local function BindLibOpenRaid()
	if openRaidLib then return end
	openRaidLib = LibStub:GetLibrary("LibOpenRaid-1.0", true)
	if not openRaidLib then return end

	function addonObject.OnKeystoneUpdate(unitName, info)
		if not info then return end
		local mapID = info.challengeMapID or info.mapID or 0
		local level = info.level or 0
		local rating = info.rating or 0
		local class = info.classID and select(2, GetClassInfo(info.classID)) or nil
		UpsertKey(unitName, level, mapID, rating, "LibOpenRaid", class)
	end

	openRaidLib.RegisterCallback(addonObject, "KeystoneUpdate", "OnKeystoneUpdate")
end

local function PullFromLibOpenRaid()
	BindLibOpenRaid()
	if not openRaidLib then return end
	if openRaidLib.RequestKeystoneDataFromParty then pcall(openRaidLib.RequestKeystoneDataFromParty) end
	if IsInGuild() and openRaidLib.RequestKeystoneDataFromGuild then pcall(openRaidLib.RequestKeystoneDataFromGuild) end
	if openRaidLib.GetAllKeystonesInfo then
		local all = openRaidLib.GetAllKeystonesInfo()
		if type(all) == "table" then
			for unitName, info in pairs(all) do
				if type(info) == "table" then
					local mapID = info.challengeMapID or info.mapID or 0
					UpsertKey(unitName, info.level or 0, mapID, info.rating or 0, "LibOpenRaid")
				end
			end
		end
	end
end

local function PullFromAstralKeys()
	local ak = _G.AstralKeys
	if type(ak) ~= "table" then return end
	for i = 1, #ak do
		local entry = ak[i]
		if type(entry) == "table" and entry.unit then
			UpsertKey(entry.unit, entry.key_level or 0, entry.dungeon_id or 0, entry.mplus_score or 0, "AstralKeys", entry.class)
		end
	end
end

local function PullSelfDungeonHistory()
	wipe(selfDungeonBest)
	local summary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary("player")
	if type(summary) ~= "table" or type(summary.runs) ~= "table" then return end
	for _, run in ipairs(summary.runs) do
		local mid = run.challengeModeID
		if mid then
			selfDungeonBest[mid] = {
				level = run.bestRunLevel or 0,
				timed = run.finishedSuccess and true or false,
				mapScore = run.mapScore or 0,
				durationMS = run.bestRunDurationMS or 0,
			}
		end
	end
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

-- Returns: isUpgrade (bool), reason (string), currentBest (number)
-- A timed run of `candidateLevel` in `challengeMapID` upgrades your score if:
--   * you've never run that dungeon, or
--   * your current best is untimed and candidateLevel >= that level, or
--   * candidateLevel > your best timed level
local function IsKeyUpgrade(challengeMapID, candidateLevel)
	if not challengeMapID or challengeMapID == 0 or not candidateLevel or candidateLevel < 2 then
		return false, nil, 0
	end
	local best = selfDungeonBest[challengeMapID]
	if not best or best.level == 0 then
		return true, "new dungeon", 0
	end
	if not best.timed then
		if candidateLevel >= best.level then
			return true, "your best is untimed", best.level
		end
	else
		if candidateLevel > best.level then
			return true, "above your timed best", best.level
		end
	end
	return false, nil, best.level
end

local function PullSelf()
	local level = C_MythicPlus.GetOwnedKeystoneLevel() or 0
	local mapID = C_MythicPlus.GetOwnedKeystoneChallengeMapID() or 0
	local rating = 0
	local summary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary("player")
	if type(summary) == "table" and summary.currentSeasonScore then rating = summary.currentSeasonScore end
	local _, class = UnitClass("player")
	UpsertKey(UnitName("player"), level, mapID, rating, "self", class)

	local currentSpecIdx = GetSpecialization()
	if currentSpecIdx then
		local specID, _, _, _, role = GetSpecializationInfo(currentSpecIdx)
		if specID then
			UpsertSpec(UnitName("player"), specID, role)
		end
	end

	PullSelfDungeonHistory()
end

-- ----------------------------------------------------------------------------
-- UI
-- ----------------------------------------------------------------------------

local ROW_HEIGHT = 22
local MAX_ROWS = 30                 -- pre-created, hidden until frame grows
local DEFAULT_VISIBLE_ROWS = 10
local FRAME_W = 580
local FRAME_H = 70 + ROW_HEIGHT * DEFAULT_VISIBLE_ROWS
local ROWS_TOP_OFFSET = 60          -- y where first row starts (from frame top)
local ROWS_BOTTOM_PAD = 36          -- space for footer (refresh btn + resize grip)

local function VisibleRowCount()
	if not mainFrame then return DEFAULT_VISIBLE_ROWS end
	local avail = mainFrame:GetHeight() - ROWS_TOP_OFFSET - ROWS_BOTTOM_PAD
	return math.max(1, math.min(MAX_ROWS, math.floor(avail / ROW_HEIGHT)))
end

local function ProcessPending()
	if InCombatLockdown() then return end
	for btn, info in pairs(pendingButtonUpdates) do
		btn:SetAttribute("type", "spell")
		btn:SetAttribute("spell", info.spellID)
		pendingButtonUpdates[btn] = nil
	end
end

local function SetTeleportButton(btn, spellID)
	if not spellID or not IsSpellKnown(spellID) then btn:Hide(); return end
	btn:Show()
	if InCombatLockdown() then
		pendingButtonUpdates[btn] = { spellID = spellID }
	else
		btn:SetAttribute("type", "spell")
		btn:SetAttribute("spell", spellID)
	end
	local info = C_Spell.GetSpellInfo(spellID)
	if info and info.iconID then btn.icon:SetTexture(info.iconID) end
	btn.tip = info and info.name or "Teleport"
end

local function CopyRaiderIO(fullName)
	local url = RaiderIOUrl(fullName)
	if not url then return end
	-- CopyToClipboard is a protected function — addons can't call it.
	-- Open a popup with the URL pre-selected so the user can Ctrl+C it.
	StaticPopup_Show("SEANKEYS_COPY_URL", nil, nil, url)
end

local function CreateRow(parent, index)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(FRAME_W - 20, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -60 - (index - 1) * ROW_HEIGHT)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.08 or 0.05)

	-- Role icon
	row.role = row:CreateTexture(nil, "ARTWORK")
	row.role:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
	row.role:SetPoint("LEFT", 4, 0)

	-- Spec icon
	row.specIcon = row:CreateTexture(nil, "ARTWORK")
	row.specIcon:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
	row.specIcon:SetPoint("LEFT", 26, 0)
	row.specIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	-- Name button (click to copy Raider.IO URL). Not secure - simple OnClick.
	local nameBtn = CreateFrame("Button", "SeanKeysNameBtn" .. index, row)
	nameBtn:SetSize(140, ROW_HEIGHT)
	nameBtn:SetPoint("LEFT", row, "LEFT", 48, 0)
	nameBtn:RegisterForClicks("AnyUp")
	nameBtn.text = nameBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	nameBtn.text:SetPoint("LEFT")
	nameBtn.text:SetPoint("RIGHT")
	nameBtn.text:SetJustifyH("LEFT")
	nameBtn.text:SetWordWrap(false)
	nameBtn:SetScript("OnEnter", function(self)
		if not self.fullName then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Click to copy Raider.IO URL", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	nameBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	nameBtn:SetScript("OnClick", function(self) CopyRaiderIO(self.fullName) end)
	row.nameBtn = nameBtn

	-- Teleport button lives at the start of the Key column, just before the dungeon name.
	local btn = CreateFrame("Button", "SeanKeysTeleBtn" .. index, row, "SecureActionButtonTemplate")
	btn:SetSize(ROW_HEIGHT - 2, ROW_HEIGHT - 2)
	btn:SetPoint("LEFT", row, "LEFT", 196, 0)
	btn:RegisterForClicks("AnyUp", "AnyDown")
	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints()
	btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	btn:SetScript("OnEnter", function(self)
		if not self.tip then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(self.tip)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row.teleport = btn

	-- Right cluster: source -> rating -> level, anchored right-to-left from the row's right edge.
	row.source = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.source:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.source:SetWidth(64)
	row.source:SetJustifyH("RIGHT")
	row.source:SetWordWrap(false)

	row.rating = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.rating:SetPoint("RIGHT", row.source, "LEFT", -6, 0)
	row.rating:SetWidth(50)
	row.rating:SetJustifyH("CENTER")

	row.level = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	row.level:SetPoint("RIGHT", row.rating, "LEFT", -6, 0)
	row.level:SetWidth(30)
	row.level:SetJustifyH("CENTER")

	-- Upgrade arrow sits in the gap to the right of the level number.
	-- It's a Frame (not a bare Texture) so it can capture mouse hover for a tooltip.
	row.upgrade = CreateFrame("Frame", nil, row)
	row.upgrade:SetSize(14, 14)
	row.upgrade:SetPoint("LEFT", row.level, "RIGHT", 1, 0)
	row.upgrade:EnableMouse(true)
	row.upgrade.arrow = row.upgrade:CreateTexture(nil, "OVERLAY")
	row.upgrade.arrow:SetSize(12, 12)
	row.upgrade.arrow:SetPoint("CENTER")
	row.upgrade.arrow:SetTexture("Interface\\Tooltips\\ReforgeGreenArrow")
	row.upgrade.arrow:SetRotation(math.pi / 2)
	row.upgrade:Hide()
	row.upgrade:SetScript("OnEnter", function(self)
		local mid = self.mapID
		if not mid or mid == 0 then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(GetDungeonName(mid), 1, 0.82, 0)
		local best = selfDungeonBest[mid]
		if not best or best.level == 0 then
			GameTooltip:AddLine("You haven't run this dungeon this season.", 0.8, 0.8, 0.8)
		else
			GameTooltip:AddLine(string.format("Your score: |cffffffff%d|r", math.floor(best.mapScore or 0)))
			local status = best.timed and "|cff33ff33timed|r" or "|cffff6666over time|r"
			GameTooltip:AddLine(string.format("Best run: +%d %s (%s)", best.level, status, FormatDuration(best.durationMS)))
		end
		if self.candidateLevel and self.candidateLevel > 0 then
			local newDungeonMin = EstimateMinTimedScore(self.candidateLevel)
			local oldDungeon = (best and best.mapScore) or 0
			local delta = newDungeonMin - oldDungeon
			if delta > 0 then
				local summary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary("player")
				local currentTotal = (summary and summary.currentSeasonScore) or 0
				local newTotalMin = math.floor(currentTotal + delta)
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine(string.format(
					"Timing this |cffffffff+%d|r will increase your score by at least |cffffffff+%d|r (total |cffffffff%d|r).",
					self.candidateLevel, delta, newTotalMin), 0.4, 1, 0.4)
			else
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine(string.format("Timing this |cffffffff+%d|r would upgrade your score.", self.candidateLevel), 0.4, 1, 0.4)
			end
		end
		GameTooltip:Show()
	end)
	row.upgrade:SetScript("OnLeave", GameTooltip_Hide)

	-- Dungeon name is a Button so left-click opens the loot preview.
	row.dungeon = CreateFrame("Button", nil, row)
	row.dungeon:SetPoint("LEFT", btn, "RIGHT", 4, 0)
	row.dungeon:SetPoint("RIGHT", row.level, "LEFT", -8, 0)
	row.dungeon:SetHeight(ROW_HEIGHT)
	row.dungeon:RegisterForClicks("LeftButtonUp")
	row.dungeon:SetScript("OnClick", function(self)
		Dbg("dungeon row clicked, challengeMapID=", self.challengeMapID, "keyLevel=", self.keyLevel)
		if self.challengeMapID and self.challengeMapID > 0 and ns.ShowLootFor then
			ns.ShowLootFor(self.challengeMapID, self.keyLevel)
		end
	end)
	row.dungeon:SetScript("OnEnter", function(self)
		if not self.challengeMapID or self.challengeMapID == 0 then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Click to open loot preview", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	row.dungeon:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row.dungeon.text = row.dungeon:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.dungeon.text:SetAllPoints()
	row.dungeon.text:SetJustifyH("LEFT")
	row.dungeon.text:SetWordWrap(false)

	return row
end

local function BuildFrame()
	if mainFrame then return mainFrame end

	local f = CreateFrame("Frame", "SeanKeysFrame", UIParent, "PortraitFrameTemplate")
	f:SetSize(FRAME_W, FRAME_H)
	f:SetPoint("CENTER")
	f:SetFrameStrata("MEDIUM")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:SetResizable(true)
	-- Width is locked; only height resizes (so the column layout stays sane).
	local minH = ROWS_TOP_OFFSET + ROWS_BOTTOM_PAD + ROW_HEIGHT      -- 1 row minimum
	local maxH = ROWS_TOP_OFFSET + ROWS_BOTTOM_PAD + ROW_HEIGHT * MAX_ROWS
	if f.SetResizeBounds then
		f:SetResizeBounds(FRAME_W, minH, FRAME_W, maxH)
	else
		f:SetMinResize(FRAME_W, minH)
		f:SetMaxResize(FRAME_W, maxH)
	end
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local _, _, rel, x, y = self:GetPoint()
		db.framePos = { relativePoint = rel, x = x, y = y }
	end)
	f:Hide()

	-- Title and portrait. Different WoW versions expose these under different
	-- field names; try the common ones.
	if f.SetTitle then
		f:SetTitle("SeanKeys")
	elseif f.TitleText then
		f.TitleText:SetText("SeanKeys")
	end
	-- Use the mythic keystone item icon for the portrait so the slot looks intentional.
	if f.SetPortraitToAsset then
		f:SetPortraitToAsset(525134)
	elseif f.portrait then
		f.portrait:SetTexture(525134)
	elseif f.PortraitContainer and f.PortraitContainer.portrait then
		f.PortraitContainer.portrait:SetTexture(525134)
	end
	-- Lighten the inset content background so the window doesn't feel as heavy.
	if f.Inset and f.Inset.Bg then
		f.Inset.Bg:SetAlpha(0.7)
	end

	if db.framePos then
		f:ClearAllPoints()
		f:SetPoint(db.framePos.relativePoint or "CENTER", UIParent, db.framePos.relativePoint or "CENTER", db.framePos.x or 0, db.framePos.y or 0)
	end
	if db.frameHeight then
		f:SetHeight(math.max(minH, math.min(maxH, db.frameHeight)))
	end

	-- Resize grip at bottom-right.
	local grip = CreateFrame("Button", nil, f)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -4, 4)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function(self, button)
		if button == "LeftButton" then f:StartSizing("BOTTOMRIGHT") end
	end)
	grip:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
		db.frameHeight = math.floor(f:GetHeight())
	end)

	local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	refresh:SetSize(80, 20)
	refresh:SetPoint("BOTTOMRIGHT", -24, 4)
	refresh:SetText("Refresh")
	refresh:SetScript("OnClick", function() ns.Refresh(true) end)

	local debugBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	debugBtn:SetSize(60, 20)
	debugBtn:SetPoint("RIGHT", refresh, "LEFT", -4, 0)
	debugBtn:SetText("Debug")
	debugBtn:SetScript("OnClick", function() ShowDebugWindow() end)
	f.debugBtn = debugBtn
	if not db.showDebugButton then debugBtn:Hide() end

	-- Re-render row visibility live as the user drags the grip.
	f:SetScript("OnSizeChanged", function()
		if mainFrame and mainFrame:IsShown() then ns.Refresh() end
	end)

	-- Column headers
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetSize(FRAME_W - 20, 16)
	hdr:SetPoint("TOPLEFT", 10, -40)
	local function H(text, x, w, justify)
		local fs = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("LEFT", x, 0)
		fs:SetWidth(w)
		fs:SetJustifyH(justify or "LEFT")
		fs:SetText("|cffffcc00" .. text .. "|r")
		return fs
	end
	-- align to row layout:
	--   role(4..22) spec(26..44) name(48..188) tp_btn(196..216) dungeon(220..392)
	--   lvl(400..430) rating(436..486) source(492..556)
	H("",       4,   18)         -- role
	H("",       26,  18)         -- spec
	H("Player", 48,  140, "LEFT")
	H("Key",    220, 172, "LEFT")
	H("Lvl",    400, 30,  "CENTER")
	H("Rating", 436, 50,  "CENTER")
	H("Source", 492, 64,  "RIGHT")

	for i = 1, MAX_ROWS do
		rows[i] = CreateRow(f, i)
	end

	mainFrame = f
	return f
end

-- ----------------------------------------------------------------------------
-- Refresh: party first, then everything else by key level desc
-- ----------------------------------------------------------------------------

local function CollectPartyNames()
	local set, list = {}, {}
	local selfName = NormalizeName(UnitName("player"))
	if selfName then set[selfName] = true; list[#list + 1] = selfName end
	if IsInGroup() then
		local prefix = IsInRaid() and "raid" or "party"
		local n = GetNumGroupMembers()
		for i = 1, n do
			local unit = prefix .. i
			if UnitExists(unit) and not UnitIsUnit(unit, "player") then
				local name = NormalizeName(GetUnitName(unit, true))
				if name and not set[name] then
					set[name] = true
					list[#list + 1] = name
					local entry = GetOrCreate(name)
					local _, class = UnitClass(unit)
					if class and not entry.class then entry.class = class end
					if not entry.role then
						local r = UnitGroupRolesAssigned(unit)
						if r and r ~= "NONE" then entry.role = r end
					end
				end
			end
		end
	end
	return list, set
end

function ns.Refresh(force)
	if force then
		PullSelf()
		PullFromLibOpenRaid()
		PullFromAstralKeys()
		if LKS and IsInGroup() then LKS.Request("PARTY") end
		if LSP and IsInGroup() and LSP.RequestGroupSpecialization then
			pcall(LSP.RequestGroupSpecialization)
		end
	end
	if not mainFrame then return end

	local partyList, partySet = CollectPartyNames()
	local display = {}
	for _, name in ipairs(partyList) do display[#display + 1] = name end
	local extras = {}
	for name in pairs(keys) do if not partySet[name] then extras[#extras + 1] = name end end
	table.sort(extras, function(a, b)
		local la = (keys[a] and keys[a].level) or 0
		local lb = (keys[b] and keys[b].level) or 0
		if la == lb then return a < b end
		return la > lb
	end)
	for _, name in ipairs(extras) do display[#display + 1] = name end

	local visible = VisibleRowCount()
	for i = 1, MAX_ROWS do
		local row = rows[i]
		local name = display[i]
		if not name or i > visible then
			row:Hide()
		else
			row:Show()
			local entry = keys[name] or {}

			SetRoleIcon(row.role, entry.role)

			if entry.specID and entry.specID > 0 then
				local _, _, _, icon = GetSpecializationInfoByID(entry.specID)
				if icon then
					row.specIcon:SetTexture(icon)
					row.specIcon:Show()
				else
					row.specIcon:Hide()
				end
			else
				row.specIcon:Hide()
			end

			local r, g, b = GetClassColor(entry.class)
			row.nameBtn.text:SetText(name)
			row.nameBtn.text:SetTextColor(r, g, b)
			local tip = name
			local spec = SpecName(entry.specID)
			if spec then tip = spec .. " " .. (entry.class or "") .. " - " .. name end
			row.nameBtn.tip = tip
			row.nameBtn.fullName = name

			local lvl = entry.level or 0
			row.dungeon.challengeMapID = entry.mapID
			row.dungeon.keyLevel = lvl
			if lvl > 0 then
				row.dungeon.text:SetText(GetDungeonName(entry.mapID))
				row.level:SetText(tostring(lvl))
				local lr, lg, lb = KeyLevelColor(lvl)
				row.level:SetTextColor(lr, lg, lb)
				local upgrade = IsKeyUpgrade(entry.mapID, lvl)
				row.upgrade.mapID = entry.mapID
				row.upgrade.candidateLevel = lvl
				if upgrade then row.upgrade:Show() else row.upgrade:Hide() end
			else
				row.dungeon.text:SetText("|cff888888no key|r")
				row.level:SetText("")
				row.upgrade.mapID = nil
				row.upgrade.candidateLevel = nil
				row.upgrade:Hide()
			end

			local rating = entry.rating or 0
			if rating > 0 then
				row.rating:SetText(tostring(math.floor(rating)))
			else
				row.rating:SetText("|cff666666-|r")
			end

			row.source:SetText(entry.source and ("|cff666666" .. entry.source .. "|r") or "")

			local spellID = TELEPORT_SPELL_BY_CHALLENGEMAP[entry.mapID or 0]
			SetTeleportButton(row.teleport, spellID)
		end
	end
end

local function Toggle()
	BuildFrame()
	if mainFrame:IsShown() then
		mainFrame:Hide()
	else
		ns.Refresh(true)
		mainFrame:Show()
		mainFrame:Raise()
	end
end

ns.Toggle = Toggle

-- ----------------------------------------------------------------------------
-- Loot preview: left-click a dungeon name to open a window listing the loot
-- the player's current spec can receive from that dungeon.
-- ----------------------------------------------------------------------------

local SECONDARY_LABELS = {
	ITEM_MOD_CRIT_RATING_SHORT       = "Crit",
	ITEM_MOD_HASTE_RATING_SHORT      = "Haste",
	ITEM_MOD_MASTERY_RATING_SHORT    = "Mastery",
	ITEM_MOD_VERSATILITY             = "Vers",
	ITEM_MOD_LEECH_RATING_SHORT      = "Leech",
	ITEM_MOD_AVOIDANCE_RATING_SHORT  = "Avoid",
	ITEM_MOD_SPEED_RATING_SHORT      = "Speed",
	ITEM_MOD_LIFESTEAL_SHORT         = "Leech",
}

local function GetSecondaries(itemLink)
	if not itemLink then return "" end
	local stats = (C_Item and C_Item.GetItemStats and C_Item.GetItemStats(itemLink)) or GetItemStats(itemLink)
	if not stats then return "" end
	local out = {}
	for key, label in pairs(SECONDARY_LABELS) do
		if stats[key] and stats[key] > 0 then table.insert(out, label) end
	end
	table.sort(out)
	return table.concat(out, " / ")
end

-- Challenge map ID -> instance UI map ID for the *original* dungeon entry that
-- the Encounter Journal indexes. Values match DBM's teleportMap and are known to
-- resolve via EJ_GetInstanceForMap. The LibOpenRaid table sometimes has the
-- modern remix instance ID (e.g. Magister's Terrace = 2811 vs original 585)
-- which the journal doesn't recognize.
local CHALLENGE_TO_INSTANCEMAP = {
	-- Midnight S1
	[161] = 1209,  -- Skyreach
	[239] = 1753,  -- Seat of the Triumvirate
	[402] = 2526,  -- Algeth'ar Academy
	[556] = 658,   -- Pit of Saron
	[557] = 2805,  -- Windrunner Spire
	[558] = 585,   -- Magister's Terrace
	[559] = 2915,  -- Nexus-Point Xenas
	[560] = 2874,  -- Maisara Caverns
	-- Recent TWW dungeons
	[542] = 2830,  -- Eco-Dome Al'dani
	[378] = 2287,  -- Halls of Atonement
	[525] = 2773,  -- Operation: Floodgate
	[505] = 2660,  -- Ara-Kara, City of Echoes
	[503] = 2662,  -- The Dawnbreaker
	[499] = 2649,  -- Priory of the Sacred Flame
	[391] = 2441,  -- Tazavesh: Streets of Wonder
	[392] = 2441,  -- Tazavesh: So'leah's Gambit
}

local function EnsureEJLoaded()
	if C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal") then return true end
	Dbg("  loading Blizzard_EncounterJournal addon")
	local ok, reason = C_AddOns.LoadAddOn("Blizzard_EncounterJournal")
	Dbg("  load result:", ok, "reason:", reason)
	return ok
end

local function TryJournalForUiMap(uiMapID)
	if not uiMapID or not EJ_GetInstanceForMap then return nil end
	local id = EJ_GetInstanceForMap(uiMapID)
	if id and id > 0 then return id end
	return nil
end

-- Last-resort: iterate all dungeon-tier journal instances and match by name.
-- Iterates a few tiers (current + recent) since older dungeons sit in earlier
-- expansion tiers.
local function FindJournalByName(dungeonName)
	if not dungeonName or dungeonName == "" or not EJ_SelectTier or not EJ_GetInstanceByIndex then return nil end
	local currentTier = EJ_GetCurrentTier and EJ_GetCurrentTier() or nil
	local prevTier = currentTier
	local numTiers = EJ_GetNumTiers and EJ_GetNumTiers() or 0
	Dbg("  searching journal by name across", numTiers, "tiers for:", dungeonName)
	for tier = numTiers, 1, -1 do
		EJ_SelectTier(tier)
		local i = 1
		while true do
			local instanceID, name = EJ_GetInstanceByIndex(i, false)  -- false = dungeon
			if not instanceID then break end
			if name == dungeonName then
				Dbg("    matched tier=", tier, "instanceID=", instanceID, "name=", name)
				if prevTier then EJ_SelectTier(prevTier) end
				return instanceID
			end
			i = i + 1
		end
	end
	if prevTier then EJ_SelectTier(prevTier) end
	return nil
end

local function GetJournalInstance(challengeMapID)
	Dbg("GetJournalInstance: challengeMapID=", challengeMapID)
	if not challengeMapID or challengeMapID == 0 then
		Dbg("  -> invalid challengeMapID")
		return nil
	end

	-- EJ API needs the journal addon loaded before any of its lookups work.
	EnsureEJLoaded()

	-- 1. Hardcoded table — matches DBM's known-good values.
	local hardcodedUiMap = CHALLENGE_TO_INSTANCEMAP[challengeMapID]
	if hardcodedUiMap then
		local journalID = TryJournalForUiMap(hardcodedUiMap)
		Dbg("  hardcoded uiMap=", hardcodedUiMap, "-> journalID=", journalID)
		if journalID then return journalID end
	else
		Dbg("  no entry in CHALLENGE_TO_INSTANCEMAP for", challengeMapID)
	end

	-- 2. Fall back to LibOpenRaid's uiMapID.
	local mapTable = _G.LIB_OPEN_RAID_MYTHIC_PLUS_MAPINFO
	local mapInfo = mapTable and mapTable[challengeMapID]
	if mapInfo and mapInfo[6] then
		local journalID = TryJournalForUiMap(mapInfo[6])
		Dbg("  LibOpenRaid uiMap=", mapInfo[6], "name=", mapInfo[1], "-> journalID=", journalID)
		if journalID then return journalID end
	end

	-- 3. Last-resort: scan journal entries and match by dungeon name.
	local dungeonName
	if C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
		dungeonName = C_ChallengeMode.GetMapUIInfo(challengeMapID)
	end
	if dungeonName then
		local journalID = FindJournalByName(dungeonName)
		if journalID then return journalID end
	end

	Dbg("  -> no journal instance resolved")
	return nil
end

local function GatherLoot(journalInstanceID, classID, specID)
	Dbg("GatherLoot: journalInstanceID=", journalInstanceID, "classID=", classID, "specID=", specID)
	if not journalInstanceID or journalInstanceID == 0 then
		Dbg("  -> invalid journalInstanceID")
		return {}
	end
	if not C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal") then
		Dbg("  loading Blizzard_EncounterJournal addon")
		local loaded, reason = C_AddOns.LoadAddOn("Blizzard_EncounterJournal")
		Dbg("  load result:", loaded, "reason:", reason)
	else
		Dbg("  Blizzard_EncounterJournal already loaded")
	end
	local prevClass, prevSpec = EJ_GetLootFilter()
	Dbg("  prev filter:", prevClass, prevSpec)
	EJ_SetLootFilter(classID or 0, specID or 0)
	EJ_SelectInstance(journalInstanceID)
	local count = EJ_GetNumLoot() or 0
	Dbg("  EJ_GetNumLoot =", count)
	local getLootInfo = (C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex) or EJ_GetLootInfoByIndex
	if not getLootInfo then
		Dbg("  ERROR: no GetLootInfoByIndex API available")
		EJ_SetLootFilter(prevClass or 0, prevSpec or 0)
		return {}
	end
	Dbg("  using", (C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex) and "C_EncounterJournal.GetLootInfoByIndex" or "EJ_GetLootInfoByIndex")
	local seen, out = {}, {}
	local dropped = 0
	for i = 1, count do
		local info = getLootInfo(i)
		if info and info.itemID and info.itemID > 0 then
			if not seen[info.itemID] then
				seen[info.itemID] = true
				table.insert(out, info)
			end
		else
			dropped = dropped + 1
		end
	end
	Dbg("  collected", #out, "unique items, dropped", dropped, "(no itemID)")
	-- Sample the first few items for sanity
	for i = 1, math.min(3, #out) do
		local it = out[i]
		Dbg("    sample", i, "itemID=", it.itemID, "name=", it.name, "slot=", it.slot)
	end
	EJ_SetLootFilter(prevClass or 0, prevSpec or 0)
	return out
end

local LOOT_FRAME_W = 400
local LOOT_ROW_H = 32
local LOOT_NUM_GEAR_ROWS = 10
local OTHER_ICON_SIZE = 28
local OTHER_ICONS_PER_ROW = 12
local OTHER_MAX_ROWS = 2
local OTHER_MAX_ICONS = OTHER_ICONS_PER_ROW * OTHER_MAX_ROWS
local lootFrame, lootRows, otherIcons

-- Use C_Item.GetItemInfoInstant — synchronous, doesn't require item to be cached,
-- and returns reliable classID + equipLoc regardless of how the EJ struct is populated.
local function IsGearItem(info)
	if not info or not info.itemID then return false end
	local _, _, _, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(info.itemID)
	-- classID 2 = Weapon, 4 = Armor
	if classID == 2 or classID == 4 then
		-- But ignore armor subclass 0 ("Miscellaneous") cosmetic/junk pieces
		-- only when they have no equipLoc; armor with a real slot is gear.
		if equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" then
			return true
		end
	end
	-- Fallback: anything with a real equipLoc is gear
	if equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" and equipLoc ~= "INVTYPE_BAG" then
		return true
	end
	return false
end

local function BuildLootFrame()
	if lootFrame then return lootFrame end
	local f = CreateFrame("Frame", "SeanKeysLootFrame", UIParent, "PortraitFrameTemplate")
	-- height = chrome + gear rows + other-items section + footer
	local otherSectionH = 24 + (OTHER_ICON_SIZE + 4) * OTHER_MAX_ROWS
	f:SetSize(LOOT_FRAME_W, 80 + LOOT_ROW_H * LOOT_NUM_GEAR_ROWS + otherSectionH + 24)
	f:SetPoint("CENTER")
	f:SetFrameStrata("MEDIUM")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	-- Title and portrait set per-dungeon by ShowLootFor.
	if f.Inset and f.Inset.Bg then f.Inset.Bg:SetAlpha(0.7) end

	f.subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.subtitle:SetPoint("TOP", 0, -28)
	f.subtitle:SetText("")

	-- Headers
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetSize(LOOT_FRAME_W - 20, 16)
	hdr:SetPoint("TOPLEFT", 10, -52)
	local function H(text, x, w)
		local fs = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("LEFT", x, 0)
		fs:SetWidth(w)
		fs:SetJustifyH("LEFT")
		fs:SetText("|cffffcc00" .. text .. "|r")
	end
	H("Item",  4,   34)
	H("Slot",  44,  100)
	H("Stats", 148, 200)

	lootRows = {}
	for i = 1, LOOT_NUM_GEAR_ROWS do
		local row = CreateFrame("Frame", nil, f)
		row:SetSize(LOOT_FRAME_W - 20, LOOT_ROW_H)
		row:SetPoint("TOPLEFT", 10, -70 - (i - 1) * LOOT_ROW_H)

		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.08 or 0.05)

		local iconBtn = CreateFrame("Button", nil, row)
		iconBtn:SetSize(LOOT_ROW_H - 4, LOOT_ROW_H - 4)
		iconBtn:SetPoint("LEFT", 4, 0)
		iconBtn.icon = iconBtn:CreateTexture(nil, "ARTWORK")
		iconBtn.icon:SetAllPoints()
		iconBtn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		iconBtn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if self.itemLink then
				GameTooltip:SetHyperlink(self.itemLink)
			elseif self.itemID then
				GameTooltip:SetItemByID(self.itemID)
			end
			GameTooltip:Show()
		end)
		iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row.iconBtn = iconBtn

		row.slot = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.slot:SetPoint("LEFT", 44, 0)
		row.slot:SetWidth(100)
		row.slot:SetJustifyH("LEFT")
		row.slot:SetWordWrap(false)

		row.stats = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.stats:SetPoint("LEFT", 148, 0)
		row.stats:SetWidth(200)
		row.stats:SetJustifyH("LEFT")
		row.stats:SetWordWrap(false)

		row:Hide()
		lootRows[i] = row
	end

	-- "Other Items" heading and icon grid below the gear rows.
	local otherY = -70 - LOOT_NUM_GEAR_ROWS * LOOT_ROW_H - 4
	f.otherHeading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.otherHeading:SetPoint("TOPLEFT", 10, otherY)
	f.otherHeading:SetText("|cffffcc00Other Items|r")
	f.otherHeading:Hide()

	otherIcons = {}
	local iconStartY = otherY - 18
	for i = 1, OTHER_MAX_ICONS do
		local row = math.floor((i - 1) / OTHER_ICONS_PER_ROW)
		local col = (i - 1) % OTHER_ICONS_PER_ROW
		local btn = CreateFrame("Button", nil, f)
		btn:SetSize(OTHER_ICON_SIZE, OTHER_ICON_SIZE)
		btn:SetPoint("TOPLEFT", 10 + col * (OTHER_ICON_SIZE + 4), iconStartY - row * (OTHER_ICON_SIZE + 4))
		btn.icon = btn:CreateTexture(nil, "ARTWORK")
		btn.icon:SetAllPoints()
		btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		btn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if self.itemLink then
				GameTooltip:SetHyperlink(self.itemLink)
			elseif self.itemID then
				GameTooltip:SetItemByID(self.itemID)
			end
			GameTooltip:Show()
		end)
		btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
		btn:Hide()
		otherIcons[i] = btn
	end

	-- Footer hint
	f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.hint:SetPoint("BOTTOM", 0, 10)

	lootFrame = f
	return f
end

local function ItemLevelFromLink(link)
	if not link then return nil end
	if C_Item and C_Item.GetDetailedItemLevelInfo then
		local effective = C_Item.GetDetailedItemLevelInfo(link)
		if effective and effective > 0 then return effective end
	end
	local _, _, _, ilvl = GetItemInfo(link)
	return ilvl
end

local function PopulateLootRow(row, lootInfo)
	row:Show()
	row.iconBtn.itemID = lootInfo.itemID
	row.iconBtn.itemLink = lootInfo.link
	row.iconBtn.icon:SetTexture(lootInfo.icon or GetItemIcon(lootInfo.itemID) or 134400)
	row.slot:SetText(lootInfo.slot or "?")
	row.stats:SetText("|cff888888loading...|r")

	local item = lootInfo.link and Item:CreateFromItemLink(lootInfo.link)
		or Item:CreateFromItemID(lootInfo.itemID)
	item:ContinueOnItemLoad(function()
		if row.iconBtn.itemID ~= lootInfo.itemID then return end
		local link = item:GetItemLink() or lootInfo.link
		row.iconBtn.itemLink = link
		local secs = GetSecondaries(link)
		row.stats:SetText(secs == "" and "|cff666666-|r" or secs)
		local icon = item:GetItemIcon()
		if icon then row.iconBtn.icon:SetTexture(icon) end
	end)
end

local function PopulateOtherIcon(btn, lootInfo)
	btn:Show()
	btn.itemID = lootInfo.itemID
	btn.itemLink = lootInfo.link
	btn.icon:SetTexture(lootInfo.icon or GetItemIcon(lootInfo.itemID) or 134400)
	local item = lootInfo.link and Item:CreateFromItemLink(lootInfo.link)
		or Item:CreateFromItemID(lootInfo.itemID)
	item:ContinueOnItemLoad(function()
		if btn.itemID ~= lootInfo.itemID then return end
		local link = item:GetItemLink() or lootInfo.link
		btn.itemLink = link
		local icon = item:GetItemIcon()
		if icon then btn.icon:SetTexture(icon) end
	end)
end

function ns.ShowLootFor(challengeMapID, keyLevel)
	Dbg("=== ShowLootFor invoked, challengeMapID=", challengeMapID, "keyLevel=", keyLevel, " ===")
	local f = BuildLootFrame()
	local dungeonName = GetDungeonName(challengeMapID)
	Dbg("dungeon name resolved:", dungeonName)

	-- Tell the journal what M+ level to scale items to so the link includes the
	-- correct preview ilvl. Default to the player's own key level if the row had none.
	local previewLevel = (keyLevel and keyLevel > 0) and keyLevel or (C_MythicPlus.GetOwnedKeystoneLevel() or 0)
	if previewLevel == 0 then previewLevel = 10 end  -- sensible fallback
	if C_EncounterJournal and C_EncounterJournal.SetPreviewMythicPlusLevel then
		EnsureEJLoaded()
		C_EncounterJournal.SetPreviewMythicPlusLevel(previewLevel)
		Dbg("SetPreviewMythicPlusLevel:", previewLevel)
	end

	local className, _, classID = UnitClass("player")
	local specIdx = GetSpecialization()
	local specID, specName = nil, nil
	if specIdx then
		specID, specName = GetSpecializationInfo(specIdx)
	end
	Dbg("player: className=", className, "classID=", classID, "specID=", specID, "specName=", specName)

	-- Use the dungeon's own UI info for title text and portrait icon.
	local mapName, _, _, mapTexture = nil, nil, nil, nil
	if C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
		mapName, _, _, mapTexture = C_ChallengeMode.GetMapUIInfo(challengeMapID)
	end
	local displayName = mapName or dungeonName or "Dungeon"
	local titleText = displayName .. " Loot"
	if f.SetTitle then f:SetTitle(titleText) elseif f.TitleText then f.TitleText:SetText(titleText) end
	if mapTexture then
		if f.SetPortraitToAsset then
			f:SetPortraitToAsset(mapTexture)
		elseif f.portrait then
			f.portrait:SetTexture(mapTexture)
		elseif f.PortraitContainer and f.PortraitContainer.portrait then
			f.PortraitContainer.portrait:SetTexture(mapTexture)
		end
	end

	local journalID = GetJournalInstance(challengeMapID)
	f.subtitle:SetText(string.format("%s %s  |cff888888-|r  +%d preview", specName or "", className, previewLevel))

	local function HideAll()
		for i = 1, LOOT_NUM_GEAR_ROWS do lootRows[i]:Hide() end
		for i = 1, OTHER_MAX_ICONS do otherIcons[i]:Hide() end
		f.otherHeading:Hide()
	end

	if not journalID then
		f.hint:SetText("|cffff6666Couldn't resolve journal instance. Check Debug log.|r")
		HideAll()
		f:Show()
		f:Raise()
		return
	end

	local loot = GatherLoot(journalID, classID, specID)

	-- Split into gear (slot-bearing) and "other" (crafting mats, tokens, etc.)
	local gear, other = {}, {}
	for idx, info in ipairs(loot) do
		local isGear = IsGearItem(info)
		if isGear then
			table.insert(gear, info)
		else
			table.insert(other, info)
		end
		if idx <= 6 then
			local _, _, _, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(info.itemID)
			Dbg("  item", idx, "id=", info.itemID, "name=", info.name,
				"classID=", classID, "subclassID=", subclassID, "equipLoc=", equipLoc,
				"-> ", isGear and "GEAR" or "other")
		end
	end
	Dbg("ShowLootFor: split", #gear, "gear,", #other, "other")

	HideAll()
	for i = 1, math.min(#gear, LOOT_NUM_GEAR_ROWS) do
		PopulateLootRow(lootRows[i], gear[i])
	end
	if #other > 0 then
		f.otherHeading:Show()
		for i = 1, math.min(#other, OTHER_MAX_ICONS) do
			PopulateOtherIcon(otherIcons[i], other[i])
		end
	end

	local hintParts = { string.format("%d gear", #gear) }
	if #gear > LOOT_NUM_GEAR_ROWS then
		hintParts[1] = string.format("%d gear (showing %d)", #gear, LOOT_NUM_GEAR_ROWS)
	end
	if #other > 0 then
		if #other > OTHER_MAX_ICONS then
			table.insert(hintParts, string.format("%d other (showing %d)", #other, OTHER_MAX_ICONS))
		else
			table.insert(hintParts, string.format("%d other", #other))
		end
	end
	f.hint:SetText(table.concat(hintParts, "  •  "))
	if #gear == 0 and #other == 0 then
		f.hint:SetText("|cffff6666No loot returned for this spec.|r")
	end
	f:Show()
	f:Raise()
end

-- ----------------------------------------------------------------------------
-- Slash commands
-- ----------------------------------------------------------------------------

SLASH_SEANKEYS1 = "/seankeys"
SLASH_SEANKEYS2 = "/sk"
local function UpdateDebugButtonVisibility()
	if not mainFrame or not mainFrame.debugBtn then return end
	if db and db.showDebugButton then
		mainFrame.debugBtn:Show()
	else
		mainFrame.debugBtn:Hide()
	end
end

SlashCmdList.SEANKEYS = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "refresh" or msg == "r" then
		ns.Refresh(true)
		print("|cffffcc00SeanKeys:|r refreshed.")
	elseif msg == "debug" then
		db.showDebugButton = not db.showDebugButton
		UpdateDebugButtonVisibility()
		print("|cffffcc00SeanKeys:|r debug button " .. (db.showDebugButton and "|cff33ff33shown|r" or "|cffff6666hidden|r"))
	elseif msg == "dump" then
		for name, k in pairs(keys) do
			local upgrade, reason = IsKeyUpgrade(k.mapID, k.level)
			local upTag = upgrade and (" |cff33ff33[UPGRADE: " .. (reason or "") .. "]|r") or ""
			print(string.format("|cffffcc00SeanKeys:|r %s = lvl %d %s rating=%d spec=%s role=%s (%s)%s",
				name, k.level or 0, GetDungeonName(k.mapID), k.rating or 0,
				tostring(SpecName(k.specID) or "?"), tostring(k.role or "?"), k.source or "?", upTag))
		end
		print(string.format("|cffffcc00SeanKeys:|r tracked %d dungeons in your run history.", (function() local n=0; for _ in pairs(selfDungeonBest) do n=n+1 end; return n end)()))
	else
		Toggle()
	end
end

-- ----------------------------------------------------------------------------
-- Events
-- ----------------------------------------------------------------------------

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("GROUP_ROSTER_UPDATE")
boot:RegisterEvent("CHALLENGE_MODE_COMPLETED")
boot:RegisterEvent("BAG_UPDATE_DELAYED")
boot:RegisterEvent("PLAYER_REGEN_ENABLED")
boot:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
boot:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			SeanKeysDB = SeanKeysDB or {}
			db = SeanKeysDB
			if db.showDebugButton == nil then db.showDebugButton = false end
		end
	elseif event == "PLAYER_LOGIN" then
		PullSelf()
		BindLibOpenRaid()
	elseif event == "PLAYER_ENTERING_WORLD" then
		C_Timer.After(2, function()
			PullSelf()
			PullFromAstralKeys()
			PullFromLibOpenRaid()
			if LKS and IsInGroup() then LKS.Request("PARTY") end
			if LSP and IsInGroup() and LSP.RequestGroupSpecialization then
				pcall(LSP.RequestGroupSpecialization)
			end
		end)
	elseif event == "GROUP_ROSTER_UPDATE" then
		C_Timer.After(1, function()
			if LKS and IsInGroup() then LKS.Request("PARTY") end
			if LSP and IsInGroup() and LSP.RequestGroupSpecialization then
				pcall(LSP.RequestGroupSpecialization)
			end
			PullFromLibOpenRaid()
			if mainFrame and mainFrame:IsShown() then ns.Refresh() end
		end)
	elseif event == "CHALLENGE_MODE_COMPLETED" or event == "BAG_UPDATE_DELAYED" then
		C_Timer.After(2, PullSelf)
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		C_Timer.After(0.5, PullSelf)
	elseif event == "PLAYER_REGEN_ENABLED" then
		ProcessPending()
	end
end)
