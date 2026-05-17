local ADDON_NAME, ns = ...

-- ============================================================================
-- ConsumableShopping: a custom Auction House tab that surfaces per-character,
-- per-spec consumable shopping lists. Each row shows your bag count vs. a
-- target, and if you're short, the per-unit and total AH price plus a "Buy"
-- button that drives the commodity-purchase flow end-to-end.
--
-- Companion module: ConsumableSettings.lua (the settings window).
-- ============================================================================

local function Dbg(...) if ns.Dbg then ns.Dbg(...) end end

-- ----------------------------------------------------------------------------
-- Current-season consumables — UPDATE EACH SEASON
--
-- Midnight S1 (Interface 120005). Sourced from Wowhead. See CLAUDE.md
-- "Per-season data tables".
--
-- Schema: CURRENT_SEASON_CONSUMABLES[category] = { { itemID, name }, ... }
-- (name is purely a fallback for the picker dropdown; we resolve real names
--  via C_Item.GetItemInfo at runtime once items are cached.)
-- ----------------------------------------------------------------------------
ns.CURRENT_SEASON_CONSUMABLES = {
	food = {
		{ itemID = 255845, name = "Silvermoon Parade" },        -- primary-stat feast
		{ itemID = 255847, name = "Impossibly Royal Roast" },   -- primary-stat feast
		{ itemID = 242283, name = "Sun-Seared Lumifin" },       -- Crit
		{ itemID = 242285, name = "Warped Wise Wings" },        -- Mastery
		{ itemID = 242284, name = "Void-Kissed Fish Rolls" },   -- Versatility
	},
	flask = {
		{ itemID = 241320, name = "Flask of Thalassian Resistance" }, -- Versatility
		{ itemID = 241325, name = "Flask of the Blood Knights" },     -- Haste
		{ itemID = 241322, name = "Flask of the Magisters" },         -- Mastery
	},
	combatPotion = {
		{ itemID = 241296, name = "Potion of Zealotry" },
		{ itemID = 241289, name = "Potion of Recklessness" },
		{ itemID = 241293, name = "Draught of Rampant Abandon" },
	},
	healthPotion = {
		{ itemID = 241305, name = "Silvermoon Health Potion" },
		{ itemID = 241300, name = "Lightfused Mana Potion" },
	},
	weaponEnchant = {
		{ itemID = 243733, name = "Thalassian Phoenix Oil" },
		{ itemID = 243738, name = "Smuggler's Enchanted Edge" },
		{ itemID = 237370, name = "Refulgent Whetstone" },  -- bladed weapons
		{ itemID = 237367, name = "Refulgent Weightstone" }, -- blunt weapons
	},
	augmentRune = {
		{ itemID = 259085, name = "Void-Touched Augment Rune" },
	},
}

ns.CONSUMABLE_CATEGORIES = {
	{ key = "food",          label = "Buff Food" },
	{ key = "flask",         label = "Flask" },
	{ key = "combatPotion",  label = "Combat Potion" },
	{ key = "healthPotion",  label = "Health Potion" },
	{ key = "weaponEnchant", label = "Weapon Enchant" },
	{ key = "augmentRune",   label = "Augment Rune" },
}

-- ----------------------------------------------------------------------------
-- Data access helpers
-- ----------------------------------------------------------------------------

local function CurrentSpecID()
	local idx = GetSpecialization()
	if not idx then return nil end
	local id = GetSpecializationInfo(idx)
	return id
end

local function GetSpecList(specID)
	if not specID or not ns.charDb then return nil end
	ns.charDb.consumables = ns.charDb.consumables or {}
	local bySpec = ns.charDb.consumables
	if not bySpec[specID] then
		bySpec[specID] = { food = {}, flask = {}, combatPotion = {}, healthPotion = {}, weaponEnchant = {}, augmentRune = {} }
	end
	for _, cat in ipairs(ns.CONSUMABLE_CATEGORIES) do
		bySpec[specID][cat.key] = bySpec[specID][cat.key] or {}
	end
	return bySpec[specID]
