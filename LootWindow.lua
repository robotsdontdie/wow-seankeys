local ADDON_NAME, ns = ...

-- ============================================================================
-- LootWindow: left-click a dungeon name to open a window listing the loot
-- the player's current spec can receive from that dungeon.
-- ============================================================================

local function Dbg(...) if ns.Dbg then ns.Dbg(...) end end

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

-- Deterministic order for picking "the" stat on a trinket that has only one
-- secondary. pairs() iteration order isn't stable, so we walk this list.
local SECONDARY_ORDER = {
	"ITEM_MOD_CRIT_RATING_SHORT", "ITEM_MOD_HASTE_RATING_SHORT",
	"ITEM_MOD_MASTERY_RATING_SHORT", "ITEM_MOD_VERSATILITY",
	"ITEM_MOD_LEECH_RATING_SHORT", "ITEM_MOD_LIFESTEAL_SHORT",
	"ITEM_MOD_AVOIDANCE_RATING_SHORT", "ITEM_MOD_SPEED_RATING_SHORT",
}

local PRIMARY_ORDER = {
	{ key = "ITEM_MOD_STRENGTH_SHORT",  label = "Strength"  },
	{ key = "ITEM_MOD_AGILITY_SHORT",   label = "Agility"   },
	{ key = "ITEM_MOD_INTELLECT_SHORT", label = "Intellect" },
	{ key = "ITEM_MOD_STAMINA_SHORT",   label = "Stamina"   },
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

-- Picks the most "headline" stat for a trinket: primary stat (Str/Agi/Int) if
-- present, else stamina, else the first non-zero secondary in canonical order.
local function GetTrinketFlatStat(itemLink)
	if not itemLink then return nil end
	local stats = (C_Item and C_Item.GetItemStats and C_Item.GetItemStats(itemLink)) or GetItemStats(itemLink)
	if not stats then return nil end
	for _, entry in ipairs(PRIMARY_ORDER) do
		if stats[entry.key] and stats[entry.key] > 0 then return entry.label end
	end
	for _, key in ipairs(SECONDARY_ORDER) do
		if stats[key] and stats[key] > 0 then return SECONDARY_LABELS[key] end
	end
	return nil
end

-- "On Use" if the tooltip has a "Use:" line, "Proc" if it has an "Equip:"
-- line that describes a triggered effect. Returns nil for plain stat sticks.
local function GetTrinketTriggerKind(itemID)
	if not itemID or not C_TooltipInfo or not C_TooltipInfo.GetItemByID then return nil end
	local data = C_TooltipInfo.GetItemByID(itemID)
	if not data or not data.lines then return nil end
	local onUse = ITEM_SPELL_TRIGGER_ONUSE   or "Use:"
	local onEq  = ITEM_SPELL_TRIGGER_ONEQUIP or "Equip:"
	for _, line in ipairs(data.lines) do
		local t = line.leftText
		if t then
			if t:sub(1, #onUse) == onUse then return "On Use" end
			if t:sub(1, #onEq)  == onEq  then return "Proc" end
		end
	end
	return nil
end

local function IsTrinket(itemID)
	if not itemID then return false end
	local _, _, _, equipLoc = C_Item.GetItemInfoInstant(itemID)
	return equipLoc == "INVTYPE_TRINKET"
end

local function FormatStatsText(itemID, itemLink)
	if IsTrinket(itemID) then
		local stat = GetTrinketFlatStat(itemLink) or "?"
		local trigger = GetTrinketTriggerKind(itemID)
		if trigger then return stat .. " / " .. trigger end
		return stat
	end
	local secs = GetSecondaries(itemLink)
	return (secs == "") and "|cff666666-|r" or secs
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

-- Loading Blizzard_EncounterJournal causes EJ to register with UIParent's
-- panel manager. If we load it from inside a click handler (or any tainted
-- chain), our addon's execution context rides into the panel manager and
-- gets blamed for unrelated protected calls later (e.g. UseContainerItem on
-- a bag click). Wrapping the call in `securecallfunction` strips our
-- identity for the load, so EJ registers as Blizzard rather than SeanKeys.
-- See SeanKeys.lua's PLAYER_LOGIN handler for a one-shot pre-load too.
local function EnsureEJLoaded()
	if C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal") then return true end
	Dbg("  loading Blizzard_EncounterJournal addon (securecall)")
	local ok, reason = securecallfunction(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal")
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
		Dbg("  loading Blizzard_EncounterJournal addon (securecall)")
		-- See EnsureEJLoaded above for why securecallfunction is required.
		local loaded, reason = securecallfunction(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal")
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

-- State for the active loot view. Reset on each ShowLootFor (per the spec
-- "default to current spec"). The spec selector dropdown mutates
-- activeClassID/activeSpecID and calls RenderLoot to refresh in place.
local activeMapID, activeKeyLevel, activeJournalID
local activeClassID, activeSpecID

-- Forward declarations: BuildLootFrame's OnClick captures ShowSpecMenu before
-- the function is defined. Declaring them as file-locals up here lets the
-- closure bind to the same upvalue we later assign.
local UpdateSpecSelectorText, ShowSpecMenu, RenderLoot

local function ClassDisplay(classID)
	if not classID then return nil, nil end
	local info = C_CreatureInfo and C_CreatureInfo.GetClassInfo and C_CreatureInfo.GetClassInfo(classID)
	if info then return info.className, info.classFile end
	for i = 1, GetNumClasses() do
		local n, file, id = GetClassInfo(i)
		if id == classID then return n, file end
	end
	return nil, nil
end

local function SpecName(specID)
	if not specID then return nil end
	local _, name = GetSpecializationInfoByID(specID)
	return name
end

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

-- Star button visibility on a gear row. Empty outline star on hover, filled
-- gold star when wishlisted, hidden otherwise. The row's iconBtn child captures
-- mouse over its area, so hovering the icon does not show the star — by spec.
local function UpdateStarVisibility(row)
	local star = row and row.star
	if not star then return end
	if not star.itemID then star:Hide(); return end
	local wished = ns.Wishlist and ns.Wishlist.IsWishlisted(star.itemID)
	local hovered = row._rowHover
	if wished then
		star.icon:SetAtlas("auctionhouse-icon-favorite")
		star.icon:SetAlpha(1.0)
		star:Show()
	elseif hovered then
		-- Same filled gold star, half-faded — reads as "ghost preview" of
		-- what the click will produce, in the same color as the real thing.
		star.icon:SetAtlas("auctionhouse-icon-favorite")
		star.icon:SetAlpha(0.45)
		star:Show()
	else
		star:Hide()
	end
end

local function BuildLootFrame()
	if lootFrame then return lootFrame end
	local f = CreateFrame("Frame", "SeanKeysLootFrame", UIParent, "PortraitFrameTemplate")
	tinsert(UISpecialFrames, "SeanKeysLootFrame")  -- ESC closes
	-- height = chrome + gear rows + other-items section + footer
	local otherSectionH = 24 + (OTHER_ICON_SIZE + 4) * OTHER_MAX_ROWS
	f:SetSize(LOOT_FRAME_W, 80 + LOOT_ROW_H * LOOT_NUM_GEAR_ROWS + otherSectionH + 24)
	f:SetPoint("CENTER")
	f:SetFrameStrata("MEDIUM")
	-- Higher than the keys window's 500 so the loot popup floats above it
	-- when both are on screen. PromoteFrameLevels also bumps the template
	-- children so the portrait/close button don't render under other addons.
	-- See KeysWindow.lua BuildFrame and Core.lua PromoteFrameLevels for the
	-- full rationale.
	ns.PromoteFrameLevels(f, 2100)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	-- Title and portrait set per-dungeon by ShowLootFor.
	if f.Inset and f.Inset.Bg then f.Inset.Bg:SetAlpha(0.7) end

	-- Clickable subtitle: shows the active class+spec+preview level and opens
	-- a class>spec context menu when clicked. The text is set by
	-- UpdateSpecSelectorText below.
	f.specSelector = CreateFrame("Button", nil, f)
	f.specSelector:SetSize(LOOT_FRAME_W - 60, 22)
	f.specSelector:SetPoint("TOP", 0, -28)
	f.specSelector.text = f.specSelector:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	-- Center-anchored with no width constraint so the FontString sizes to its
	-- content; the arrow anchors to the text's right edge so it sits flush with
	-- the name regardless of how long the class/spec label is.
	f.specSelector.text:SetPoint("CENTER")
	f.specSelector.text:SetJustifyH("CENTER")
	f.specSelector.arrow = f.specSelector:CreateTexture(nil, "OVERLAY")
	f.specSelector.arrow:SetSize(10, 10)
	f.specSelector.arrow:SetPoint("LEFT", f.specSelector.text, "RIGHT", 2, -1)
	f.specSelector.arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
	-- Hover highlight (a faint white wash so it reads as a button).
	local hl = f.specSelector:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.08)
	f.specSelector:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Click to filter by a different spec", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	f.specSelector:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.specSelector:SetScript("OnClick", function(self) ShowSpecMenu(self) end)

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

		-- Wishlist star at the right edge of the row.
		local star = CreateFrame("Button", nil, row)
		star:SetSize(18, 18)
		star:SetPoint("RIGHT", row, "RIGHT", -6, 0)
		star:RegisterForClicks("LeftButtonUp")
		star.icon = star:CreateTexture(nil, "ARTWORK")
		star.icon:SetAllPoints()
		star.parentRow = row
		star:SetScript("OnClick", function(self)
			if not self.itemID or not ns.Wishlist then return end
			ns.Wishlist.Toggle(self.itemID, self.challengeMapID, self.itemName)
			UpdateStarVisibility(self.parentRow)
			-- Update tooltip to reflect the new state.
			if GameTooltip:IsOwned(self) then
				GameTooltip:SetText(ns.Wishlist.IsWishlisted(self.itemID) and "Remove from wishlist" or "Add to wishlist", 1, 1, 1)
				GameTooltip:Show()
			end
		end)
		star:SetScript("OnEnter", function(self)
			if self.itemID then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText(ns.Wishlist and ns.Wishlist.IsWishlisted(self.itemID) and "Remove from wishlist" or "Add to wishlist", 1, 1, 1)
				GameTooltip:Show()
			end
		end)
		star:SetScript("OnLeave", function() GameTooltip:Hide() end)
		star:Hide()
		row.star = star

		-- OnEnter/OnLeave on adjacent rows can race when the cursor moves
		-- quickly (one OnLeave gets eaten, leaving a row "stuck" hovered).
		-- Poll IsMouseOver each frame instead — geometry is authoritative.
		-- The iconBtn area is excluded so hovering the icon doesn't show the
		-- star (matches the original UX spec).
		row:SetScript("OnUpdate", function(self)
			local nowHover = self:IsMouseOver() and not self.iconBtn:IsMouseOver()
			if nowHover ~= self._rowHover then
				self._rowHover = nowHover
				UpdateStarVisibility(self)
			end
		end)

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

-- The EJ-provided slot string is empty when an item isn't cached yet (typical
-- on the first loot-window open this session). `GetItemInfoInstant` returns
-- the equipLoc constant synchronously even on a cold cache, and WoW publishes
-- localized globals like `_G.INVTYPE_HEAD = "Head"` we can use for display.
local function ResolveSlotText(lootInfo)
	if lootInfo.slot and lootInfo.slot ~= "" then return lootInfo.slot end
	if not lootInfo.itemID then return nil end
	local _, _, _, equipLoc = C_Item.GetItemInfoInstant(lootInfo.itemID)
	if equipLoc and equipLoc ~= "" then
		local localized = _G[equipLoc]
		if localized and localized ~= "" then return localized end
	end
	return nil
end

local function PopulateLootRow(row, lootInfo, challengeMapID)
	row:Show()
	row.iconBtn.itemID = lootInfo.itemID
	row.iconBtn.itemLink = lootInfo.link
	row.iconBtn.icon:SetTexture(lootInfo.icon or GetItemIcon(lootInfo.itemID) or 134400)
	row.slot:SetText(ResolveSlotText(lootInfo) or "|cff888888loading...|r")
	row.stats:SetText("|cff888888loading...|r")

	-- Reset hover state and bind star to this item / dungeon.
	row._rowHover = false
	row.star.itemID = lootInfo.itemID
	row.star.challengeMapID = challengeMapID
	row.star.itemName = lootInfo.name
	UpdateStarVisibility(row)

	local item = lootInfo.link and Item:CreateFromItemLink(lootInfo.link)
		or Item:CreateFromItemID(lootInfo.itemID)
	item:ContinueOnItemLoad(function()
		if row.iconBtn.itemID ~= lootInfo.itemID then return end
		local link = item:GetItemLink() or lootInfo.link
		row.iconBtn.itemLink = link
		row.stats:SetText(FormatStatsText(lootInfo.itemID, link))
		local icon = item:GetItemIcon()
		if icon then row.iconBtn.icon:SetTexture(icon) end
		-- Slot may still be missing if the EJ payload was empty; retry now
		-- that the item is fully cached.
		local slotText = ResolveSlotText(lootInfo)
		if slotText then row.slot:SetText(slotText) end
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

UpdateSpecSelectorText = function(f)
	if not f or not f.specSelector then return end
	local className, classFile = ClassDisplay(activeClassID)
	local specName = SpecName(activeSpecID)
	local color = classFile and RAID_CLASS_COLORS[classFile]
	local hex = color and color.colorStr or "ffffffff"
	f.specSelector.text:SetText(string.format("|c%s%s %s|r",
		hex, specName or "", className or ""))
end

ShowSpecMenu = function(button)
	if not MenuUtil or not MenuUtil.CreateContextMenu then
		Dbg("ShowSpecMenu: MenuUtil unavailable")
		return
	end
	MenuUtil.CreateContextMenu(button, function(owner, root)
		root:CreateTitle("Filter loot by spec")
		for i = 1, GetNumClasses() do
			local className, classFile, classID = GetClassInfo(i)
			local color = RAID_CLASS_COLORS[classFile]
			local label = color and string.format("|c%s%s|r", color.colorStr, className) or className
			local classMenu = root:CreateButton(label)
			for s = 1, GetNumSpecializationsForClassID(classID) do
				local specID, specName = GetSpecializationInfoForClassID(classID, s)
				classMenu:CreateRadio(
					specName,
					function() return activeSpecID == specID end,
					function()
						activeClassID = classID
						activeSpecID = specID
						RenderLoot()
					end)
			end
		end
	end)
end

-- Re-fetch and re-render the loot grid for the active dungeon + spec. Safe to
-- call repeatedly without re-resolving the journal instance — used both by
-- ShowLootFor (initial render) and the spec selector dropdown (re-render).
RenderLoot = function()
	local f = lootFrame
	if not f then return end
	UpdateSpecSelectorText(f)

	local function HideAll()
		for i = 1, LOOT_NUM_GEAR_ROWS do lootRows[i]:Hide() end
		for i = 1, OTHER_MAX_ICONS do otherIcons[i]:Hide() end
		f.otherHeading:Hide()
	end

	if not activeJournalID then
		f.hint:SetText("|cffff6666Couldn't resolve journal instance. Check Debug log.|r")
		HideAll()
		return
	end

	-- Update the journal's preview-level state to the active key level so item
	-- links return the correct ilvl scaling.
	if C_EncounterJournal and C_EncounterJournal.SetPreviewMythicPlusLevel then
		C_EncounterJournal.SetPreviewMythicPlusLevel(activeKeyLevel)
	end

	local loot = GatherLoot(activeJournalID, activeClassID, activeSpecID)

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
	Dbg("RenderLoot: split", #gear, "gear,", #other, "other")

	HideAll()
	for i = 1, math.min(#gear, LOOT_NUM_GEAR_ROWS) do
		PopulateLootRow(lootRows[i], gear[i], activeMapID)
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
end

function ns.ShowLootFor(challengeMapID, keyLevel)
	Dbg("=== ShowLootFor invoked, challengeMapID=", challengeMapID, "keyLevel=", keyLevel, " ===")
	local f = BuildLootFrame()
	local dungeonName = ns.GetDungeonName(challengeMapID)
	Dbg("dungeon name resolved:", dungeonName)

	-- Reset spec to player's current on each (re-)open of the loot window.
	local _, _, classID = UnitClass("player")
	local specIdx = GetSpecialization()
	local specID = specIdx and (GetSpecializationInfo(specIdx)) or nil
	activeClassID = classID
	activeSpecID = specID
	activeMapID = challengeMapID
	activeKeyLevel = (keyLevel and keyLevel > 0) and keyLevel or (C_MythicPlus.GetOwnedKeystoneLevel() or 0)
	if activeKeyLevel == 0 then activeKeyLevel = 10 end
	Dbg("player: classID=", classID, "specID=", specID, "previewLevel=", activeKeyLevel)

	if C_EncounterJournal and C_EncounterJournal.SetPreviewMythicPlusLevel then
		EnsureEJLoaded()
		C_EncounterJournal.SetPreviewMythicPlusLevel(activeKeyLevel)
	end

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

	activeJournalID = GetJournalInstance(challengeMapID)
	RenderLoot()
	f:Show()
end
