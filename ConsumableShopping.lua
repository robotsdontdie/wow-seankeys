local ADDON_NAME, ns = ...

-- ============================================================================
-- ConsumableShopping: a custom Auction House tab that surfaces per-character
-- consumable shopping lists organized into user-named profiles. Each row shows
-- your bag count vs. a target, and if you're short, the per-unit and total AH
-- price plus a "Buy" button that drives the commodity-purchase flow end-to-end.
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
-- Schema notes:
-- * Each crafted consumable has a separate itemID per quality (commodity AH
--   queries key on itemID, so Q1 and Q2 list at different prices). To track
--   them as one row with a quality dropdown, set `qualities = { q1Id, q2Id }`
--   in the order Q1, Q2. The Add menu always inserts the Q1 itemID; the
--   dropdown rewrites `entry.itemID` to the chosen quality's variant.
-- * Sequential-allocation pattern: Midnight allocates consumable itemIDs in
--   (Q2, Q1) order — the higher numeric ID is Q1, the lower is Q2. Verified
--   empirically: at the AH, the higher-priced (more expensive = higher
--   quality = Q1) variant is the larger of the two itemIDs.
-- * For non-craftable items (single-quality), use `itemID = N` instead.
ns.CURRENT_SEASON_CONSUMABLES = {
	food = {
		{ itemID = 255845, name = "Silvermoon Parade" },        -- primary-stat feast
		{ itemID = 255847, name = "Impossibly Royal Roast" },   -- primary-stat feast
		{ itemID = 242283, name = "Sun-Seared Lumifin" },       -- Crit
		{ itemID = 242285, name = "Warped Wise Wings" },        -- Mastery
		{ itemID = 242284, name = "Void-Kissed Fish Rolls" },   -- Versatility
	},
	flask = {
		{ qualities = { 241321, 241320 }, name = "Flask of Thalassian Resistance" }, -- Versatility
		{ qualities = { 241325, 241324 }, name = "Flask of the Blood Knights" },     -- Haste
		{ qualities = { 241323, 241322 }, name = "Flask of the Magisters" },         -- Mastery
	},
	potion = {
		{ itemID = 241296, name = "Potion of Zealotry" },
		{ itemID = 241289, name = "Potion of Recklessness" },
		{ itemID = 241293, name = "Draught of Rampant Abandon" },
		{ itemID = 241305, name = "Silvermoon Health Potion" },
		{ itemID = 241300, name = "Lightfused Mana Potion" },
	},
	weaponEnchant = {
		{ itemID = 243733, name = "Thalassian Phoenix Oil" },
		{ itemID = 243738, name = "Smuggler's Enchanted Edge" },
		{ itemID = 237370, name = "Refulgent Whetstone" },  -- bladed weapons
		{ itemID = 237367, name = "Refulgent Weightstone" }, -- blunt weapons
	},
	other = {
		{ itemID = 259085, name = "Void-Touched Augment Rune" },
		{ itemID = 244639, name = "Void-Touched Drums" },
		{ itemID = 248486, name = "Emergency Soul Link" },  -- Midnight engineering battle rez
	},
}

-- Normalize: every catalog entry exposes `qualities` (array indexed by tier),
-- so resolvers don't have to special-case the `itemID = N` shorthand.
for _, cat in pairs(ns.CURRENT_SEASON_CONSUMABLES) do
	for _, entry in ipairs(cat) do
		if not entry.qualities then
			entry.qualities = { entry.itemID }
		end
		entry.itemID = entry.qualities[1]  -- canonical = Q1 (used by Add menu)
	end
end

ns.CONSUMABLE_CATEGORIES = {
	{ key = "food",          label = "Food" },
	{ key = "flask",         label = "Flask" },
	{ key = "potion",        label = "Potion" },
	{ key = "weaponEnchant", label = "Weapon Enchant" },
	{ key = "other",         label = "Other" },
}

