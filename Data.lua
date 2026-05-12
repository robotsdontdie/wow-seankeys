local ADDON_NAME, ns = ...

-- ============================================================================
-- Data: keystone + spec store, persistence cache, protocol subscriptions
-- (LibKeystone, LibSpecialization, LibOpenRaid, AstralKeys, self-pull).
-- ============================================================================

local LKS = LibStub("LibKeystone", true)
local LSP = LibStub("LibSpecialization", true)

local keys = {}                  -- normalizedName -> { level, mapID, rating, source, lastSeen, class, specID, role }
local selfDungeonBest = {}       -- challengeMapID -> { level, timed, mapScore }
local guildMembers = {}          -- [fullName] = true for current guild roster

ns.keys = keys
ns.selfDungeonBest = selfDungeonBest
ns.guildMembers = guildMembers

local function Dbg(...) if ns.Dbg then ns.Dbg(...) end end

local function RefreshIfVisible()
	if ns.mainFrame and ns.mainFrame:IsShown() and ns.Refresh then ns.Refresh() end
end

-- ----------------------------------------------------------------------------
-- Account-wide cache: persist key + spec info for "my" characters and current
-- guild members so they remain visible across sessions, even offline. Keyed
-- by FullName(); category is "self" or "guild".
-- ----------------------------------------------------------------------------

local function CacheCategoryFor(fullName)
	if not fullName or not ns.db then return nil end
	if ns.db.myCharacters and ns.db.myCharacters[fullName] then return "self" end
	if guildMembers[fullName] then return "guild" end
	return nil
end

local function PersistEntry(shortName, entry)
	if not ns.db or not entry then return end
	local fn = ns.FullName(shortName)
	if not fn then return end
	local cat = CacheCategoryFor(fn)
	if not cat then return end
	ns.db.cache = ns.db.cache or {}
	local rec = ns.db.cache[fn] or {}
	rec.level = entry.level or 0
	rec.mapID = entry.mapID or 0
	if entry.rating and entry.rating > 0 then rec.rating = entry.rating end
	if entry.class then rec.class = entry.class end
	if entry.specID and entry.specID > 0 then rec.specID = entry.specID end
	if entry.role and entry.role ~= "" then rec.role = entry.role end
	if entry.source then rec.source = entry.source end
	rec.lastSeen = time()
	rec.category = cat
	ns.db.cache[fn] = rec
end

local function RecordSelf()
	if not ns.db then return end
	ns.db.myCharacters = ns.db.myCharacters or {}
	local short = ns.NormalizeName(UnitName("player"))
	local fn = ns.FullName(short)
	if not fn then return end
	local _, class = UnitClass("player")
	local rec = ns.db.myCharacters[fn] or {}
	if class then rec.class = class end
	rec.lastSeen = time()
	ns.db.myCharacters[fn] = rec
end

local function RebuildGuildSet()
	wipe(guildMembers)
	if not IsInGuild() then return end
	local n = GetNumGuildMembers() or 0
	for i = 1, n do
		local name = GetGuildRosterInfo(i)
		if name and name ~= "" then
			local fn = ns.FullName(name)
			if fn then guildMembers[fn] = true end
		end
	end
end

-- After the guild roster is known, retroactively persist any keys we already
-- have in memory for guildies (their broadcasts may have arrived first).
local function PersistAllTracked()
	for shortName, entry in pairs(keys) do
		PersistEntry(shortName, entry)
	end
end

local function GetOrCreate(name)
	local entry = keys[name]
	if not entry then
		entry = { level = 0, mapID = 0, rating = 0, lastSeen = GetTime() }
		keys[name] = entry
	end
	return entry
end

local function UpsertKey(playerName, level, mapID, rating, source, class)
	local name = ns.NormalizeName(playerName)
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

	PersistEntry(name, entry)

	RefreshIfVisible()
end

local function UpsertSpec(playerName, specID, role)
	local name = ns.NormalizeName(playerName)
	if not name then return end
	local entry = GetOrCreate(name)
	if specID and specID > 0 then
		entry.specID = specID
		local cls = ns.ClassFromSpec(specID)
		if cls then entry.class = cls end
	end
	if role and role ~= "" then entry.role = role end
	entry.lastSeen = GetTime()

	PersistEntry(name, entry)

	RefreshIfVisible()
end

ns.UpsertKey = UpsertKey
ns.UpsertSpec = UpsertSpec
ns.RebuildGuildSet = RebuildGuildSet
ns.PersistAllTracked = PersistAllTracked

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
	RecordSelf()
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

ns.BindLibOpenRaid = BindLibOpenRaid
ns.PullFromLibOpenRaid = PullFromLibOpenRaid
ns.PullFromAstralKeys = PullFromAstralKeys
ns.PullSelf = PullSelf
ns.IsKeyUpgrade = IsKeyUpgrade
