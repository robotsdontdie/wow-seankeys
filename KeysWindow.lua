local ADDON_NAME, ns = ...

-- ============================================================================
-- KeysWindow: the main aggregated-keystone window with party/alts/guildies
-- sections, teleport buttons, and dungeon-name click-to-loot-preview.
-- ============================================================================

local LKS = LibStub("LibKeystone", true)
local LSP = LibStub("LibSpecialization", true)

local function Dbg(...) if ns.Dbg then ns.Dbg(...) end end

local ROW_HEIGHT = 22
local MAX_ROWS = 30                 -- pre-created, hidden until frame grows
local DEFAULT_VISIBLE_ROWS = 10
local FRAME_W = 580
local FRAME_H = 70 + ROW_HEIGHT * DEFAULT_VISIBLE_ROWS
local ROWS_TOP_OFFSET = 60          -- y where first row starts (from frame top)
local ROWS_BOTTOM_PAD = 36          -- space for footer (refresh btn + resize grip)
local SEPARATOR_HEIGHT = 10

local rows = {}
local separators = {}            -- pre-created horizontal section dividers
local mainFrame
local pendingButtonUpdates = {}  -- secure attribute updates queued for combat end

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

ns.ProcessPending = ProcessPending

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
	local url = ns.RaiderIOUrl(fullName)
	if not url then return end
	-- CopyToClipboard is a protected function — addons can't call it.
	-- Open a popup with the URL pre-selected so the user can Ctrl+C it.
	StaticPopup_Show("SEANKEYS_COPY_URL", nil, nil, url)
end

local function GetMDT()
	return _G.MDT or _G.MythicDungeonTools
end

-- Normalize a dungeon name for fuzzy matching: lowercase, strip color codes,
-- strip whitespace and punctuation. Handles cases like "Nexus-Point Xenas"
-- vs "Nexus-Point: Xenas" or season-prefix decorations.
local function NormalizeDungeonName(s)
	if type(s) ~= "string" then return "" end
	s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	s = s:lower():gsub("[%s%p]", "")
	return s
end

-- Resolve our challengeMapID to MDT's internal dungeon index. MDT exposes a
-- `zoneIdToDungeonIdx` table (keyed by uiMapID, not challengeMapID, hence the
-- name-match fallback). Without testing every season we can't guarantee one
-- works, so we try id-lookup first then fall back to fuzzy name matching.
local function MDT_DungeonIdxFor(mdt, challengeMapID)
	if type(mdt.zoneIdToDungeonIdx) == "table" then
		local idx = mdt.zoneIdToDungeonIdx[challengeMapID]
		if idx then return idx end
	end
	if type(mdt.dungeonList) == "table" then
		local target = ns.GetDungeonName(challengeMapID)
		if target then
			local normTarget = NormalizeDungeonName(target)
			for idx, name in pairs(mdt.dungeonList) do
				if NormalizeDungeonName(name) == normTarget then return idx end
			end
		end
	end
	return nil
end

-- Opens MDT (if installed) and switches it to the given dungeon. Reading
-- MDT's source clarifies the signature and gotchas:
--   * UpdateToDungeon(idx, ignoreUpdateMap, init) — the 2nd arg is a SKIP
--     flag for the map redraw, not "force". Pass nil to get the redraw.
--   * It early-returns if `idx == db.currentDungeonIdx`, so we must NOT
--     pre-set the db value (that would no-op our refresh).
--   * ShowInterface is async (MDT:Async), and its internal path calls
--     CheckCurrentZone which may auto-switch to whatever zone the player is
--     in. To override that, our UpdateToDungeon must land AFTER main_frame
--     is shown — we poll for IsShown.
--   * UpdateToDungeon calls UpdatePresetDropDown which indexes main_frame,
--     so we have to wait for main_frame to exist before calling it.
local function TryOpenMDT(challengeMapID)
	local mdt = GetMDT()
	if not mdt or type(mdt.ShowInterface) ~= "function" then return false end
	local match = MDT_DungeonIdxFor(mdt, challengeMapID)
	mdt:ShowInterface()
	if not match then
		Dbg("MDT: no match for challengeMapID=", challengeMapID)
		return true
	end
	if type(mdt.UpdateToDungeon) ~= "function" then return true end
	local attempts = 0
	local function tryUpdate()
		attempts = attempts + 1
		if mdt.main_frame and mdt.main_frame:IsShown() then
			local ok, err = pcall(function() mdt:UpdateToDungeon(match) end)
			if not ok then Dbg("MDT UpdateToDungeon error:", tostring(err)) end
			return
		end
		if attempts < 40 then C_Timer.After(0.05, tryUpdate) end  -- ~2s ceiling
	end
	C_Timer.After(0, tryUpdate)
	return true
