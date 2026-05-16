local ADDON_NAME, ns = ...

-- ============================================================================
-- SeanKeys: cross-protocol keystone + spec aggregator with teleport UI.
--
-- This file is the entry point: it holds season-specific data (teleport
-- spell IDs), wires up slash commands, and drives event-based pulls. The
-- bulk of the implementation lives in:
--
--   Core.lua       - debug log, helpers (names, colors, score math)
--   Data.lua       - keystone/spec store + protocol subscriptions
--   LootWindow.lua - left-click-dungeon loot preview window
--   KeysWindow.lua - main aggregated keystone window
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
-- Exposed via ns so KeysWindow.lua's PopulateRow can read it.
ns.TELEPORT_SPELL_BY_CHALLENGEMAP = {
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

-- ----------------------------------------------------------------------------
-- Slash commands
-- ----------------------------------------------------------------------------

SLASH_SEANKEYS1 = "/seankeys"
SLASH_SEANKEYS2 = "/sk"
SLASH_SEANKEYS3 = "/keys"

local function UpdateDebugButtonVisibility()
	if not ns.mainFrame or not ns.mainFrame.debugBtn then return end
	if ns.db and ns.db.showDebugButton then
		ns.mainFrame.debugBtn:Show()
	else
		ns.mainFrame.debugBtn:Hide()
	end
end
ns.UpdateDebugButtonVisibility = UpdateDebugButtonVisibility

SlashCmdList.SEANKEYS = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "refresh" or msg == "r" then
		ns.Refresh(true)
		print("|cffffcc00SeanKeys:|r refreshed.")
	elseif msg == "debug" then
		ns.db.showDebugButton = not ns.db.showDebugButton
		UpdateDebugButtonVisibility()
		print("|cffffcc00SeanKeys:|r debug button " .. (ns.db.showDebugButton and "|cff33ff33shown|r" or "|cffff6666hidden|r"))
	elseif msg == "hudtest" then
		if ns.MPlusHud and ns.MPlusHud.ToggleTest then
			local on = ns.MPlusHud.ToggleTest()
			print("|cffffcc00SeanKeys:|r M+ HUD test " .. (on and "|cff33ff33shown|r (sample data)" or "|cffff6666hidden|r"))
		end
	elseif msg == "levels" then
		print("|cffffcc00SeanKeys:|r dumping frame levels to debug log...")
		if ns.mainFrame then ns.DumpFrameLevels(ns.mainFrame) end
		if _G.SeanKeysLootFrame then ns.DumpFrameLevels(_G.SeanKeysLootFrame) end
		if _G.SeanKeysDebugFrame then ns.DumpFrameLevels(_G.SeanKeysDebugFrame) end
		ns.ShowDebugWindow()
	elseif msg == "dump" then
		for name, k in pairs(ns.keys) do
			local upgrade, reason = ns.IsKeyUpgrade(k.mapID, k.level)
			local upTag = upgrade and (" |cff33ff33[UPGRADE: " .. (reason or "") .. "]|r") or ""
			print(string.format("|cffffcc00SeanKeys:|r %s = lvl %d %s rating=%d spec=%s role=%s (%s)%s",
				name, k.level or 0, ns.GetDungeonName(k.mapID), k.rating or 0,
				tostring(ns.SpecName(k.specID) or "?"), tostring(k.role or "?"), k.source or "?", upTag))
		end
		print(string.format("|cffffcc00SeanKeys:|r tracked %d dungeons in your run history.", (function() local n=0; for _ in pairs(ns.selfDungeonBest) do n=n+1 end; return n end)()))
	else
		ns.Toggle()
	end
end

-- ----------------------------------------------------------------------------
-- Events
-- ----------------------------------------------------------------------------

-- Debounce flags so spammy events (BAG_UPDATE_DELAYED on every loot/vendor
-- click; GUILD_ROSTER_UPDATE on roster bursts) don't stack timers or do
-- redundant Refresh work. A single deferred consumer drains each one.
local pullSelfPending = false
local guildRefreshPending = false

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("GROUP_ROSTER_UPDATE")
boot:RegisterEvent("GUILD_ROSTER_UPDATE")
boot:RegisterEvent("PLAYER_GUILD_UPDATE")
boot:RegisterEvent("CHALLENGE_MODE_COMPLETED")
boot:RegisterEvent("BAG_UPDATE_DELAYED")
boot:RegisterEvent("PLAYER_REGEN_ENABLED")
boot:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
boot:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			SeanKeysDB = SeanKeysDB or {}
			ns.db = SeanKeysDB
			SeanKeysCharDB = SeanKeysCharDB or {}
			ns.charDb = SeanKeysCharDB
			if ns.db.showDebugButton == nil then ns.db.showDebugButton = false end
			if ns.Wishlist and ns.Wishlist.Init then ns.Wishlist.Init() end
		end
	elseif event == "PLAYER_LOGIN" then
		ns.PullSelf()
		ns.BindLibOpenRaid()
		-- Pre-load Blizzard_EncounterJournal once at login so its panel-manager
		-- registration happens here (clean context) rather than later from a
		-- click chain. securecallfunction strips our identity from the load so
		-- EJ doesn't get filed under "SeanKeys" with the panel manager.
		-- Without this, opening the loot window can leave SeanKeys-tainted
		-- state that gets blamed for later protected calls (e.g. clicking an
		-- item in your bag triggering ADDON_ACTION_FORBIDDEN on UseContainerItem).
		if not C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal") then
			securecallfunction(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal")
		end
		-- Pre-build all UI frames now, in a clean execution context, instead
		-- of letting them be built lazily inside whatever click/event chain
		-- triggers the first show. CreateFrame + SecureActionButtonTemplate
		-- setup + tinsert(UISpecialFrames, ...) are exactly the kind of work
		-- that left taint residue when run from the MythicPlusHud event
		-- handlers. Wrapping in securecallfunction strips our identity from
		-- the build so subsequent panel-manager / action-bar walks don't
		-- file the resulting frames under "SeanKeys".
		if ns.BuildKeysFrame  then securecallfunction(ns.BuildKeysFrame)  end
		if ns.BuildLootFrame  then securecallfunction(ns.BuildLootFrame)  end
		if ns.BuildDebugWindow then securecallfunction(ns.BuildDebugWindow) end
		if IsInGuild() then
			if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
			elseif GuildRoster then GuildRoster() end
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		C_Timer.After(2, function()
			ns.PullSelf()
			ns.PullFromAstralKeys()
			ns.PullFromLibOpenRaid()
			if LKS and IsInGroup() then LKS.Request("PARTY") end
			if LSP and IsInGroup() and LSP.RequestGroupSpecialization then
				pcall(LSP.RequestGroupSpecialization)
			end
			if IsInGuild() then
				if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
				elseif GuildRoster then GuildRoster() end
			end
		end)
	elseif event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
		-- Roster events arrive in bursts (login, members logging on/off, our
		-- own GuildRoster() requests). Synchronous Refresh from the event
		-- handler walks rows, manipulates secure teleport buttons, and
		-- mutates `ns.mainFrame` layout — exactly the kind of work that
		-- left taint residue when MythicPlusHud did similar from
		-- PLAYER_REGEN_DISABLED. Defer + dedupe so the work runs on a
		-- clean call chain and only once per burst.
		ns.RebuildGuildSet()
		ns.PersistAllTracked()
		if ns.mainFrame and ns.mainFrame:IsShown() and not guildRefreshPending then
			guildRefreshPending = true
			C_Timer.After(0, function()
				guildRefreshPending = false
				if not InCombatLockdown() and ns.mainFrame and ns.mainFrame:IsShown() then
					ns.Refresh()
				end
			end)
		end
	elseif event == "GROUP_ROSTER_UPDATE" then
		C_Timer.After(1, function()
			if LKS and IsInGroup() then LKS.Request("PARTY") end
			if LSP and IsInGroup() and LSP.RequestGroupSpecialization then
				pcall(LSP.RequestGroupSpecialization)
			end
			ns.PullFromLibOpenRaid()
			if ns.mainFrame and ns.mainFrame:IsShown() and not InCombatLockdown() then
				ns.Refresh()
			end
		end)
	elseif event == "CHALLENGE_MODE_COMPLETED" or event == "BAG_UPDATE_DELAYED" then
		-- BAG_UPDATE_DELAYED fires on every loot, quest reward, and vendor
		-- click; without dedupe we stack one PullSelf timer per event,
		-- and PullSelf itself fans out into UpsertKey -> RefreshIfVisible.
		-- A single pending flag collapses bursts into one pull.
		if not pullSelfPending then
			pullSelfPending = true
			C_Timer.After(2, function()
				pullSelfPending = false
				ns.PullSelf()
			end)
		end
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		C_Timer.After(0.5, ns.PullSelf)
	elseif event == "PLAYER_REGEN_ENABLED" then
		-- ProcessPending writes SetAttribute on SecureActionButtonTemplate
		-- buttons. Wrap in securecallfunction so any taint we accumulate
		-- iterating + writing attributes doesn't carry SeanKeys identity
		-- into the post-combat action-bar refresh chain that immediately
		-- follows PLAYER_REGEN_ENABLED.
		securecallfunction(ns.ProcessPending)
	end
end)