-- Midnight crafting tier caps out at Tier 2 — no Tier 3 quality this season.
local MAX_QUALITY = 2

-- ----------------------------------------------------------------------------
-- Catalog lookup helpers
-- ----------------------------------------------------------------------------

-- Find the catalog entry whose `qualities` array contains the given itemID,
-- plus the index (tier) at which it appears. Returns (catalogEntry, tier).
local function FindCatalogByItemID(itemID)
	if not itemID then return nil, nil end
	for _, cat in pairs(ns.CURRENT_SEASON_CONSUMABLES) do
		for _, entry in ipairs(cat) do
			for tier, id in ipairs(entry.qualities or {}) do
				if id == itemID then return entry, tier end
			end
		end
	end
	return nil, nil
end

-- Given the actual itemID currently on a row and a target quality, return the
-- itemID of the sibling variant at that quality. Falls back to the input
-- itemID if no catalog mapping exists or the requested quality isn't defined
-- (e.g. consumables we haven't mapped quality variants for yet — the
-- dropdown becomes cosmetic for those).
local function ResolveQualityItemID(currentItemID, targetQuality)
	local entry = FindCatalogByItemID(currentItemID)
	if not entry then return currentItemID end
	return entry.qualities[targetQuality] or currentItemID
end

-- ----------------------------------------------------------------------------
-- Data access helpers
-- ----------------------------------------------------------------------------