end
ns.ConsumablesGetSpecList = GetSpecList

local function GetBagCount(itemID)
	if not itemID then return 0 end
	if C_Item and C_Item.GetItemCount then
		return C_Item.GetItemCount(itemID, false, false, true) or 0
	end
	return GetItemCount(itemID) or 0
end

-- Build the flat list of {category, itemID, entry, listRef} the tab will
-- display. `entry` is the underlying SeanKeysCharDB entry so inline editors
-- (target qty editbox, remove button) can mutate it directly; `listRef` is the
-- category's array for remove operations.
local function BuildDisplayList(specID)
	local list = GetSpecList(specID)
	if not list then return {} end
	local out = {}
	for _, cat in ipairs(ns.CONSUMABLE_CATEGORIES) do
		for _, entry in ipairs(list[cat.key] or {}) do
			out[#out + 1] = {
				category = cat.key,
				label = cat.label,
				itemID = entry.itemID,
				entry = entry,
				listRef = list[cat.key],
			}
		end
	end
	return out
end

-- ----------------------------------------------------------------------------
-- List mutation helpers (used by Add menu + per-row X button)
-- ----------------------------------------------------------------------------

local function FindEntry(list, itemID)
	for i, e in ipairs(list) do
		if e.itemID == itemID then return i, e end
	end
	return nil, nil
end

