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
		ns.RebuildGuildSet()
		ns.PersistAllTracked()
		if ns.mainFrame and ns.mainFrame:IsShown() then ns.Refresh() end
	elseif event == "GROUP_ROSTER_UPDATE" then
		C_Timer.After(1, function()
			if LKS and IsInGroup() then LKS.Request("PARTY") end
			if LSP and IsInGroup() and LSP.RequestGroupSpecialization then
				pcall(LSP.RequestGroupSpecialization)
			end
			ns.PullFromLibOpenRaid()
			if ns.mainFrame and ns.mainFrame:IsShown() then ns.Refresh() end
		end)
	elseif event == "CHALLENGE_MODE_COMPLETED" or event == "BAG_UPDATE_DELAYED" then
		C_Timer.After(2, ns.PullSelf)
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		C_Timer.After(0.5, ns.PullSelf)
	elseif event == "PLAYER_REGEN_ENABLED" then
		ns.ProcessPending()
	end
end)