-- Legacy per-spec key migration: combatPotion / healthPotion -> potion,
-- augmentRune -> other. Also backfills `quality = 1` on entries that pre-date
-- the quality field, and clamps quality to MAX_QUALITY (Midnight dropped T3).
-- Final pass syncs each entry's stored quality with the catalog tier of its
-- itemID — handy when a pre-existing row stored a Q2 itemID but has
-- `quality = 1` recorded (the catalog now knows that ID is the Q2 sibling).
-- Idempotent.
local function MigrateLegacyKeys(list)
	if list.combatPotion or list.healthPotion then
		list.potion = list.potion or {}
		for _, e in ipairs(list.combatPotion or {}) do list.potion[#list.potion + 1] = e end
		for _, e in ipairs(list.healthPotion or {}) do list.potion[#list.potion + 1] = e end
		list.combatPotion = nil
		list.healthPotion = nil
	end
	if list.augmentRune then
		list.other = list.other or {}
		for _, e in ipairs(list.augmentRune) do list.other[#list.other + 1] = e end
		list.augmentRune = nil
	end
	for _, cat in pairs(list) do
		if type(cat) == "table" then
			for _, entry in ipairs(cat) do
				if type(entry) == "table" then
					if not entry.quality then entry.quality = 1 end
					if entry.quality > MAX_QUALITY then entry.quality = MAX_QUALITY end
					local _, catalogTier = FindCatalogByItemID(entry.itemID)
					if catalogTier and catalogTier ~= entry.quality then
						entry.quality = catalogTier
					end
				end
			end
		end
	end
end

-- One-shot migration from the previous spec-keyed schema
-- (`ns.charDb.consumables[specID][category]`) to the new profile-based schema
-- (`ns.charDb.consumableProfiles = { { name, lists }, ... }`). Each non-empty
-- spec entry becomes its own profile, named after the spec. Idempotent: nukes
-- the old key after migration and bails if profiles already exist.
local function MigrateSpecToProfiles()
	if not ns.charDb then return end
	if ns.charDb.consumableProfiles and #ns.charDb.consumableProfiles > 0 then
		ns.charDb.consumables = nil  -- already migrated; drop stale data
		return
	end
	ns.charDb.consumableProfiles = ns.charDb.consumableProfiles or {}
	if type(ns.charDb.consumables) ~= "table" then return end
	for specID, lists in pairs(ns.charDb.consumables) do
		if type(lists) == "table" then
			local hasAny = false
			for _, cat in pairs(lists) do
				if type(cat) == "table" and #cat > 0 then hasAny = true; break end
			end
			if hasAny then
				MigrateLegacyKeys(lists)
				local specName = (ns.SpecName and ns.SpecName(specID))
					or string.format("Profile %d", #ns.charDb.consumableProfiles + 1)
				ns.charDb.consumableProfiles[#ns.charDb.consumableProfiles + 1] = {
					name = specName,
					lists = lists,
				}
			end
		end
	end
	ns.charDb.consumables = nil
end

local function GetProfiles()
	if not ns.charDb then return nil end
	MigrateSpecToProfiles()
	ns.charDb.consumableProfiles = ns.charDb.consumableProfiles or {}
	if #ns.charDb.consumableProfiles == 0 then
		ns.charDb.consumableProfiles[1] = { name = "Profile 1", lists = {} }
	end
	local n = #ns.charDb.consumableProfiles
	if not ns.charDb.activeConsumableProfile
		or ns.charDb.activeConsumableProfile < 1
		or ns.charDb.activeConsumableProfile > n then
		ns.charDb.activeConsumableProfile = 1
	end
	return ns.charDb.consumableProfiles
end

local function ActiveProfile()
	local profiles = GetProfiles()
	if not profiles then return nil end
	local p = profiles[ns.charDb.activeConsumableProfile]
	if not p then return nil end
	p.lists = p.lists or {}
	MigrateLegacyKeys(p.lists)
	for _, cat in ipairs(ns.CONSUMABLE_CATEGORIES) do
		p.lists[cat.key] = p.lists[cat.key] or {}
	end
	return p
end

local function ActiveLists()
	local p = ActiveProfile()
	return p and p.lists or nil
end

local function GetBagCount(itemID)
	if not itemID then return 0 end
	if C_Item and C_Item.GetItemCount then
		return C_Item.GetItemCount(itemID, false, false, true) or 0
	end
	return GetItemCount(itemID) or 0
end

-- Build the flat list of {category, itemID, entry, listRef} the tab will
-- display. `entry` is the underlying profile entry so inline editors (target
-- qty editbox, remove button) can mutate it directly; `listRef` is the
-- category's array for remove operations.
local function BuildDisplayList()
	local lists = ActiveLists()
	if not lists then return {} end
	local out = {}
	for _, cat in ipairs(ns.CONSUMABLE_CATEGORIES) do
		for _, entry in ipairs(lists[cat.key] or {}) do
			out[#out + 1] = {
				category = cat.key,
				label = cat.label,
				itemID = entry.itemID,
				entry = entry,
				listRef = lists[cat.key],
			}
		end
	end
	return out
end

-- ----------------------------------------------------------------------------
-- List mutation helpers (used by Add menu + per-row X button)
--
-- Row identity is (itemID, quality). The Add menu always inserts at quality=1
-- and greys out items that already have a quality-1 row, so re-adding the
-- same item is only possible after the user changes the existing row's
-- quality. That lets a user track Q1 and Q2 of the same flask as separate
-- shopping targets.
-- ----------------------------------------------------------------------------

local function FindEntry(list, itemID, quality)
	quality = quality or 1
	for i, e in ipairs(list) do
		if e.itemID == itemID and (e.quality or 1) == quality then return i, e end
	end
	return nil, nil
end

local function AddEntryAtQ1(list, itemID, target)
	if FindEntry(list, itemID, 1) then return end
	list[#list + 1] = { itemID = itemID, quality = 1, target = target }
end

local function RemoveEntry(list, itemID, quality)
	local idx = FindEntry(list, itemID, quality)
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
		if not priceCache[entry.itemID] then
			searchQueue[#searchQueue + 1] = entry.itemID
		end
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
	Dbg(string.format("StartBuy: itemID=%s qty=%s inCombat=%s",
		tostring(itemID), tostring(qty), tostring(InCombatLockdown())))
	if not itemID or not qty or qty <= 0 then
		Dbg("StartBuy: bad args, bailing")
		return
	end
	if InCombatLockdown() then
		Dbg("StartBuy: combat lockdown, bailing")
		return
	end
	if not C_AuctionHouse or not C_AuctionHouse.StartCommoditiesPurchase then
		Dbg("StartBuy: C_AuctionHouse.StartCommoditiesPurchase missing, bailing")
		return
	end
	-- The API requires the user to have read the unit price from a recent
	-- commodity search before they can purchase. Verify we have one.
	local r = C_AuctionHouse.GetCommoditySearchResultInfo and C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
	Dbg(string.format("StartBuy: first commodity result unitPrice=%s quantity=%s",
		tostring(r and r.unitPrice), tostring(r and r.quantity)))
	pendingBuy = { itemID = itemID, qty = qty }
	Dbg(string.format("StartBuy: calling StartCommoditiesPurchase(%d, %d)", itemID, qty))
	-- Wrap in securecallfunction: the AH protected calls walk a panel-manager
	-- chain we don't want SeanKeys taint propagating into.
	securecallfunction(C_AuctionHouse.StartCommoditiesPurchase, itemID, qty)
end

-- COMMODITY_PRICE_UPDATED fires with (newUnitPrice, newTotalPrice) — NOT
-- (itemID, quantity) as a naive reading of the AH docs would suggest.
-- (Verified against Auctionator's CheckPurchase signature.) We track the
-- intended purchase in `pendingBuy` and just need any-price-update as the
-- "you may now confirm" signal. Sanity-check the new unit price against the
-- one we last cached so a sudden spike doesn't auto-buy at 10x.
local function OnCommodityPriceUpdated(newUnitPrice, newTotalPrice)
	Dbg(string.format("COMMODITY_PRICE_UPDATED: newUnit=%s newTotal=%s pending=%s/%s",
		tostring(newUnitPrice), tostring(newTotalPrice),
		tostring(pendingBuy and pendingBuy.itemID), tostring(pendingBuy and pendingBuy.qty)))
	if not pendingBuy then
		Dbg("  -> no pendingBuy, ignoring")
		return
	end
	if not C_AuctionHouse.ConfirmCommoditiesPurchase then
		Dbg("  -> ConfirmCommoditiesPurchase missing, bailing")
		return
	end
	local cached = priceCache[pendingBuy.itemID]
	if cached and cached.perUnit and newUnitPrice and newUnitPrice > cached.perUnit * 2 then
		Dbg(string.format("  -> price spike (cached=%s, new=%s) — cancelling",
			tostring(cached.perUnit), tostring(newUnitPrice)))
		if C_AuctionHouse.CancelCommoditiesPurchase then
			securecallfunction(C_AuctionHouse.CancelCommoditiesPurchase)
		end
		pendingBuy = nil
		return
	end
	Dbg(string.format("  -> calling ConfirmCommoditiesPurchase(%d, %d)",
		pendingBuy.itemID, pendingBuy.qty))
	securecallfunction(C_AuctionHouse.ConfirmCommoditiesPurchase, pendingBuy.itemID, pendingBuy.qty)
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

-- Gold-only formatter. Pass copper * (gold/copper) via GetCoinTextureString
-- so we get the standard gold-icon string but with silver/copper stripped.
-- Consumables shopping always involves stacks worth at least several gold;
-- the sub-gold portion is just noise. Rounds DOWN so the displayed price
-- never overstates what the AH will actually charge.
local function FormatCoin(copper)
	if not copper or copper <= 0 then return "-" end
	local gold = math.floor(copper / 10000)
	if gold == 0 then return "<1g" end
	if GetCoinTextureString then return GetCoinTextureString(gold * 10000) end
	return string.format("%dg", gold)
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

	-- Quality icon
	local quality = item.entry.quality or 1
	if quality > MAX_QUALITY then quality = MAX_QUALITY end
	if row.qualityIcon then
		row.qualityIcon:SetAtlas(string.format("Professions-Icon-Quality-12-Tier%d", quality))
	end

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

local function UpdateProfileBtnText()
	if not contentFrame or not contentFrame.profileBtn then return end
	local p = ActiveProfile()
	contentFrame.profileBtn:SetText(((p and p.name) or "Profile 1") .. "  |TInterface\\ChatFrame\\ChatFrameExpandArrow:12|t")
end

local function RefreshRows()
	if not contentFrame or not contentFrame:IsShown() then return end
	UpdateProfileBtnText()
	local list = BuildDisplayList()
	for i = 1, MAX_VISIBLE_ROWS do
		contentRows[i]:Hide()
	end
	if #list == 0 then
		contentFrame.empty:Show()
		contentFrame.overflow:Hide()
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

local function RefreshAll()
	RefreshRows()
	local list = BuildDisplayList()
	EnqueueSearchesForList(list)
end

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

	-- Quality dropdown: between the icon and the item name. Click to pick
	-- Q1/Q2 (Midnight crafting caps at T2 — no T3 this season).
	row.qualityBtn = CreateFrame("Button", nil, row)
	row.qualityBtn:SetSize(24, 24)
	row.qualityBtn:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.qualityIcon = row.qualityBtn:CreateTexture(nil, "ARTWORK")
	row.qualityIcon:SetAllPoints()
	local qHl = row.qualityBtn:CreateTexture(nil, "HIGHLIGHT")
	qHl:SetAllPoints()
	qHl:SetColorTexture(1, 1, 1, 0.15)
	row.qualityBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Click to pick quality", 1, 1, 1)
		GameTooltip:Show()
	end)
	row.qualityBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row.qualityBtn:SetScript("OnClick", function(self)
		if not MenuUtil or not MenuUtil.CreateContextMenu or not row.entry then return end
		MenuUtil.CreateContextMenu(self, function(_, menuRoot)
			menuRoot:CreateTitle("Quality")
			for q = 1, MAX_QUALITY do
				local label = string.format("|A:Professions-Icon-Quality-12-Tier%d:16:16|a Quality %d", q, q)
				menuRoot:CreateRadio(
					label,
					function() return (row.entry.quality or 1) == q end,
					function()
						-- Swap the row's itemID to the catalog's sibling
						-- variant for the chosen quality. Falls back to the
						-- current itemID if this consumable hasn't had its
						-- quality variants mapped yet — the dropdown is
						-- cosmetic in that case.
						local newID = ResolveQualityItemID(row.entry.itemID, q)
						row.entry.itemID = newID
						row.entry.quality = q
						if ns.ConsumablesRefreshRows then ns.ConsumablesRefreshRows() end
						-- Kick a price query for the new itemID if it isn't
						-- already cached.
						if not priceCache[newID] then
							searchQueue[#searchQueue + 1] = newID
							TryNextSearch()
						end
					end)
			end
		end)
	end)

	row.category = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.category:SetPoint("LEFT", row.qualityBtn, "RIGHT", 8, 8)
	row.category:SetWidth(110)
	row.category:SetJustifyH("LEFT")

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.name:SetPoint("LEFT", row.qualityBtn, "RIGHT", 8, -6)
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
	row.targetEdit:SetPoint("LEFT", row.have, "RIGHT", 8, 0)
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
	row.cost:SetWidth(180)
	row.cost:SetJustifyH("RIGHT")

	row.buyBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.buyBtn:SetSize(72, 22)
	row.buyBtn:SetPoint("LEFT", row.cost, "RIGHT", 6, 0)
	row.buyBtn:SetText("Buy")
	row.buyBtn:SetScript("OnClick", function(self)
		Dbg(string.format("BuyBtn clicked: itemID=%s qty=%s", tostring(row.itemID), tostring(self.qty)))
		if not row.itemID or not self.qty or self.qty <= 0 then
			Dbg("  -> missing itemID or qty, bailing")
			return
		end
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
		local q = row.entry and row.entry.quality or 1
		RemoveEntry(row.listRef, row.itemID, q)
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

-- Category > item submenu picker. Adds a fresh entry to the current profile's
-- list with a default target of 20 and quality=1, then refreshes the tab.
-- Items that already have a quality-1 entry in this profile's list are greyed
-- out and become no-ops on click — the user has to change the existing row's
-- quality first (creating a "free" quality-1 slot) before re-adding.
local function ShowAddMenu(button)
	if not MenuUtil or not MenuUtil.CreateContextMenu then return end
	local lists = ActiveLists()
	if not lists then return end
	MenuUtil.CreateContextMenu(button, function(_, root)
		root:CreateTitle("Add a consumable")
		for _, cat in ipairs(ns.CONSUMABLE_CATEGORIES or {}) do
			local catMenu = root:CreateButton(cat.label)
			local options = (ns.CURRENT_SEASON_CONSUMABLES and ns.CURRENT_SEASON_CONSUMABLES[cat.key]) or {}
			for _, opt in ipairs(options) do
				local realName = (C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(opt.itemID)) or opt.name
				local alreadyHasQ1 = FindEntry(lists[cat.key], opt.itemID, 1) ~= nil
				local label = alreadyHasQ1 and ("|cff666666" .. realName .. "|r") or realName
				local entry = catMenu:CreateButton(label, function()
					if alreadyHasQ1 then return end  -- defensive: also handled by SetEnabled
					AddEntryAtQ1(lists[cat.key], opt.itemID, 20)
					if ns.ConsumablesRefreshRows then ns.ConsumablesRefreshRows() end
					-- Kick a price query for the newly-added item.
					if not priceCache[opt.itemID] then
						searchQueue[#searchQueue + 1] = opt.itemID
						TryNextSearch()
					end
				end)
				if alreadyHasQ1 and entry and entry.SetEnabled then
					entry:SetEnabled(false)
				end
			end
		end
	end)
end

-- ----------------------------------------------------------------------------
-- Profile management
-- ----------------------------------------------------------------------------

local function ShowProfileMenu(button)
	if not MenuUtil or not MenuUtil.CreateContextMenu then return end
	local profiles = GetProfiles()
	if not profiles then return end
	MenuUtil.CreateContextMenu(button, function(_, root)
		root:CreateTitle("Switch profile")
		for i, p in ipairs(profiles) do
			root:CreateRadio(
				p.name or string.format("Profile %d", i),
				function() return ns.charDb.activeConsumableProfile == i end,
				function()
					ns.charDb.activeConsumableProfile = i
					RefreshAll()
				end)
		end
	end)
end

local function AddProfile()
	local profiles = GetProfiles()
	if not profiles then return end
	profiles[#profiles + 1] = {
		name = string.format("Profile %d", #profiles + 1),
		lists = {},
	}
	ns.charDb.activeConsumableProfile = #profiles
	RefreshAll()
end

StaticPopupDialogs["SEANKEYS_CONSUMABLE_RENAME_PROFILE"] = {
	text = "Rename profile:",
	button1 = ACCEPT or "Accept",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	maxLetters = 32,
	OnShow = function(self, data)
		local eb = self.EditBox or self.editBox
		if eb then
			eb:SetText(data or "")
			eb:HighlightText()
			eb:SetFocus()
		end
	end,
	OnAccept = function(self)
		local eb = self.EditBox or self.editBox
		local newName = eb and eb:GetText() or ""
		newName = strtrim(newName)
		if newName == "" then return end
		local profiles = GetProfiles()
		if not profiles then return end
		local p = profiles[ns.charDb.activeConsumableProfile]
		if not p then return end
		p.name = newName
		RefreshAll()
	end,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		if parent.button1 and parent.button1:IsEnabled() then
			StaticPopupDialogs["SEANKEYS_CONSUMABLE_RENAME_PROFILE"].OnAccept(parent)
			parent:Hide()
		end
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local function ShowRenameDialog()
	local profiles = GetProfiles()
	if not profiles then return end
	local p = profiles[ns.charDb.activeConsumableProfile]
	StaticPopup_Show("SEANKEYS_CONSUMABLE_RENAME_PROFILE", nil, nil, p and p.name or "")
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

	-- Profile selector: button styled to look like a dropdown, opens a context
	-- menu of all profiles when clicked. + creates a new profile; Rename
	-- prompts for a new name for the current one.
	f.profileBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.profileBtn:SetSize(160, 22)
	f.profileBtn:SetPoint("LEFT", f.title, "RIGHT", 16, 0)
	f.profileBtn:SetScript("OnClick", function(self) ShowProfileMenu(self) end)

	f.newProfileBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.newProfileBtn:SetSize(22, 22)
	f.newProfileBtn:SetPoint("LEFT", f.profileBtn, "RIGHT", 4, 0)
	f.newProfileBtn:SetText("+")
	f.newProfileBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("New profile", 1, 1, 1)
		GameTooltip:Show()
	end)
	f.newProfileBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.newProfileBtn:SetScript("OnClick", function() AddProfile() end)

	-- Rename button with a pencil glyph. Friz Quadrata renders the U+270E
	-- "lower right pencil" character fine; tooltip clarifies its purpose
	-- regardless of font fallback.
	f.renameBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.renameBtn:SetSize(22, 22)
	f.renameBtn:SetPoint("LEFT", f.newProfileBtn, "RIGHT", 4, 0)
	f.renameBtn:SetText("\xE2\x9C\x8E")  -- ✎ U+270E
	f.renameBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Rename profile", 1, 1, 1)
		GameTooltip:Show()
	end)
	f.renameBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.renameBtn:SetScript("OnClick", function() ShowRenameDialog() end)

	-- Refresh on the right, Add to its left.
	local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	refreshBtn:SetSize(80, 22)
	refreshBtn:SetPoint("TOPRIGHT", -12, -8)
	refreshBtn:SetText("Refresh")
	refreshBtn:SetScript("OnClick", function()
		wipe(priceCache)
		RefreshRows()
		EnqueueSearchesForList(BuildDisplayList())
	end)

	local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	addBtn:SetSize(80, 22)
	addBtn:SetPoint("RIGHT", refreshBtn, "LEFT", -4, 0)
	addBtn:SetText("Add...")
	addBtn:SetScript("OnClick", function(self) ShowAddMenu(self) end)
	f.addBtn = addBtn

	-- Column headers. X coords are f-relative (parent frame). Row body starts
	-- at x=12; quality button now sits between icon and item, so the Item
	-- header shifts right and there's no Q column header (the dropdown is
	-- self-describing on hover).
	local function H(text, x, w, justify)
		local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("TOPLEFT", x, -36)
		fs:SetWidth(w)
		fs:SetJustifyH(justify or "LEFT")
		fs:SetText("|cffffcc00" .. text .. "|r")
	end
	H("Item",   84,  220, "LEFT")
	H("Bags",   312, 40,  "CENTER")
	H("Target", 360, 44,  "CENTER")
	H("Cost",   416, 180, "RIGHT")

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
		RefreshAll()
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
ev:RegisterEvent("COMMODITY_PRICE_UNAVAILABLE")
ev:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
ev:RegisterEvent("COMMODITY_PURCHASE_FAILED")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
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
	elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
		Dbg(string.format("COMMODITY_PRICE_UNAVAILABLE: itemID=%s", tostring(a)))
		pendingBuy = nil
	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		Dbg("COMMODITY_PURCHASE_SUCCEEDED")
		pendingBuy = nil
	elseif event == "COMMODITY_PURCHASE_FAILED" then
		Dbg("COMMODITY_PURCHASE_FAILED")
		pendingBuy = nil
	elseif event == "BAG_UPDATE_DELAYED" then
		if contentFrame and contentFrame:IsShown() then RefreshRows() end
	end
end)