end

local function CreateSeparator(parent)
	local sep = CreateFrame("Frame", nil, parent)
	sep:SetHeight(SEPARATOR_HEIGHT)
	local line = sep:CreateTexture(nil, "ARTWORK")
	line:SetHeight(1)
	line:SetPoint("LEFT", sep, "LEFT", 0, 0)
	line:SetPoint("RIGHT", sep, "RIGHT", 0, 0)
	line:SetColorTexture(0.6, 0.5, 0.2, 0.6)
	sep.line = line
	sep:Hide()
	return sep
end

local function CreateRow(parent, index)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(FRAME_W - 20, ROW_HEIGHT)
	-- Position is assigned dynamically in Refresh() so section separators
	-- can shift rows down.

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 1, 0.05)

	-- Role icon
	row.role = row:CreateTexture(nil, "ARTWORK")
	row.role:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
	row.role:SetPoint("LEFT", 8, 0)

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

	-- Wishlist indicator: tiny gold star anchored just after the rendered
	-- dungeon name (position recomputed in PopulateRow from text width).
	row.wishStar = row:CreateTexture(nil, "OVERLAY")
	row.wishStar:SetSize(12, 12)
	row.wishStar:SetAtlas("auctionhouse-icon-favorite")
	row.wishStar:Hide()

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

	-- Right cluster: rating -> level, anchored right-to-left from the row's right edge.
	row.rating = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.rating:SetPoint("RIGHT", row, "RIGHT", -16, 0)
	row.rating:SetWidth(50)
	row.rating:SetJustifyH("CENTER")

	-- Custom Skurri-based font (defined at file scope above): bold, chunky,
	-- tabular digits so 1- vs 2-digit levels stay aligned.
	row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightMedium")
	row.level:SetPoint("RIGHT", row.rating, "LEFT", -6, 0)
	row.level:SetWidth(30)
	row.level:SetJustifyH("LEFT")

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
		GameTooltip:AddLine(ns.GetDungeonName(mid), 1, 0.82, 0)
		local best = ns.selfDungeonBest[mid]
		if not best or best.level == 0 then
			GameTooltip:AddLine("You haven't run this dungeon this season.", 0.8, 0.8, 0.8)
		else
			GameTooltip:AddLine(string.format("Your score: |cffffffff%d|r", math.floor(best.mapScore or 0)))
			local status = best.timed and "|cff33ff33timed|r" or "|cffff6666over time|r"
			GameTooltip:AddLine(string.format("Best run: +%d %s (%s)", best.level, status, ns.FormatDuration(best.durationMS)))
		end
		if self.candidateLevel and self.candidateLevel > 0 then
			local newDungeonMin = ns.EstimateMinTimedScore(self.candidateLevel)
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
	row.dungeon:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row.dungeon:SetScript("OnClick", function(self, button)
		Dbg("dungeon row clicked, btn=", button, "challengeMapID=", self.challengeMapID, "keyLevel=", self.keyLevel)
		if not self.challengeMapID or self.challengeMapID == 0 then return end
		if button == "RightButton" then
			TryOpenMDT(self.challengeMapID)
		elseif ns.ShowLootFor then
			ns.ShowLootFor(self.challengeMapID, self.keyLevel)
		end
	end)
	row.dungeon:SetScript("OnEnter", function(self)
		if not self.challengeMapID or self.challengeMapID == 0 then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Left-click: loot preview", 0.7, 0.7, 0.7)
		if GetMDT() then
			GameTooltip:AddLine("Right-click: open MDT", 0.7, 0.7, 0.7)
		end
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
		ns.db.framePos = { relativePoint = rel, x = x, y = y }
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

	if ns.db.framePos then
		f:ClearAllPoints()
		f:SetPoint(ns.db.framePos.relativePoint or "CENTER", UIParent, ns.db.framePos.relativePoint or "CENTER", ns.db.framePos.x or 0, ns.db.framePos.y or 0)
	end
	if ns.db.frameHeight then
		f:SetHeight(math.max(minH, math.min(maxH, ns.db.frameHeight)))
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
		ns.db.frameHeight = math.floor(f:GetHeight())
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
	debugBtn:SetScript("OnClick", function() ns.ShowDebugWindow() end)
	f.debugBtn = debugBtn
	if not ns.db.showDebugButton then debugBtn:Hide() end

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
	-- align to row layout (row width 560 = FRAME_W - 20):
	--   role(8..26) spec(26..44) name(48..188) tp_btn(196..216) dungeon(220..452)
	--   lvl(458..488) rating(494..544) — 16px right padding to row edge
	H("",       8,   18)         -- role
	H("",       26,  18)         -- spec
	H("Player", 48,  140, "LEFT")
	H("Key",    220, 172, "LEFT")
	H("Lvl",    458, 30,  "LEFT")
	H("Rating", 494, 50,  "CENTER")

	for i = 1, MAX_ROWS do
		rows[i] = CreateRow(f, i)
	end

	-- Two separators are enough: party|alts and alts|guildies (or party|guildies
	-- when there are no alts).
	for i = 1, 2 do
		separators[i] = CreateSeparator(f)
	end

	mainFrame = f
	ns.mainFrame = f
	return f
end

-- ----------------------------------------------------------------------------
-- Refresh: party first, then everything else by key level desc
-- ----------------------------------------------------------------------------

local function CollectPartyNames()
	local set, list = {}, {}
	local selfName = ns.NormalizeName(UnitName("player"))
	if selfName then set[selfName] = true; list[#list + 1] = selfName end
	if IsInGroup() then
		local prefix = IsInRaid() and "raid" or "party"
		local n = GetNumGroupMembers()
		for i = 1, n do
			local unit = prefix .. i
			if UnitExists(unit) and not UnitIsUnit(unit, "player") then
				local name = ns.NormalizeName(GetUnitName(unit, true))
				if name and not set[name] then
					set[name] = true
					list[#list + 1] = name
					local entry = ns.keys[name]
					if not entry then
						entry = { level = 0, mapID = 0, rating = 0, lastSeen = GetTime() }
						ns.keys[name] = entry
					end
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

-- Collect each section's full-name list. Sections are dedup'd against earlier
-- sections (party wins over alts wins over guild) so a guildie currently in
-- our party only appears once, at the top.
local function CollectAlts(excludeSet)
	local list = {}
	if not ns.db or not ns.db.myCharacters then return list end
	local selfFull = ns.FullName(ns.NormalizeName(UnitName("player")))
	for fn in pairs(ns.db.myCharacters) do
		if fn ~= selfFull and not excludeSet[fn] then
			list[#list + 1] = fn
			excludeSet[fn] = true
		end
	end
	return list
end

local function CollectGuildies(excludeSet)
	local list = {}
	if not ns.db or not ns.db.cache then return list end
	for fn, rec in pairs(ns.db.cache) do
		if rec.category == "guild" and not excludeSet[fn] then
			list[#list + 1] = fn
			excludeSet[fn] = true
		end
	end
	return list
end

local function EntryFor(fullName)
	local shortName = Ambiguate(fullName, "none")
	local live = ns.keys[shortName]
	local cached = ns.db and ns.db.cache and ns.db.cache[fullName]
	return live or cached or {}, (live ~= nil), shortName
end

local function SortByLevelDesc(list)
	table.sort(list, function(a, b)
		local ea = select(1, EntryFor(a))
		local eb = select(1, EntryFor(b))
		local la = (ea.level) or 0
		local lb = (eb.level) or 0
		if la == lb then return a < b end
		return la > lb
	end)
end

local function PopulateRow(row, fullName, rowIdx, section)
	local entry, isLive, shortName = EntryFor(fullName)

	-- Stripe alpha alternates by visible row index so the pattern stays
	-- consistent across sections.
	row.bg:SetColorTexture(1, 1, 1, rowIdx % 2 == 0 and 0.08 or 0.05)

	ns.SetRoleIcon(row.role, entry.role)

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

	row.nameBtn.text:SetText(shortName)
	local r, g, b = ns.GetClassColor(entry.class)
	row.nameBtn.text:SetTextColor(r, g, b)
	local tip = shortName
	local spec = ns.SpecName(entry.specID)
	if spec then tip = spec .. " " .. (entry.class or "") .. " - " .. shortName end
	row.nameBtn.tip = tip
	row.nameBtn.fullName = shortName

	-- Wishlist star placement is deferred until after the dungeon name has
	-- been set below (we need its rendered width). Pre-decide visibility now.
	local showStar = section ~= "alts"
		and entry.mapID and entry.mapID > 0
		and ns.Wishlist and ns.Wishlist.HasItemForDungeon(entry.mapID)

	local lvl = entry.level or 0
	row.dungeon.challengeMapID = entry.mapID
	row.dungeon.keyLevel = lvl
	if lvl > 0 then
		if isLive then
			row.dungeon.text:SetText(ns.GetDungeonName(entry.mapID))
		else
			-- Cache-only entry: grey the dungeon name to signal stale data.
			row.dungeon.text:SetText("|cff888888" .. ns.GetDungeonName(entry.mapID) .. "|r")
		end
		row.level:SetText(tostring(lvl))
		local lr, lg, lb = ns.KeyLevelColor(lvl)
		row.level:SetTextColor(lr, lg, lb)
		local upgrade = section ~= "alts" and ns.IsKeyUpgrade(entry.mapID, lvl)
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

	local spellID = ns.TELEPORT_SPELL_BY_CHALLENGEMAP[entry.mapID or 0]
	SetTeleportButton(row.teleport, spellID)

	if showStar then
		local w = row.dungeon.text:GetStringWidth() or 0
		local maxOffset = row.dungeon:GetWidth() - 14
		local offset = math.min(w + 3, maxOffset)
		if offset < 0 then offset = 0 end
		row.wishStar:ClearAllPoints()
		row.wishStar:SetPoint("LEFT", row.dungeon, "LEFT", offset, 0)
		row.wishStar:Show()
	else
		row.wishStar:Hide()
	end
end

function ns.Refresh(force)
	if force then
		ns.PullSelf()
		ns.PullFromLibOpenRaid()
		ns.PullFromAstralKeys()
		if LKS and IsInGroup() then LKS.Request("PARTY") end
		if LSP and IsInGroup() and LSP.RequestGroupSpecialization then
			pcall(LSP.RequestGroupSpecialization)
		end
	end
	if not mainFrame then return end

	-- Section 1: current party (live).
	local partyShorts = CollectPartyNames()
	local partyFulls, seen = {}, {}
	for _, sn in ipairs(partyShorts) do
		local fn = ns.FullName(sn)
		if fn and not seen[fn] then
			partyFulls[#partyFulls + 1] = fn
			seen[fn] = true
		end
	end

	-- Section 2: account alts (excluding current player + anyone in party).
	local altFulls = CollectAlts(seen)
	SortByLevelDesc(altFulls)

	-- Section 3: cached guildies (excluding anyone above).
	local guildFulls = CollectGuildies(seen)
	SortByLevelDesc(guildFulls)

	-- Build the layout sequence: row, row, sep, row, sep, row, ...
	-- Each row carries its section so PopulateRow can decide whether to show
	-- the wishlist star (suppressed for alts).
	local items = {}
	for _, fn in ipairs(partyFulls) do items[#items + 1] = { kind = "row", fn = fn, section = "party" } end
	if #partyFulls > 0 and (#altFulls > 0 or #guildFulls > 0) then
		items[#items + 1] = { kind = "sep" }
	end
	for _, fn in ipairs(altFulls) do items[#items + 1] = { kind = "row", fn = fn, section = "alts" } end
	if #altFulls > 0 and #guildFulls > 0 then
		items[#items + 1] = { kind = "sep" }
	end
	for _, fn in ipairs(guildFulls) do items[#items + 1] = { kind = "row", fn = fn, section = "guild" } end

	-- Hide everything first; we'll show only what fits.
	for i = 1, MAX_ROWS do rows[i]:Hide() end
	for i = 1, #separators do separators[i]:Hide() end

	local contentH = mainFrame:GetHeight() - ROWS_TOP_OFFSET - ROWS_BOTTOM_PAD
	local y = 0
	local rowIdx, sepIdx = 0, 0
	for _, item in ipairs(items) do
		if item.kind == "sep" then
			local needed = SEPARATOR_HEIGHT
			if y + needed > contentH then break end
			sepIdx = sepIdx + 1
			local sep = separators[sepIdx]
			if not sep then break end
			sep:ClearAllPoints()
			sep:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 14, -(ROWS_TOP_OFFSET + y))
			sep:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -14, -(ROWS_TOP_OFFSET + y))
			sep:SetHeight(SEPARATOR_HEIGHT)
			sep:Show()
			y = y + SEPARATOR_HEIGHT
		else
			if y + ROW_HEIGHT > contentH then break end
			rowIdx = rowIdx + 1
			local row = rows[rowIdx]
			if not row then break end
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -(ROWS_TOP_OFFSET + y))
			PopulateRow(row, item.fn, rowIdx, item.section)
			row:Show()
			y = y + ROW_HEIGHT
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
