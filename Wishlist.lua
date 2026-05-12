local ADDON_NAME, ns = ...

-- ============================================================================
-- Wishlist: per-character set of itemIDs the player is gunning for, tagged by
-- the challengeMapID they drop in. Backed by SeanKeysCharDB.wishlist.
--
-- Other files consume this via:
--   ns.Wishlist.IsWishlisted(itemID)        -- bool
--   ns.Wishlist.Toggle(itemID, mapID, name) -- returns new state (bool)
--   ns.Wishlist.HasItemForDungeon(mapID)    -- bool, drives the main-list star
--
-- A derived `mapHasWishlist` index is rebuilt at load and maintained on
-- toggle, so the per-row check in the keys window is O(1).
-- ============================================================================

local wishlist                  -- [itemID] = { challengeMapID = m, name = "..." }
local mapHasWishlist = {}       -- [challengeMapID] = count

local function RebuildIndex()
	wipe(mapHasWishlist)
	if type(wishlist) ~= "table" then return end
	for _, rec in pairs(wishlist) do
		local m = rec and rec.challengeMapID
		if m then mapHasWishlist[m] = (mapHasWishlist[m] or 0) + 1 end
	end
end

local function RefreshUI()
	if ns.mainFrame and ns.mainFrame:IsShown() and ns.Refresh then ns.Refresh() end
end

ns.Wishlist = {}

-- Called from SeanKeys.lua ADDON_LOADED once SeanKeysCharDB is ready.
function ns.Wishlist.Init()
	if not ns.charDb then return end
	ns.charDb.wishlist = ns.charDb.wishlist or {}
	wishlist = ns.charDb.wishlist
	RebuildIndex()
end

function ns.Wishlist.IsWishlisted(itemID)
	if not itemID or not wishlist then return false end
	return wishlist[itemID] ~= nil
end

-- Toggles wishlist state for the given itemID. Returns the new state
-- (true = now wishlisted, false = now removed).
function ns.Wishlist.Toggle(itemID, challengeMapID, name)
	if not itemID or not wishlist then return false end
	if wishlist[itemID] then
		local prev = wishlist[itemID]
		wishlist[itemID] = nil
		local m = prev and prev.challengeMapID
		if m and mapHasWishlist[m] then
			mapHasWishlist[m] = mapHasWishlist[m] - 1
			if mapHasWishlist[m] <= 0 then mapHasWishlist[m] = nil end
		end
		RefreshUI()
		return false
	else
		wishlist[itemID] = { challengeMapID = challengeMapID, name = name }
		if challengeMapID then
			mapHasWishlist[challengeMapID] = (mapHasWishlist[challengeMapID] or 0) + 1
		end
		RefreshUI()
		return true
	end
end

function ns.Wishlist.HasItemForDungeon(challengeMapID)
	if not challengeMapID or challengeMapID == 0 then return false end
	return mapHasWishlist[challengeMapID] ~= nil
end