local function AddOrUpdate(list, itemID, target)
	local _, existing = FindEntry(list, itemID)
	if existing then
		existing.target = target
		return
	end
	list[#list + 1] = { itemID = itemID, target = target }
end

local function RemoveEntry(list, itemID)
	local idx = FindEntry(list, itemID)
	if idx then table.remove(list, idx) end
end

-- ----------------------------------------------------------------------------
-- Search queue
--
-- We need a price for every configured itemID on tab show. The AH's throttling
-- system prefers we space queries out. We feed one search at a time, advancing
-- on COMMODITY_SEARCH_RESULTS_UPDATED (or ITEM_SEARCH_RESULTS_UPDATED) and on
-- AUCTION_HOUSE_THROTTLED_SYSTEM_READY. Results land in `priceCache` keyed by
-- itemID; rows poll the cache on every refresh.
-- ----------------------------------------------------------------------------

local searchQueue = {}
local searching = false
local activeSearchItemID
local priceCache = {}   -- [itemID] = { perUnit, totalQty }

local function MakeItemKey(itemID)
	return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
end

-- Forward decl: TryNextSearch is called by event handlers below.
local TryNextSearch

local function OnCommodityResults(itemID)
	if itemID ~= activeSearchItemID then return end
	local count = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
	local perUnit, totalQty
	for i = 1, count do
		local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
		if r and r.unitPrice and r.unitPrice > 0 then
			if not perUnit or r.unitPrice < perUnit then perUnit = r.unitPrice end
			totalQty = (totalQty or 0) + (r.quantity or 0)
		end
	end
	priceCache[itemID] = { perUnit = perUnit, totalQty = totalQty or 0, kind = "commodity" }
	searching = false
	activeSearchItemID = nil
	if ns.ConsumablesRefreshRows then ns.ConsumablesRefreshRows() end
	TryNextSearch()
end

local function OnItemResults(itemKey)
	if not itemKey or itemKey.itemID ~= activeSearchItemID then return end
	local count = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
	local perUnit, totalQty
	for i = 1, count do
		local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
		if r and r.buyoutAmount and r.buyoutAmount > 0 then
			local unit = r.quantity and r.quantity > 0 and (r.buyoutAmount / r.quantity) or r.buyoutAmount
			if not perUnit or unit < perUnit then perUnit = unit end
			totalQty = (totalQty or 0) + (r.quantity or 0)
		end
	end
	priceCache[activeSearchItemID] = { perUnit = perUnit and math.floor(perUnit) or nil, totalQty = totalQty or 0, kind = "item" }
	searching = false
	activeSearchItemID = nil
	if ns.ConsumablesRefreshRows then ns.ConsumablesRefreshRows() end
	TryNextSearch()
end

TryNextSearch = function()
	if searching then return end
	if #searchQueue == 0 then return end
	if not C_AuctionHouse then return end
	if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
		-- Wait for the throttled-system-ready event; we'll be re-driven there.
		return
	end
	local itemID = table.remove(searchQueue, 1)
	activeSearchItemID = itemID
	searching = true
	local sorts = {{ sortOrder = Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false }}
	-- Commodities (stacked AH listings) use SendSearchQuery with the commodity
	-- result event. Non-commodity items use the same SendSearchQuery but emit
	-- ITEM_SEARCH_RESULTS_UPDATED. We try commodity-first; ITEM_SEARCH fallback
	-- triggers via the same event registration.
	C_AuctionHouse.SendSearchQuery(MakeItemKey(itemID), sorts, true)
end

local function EnqueueSearchesForList(list)
	wipe(searchQueue)
	for _, entry in ipairs(list) do
		searchQueue[#searchQueue + 1] = entry.itemID
	end
	TryNextSearch()
end

-- ----------------------------------------------------------------------------
-- Buy flow
--
-- Commodities: StartCommoditiesPurchase(itemID, quantity) returns asynchronously
-- via COMMODITY_PRICE_UPDATED; only after that event may we call
-- ConfirmCommoditiesPurchase. We track the active purchase here.
-- ----------------------------------------------------------------------------

local pendingBuy   -- { itemID, qty }

local function StartBuy(itemID, qty)
	if not itemID or not qty or qty <= 0 then return end
	if InCombatLockdown() then return end
	if not C_AuctionHouse or not C_AuctionHouse.StartCommoditiesPurchase then return end
	pendingBuy = { itemID = itemID, qty = qty }
	-- Wrap in securecallfunction: the AH protected calls walk a panel-manager
	-- chain we don't want SeanKeys taint propagating into.
	securecallfunction(C_AuctionHouse.StartCommoditiesPurchase, itemID, qty)
end

local function OnCommodityPriceUpdated(itemID, qty)
	if not pendingBuy or pendingBuy.itemID ~= itemID or pendingBuy.qty ~= qty then return end
	if not C_AuctionHouse.ConfirmCommoditiesPurchase then return end
	securecallfunction(C_AuctionHouse.ConfirmCommoditiesPurchase, itemID, qty)
	pendingBuy = nil
end

-- ----------------------------------------------------------------------------
-- UI
-- ----------------------------------------------------------------------------

local CONTENT_W = 760
local CONTENT_H = 460
local ROW_H = 36
local MAX_VISIBLE_ROWS = 11

local contentFrame, contentRows, tabRegistered

local function FormatCoin(copper)
	if not copper or copper <= 0 then return "-" end
	if GetCoinTextureString then return GetCoinTextureString(math.floor(copper)) end
	return tostring(math.floor(copper))
end

local function PopulateRow(row, item)
	row:Show()
	row.itemID = item.itemID
	row.entry = item.entry
	row.listRef = item.listRef

	-- Icon + name
	local icon = GetItemIcon(item.itemID) or 134400
	row.icon:SetTexture(icon)
	local name = (C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(item.itemID)) or GetItemInfo(item.itemID)
	row.name:SetText(name or string.format("Item %d", item.itemID))
	row.category:SetText(item.label)

	local have = GetBagCount(item.itemID)
	local target = (item.entry.target) or 0
	local deficit = math.max(0, target - have)
	-- Bag count color: red at 0, yellow when we have any. The cost cell
	-- separately tells you when you're complete.
	local countColor = have == 0 and "|cffff4040" or "|cffffd060"
	row.have:SetText(string.format("%s%d|r", countColor, have))

	-- Target editbox: only update text if the user isn't currently editing it
	-- (avoids stomping the caret while they're typing).
	if row.targetEdit and not row.targetEdit:HasFocus() then
		row.targetEdit:SetText(tostring(target))
	end

	local cache = priceCache[item.itemID]
	if deficit == 0 then
		row.cost:SetText("|cff33ff33complete|r")
		row.buyBtn:Hide()
	elseif cache and cache.perUnit then
		local total = cache.perUnit * deficit
		row.cost:SetText(string.format("%s |cff888888(%s ea)|r",
			FormatCoin(total), FormatCoin(cache.perUnit)))
		row.buyBtn:SetText(string.format("Buy %d", deficit))
		row.buyBtn:SetEnabled(not InCombatLockdown())
		row.buyBtn.qty = deficit
		row.buyBtn:Show()
	else
		row.cost:SetText("|cff888888searching...|r")
		row.buyBtn:Hide()
	end
end

local function RefreshRows()
	if not contentFrame or not contentFrame:IsShown() then return end
	local specID = CurrentSpecID()
	local list = BuildDisplayList(specID)
	contentFrame.specLabel:SetText(string.format("Spec: |cffffffff%s|r", (specID and ns.SpecName and ns.SpecName(specID)) or "?"))
	for i = 1, MAX_VISIBLE_ROWS do
		contentRows[i]:Hide()
	end
	if #list == 0 then
		contentFrame.empty:Show()
		return
	end
	contentFrame.empty:Hide()
	for i = 1, math.min(#list, MAX_VISIBLE_ROWS) do
		PopulateRow(contentRows[i], list[i])
	end
	if #list > MAX_VISIBLE_ROWS then
		contentFrame.overflow:SetText(string.format("+ %d more (truncated)", #list - MAX_VISIBLE_ROWS))
		contentFrame.overflow:Show()
	else
		contentFrame.overflow:Hide()
	end
end
ns.ConsumablesRefreshRows = RefreshRows

local function CreateRow(parent, idx)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(CONTENT_W - 24, ROW_H)
	row:SetPoint("TOPLEFT", 12, -52 - (idx - 1) * ROW_H)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 1, idx % 2 == 0 and 0.08 or 0.04)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ROW_H - 6, ROW_H - 6)
	row.icon:SetPoint("LEFT", 4, 0)
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	row.category = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.category:SetPoint("LEFT", row.icon, "RIGHT", 8, 8)
	row.category:SetWidth(110)
	row.category:SetJustifyH("LEFT")

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, -6)
	row.name:SetWidth(220)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row.have = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.have:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
	row.have:SetWidth(40)
	row.have:SetJustifyH("CENTER")

	-- Inline target editbox: mutates row.entry.target directly. PopulateRow
	-- avoids stomping the caret while the user is typing (HasFocus check).
	row.targetEdit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.targetEdit:SetSize(44, 20)
	row.targetEdit:SetPoint("LEFT", row.have, "RIGHT", 14, 0)
	row.targetEdit:SetAutoFocus(false)
	row.targetEdit:SetNumeric(true)
	row.targetEdit:SetMaxLetters(4)
	row.targetEdit:SetScript("OnTextChanged", function(self)
		if row.entry then
			row.entry.target = tonumber(self:GetText()) or 0
		end
		if ns.ConsumablesRefreshRows then ns.ConsumablesRefreshRows() end
	end)
	row.targetEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	row.targetEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.cost:SetPoint("LEFT", row.targetEdit, "RIGHT", 12, 0)
	row.cost:SetWidth(200)
	row.cost:SetJustifyH("RIGHT")

	row.buyBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.buyBtn:SetSize(72, 22)
	row.buyBtn:SetPoint("LEFT", row.cost, "RIGHT", 6, 0)
	row.buyBtn:SetText("Buy")
	row.buyBtn:SetScript("OnClick", function(self)
		if not row.itemID or not self.qty or self.qty <= 0 then return end
		StartBuy(row.itemID, self.qty)
	end)

	-- Small clear-X delete button. Matches the same atlas SeanKeys uses
	-- elsewhere for inline remove actions.
	row.removeBtn = CreateFrame("Button", nil, row)
	row.removeBtn:SetSize(18, 18)
	row.removeBtn:SetPoint("LEFT", row.buyBtn, "RIGHT", 6, 0)
	local rmIcon = row.removeBtn:CreateTexture(nil, "ARTWORK")
	rmIcon:SetAllPoints()
	rmIcon:SetAtlas("common-search-clearbutton")
	row.removeBtn:SetNormalTexture(rmIcon)
	local rmHl = row.removeBtn:CreateTexture(nil, "HIGHLIGHT")
	rmHl:SetAllPoints()
	rmHl:SetAtlas("common-search-clearbutton")
	rmHl:SetBlendMode("ADD")
	rmHl:SetAlpha(0.5)
	row.removeBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Remove from list", 1, 1, 1)
		GameTooltip:Show()
	end)
	row.removeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row.removeBtn:SetScript("OnClick", function()
		if not row.itemID or not row.listRef then return end
		RemoveEntry(row.listRef, row.itemID)
		if ns.ConsumablesRefreshRows then ns.ConsumablesRefreshRows() end
	end)

	-- Tooltip on hover for the item icon area only (so it doesn't blanket
	-- the row and block the inline controls).
	row.icon:SetDrawLayer("ARTWORK")
	row.iconHit = CreateFrame("Frame", nil, row)
	row.iconHit:SetAllPoints(row.icon)
	row.iconHit:EnableMouse(true)
	row.iconHit:SetScript("OnEnter", function()
		if not row.itemID then return end
		GameTooltip:SetOwner(row.iconHit, "ANCHOR_RIGHT")
		GameTooltip:SetItemByID(row.itemID)
		GameTooltip:Show()
	end)
	row.iconHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

	row:Hide()
	return row
end

-- Category > item submenu picker. Adds a fresh entry to the current spec's
-- list with a default target of 20, then refreshes the tab.
local function ShowAddMenu(button)
	if not MenuUtil or not MenuUtil.CreateContextMenu then return end
	local specID = CurrentSpecID()
	if not specID then return end
	local specList = GetSpecList(specID)
	if not specList then return end
	MenuUtil.CreateContextMenu(button, function(_, root)
		root:CreateTitle("Add a consumable")
		for _, cat in ipairs(ns.CONSUMABLE_CATEGORIES or {}) do
			local catMenu = root:CreateButton(cat.label)
			local options = (ns.CURRENT_SEASON_CONSUMABLES and ns.CURRENT_SEASON_CONSUMABLES[cat.key]) or {}
			for _, opt in ipairs(options) do
				local realName = (C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(opt.itemID)) or opt.name
				catMenu:CreateButton(realName, function()
					AddOrUpdate(specList[cat.key], opt.itemID, 20)
					if ns.ConsumablesRefreshRows then ns.ConsumablesRefreshRows() end
					-- Kick a price query for the newly-added item.
					searchQueue[#searchQueue + 1] = opt.itemID
					TryNextSearch()
				end)
			end
		end
	end)
end

local function BuildContentFrame()
	if contentFrame then return contentFrame end
	-- Anonymous + parented to AuctionHouseFrame. We don't go through
	-- ns.GetContainer here because the tab body must live inside the AH frame
	-- to be hidden/shown by LibAHTab's tab switch logic.
	local f = CreateFrame("Frame", nil, AuctionHouseFrame)
	f:SetSize(CONTENT_W, CONTENT_H)
	-- Auctionator and the built-in AH tabs anchor their bodies at TOPLEFT 0,
	-- -60 (just below the tab strip). Match that.
	f:SetPoint("TOPLEFT", 0, -60)
	f:Hide()

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOPLEFT", 12, -8)
	f.title:SetText("SeanKeys Consumables")

	f.specLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.specLabel:SetPoint("LEFT", f.title, "RIGHT", 16, 0)

	-- Refresh on the right, Add to its left.
	local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	refreshBtn:SetSize(80, 22)
	refreshBtn:SetPoint("TOPRIGHT", -12, -8)
	refreshBtn:SetText("Refresh")
	refreshBtn:SetScript("OnClick", function()
		wipe(priceCache)
		RefreshRows()
		local list = BuildDisplayList(CurrentSpecID())
		EnqueueSearchesForList(list)
	end)

	local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	addBtn:SetSize(80, 22)
	addBtn:SetPoint("RIGHT", refreshBtn, "LEFT", -4, 0)
	addBtn:SetText("Add...")
	addBtn:SetScript("OnClick", function(self) ShowAddMenu(self) end)
	f.addBtn = addBtn

	-- Column headers
	local function H(text, x, w, justify)
		local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("TOPLEFT", x, -36)
		fs:SetWidth(w)
		fs:SetJustifyH(justify or "LEFT")
		fs:SetText("|cffffcc00" .. text .. "|r")
	end
	-- X coords are f-relative (parent frame). Row body starts at x=12;
	-- icon spans 16..46; category/name 54..274; bags 282..322 centered;
	-- target editbox 336..380; cost 392..592 right-aligned.
	H("Item",   54,  220, "LEFT")
	H("Bags",   282, 40,  "CENTER")
	H("Target", 336, 44,  "CENTER")
	H("Cost",   392, 200, "RIGHT")

	contentRows = {}
	for i = 1, MAX_VISIBLE_ROWS do
		contentRows[i] = CreateRow(f, i)
	end

	f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.empty:SetPoint("TOP", 0, -120)
	f.empty:SetText("No consumables picked yet. Click |cffffffffAdd...|r above to start.")
	f.empty:Hide()

	f.overflow = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.overflow:SetPoint("BOTTOM", 0, 12)
	f.overflow:Hide()

	-- Drive a fresh search-queue and a refresh whenever the tab body becomes
	-- visible (tab click or AH reopen with this tab already selected).
	f:SetScript("OnShow", function()
		RefreshRows()
		local list = BuildDisplayList(CurrentSpecID())
		EnqueueSearchesForList(list)
	end)

	contentFrame = f
	ns.consumablesFrame = f
	return f
end

local function RegisterTab()
	if tabRegistered then return end
	if not AuctionHouseFrame then return end
	local LibAHTab = LibStub and LibStub("LibAHTab-1-0", true)
	if not LibAHTab then
		Dbg("ConsumableShopping: LibAHTab not available")
		return
	end
	local body = BuildContentFrame()
	-- Tab IDs are global to LibAHTab; namespace ours so we don't collide with
	-- Auctionator or other addons.
	securecallfunction(LibAHTab.CreateTab, LibAHTab, "SeanKeysConsumables", body, "Consumables", "SeanKeys Consumables")
	tabRegistered = true
end
ns.ConsumablesRegisterTab = RegisterTab

-- ----------------------------------------------------------------------------
-- Event plumbing
-- ----------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
ev:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
ev:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
ev:RegisterEvent("COMMODITY_PRICE_UPDATED")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:SetScript("OnEvent", function(self, event, a, b)
	if event == "AUCTION_HOUSE_SHOW" then
		RegisterTab()
	elseif event == "AUCTION_HOUSE_CLOSED" then
		wipe(searchQueue)
		searching = false
		activeSearchItemID = nil
		pendingBuy = nil
	elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		OnCommodityResults(a)
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		OnItemResults(a)
	elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
		TryNextSearch()
	elseif event == "COMMODITY_PRICE_UPDATED" then
		OnCommodityPriceUpdated(a, b)
	elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_SPECIALIZATION_CHANGED" then
		if contentFrame and contentFrame:IsShown() then RefreshRows() end
	end
end)
