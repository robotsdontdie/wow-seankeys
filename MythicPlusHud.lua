local ADDON_NAME, ns = ...
local Dbg = ns.Dbg or function() end

-- ============================================================================
-- MythicPlusHud: in-dungeon status header for an active Mythic+ run.
--
-- A small borderless backdrop that shows everything we want to glance at
-- mid-run on a single line:
--
--   <Dungeon> +<Lvl>   <Affix>/<Affix>/...   <MM:SS>   <%> <N/M>   [skull] B/T
--
-- Conventions:
--   * Forces are shown REMAINING, not done. So a fresh pull reads "100%
--     150/150" and ticks down to "0% 0/150".
--   * Bosses are shown REMAINING, e.g. "1/4" with one boss left.
--   * Affixes get a custom abbreviation: Tyrannical -> "T", Fortified -> "F",
--     and Xal'atath sub-affixes ("Xal'atath's Bargain: Devour") collapse to
--     their last word ("Devour"). Anything else falls back to its raw name.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test-mode state (forward declared so all data fns close over it)
--
-- /sk hudtest flips `testMode` on. While on, GetActiveRun / ReadCriteria /
-- GetElapsedSeconds return synthetic structs instead of querying the game,
-- so we can iterate on layout without entering an actual key. The elapsed
-- clock ticks in real time (GetTime() - testStartTime) so the countdown
-- looks live.
-- ----------------------------------------------------------------------------

local testMode = false
local testStartTime = 0

-- Pre-formatted affix labels short-circuit the GetAffixInfo lookup so test
-- mode doesn't depend on whether the current season actually has a given ID.
local TEST_RUN = {
	mapID = 558,
	level = 12,
	affixLabels = { "T", "Devour" },
	name = "Magisters' Terrace",
	timeLimit = 30 * 60,
}

local TEST_CRIT = {
	forcesQuantity = 27,
	forcesTotal = 150,
	bossesTotal = 4,
	bossesDone = 1,
}

-- ----------------------------------------------------------------------------
-- Affix abbreviation
-- ----------------------------------------------------------------------------

-- Hard overrides (the season-stable ones).
local AFFIX_OVERRIDE = {
	[9]  = "T",     -- Tyrannical
	[10] = "F",     -- Fortified
}

-- Returns the short label to display for `affixID`, or nil if this affix is
-- one we deliberately don't show on the HUD.
--
-- The HUD shows three categories at most: Tyrannical (T), Fortified (F), and
-- the rotating weekly Xal'atath sub-affix ("Xal'atath's Bargain: X" -> "X").
-- Returning nil for everything else filters out:
--   * Xal'atath's Guile     (constant seasonal meta affix)
--   * Lindormi's Guidance   (+12 keystone-hero affix)
--   * any future affixes that don't follow the "<...>: <flavor>" pattern
-- ComputeAffixDisplayString skips nil results, so the filter applies to the
-- panel's affix-line display directly.
local function ShortAffixName(affixID)
	if not affixID or affixID == 0 then return nil end
	if AFFIX_OVERRIDE[affixID] then return AFFIX_OVERRIDE[affixID] end
	local name = C_ChallengeMode.GetAffixInfo(affixID)
	if not name or name == "" then return nil end
	local tail = name:match(":%s*(.+)$")
	if tail then return tail end
	return nil
end

-- ----------------------------------------------------------------------------
-- Dungeon short names (one word per dungeon for the HUD title slot)
--
-- Falls back to the first whitespace-delimited word of the full name if a
-- challengeMapID isn't in the table — keeps the HUD readable when a season
-- introduces a dungeon we haven't curated yet.
-- ----------------------------------------------------------------------------

local SHORT_DUNGEON_NAME = {
	[161] = "Skyreach",   -- Skyreach
	[239] = "Seat",       -- Seat of the Triumvirate
	[402] = "Algethar",   -- Algeth'ar Academy
	[556] = "Pit",        -- Pit of Saron
	[557] = "Spire",      -- Windrunner Spire
	[558] = "Magisters",  -- Magisters' Terrace
	[559] = "Xenas",      -- Nexus-Point Xenas
	[560] = "Maisara",    -- Maisara Caverns
}

local function ShortDungeonName(mapID, fullName)
	if mapID and SHORT_DUNGEON_NAME[mapID] then return SHORT_DUNGEON_NAME[mapID] end
	if fullName then
		local first = fullName:match("^(%S+)")
		if first then return first end
	end
	return fullName or "?"
end

-- ----------------------------------------------------------------------------
-- Forces / boss criteria scan
--
-- Modern M+ exposes one weighted-progress criteria (Enemy Forces) plus one
-- non-weighted criteria per boss. We don't care about the order; we just
-- classify and tally.
-- ----------------------------------------------------------------------------

-- Diagnostic: log the full criteria struct once per scenario step so we can
-- verify the data types and values the API actually returns. Forces have
-- been observed showing "off but plausible-looking" numbers — likely the
-- API returning a percentage (0-100) where we expected raw mob counts, or
-- an unexpected secondary weighted-progress criterion. Throttled to once
-- per step (keyed by stepID + numCriteria) so the ticker doesn't spam.
local loggedStepKey

local function ReadCriteria()
	if testMode then return TEST_CRIT end
	local stepInfo = C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo and C_ScenarioInfo.GetScenarioStepInfo()
	if not stepInfo or not stepInfo.numCriteria then return nil end

	local stepKey = tostring(stepInfo.stepID or stepInfo.title or "?") .. "/" .. tostring(stepInfo.numCriteria)
	if loggedStepKey ~= stepKey then
		loggedStepKey = stepKey
		Dbg(string.format("ReadCriteria: stepID=%s title=%q numCriteria=%d",
			tostring(stepInfo.stepID), tostring(stepInfo.title), stepInfo.numCriteria))
		for i = 1, stepInfo.numCriteria do
			local c = C_ScenarioInfo.GetCriteriaInfo(i)
			if c then
				Dbg(string.format("  [%d] desc=%q wp=%s qty=%s(%s) total=%s(%s) qStr=%q completed=%s",
					i, tostring(c.description), tostring(c.isWeightedProgress),
					tostring(c.quantity), type(c.quantity),
					tostring(c.totalQuantity), type(c.totalQuantity),
					tostring(c.quantityString), tostring(c.completed)))
			end
		end
	end

	local forcesQuantity, forcesTotal
	local bossesTotal, bossesDone = 0, 0

	for i = 1, stepInfo.numCriteria do
		local c = C_ScenarioInfo.GetCriteriaInfo(i)
		if c then
			if c.isWeightedProgress then
				forcesQuantity = c.quantity or 0
				forcesTotal = c.totalQuantity or 0
			else
				bossesTotal = bossesTotal + 1
				if c.completed then bossesDone = bossesDone + 1 end
			end
		end
	end

	return {
		forcesQuantity = forcesQuantity,
		forcesTotal = forcesTotal,
		bossesTotal = bossesTotal,
		bossesDone = bossesDone,
	}
end

-- ----------------------------------------------------------------------------
-- Timer
--
-- WORLD_STATE_TIMER_START fires with the active timer's ID; we cache it and
-- poll GetWorldElapsedTime(timerID) each tick. If we missed the start event
-- (login/reload mid-key), enumerate active timers via GetWorldElapsedTimers
-- and find the one whose type is ChallengeMode (1).
--
-- API signature note: GetWorldElapsedTime(timerID) returns
--     (timerType, elapsed)
-- — only two values. An earlier version of this file destructured three
-- returns expecting (ok, elapsed, timerType), which made the comparison
-- against LE_WORLD_ELAPSED_TIMER_TYPE_CHALLENGE_MODE always nil-vs-1 and
-- broke reload-mid-key recovery. The activeTimerID path's `ok == 1` check
-- accidentally still worked because it was actually `timerType == 1`.
-- ----------------------------------------------------------------------------

-- LE_WORLD_ELAPSED_TIMER_TYPE_CHALLENGE_MODE. In modern retail Blizzard's
-- enum is documented as: NONE=0, BATTLEGROUND=1, CHALLENGE_MODE=2,
-- PROVING_GROUND=3, EVENT=4. Earlier versions of this file used 1, which is
-- the BG/PvP-race type — every GetWorldElapsedTime check failed and the
-- timer never resolved. Prefer Blizzard's global so a future enum shuffle
-- doesn't bite us again.
local CHALLENGE_TIMER_TYPE = _G.LE_WORLD_ELAPSED_TIMER_TYPE_CHALLENGE_MODE or 2
-- Modern retail returns the timer "type" as the localized description string
-- (e.g. "Challenge Mode Time"), not the integer enum. There's no reliable
-- locale global for this string (CHALLENGE_MODE_TIME is nil on current
-- builds), so we match three ways:
--   1. The integer enum (older clients / forward-compat)
--   2. The known English string (covers the most common case directly)
--   3. Any non-empty string while C_ChallengeMode.IsChallengeModeActive()
--      is true (locale-agnostic fallback for non-English clients)
local CHALLENGE_TIMER_NAME = _G.CHALLENGE_MODE_TIME  -- may be nil; that's fine
local function IsChallengeTimer(timerType)
	if timerType == CHALLENGE_TIMER_TYPE then return true end
	if CHALLENGE_TIMER_NAME and timerType == CHALLENGE_TIMER_NAME then return true end
	if timerType == "Challenge Mode Time" then return true end
	if type(timerType) == "string" and timerType ~= ""
		and C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
		and C_ChallengeMode.IsChallengeModeActive() then
		return true
	end
	return false
end
Dbg(string.format("MPlusHud: CHALLENGE_TIMER_TYPE resolved to %d / name=%s (LE_WORLD_ELAPSED_TIMER_TYPE_CHALLENGE_MODE=%s, GetWorldElapsedTimers=%s, GetWorldElapsedTime=%s)",
	CHALLENGE_TIMER_TYPE,
	tostring(CHALLENGE_TIMER_NAME),
	tostring(_G.LE_WORLD_ELAPSED_TIMER_TYPE_CHALLENGE_MODE),
	tostring(GetWorldElapsedTimers and "yes" or "no"),
	tostring(GetWorldElapsedTime and "yes" or "no")))
local activeTimerID
local lastResolvedLogElapsed   -- one-shot log when we first read a sane elapsed value

-- Diagnostic throttle: we only log timer state every ~5s while we're in the
-- "searching" branch (no usable activeTimerID), so the 0.5s ticker doesn't
-- spam. Reset whenever WORLD_STATE_TIMER_START fires so a fresh search
-- after a key restart gets fresh logs.
local lastTimerLogTime = 0

local function FindActiveTimer()
	local shouldLog = (GetTime() - lastTimerLogTime) > 2
	if shouldLog then lastTimerLogTime = GetTime() end

	if not GetWorldElapsedTimers then
		if shouldLog then Dbg("FindActiveTimer: GetWorldElapsedTimers API missing") end
		return nil, 0
	end
	-- GetWorldElapsedTimers returns active timer IDs as varargs.
	local ids = { GetWorldElapsedTimers() }
	if shouldLog then
		Dbg(string.format("FindActiveTimer: GetWorldElapsedTimers() returned %d ids (looking for type=%d)",
			#ids, CHALLENGE_TIMER_TYPE))
	end
	for _, timerID in ipairs(ids) do
		local timerType, elapsed = GetWorldElapsedTime(timerID)
		local match = IsChallengeTimer(timerType)
		if shouldLog then
			Dbg(string.format("  id=%s type=%s(%s) elapsed=%s(%s) match=%s",
				tostring(timerID),
				tostring(timerType), type(timerType),
				tostring(elapsed), type(elapsed),
				tostring(match)))
		end
		if match then
			return timerID, elapsed
		end
	end
	if shouldLog and #ids == 0 then
		Dbg("FindActiveTimer: no active world-state timers at all")
	elseif shouldLog then
		Dbg("FindActiveTimer: no CHALLENGE_MODE timer among active ids")
	end
	return nil, 0
end

local function GetElapsedSeconds()
	if testMode then return GetTime() - testStartTime end
	if activeTimerID then
		local timerType, elapsed = GetWorldElapsedTime(activeTimerID)
		if IsChallengeTimer(timerType) and elapsed and elapsed > 0 then
			if not lastResolvedLogElapsed then
				Dbg(string.format("GetElapsedSeconds: FIRST RESOLVE via cached id=%s type=%s elapsed=%s",
					tostring(activeTimerID), tostring(timerType), tostring(elapsed)))
				lastResolvedLogElapsed = elapsed
			end
			return elapsed
		end
		-- Cached ID exists but no longer returns a valid timer — log
		-- once and fall through to re-discover via FindActiveTimer.
		if (GetTime() - lastTimerLogTime) > 2 then
			Dbg(string.format("GetElapsedSeconds: cached activeTimerID=%s now returns type=%s elapsed=%s (expected %d / %s)",
				tostring(activeTimerID), tostring(timerType), tostring(elapsed),
				CHALLENGE_TIMER_TYPE, tostring(CHALLENGE_TIMER_NAME)))
		end
	end
	local id, elapsed = FindActiveTimer()
	if id then
		activeTimerID = id
		if not lastResolvedLogElapsed then
			Dbg(string.format("GetElapsedSeconds: FIRST RESOLVE via FindActiveTimer id=%s elapsed=%s",
				tostring(id), tostring(elapsed)))
			lastResolvedLogElapsed = elapsed or 0
		end
	end
	return elapsed or 0
end

-- ----------------------------------------------------------------------------
-- Active-run detection
-- ----------------------------------------------------------------------------

local function GetActiveRun()
	if testMode then return TEST_RUN end
	local level, affixes = C_ChallengeMode.GetActiveKeystoneInfo()
	local mapID = C_ChallengeMode.GetActiveChallengeMapID()
	if not level or level <= 0 or not mapID then return nil end
	local name, _, timeLimit = C_ChallengeMode.GetMapUIInfo(mapID)
	return {
		mapID = mapID,
		level = level,
		affixes = affixes or {},
		name = name or ("Map " .. mapID),
		timeLimit = timeLimit or 0,
	}
end

-- ----------------------------------------------------------------------------
-- Combat tracking
--
-- Snapshot forces + bosses-done at PLAYER_REGEN_DISABLED, compare on
-- PLAYER_REGEN_ENABLED to compute the per-combat delta. Cleared on
-- CHALLENGE_MODE_START / RESET. Combats with no forces gained and no boss
-- killed are skipped (lone-mob taps from passing trash, etc).
-- ----------------------------------------------------------------------------

local combats = {}
local inCombat = false
local combatStart = nil  -- { elapsed, forces, bosses }

-- Pre-canned sample combats for /sk hudtest so the expanded panel previews
-- realistically without us having to actually run a key.
local TEST_COMBATS = {
	{ startElapsed = 18,  duration = 14, forcesKilled = 6,  boss = false },
	{ startElapsed = 44,  duration = 22, forcesKilled = 14, boss = false },
	{ startElapsed = 78,  duration = 8,  forcesKilled = 5,  boss = false },
	{ startElapsed = 110, duration = 38, forcesKilled = 12, boss = true  },
	{ startElapsed = 165, duration = 18, forcesKilled = 8,  boss = false },
	{ startElapsed = 200, duration = 26, forcesKilled = 11, boss = false },
}

local function GetCombats()
	if testMode then return TEST_COMBATS end
	return combats
end

-- Forward decl so RecordCombatEnd (below) can flush a death-state poll
-- before deciding whether to keep this combat. The actual assignment is in
-- the death-tracking section further down.
local ScanForDeaths

-- API quirk recap (also see Render comments): `forcesQuantity` is a 0..100
-- percentage, NOT a mob count. The mob count comes from `forcesTotal`. So
-- per-combat "mobs killed" = (endPct - startPct) * forcesTotal / 100. We
-- store the resulting count + the live `forcesTotal` so the history view
-- can recompute percentages even after the criterion stops reporting
-- post-completion (which leaves crit.forcesTotal = 0 at finalize time).
local function RecordCombatStart()
	if not GetActiveRun() then return end
	local crit = ReadCriteria()
	combatStart = {
		elapsed     = GetElapsedSeconds(),
		forcesPct   = (crit and crit.forcesQuantity) or 0,
		forcesTotal = (crit and crit.forcesTotal) or 0,
		bosses      = (crit and crit.bossesDone) or 0,
	}
	inCombat = true
end

local function RecordCombatEnd()
	if not inCombat or not combatStart then return end
	inCombat = false
	-- Flush a death-state poll BEFORE deciding whether to keep the combat.
	-- The ticker only polls every 0.5s, and a wipe death can land in the
	-- gap between the last poll and now — without this flush, the death
	-- wouldn't be in `deaths[]` yet and the hadDeath check below would
	-- false-negative, dropping the combat (and orphaning the death).
	if ScanForDeaths then ScanForDeaths() end
	local crit = ReadCriteria()
	local endPct    = (crit and crit.forcesQuantity) or 0
	local endBosses = (crit and crit.bossesDone) or 0
	-- Prefer the post-combat totalQuantity if the API still reports it
	-- (means we're still mid-run). Falls back to the snapshotted value
	-- from combat start, which we'd have grabbed before any criterion drop.
	local forcesTotal = (crit and crit.forcesTotal) or combatStart.forcesTotal or 0
	local pctDelta = math.max(0, endPct - combatStart.forcesPct)
	local countDelta = (forcesTotal > 0) and math.floor(forcesTotal * pctDelta / 100 + 0.5) or 0
	local entry = {
		startElapsed = combatStart.elapsed,
		duration     = GetElapsedSeconds() - combatStart.elapsed,
		forcesKilled = countDelta,
		forcesTotal  = forcesTotal,
		boss         = endBosses > combatStart.bosses,
	}
	combatStart = nil
	-- Keep combats with any noteworthy event. Wipes typically have
	-- forcesKilled=0 and boss=false but ARE worth recording so the
	-- per-combat death tooltip in the HUD panel and the history detail
	-- view can attribute each death to a real combat row. Without this
	-- last clause, a 5-person wipe between bosses gets silently dropped
	-- and its deaths only surface in the run-wide DEATHS subsection.
	local hadDeath = false
	for _, d in ipairs(deaths) do
		if d.elapsed and d.elapsed >= entry.startElapsed
		   and d.elapsed <= entry.startElapsed + entry.duration then
			hadDeath = true
			break
		end
	end
	if entry.forcesKilled > 0 or entry.boss or hadDeath then
		table.insert(combats, entry)
	end
end

local function ResetCombats()
	wipe(combats)
	inCombat = false
	combatStart = nil
end

-- ----------------------------------------------------------------------------
-- Death tracking
--
-- Midnight (12.0) removed COMBAT_LOG_EVENT_UNFILTERED for addons, so the
-- usual UNIT_DIED-subevent path is unavailable. Instead we poll the party's
-- dead-or-ghost state on the existing 0.5s HUD ticker and record edges
-- (alive -> dead) ourselves. `UnitIsDeadOrGhost`, `UnitName`, `UnitClass`,
-- and `UnitGUID` return booleans/strings — none of those are Secret Values,
-- so the polling path stays valid in M+ instances where numeric reads
-- (health, damage) are concealed.
--
-- Per-combat attribution is derived (not stored) — `DeathsInCombat(combat)`
-- walks `deaths` and matches by elapsed-time window. That keeps the death
-- list canonical (no double-bookkeeping) and means the per-combat indicator
-- in the panel and the per-combat indicator in saved history use the same
-- math without us having to update two structures on each death.
-- ----------------------------------------------------------------------------

local deaths = {}
local lastDeadStateByGUID = {}  -- guid -> true (dead at last poll) | nil/false (alive)

-- Pre-canned sample deaths for /sk hudtest so the panel preview shows the
-- death cells populated alongside the synthetic combats.
local TEST_DEATHS = {
	{ name = "Tankenstein",  class = "WARRIOR", elapsed = 124 },
	{ name = "Spellslinger", class = "MAGE",    elapsed = 138 },
	{ name = "Spellslinger", class = "MAGE",    elapsed = 211 },
}

local function GetDeaths()
	if testMode then return TEST_DEATHS end
	return deaths
end

-- Counts how many deaths fell within the combat's elapsed-time window
-- [startElapsed, startElapsed + duration]. Used by both the HUD's expanded
-- panel and the run-history detail view so the attribution is consistent.
local function DeathsInCombat(combat)
	if not combat then return 0 end
	local ds = GetDeaths()
	local startE = combat.startElapsed or 0
	local endE   = startE + (combat.duration or 0)
	local n = 0
	for _, d in ipairs(ds) do
		if d.elapsed >= startE and d.elapsed <= endE then n = n + 1 end
	end
	return n
end

local function ResetDeaths()
	wipe(deaths)
	wipe(lastDeadStateByGUID)
	-- Seed the per-unit state map with current dead/alive status so the first
	-- post-reset ScanForDeaths doesn't false-positive on units that were
	-- already dead at reset time (e.g. after a CHALLENGE_MODE_RESET fired
	-- while bodies were still on the floor).
	for i = 0, 4 do
		local unit = (i == 0) and "player" or ("party" .. i)
		if UnitExists(unit) then
			local guid = UnitGUID(unit)
			if guid then
				lastDeadStateByGUID[guid] = UnitIsDeadOrGhost(unit) and true or false
			end
		end
	end
end

-- Tooltip helpers shared by the HUD's deaths section icon (aggregate
-- count-by-name) and each combat row's per-combat death cell (chronological
-- name + MM:SS within the combat's elapsed-time window). Both anchored
-- ANCHOR_RIGHT so the tooltip floats out beside the icon without covering
-- the HUD or expanded panel content.
--
-- Defined ahead of BuildFrame / BuildPanel so the OnEnter closures attached
-- during construction can capture these locals.

local function ShowHudDeathsTooltip(anchor)
	GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Deaths", 1, 0.82, 0)
	local ds = GetDeaths()
	if #ds == 0 then
		GameTooltip:AddLine("(no deaths yet)", 0.7, 0.7, 0.7)
		GameTooltip:Show()
		return
	end
	-- Aggregate by player name, preserving first-appearance order so the
	-- list reads chronologically by who-first-died rather than alphabetically.
	local groups, order = {}, {}
	for _, d in ipairs(ds) do
		local g = groups[d.name]
		if not g then
			g = { count = 0, class = d.class }
			groups[d.name] = g
			order[#order + 1] = d.name
		end
		g.count = g.count + 1
	end
	for _, name in ipairs(order) do
		local g = groups[name]
		local r, gg, b = ns.GetClassColor(g.class)
		GameTooltip:AddDoubleLine(name, tostring(g.count), r, gg, b, 1, 1, 1)
	end
	GameTooltip:Show()
end

-- Inline MM:SS formatter — duplicated from FormatMMSS further down so this
-- tooltip helper can be declared above BuildPanel without forward-decl gymnastics.
local function FormatStamp(s)
	if not s or s < 0 then s = 0 end
	s = math.floor(s + 0.5)
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function ShowCombatDeathsTooltip(anchor, combat, combatIdx)
	if not combat then return end
	GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
	GameTooltip:AddLine(string.format("Deaths in Combat %d", combatIdx or 0), 1, 0.82, 0)
	local ds = GetDeaths()
	local startE = combat.startElapsed or 0
	local endE   = startE + (combat.duration or 0)
	local any = false
	for _, d in ipairs(ds) do
		if d.elapsed and d.elapsed >= startE and d.elapsed <= endE then
			local r, g, b = ns.GetClassColor(d.class)
			GameTooltip:AddDoubleLine(d.name or "?", FormatStamp(d.elapsed), r, g, b, 1, 1, 1)
			any = true
		end
	end
	if not any then GameTooltip:AddLine("(no deaths)", 0.7, 0.7, 0.7) end
	GameTooltip:Show()
end

-- Polled from the ticker. Walks player + party1..4, looks for any unit whose
-- dead-or-ghost state flipped from false to true since the previous poll,
-- and records a death entry with the current elapsed seconds. Resurrection
-- (dead -> alive) is also tracked so a battle-rezzed player who dies again
-- gets a second entry. We ignore deaths until the run is active so a wipe
-- in the pre-key staging area doesn't seed the list.
--
-- Assigned (not declared) so the forward-decl `local ScanForDeaths` upvalue
-- near the top of the file binds, letting RecordCombatEnd reach it without
-- caring about file ordering.
ScanForDeaths = function()
	if not GetActiveRun() then return end
	if testMode then return end
	for i = 0, 4 do
		local unit = (i == 0) and "player" or ("party" .. i)
		if UnitExists(unit) then
			local guid = UnitGUID(unit)
			if guid then
				local nowDead = UnitIsDeadOrGhost(unit) and true or false
				local wasDead = lastDeadStateByGUID[guid] and true or false
				if nowDead and not wasDead then
					local rawName = UnitName(unit) or "?"
					local short = Ambiguate and Ambiguate(rawName, "none") or rawName
					local _, class = UnitClass(unit)
					deaths[#deaths + 1] = {
						name    = short,
						class   = class,
						elapsed = GetElapsedSeconds() or 0,
					}
					Dbg(string.format("ScanForDeaths: %s (%s) died at %ds (total %d)",
						short, tostring(class), math.floor(GetElapsedSeconds() or 0), #deaths))
				end
				lastDeadStateByGUID[guid] = nowDead
			end
		end
	end
end

-- ----------------------------------------------------------------------------
-- Run lifecycle for history persistence
--
-- `currentRun` is the in-flight metadata for a run we'll save to history once
-- it ends. We build it lazily so login/reload mid-key still captures the
-- remainder of the run (start epoch is back-calculated from elapsed). We
-- finalize on three signals:
--   * CHALLENGE_MODE_COMPLETED  -> completed (with onTime + upgradeLevels)
--   * CHALLENGE_MODE_RESET      -> abandoned (key reset / left)
--   * Ticker detects no active run while currentRun is set -> abandoned
--     (covers the zone-out / log-out-then-resume cases)
--
-- Test-mode runs (/sk hudtest) are never recorded — we'd flood the saved-var
-- list with synthetic data on every test toggle.
-- ----------------------------------------------------------------------------

local currentRun = nil

local function EnsureCurrentRunMeta()
	if currentRun then return end
	if testMode then return end
	local run = GetActiveRun()
	if not run then return end
	local elapsed = GetElapsedSeconds() or 0
	currentRun = {
		startEpoch = math.floor(time() - elapsed),
		mapID      = run.mapID,
		name       = run.name,
		level      = run.level,
		affixes    = {},
		timeLimit  = run.timeLimit,
	}
	for i, id in ipairs(run.affixes or {}) do currentRun.affixes[i] = id end
	Dbg(string.format("RunHistory: tracking new run mapID=%s +%d startEpoch=%d",
		tostring(currentRun.mapID), currentRun.level, currentRun.startEpoch))
end

local function FinalizeCurrentRun(completed, completionInfo)
	if not currentRun then return end
	if testMode then currentRun = nil; return end

	-- Flush any in-flight combat before snapshotting. CHALLENGE_MODE_COMPLETED
	-- can fire before PLAYER_REGEN_ENABLED on the final-boss-kill chain — if
	-- we skipped this, the boss combat would stay buffered in `combatStart`
	-- and never make it into `combats[]`.
	if inCombat and combatStart then
		RecordCombatEnd()
	end

	local elapsed = GetElapsedSeconds() or 0
	local crit = ReadCriteria()
	-- crit.forcesTotal goes to 0 immediately on completion (the criterion
	-- stops reporting), so prefer the last positive value we ever saw via
	-- the per-combat snapshots. Walk combats[] for the max.
	local liveForcesTotal = (crit and crit.forcesTotal) or 0
	local cachedForcesTotal = 0
	for _, c in ipairs(combats) do
		if c.forcesTotal and c.forcesTotal > cachedForcesTotal then
			cachedForcesTotal = c.forcesTotal
		end
	end
	local forcesTotal = (liveForcesTotal > 0) and liveForcesTotal or cachedForcesTotal

	-- Wall-clock duration as the last-resort fallback. The completion API
	-- gives the authoritative ms-precision value when it's populated, but
	-- it can return 0 at the very moment the event fires. The in-key elapsed
	-- read is also unreliable at this point because WORLD_STATE_TIMER_STOP
	-- often arrives in the same frame and zeroes our cached timer.
	local wallClock = (currentRun.startEpoch and currentRun.startEpoch > 0)
		and math.max(0, time() - currentRun.startEpoch) or 0

	local bestDuration = 0
	if completionInfo and completionInfo.time and completionInfo.time > 0 then
		bestDuration = math.floor(completionInfo.time / 1000)
	elseif elapsed > 0 then
		bestDuration = math.floor(elapsed)
	else
		bestDuration = wallClock
	end

	local snap = {
		startEpoch     = currentRun.startEpoch,
		endEpoch       = time(),
		duration       = bestDuration,
		mapID          = currentRun.mapID,
		name           = currentRun.name,
		level          = currentRun.level,
		affixes        = currentRun.affixes,
		timeLimit      = currentRun.timeLimit,
		forcesTotal    = forcesTotal,
		completed      = completed and true or false,
		onTime         = false,
		upgradeLevels  = 0,
		player         = ns.FullName and ns.FullName(ns.NormalizeName(UnitName("player"))) or UnitName("player"),
		combats        = {},
		deaths         = {},
	}

	-- Best-effort onTime + upgradeLevels.
	--   * Trust the API's onTime when it says true.
	--   * Otherwise derive from duration vs par — covers the case where the
	--     completion API returned partial data and reported onTime=false on
	--     a run we actually timed (saw this on a real Pit of Saron +11 that
	--     finished at 21:28 of a 30:00 par).
	if completed then
		if completionInfo and completionInfo.onTime then
			snap.onTime = true
		elseif snap.timeLimit and snap.timeLimit > 0 and snap.duration > 0
		   and snap.duration <= snap.timeLimit then
			snap.onTime = true
		end
		if completionInfo and completionInfo.keystoneUpgradeLevels
		   and completionInfo.keystoneUpgradeLevels > 0 then
			snap.upgradeLevels = completionInfo.keystoneUpgradeLevels
		elseif snap.onTime and snap.timeLimit and snap.timeLimit > 0 then
			-- Derive the upgrade tier from the timer fraction: 60% par = +3,
			-- 80% = +2, on-par = +1. Matches Blizzard's tier breakpoints.
			local frac = snap.duration / snap.timeLimit
			if     frac <= 0.60 then snap.upgradeLevels = 3
			elseif frac <= 0.80 then snap.upgradeLevels = 2
			else                     snap.upgradeLevels = 1
			end
		end
	end

	for i, c in ipairs(combats) do
		snap.combats[i] = {
			startElapsed = c.startElapsed,
			duration     = c.duration,
			forcesKilled = c.forcesKilled,
			forcesTotal  = c.forcesTotal,  -- per-combat denominator for pct
			boss         = c.boss and true or false,
		}
	end

	for i, d in ipairs(deaths) do
		snap.deaths[i] = {
			name    = d.name,
			class   = d.class,
			elapsed = d.elapsed,
		}
	end

	if ns.RunHistory and ns.RunHistory.Append then
		ns.RunHistory.Append(snap)
	end
	Dbg(string.format("RunHistory: finalized completed=%s onTime=%s duration=%ds combats=%d deaths=%d",
		tostring(snap.completed), tostring(snap.onTime), snap.duration, #snap.combats, #snap.deaths))

	currentRun = nil
end

-- ----------------------------------------------------------------------------
-- Frame + section layout
--
-- The HUD is a horizontal chain of sections. Each section is an (icon, text)
-- pair, anchored left-to-right with a gap between sections and a tight gap
-- between an icon and its own label. Per-section colors and icons make each
-- chunk of info visually distinct at a glance.
--
-- Section render data lives in `f.sections[key]` (icon Texture + text
-- FontString). `Render` updates the text values, then walks SECTION_ORDER
-- to re-anchor the visible sections and resize the frame to fit.
-- ----------------------------------------------------------------------------

local f
local PADDING_X, PADDING_Y = 10, 6
local SECTION_GAP = 10        -- between sections
local ICON_TEXT_GAP = 2       -- between an icon and its own label
local ICON_SIZE = 14

-- Forward declarations so BuildFrame's click handler and Render can refer to
-- functions defined further down. Use `name = function() end` (not
-- `function name()`) when assigning so the local upvalue is bound, not a
-- new global of the same name.
local ToggleExpanded
local RenderPanel

-- HUD slot order, left-to-right. Affixes were dropped from the HUD and
-- moved into the expanded details panel; the SECTION_DEFS.affixes entry is
-- kept only for its color value, which the panel reuses for its affix line.
-- Deaths sits just before timer: forces/deaths read as the "what's been
-- spent" pair (mob budget + raid losses) before the time-remaining anchor.
local SECTION_ORDER = { "dungeon", "bosses", "forces", "deaths", "timer" }

-- Per-section visual config.
--   * `icon` is a static texture path. Sections with no `icon` and no
--     `dynamicIcon` render text only (no leading icon).
--   * `dynamicIcon` means the icon's texture is set per-Render from live
--     run data (the dungeon section uses C_ChallengeMode.GetMapUIInfo's
--     portrait texture so the icon matches the active dungeon).
--   * `crop` strips the standard icon border for Interface\Icons textures
--     (they're 64x64 with a border); `false` for UI textures that already
--     display cleanly at their native crop.
local SECTION_DEFS = {
	dungeon = {
		dynamicIcon = true,
		color = { 1.00, 0.82, 0.00 }, -- gold
		crop  = true,
	},
	affixes = {
		-- Not in SECTION_ORDER; kept for color reused by the details panel.
		color = { 1.00, 0.65, 0.40 }, -- coral
	},
	timer = {
		icon  = "Interface\\Icons\\INV_Misc_PocketWatch_01",
		color = { 1.00, 1.00, 1.00 }, -- white default; Render overrides per-tick
		crop  = true,
	},
	forces = {
		icon  = "Interface\\Icons\\INV_Sword_04",
		color = { 0.40, 0.95, 0.50 }, -- light green
		crop  = true,
	},
	bosses = {
		icon  = "Interface\\TARGETINGFRAME\\UI-TargetingFrame-Skull",
		color = { 0.85, 0.65, 1.00 }, -- light violet
		crop  = false,
	},
	deaths = {
		-- Reuses the boss skull but red-tinted via `iconVertex` so the deaths
		-- counter reads as "bad skull" at a glance — distinct from the violet
		-- bosses-remaining counter without needing a separate texture.
		icon       = "Interface\\TARGETINGFRAME\\UI-TargetingFrame-Skull",
		iconVertex = { 1.00, 0.35, 0.35, 1 },
		color      = { 1.00, 0.40, 0.40 }, -- red
		crop       = false,
	},
}

-- Worst-case sample strings per HUD section. BuildFrame renders each into
-- the corresponding FontString, measures the resulting pixel width, and
-- locks that as the section's slot width. This keeps the layout stable
-- across value changes (timer ticking, forces dropping).
local SECTION_SAMPLES = {
	dungeon = "Magisters +30",   -- longest curated short name + plausible top level
	timer   = "59:59",           -- MM:SS (we clamp negatives to 0:00)
	forces  = "999/999 (100%)",  -- full pull, "<remaining>/<total> (<pct>)"
	bosses  = "9/9",             -- bosses-remaining/bosses-total
	deaths  = "99",              -- two-digit cap; absurd-key territory but defensive
}

local SLOT_PADDING = 2  -- a couple px of safety added to each measurement

-- Joins a run's affixes into the slash-separated display string used by the
-- details panel (e.g. "T/F/Devour"). Honors test-mode pre-formatted
-- `affixLabels` if present; otherwise iterates `affixes` IDs through
-- ShortAffixName (which filters out non-display affixes like Lindormi's
-- Guidance and Xal'atath's Guile).
local function ComputeAffixDisplayString(run)
	if not run then return "-" end
	if run.affixLabels then
		return (#run.affixLabels > 0) and table.concat(run.affixLabels, "/") or "-"
	end
	local labels = {}
	for _, affixID in ipairs(run.affixes or {}) do
		local s = ShortAffixName(affixID)
		if s then labels[#labels + 1] = s end
	end
	return (#labels > 0) and table.concat(labels, "/") or "-"
end

-- Set a section's text to `sample`, measure it, and lock that as the
-- section's slot width. Called once per section from BuildFrame.
local function MeasureSection(key, sample)
	local s = f and f.sections and f.sections[key]
	if not s or not s.text then
		Dbg("MPlusHud.MeasureSection: no section for key=" .. tostring(key))
		return
	end
	s.text:SetText(sample or "")
	local strW = s.text:GetStringWidth() or 0
	s.slotWidth = math.ceil(strW + SLOT_PADDING)
	s.text:SetWidth(s.slotWidth)
	s.text:SetText("")
	Dbg(string.format("MPlusHud.MeasureSection: key=%s sample=%q stringWidth=%.1f slotWidth=%d",
		key, sample or "", strW, s.slotWidth))
end

-- Called via `securecallfunction(BuildFrame)` at PLAYER_LOGIN so the initial
-- frame creation (and tinsert into UISpecialFrames) happens in a clean
-- execution context. Without this, lazy first-build during an event handler
-- (combat-edge events, ZONE_CHANGED_NEW_AREA on dungeon load, etc.) can
-- leave SeanKeys-tainted state that Blizzard's ActionButton cooldown
-- system later blames for a "Secret values are only allowed during
-- untainted execution" error on every SPELL_UPDATE_COOLDOWN tick.
local function BuildFrame()
	if f then return f end

	-- Anonymous + parented to the SeanKeys container. ESC routes through
	-- the container's OnHide (see Core.lua GetContainer). Note this means
	-- pressing ESC during a key briefly hides the HUD; the 0.5s ticker
	-- re-shows it on the next tick because GetActiveRun() is still true.
	f = CreateFrame("Frame", nil, ns.GetContainer(), "BackdropTemplate")
	ns.RegisterWindow(f)
	f:SetFrameStrata("MEDIUM")
	f:SetSize(420, 28)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetBackdrop({
		bgFile = "Interface/Tooltips/UI-Tooltip-Background",
		edgeFile = nil,
		insets = { left = 0, right = 0, top = 0, bottom = 0 },
	})
	f:SetBackdropColor(0, 0, 0, 0.55)
	-- Drag vs click: OnDragStart sets a flag we check in OnMouseUp so a
	-- finished drag doesn't also fire as a click. Toggle is gated by
	-- "left button + not dragged in this gesture".
	f:SetScript("OnDragStart", function(self)
		self._dragged = true
		self:StartMoving()
	end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		ns.db = ns.db or {}
		ns.db.mpHudPos = { point = point, relPoint = relPoint, x = x, y = y }
	end)
	f:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" and not self._dragged and ToggleExpanded then
			ToggleExpanded()
		end
		self._dragged = false
	end)

	-- Apply saved position (or default top-center) once the frame exists.
	local pos = ns.db and ns.db.mpHudPos
	if pos and pos.point then
		f:ClearAllPoints()
		f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
	else
		f:ClearAllPoints()
		f:SetPoint("TOP", UIParent, "TOP", 0, -180)
	end

	f.sections = {}
	for _, key in ipairs(SECTION_ORDER) do
		local def = SECTION_DEFS[key]
		local s = {}

		if def.icon or def.dynamicIcon then
			s.icon = f:CreateTexture(nil, "OVERLAY")
			s.icon:SetSize(ICON_SIZE, ICON_SIZE)
			if def.icon then s.icon:SetTexture(def.icon) end
			if def.crop then s.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
			-- Optional tint (e.g. red for deaths, reusing the bosses skull).
			if def.iconVertex then
				s.icon:SetVertexColor(def.iconVertex[1], def.iconVertex[2], def.iconVertex[3], def.iconVertex[4] or 1)
			end
		end

		s.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		s.text:SetWordWrap(false)
		s.text:SetNonSpaceWrap(false)
		s.text:SetJustifyH("LEFT")
		s.text:SetJustifyV("MIDDLE")
		s.text:SetTextColor(def.color[1], def.color[2], def.color[3], 1)

		f.sections[key] = s
	end

	-- Measure each section's worst-case sample to lock in a slot width.
	for _, key in ipairs(SECTION_ORDER) do
		MeasureSection(key, SECTION_SAMPLES[key] or "")
	end

	-- Hover area over the deaths section (icon + text slot) for the
	-- aggregated death-count-by-name tooltip. Anchored relative to the
	-- icon/text so it tracks the layout-pass positions in Render.
	local dsec = f.sections.deaths
	if dsec and dsec.icon and dsec.text then
		dsec.hover = CreateFrame("Frame", nil, f)
		dsec.hover:SetPoint("LEFT",   dsec.icon, "LEFT",   0, 0)
		dsec.hover:SetPoint("RIGHT",  dsec.text, "RIGHT",  0, 0)
		dsec.hover:SetPoint("TOP",    dsec.icon, "TOP",    0, 2)
		dsec.hover:SetPoint("BOTTOM", dsec.icon, "BOTTOM", 0, -2)
		dsec.hover:EnableMouse(true)
		dsec.hover:SetScript("OnEnter", function(self) ShowHudDeathsTooltip(self) end)
		dsec.hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end

	f:Hide()
	return f
end

-- ----------------------------------------------------------------------------
-- Render
-- ----------------------------------------------------------------------------

local function FormatMMSS(sec)
	if not sec or sec < 0 then sec = 0 end
	sec = math.floor(sec + 0.5)
	return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Timer color: white default, amber inside the last 20% of par, red over par.
local function TimerRGB(remaining, timeLimit)
	if not remaining or remaining <= 0 then return 1.00, 0.31, 0.31 end
	if timeLimit and timeLimit > 0 and remaining < timeLimit * 0.2 then
		return 1.00, 0.82, 0.38
	end
	return 1.00, 1.00, 1.00
end

local function Render()
	if not f then return end
	local run = GetActiveRun()
	if not run then
		f:Hide()
		return
	end

	-- Dungeon
	local dungeonStr = string.format("%s +%d", ShortDungeonName(run.mapID, run.name), run.level)

	-- Timer (countdown)
	local elapsed = GetElapsedSeconds()
	local remaining = (run.timeLimit or 0) - elapsed
	local timerStr = FormatMMSS(remaining)
	local tr, tg, tb = TimerRGB(remaining, run.timeLimit)

	-- Forces + bosses (remaining)
	--
	-- API quirk in Midnight: the Enemy Forces criterion mixes units —
	-- `quantity` is the completion percentage (0..100) while
	-- `totalQuantity` is the actual mob count required (e.g. 596). So
	-- the "remaining count" is total * (1 - quantity/100), NOT total - quantity
	-- as the naive math would suggest. The naive math made the display
	-- decrease by exactly 100 over a full clear regardless of dungeon size.
	-- See the ReadCriteria diagnostic log if this ever shifts again.
	local crit = ReadCriteria()
	local forcesStr = "?"
	local bossesStr, hasBosses
	if crit then
		local qPct, t = crit.forcesQuantity or 0, crit.forcesTotal or 0
		if t > 0 then
			local pctRemain = math.max(0, 100 - qPct)
			local countRemain = math.floor(t * pctRemain / 100 + 0.5)
			forcesStr = string.format("%d/%d (%d%%)", countRemain, t, math.floor(pctRemain + 0.5))
		end
		local bossTotal = crit.bossesTotal or 0
		if bossTotal > 0 then
			local bossRemaining = math.max(0, bossTotal - (crit.bossesDone or 0))
			bossesStr = string.format("%d/%d", bossRemaining, bossTotal)
			hasBosses = true
		end
	end

	-- Push values to the section fontstrings.
	f.sections.dungeon.text:SetText(dungeonStr)
	f.sections.timer.text:SetText(timerStr)
	f.sections.timer.text:SetTextColor(tr, tg, tb, 1)
	f.sections.forces.text:SetText(forcesStr)
	f.sections.deaths.text:SetText(tostring(#GetDeaths()))

	-- Dungeon icon follows the active dungeon. Cached so we only hit
	-- GetMapUIInfo and SetTexture when the map actually changes.
	local dungeonIcon = f.sections.dungeon.icon
	if dungeonIcon and run.mapID and run.mapID ~= f._dungeonIconMapID then
		local _, _, _, tex = C_ChallengeMode.GetMapUIInfo(run.mapID)
		if tex then
			dungeonIcon:SetTexture(tex)
			dungeonIcon:Show()
		else
			dungeonIcon:Hide()
		end
		f._dungeonIconMapID = run.mapID
	end

	if hasBosses then
		f.sections.bosses.text:SetText(bossesStr)
		f.sections.bosses.icon:Show()
		f.sections.bosses.text:Show()
	else
		f.sections.bosses.text:SetText("")
		f.sections.bosses.icon:Hide()
		f.sections.bosses.text:Hide()
	end

	-- Layout: walk sections left-to-right at their measured slot widths so
	-- internal text changes don't shift neighbors. Sections without an icon
	-- (e.g. affixes) skip the icon span and start with text directly.
	local x = PADDING_X
	for _, key in ipairs(SECTION_ORDER) do
		local s = f.sections[key]
		if s.text:IsShown() then
			local slotW = s.slotWidth or 80
			s.text:ClearAllPoints()
			if s.icon and s.icon:IsShown() then
				s.icon:ClearAllPoints()
				s.icon:SetPoint("LEFT", f, "LEFT", x, 0)
				s.text:SetPoint("LEFT", s.icon, "RIGHT", ICON_TEXT_GAP, 0)
				x = x + ICON_SIZE + ICON_TEXT_GAP + slotW + SECTION_GAP
			else
				s.text:SetPoint("LEFT", f, "LEFT", x, 0)
				x = x + slotW + SECTION_GAP
			end
		end
	end

	-- Frame width is also fixed (sum of slot widths + gaps + padding) so the
	-- background doesn't breathe with the content either. Cache the applied
	-- dimensions and only call SetWidth/SetHeight when they actually change —
	-- the ticker fires every 0.5s, and resizing a UIParent-parented frame on
	-- every tick is the kind of thing that has historically left taint
	-- residue on Blizzard's per-frame layout state.
	local newW = math.max(120, x - SECTION_GAP + PADDING_X)
	local newH = math.max(20, ICON_SIZE + PADDING_Y * 2)
	if f._appliedW ~= newW then f:SetWidth(newW); f._appliedW = newW end
	if f._appliedH ~= newH then f:SetHeight(newH); f._appliedH = newH end

	if not f:IsShown() then
		ns.GetContainer():Show()
		f:Show()
	end

	-- Cascade into the expanded panel if it's open. Cheap when collapsed
	-- (RenderPanel early-returns).
	if RenderPanel then RenderPanel() end
end

-- ----------------------------------------------------------------------------
-- Expanded details panel
--
-- Click the HUD to toggle. Anchored under the HUD, parented to it (so it
-- moves with drags and hides when the HUD hides). Two stacked sections:
--   1. Three timers showing time remaining to upgrade the key by +1/+2/+3.
--   2. Combat log: per-combat row with forces killed, duration, dungeon
--      time remaining when combat started, and a skull marker for boss pulls.
--
-- Layout is a single top-down vertical pass that walks an accumulating y
-- offset; the panel resizes to fit. Combat rows are pre-built up to
-- MAX_COMBAT_ROWS and shown/hidden per render — newest combat at the top.
-- ----------------------------------------------------------------------------

local panel
local PANEL_PAD_X       = 8
local PANEL_PAD_Y       = 6
local PANEL_LINE        = 14
local PANEL_SECTION_GAP = 8
local PANEL_HEADER_GAP  = 2
local MAX_COMBAT_ROWS   = 30

-- Cell-icon textures, reused from the main HUD's section defs so a tweak
-- there propagates here too.
local COMBAT_SKULL_TEX  = SECTION_DEFS.bosses.icon
local COMBAT_FORCES_TEX = SECTION_DEFS.forces.icon
local COMBAT_TIME_TEX   = SECTION_DEFS.timer.icon

-- Fixed column anchors inside a combat row (px from row LEFT). The fixed
-- positions keep all rows aligned regardless of which optional cells are
-- shown (skull only appears for boss combats). The forces and time cells
-- each split into two fontstrings — a right-aligned primary value and a
-- left-aligned parenthesized secondary — so the "(" lines up vertically
-- across rows. Widths are sized for: 3-digit force counts, "(NNN%)" pcts,
-- "MM:SS" durations, and "(M:SS)" parenthesized durations.
local C_NAME_X          = 4
local C_NAME_W          = 64
local C_SKULL_X         = 72
local C_FORCES_ICON_X   = 88
local C_FORCES_KILLED_W = 22  -- "999"
local C_FORCES_PCT_W    = 40  -- "(100%)"
local C_TIME_ICON_X     = 180
local C_TIME_START_W    = 38  -- "MM:SS" (with slack)
local C_TIME_DUR_W      = 50  -- "(MM:SS)" worst case
-- Death cell anchored after the time cell; only shown when the combat had
-- one or more deaths. ICON_X is past the end of the time-dur slot
-- (180 + 11 icon + 3 + 38 + 3 + 50 = 285), plus a small visual gap.
local C_DEATH_ICON_X    = 296
local C_DEATH_COUNT_W   = 20  -- single- or two-digit count
local C_ICON_GAP        = 3   -- icon -> primary value
local C_PAREN_GAP       = 3   -- primary value -> parenthesized value
local CELL_ICON_SIZE    = 11

local function BuildPanel()
	if panel then return panel end
	if not f then return nil end

	-- Anonymous: no need for a global name on this private child.
	panel = CreateFrame("Frame", nil, f, "BackdropTemplate")
	panel:SetFrameStrata(f:GetFrameStrata())
	panel:SetPoint("TOPLEFT",  f, "BOTTOMLEFT",  0, -2)
	panel:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -2)
	panel:SetBackdrop({
		bgFile = "Interface/Tooltips/UI-Tooltip-Background",
		insets = { left = 0, right = 0, top = 0, bottom = 0 },
	})
	panel:SetBackdropColor(0, 0, 0, 0.55)

	-- Combats section header (the run-info section is just two lines — no header).
	panel.combatsHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	panel.combatsHeader:SetText("|cffffd200COMBATS|r")

	-- Run-info section: affix line + single timer row stacked.
	panel.affixRow = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	panel.affixRow:SetJustifyH("LEFT")
	local ac = SECTION_DEFS.affixes.color
	panel.affixRow:SetTextColor(ac[1], ac[2], ac[3], 1)

	panel.timerRow = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	panel.timerRow:SetJustifyH("LEFT")

	-- Combat row pool. Each row has fixed cell columns so per-row data
	-- changes don't shift cells around.
	panel.combatRows = {}
	for i = 1, MAX_COMBAT_ROWS do
		local row = CreateFrame("Frame", nil, panel)
		row:SetHeight(PANEL_LINE)

		-- "Combat N" name label (greyed for visual de-emphasis vs. data).
		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.name:SetPoint("LEFT", C_NAME_X, 0)
		row.name:SetWidth(C_NAME_W)
		row.name:SetJustifyH("LEFT")
		row.name:SetTextColor(0.78, 0.78, 0.78, 1)

		-- Boss skull (shown only for boss combats).
		row.skull = row:CreateTexture(nil, "OVERLAY")
		row.skull:SetTexture(COMBAT_SKULL_TEX)
		row.skull:SetSize(CELL_ICON_SIZE, CELL_ICON_SIZE)
		row.skull:SetPoint("LEFT", C_SKULL_X, 0)
		row.skull:Hide()

		-- Forces cell: sword icon + "<killed>" (right-aligned, fixed) + "(<pct>%)" (left-aligned, fixed)
		row.forcesIcon = row:CreateTexture(nil, "OVERLAY")
		row.forcesIcon:SetTexture(COMBAT_FORCES_TEX)
		row.forcesIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		row.forcesIcon:SetSize(CELL_ICON_SIZE, CELL_ICON_SIZE)
		row.forcesIcon:SetPoint("LEFT", C_FORCES_ICON_X, 0)

		local fc = SECTION_DEFS.forces.color
		row.forcesKilledText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.forcesKilledText:SetPoint("LEFT", row.forcesIcon, "RIGHT", C_ICON_GAP, 0)
		row.forcesKilledText:SetWidth(C_FORCES_KILLED_W)
		row.forcesKilledText:SetJustifyH("RIGHT")
		row.forcesKilledText:SetTextColor(fc[1], fc[2], fc[3], 1)

		row.forcesPctText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.forcesPctText:SetPoint("LEFT", row.forcesKilledText, "RIGHT", C_PAREN_GAP, 0)
		row.forcesPctText:SetWidth(C_FORCES_PCT_W)
		row.forcesPctText:SetJustifyH("LEFT")
		row.forcesPctText:SetTextColor(fc[1], fc[2], fc[3], 1)

		-- Time cell: clock icon + "<startRem>" (right-aligned, fixed) + "(<dur>)" (left-aligned, fixed)
		row.timeIcon = row:CreateTexture(nil, "OVERLAY")
		row.timeIcon:SetTexture(COMBAT_TIME_TEX)
		row.timeIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		row.timeIcon:SetSize(CELL_ICON_SIZE, CELL_ICON_SIZE)
		row.timeIcon:SetPoint("LEFT", C_TIME_ICON_X, 0)

		row.timeStartText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.timeStartText:SetPoint("LEFT", row.timeIcon, "RIGHT", C_ICON_GAP, 0)
		row.timeStartText:SetWidth(C_TIME_START_W)
		row.timeStartText:SetJustifyH("RIGHT")
		row.timeStartText:SetTextColor(1, 1, 1, 1)

		row.timeDurText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.timeDurText:SetPoint("LEFT", row.timeStartText, "RIGHT", C_PAREN_GAP, 0)
		row.timeDurText:SetWidth(C_TIME_DUR_W)
		row.timeDurText:SetJustifyH("LEFT")
		row.timeDurText:SetTextColor(1, 1, 1, 1)

		-- Deaths cell: red-tinted skull + count. Both hidden when the combat
		-- had zero deaths so untimed pulls don't get visual noise.
		row.deathIcon = row:CreateTexture(nil, "OVERLAY")
		row.deathIcon:SetTexture(COMBAT_SKULL_TEX)
		row.deathIcon:SetVertexColor(1.00, 0.35, 0.35, 1)
		row.deathIcon:SetSize(CELL_ICON_SIZE, CELL_ICON_SIZE)
		row.deathIcon:SetPoint("LEFT", C_DEATH_ICON_X, 0)
		row.deathIcon:Hide()

		local dc = SECTION_DEFS.deaths.color
		row.deathCountText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.deathCountText:SetPoint("LEFT", row.deathIcon, "RIGHT", C_ICON_GAP, 0)
		row.deathCountText:SetWidth(C_DEATH_COUNT_W)
		row.deathCountText:SetJustifyH("LEFT")
		row.deathCountText:SetTextColor(dc[1], dc[2], dc[3], 1)
		row.deathCountText:Hide()

		-- Hover area covering the icon + count slot. RenderPanel stashes the
		-- current combat + 1-based index on the row so the tooltip handler
		-- can resolve the per-combat death list at hover time.
		row.deathHover = CreateFrame("Frame", nil, row)
		row.deathHover:SetPoint("LEFT",   row.deathIcon,       "LEFT",   0, 0)
		row.deathHover:SetPoint("RIGHT",  row.deathCountText,  "RIGHT",  0, 0)
		row.deathHover:SetPoint("TOP",    row.deathIcon,       "TOP",    0, 2)
		row.deathHover:SetPoint("BOTTOM", row.deathIcon,       "BOTTOM", 0, -2)
		row.deathHover:EnableMouse(true)
		row.deathHover:SetScript("OnEnter", function(self)
			local r = self:GetParent()
			ShowCombatDeathsTooltip(self, r._combat, r._combatIdx)
		end)
		row.deathHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row.deathHover:Hide()

		row:Hide()
		panel.combatRows[i] = row
	end

	panel:Hide()
	return panel
end

-- Assigned (not declared) so the forward-decl `local RenderPanel` upvalue
-- gets bound, letting Render reach it without ordering concerns.
RenderPanel = function()
	if not panel or not panel:IsShown() then return end
	local run = GetActiveRun()
	if not run then return end

	local elapsed = GetElapsedSeconds()
	local tl      = run.timeLimit or 0
	local crit    = ReadCriteria()
	local forcesTotal = (crit and crit.forcesTotal) or 0

	local y = PANEL_PAD_Y

	-- Section 1, line 1: affixes (e.g. "T/F/Devour"), coloured per the
	-- defunct HUD affix-section color so visual identity carries over.
	panel.affixRow:ClearAllPoints()
	panel.affixRow:SetPoint("TOPLEFT", PANEL_PAD_X, -y)
	panel.affixRow:SetText(ComputeAffixDisplayString(run))
	y = y + PANEL_LINE

	-- Section 1, line 2: single-line timer row "+3 17:30   +2 23:30   +1 29:30"
	-- Hardest first (best upgrade you can still get on the left).
	local TIERS = {
		{ label = "+3", target = tl * 0.6 },
		{ label = "+2", target = tl * 0.8 },
		{ label = "+1", target = tl       },
	}
	local parts = {}
	for _, tier in ipairs(TIERS) do
		local rem = tier.target - elapsed
		local missed = rem <= 0
		if rem < 0 then rem = 0 end
		local timeColor = missed and "|cff888888" or "|cffffffff"
		parts[#parts + 1] = string.format("|cffffd060%s|r %s%s|r",
			tier.label, timeColor, FormatMMSS(rem))
	end
	panel.timerRow:ClearAllPoints()
	panel.timerRow:SetPoint("TOPLEFT", PANEL_PAD_X, -y)
	panel.timerRow:SetText(table.concat(parts, "     "))
	y = y + PANEL_LINE + PANEL_SECTION_GAP

	-- Section 2: combats header + rows
	panel.combatsHeader:ClearAllPoints()
	panel.combatsHeader:SetPoint("TOPLEFT", PANEL_PAD_X, -y)
	y = y + PANEL_LINE + PANEL_HEADER_GAP

	-- Combat rows, newest first. Iterate in reverse so latest pull is at top.
	-- The chronological combat number (`i` in the source array) is what we
	-- display as the row label, so the top row is "Combat N" (most recent).
	local cs = GetCombats()
	local shown = 0
	for i = #cs, 1, -1 do
		shown = shown + 1
		if shown > MAX_COMBAT_ROWS then break end
		local c = cs[i]
		local row = panel.combatRows[shown]
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT",  panel, "TOPLEFT",  PANEL_PAD_X, -y)
		row:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PANEL_PAD_X, -y)

		row.name:SetText("Combat " .. i)

		if c.boss then row.skull:Show() else row.skull:Hide() end

		-- Forces: count is now a real mob delta (see RecordCombatEnd), and we
		-- prefer the per-combat forcesTotal that was snapshotted at end of
		-- combat so the percentage stays correct even if the live criterion
		-- has since stopped reporting (e.g. just after key completion).
		local killed = c.forcesKilled or 0
		local total  = c.forcesTotal or forcesTotal or 0
		row.forcesKilledText:SetText(tostring(killed))
		if total > 0 then
			local pct = math.floor((killed / total) * 100 + 0.5)
			row.forcesPctText:SetText(string.format("(%d%%)", pct))
		else
			row.forcesPctText:SetText("")
		end

		-- Time: split into start-remaining (right-aligned, fixed) + duration
		-- (left-aligned in parens) so the "(" lines up across rows.
		local timeRemAtStart = math.max(0, tl - (c.startElapsed or 0))
		row.timeStartText:SetText(FormatMMSS(timeRemAtStart))
		row.timeDurText:SetText(string.format("(%s)", FormatMMSS(c.duration or 0)))

		-- Deaths: only render when the combat had any. DeathsInCombat reads
		-- from the live deaths array (or TEST_DEATHS under /sk hudtest), and
		-- the elapsed-time-window match is the source of truth for both the
		-- live panel and the saved history view. Stash the combat + index on
		-- the row so the death-icon hover resolves the per-combat death list.
		row._combat    = c
		row._combatIdx = i
		local nDeaths = DeathsInCombat(c)
		if nDeaths > 0 then
			row.deathCountText:SetText(tostring(nDeaths))
			row.deathIcon:Show()
			row.deathCountText:Show()
			row.deathHover:Show()
		else
			row.deathIcon:Hide()
			row.deathCountText:Hide()
			row.deathHover:Hide()
		end

		row:Show()
		y = y + PANEL_LINE
	end
	-- Hide unused row slots
	for i = shown + 1, MAX_COMBAT_ROWS do
		panel.combatRows[i]:Hide()
	end

	-- Empty-state hint when there are no combats yet.
	if shown == 0 then
		if not panel.emptyHint then
			panel.emptyHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		end
		panel.emptyHint:ClearAllPoints()
		panel.emptyHint:SetPoint("TOPLEFT", PANEL_PAD_X + 8, -y)
		panel.emptyHint:SetText("(no combats yet)")
		panel.emptyHint:Show()
		y = y + PANEL_LINE
	elseif panel.emptyHint then
		panel.emptyHint:Hide()
	end

	panel:SetHeight(y + PANEL_PAD_Y)
end

ToggleExpanded = function()
	BuildPanel()
	if not panel then return end
	if panel:IsShown() then
		panel:Hide()
	else
		panel:Show()
		RenderPanel()
	end
end

-- ----------------------------------------------------------------------------
-- Ticker
-- ----------------------------------------------------------------------------

local ticker
local function StopTicker()
	if ticker then ticker:Cancel(); ticker = nil end
end

local function StartTicker()
	if ticker then return end
	ticker = C_Timer.NewTicker(0.5, function()
		if not GetActiveRun() then
			StopTicker()
			-- The run vanished without a CHALLENGE_MODE_COMPLETED event —
			-- typically the player zoned out or otherwise abandoned. Persist
			-- whatever we have so the history reflects the attempt. Same
			-- securecallfunction isolation as Render (FinalizeCurrentRun
			-- mutates ns.db, which the panel manager indirectly reads).
			if currentRun then securecallfunction(FinalizeCurrentRun, false, nil) end
			if f then f:Hide() end
			return
		end
		-- Build run metadata on first observation. Covers logging in / reloading
		-- mid-key: the START event won't fire again, so we never had a chance
		-- to capture the run otherwise.
		if not currentRun and not testMode then EnsureCurrentRunMeta() end
		-- Poll party dead-or-ghost state for new deaths. CLEU is unavailable
		-- to addons in Midnight (12.0), so this 0.5s edge-detect is our
		-- substitute for UNIT_DIED. Cheap: 5 unit lookups per tick.
		ScanForDeaths()
		-- Strip our identity from the per-tick Render so the SetWidth /
		-- SetHeight / Show / SetText / SetPoint mutations on the HUD frame
		-- (a UIParent child) never carry SeanKeys taint into UIParent's
		-- panel-manager state. The HUD is the most frequent UI mutation
		-- site in the addon (every 0.5s during a key) — the most worthwhile
		-- place to apply this isolation.
		securecallfunction(Render)
	end)
end

-- ----------------------------------------------------------------------------
-- Public + events
--
-- We deliberately split events into two buckets:
--   * "State" events (combat edges, world timer start/stop) only mutate our
--     own Lua locals. They never touch frames or layout, and they never call
--     Refresh.
--   * "Run" events (challenge-mode lifecycle, zone changes) route through
--     Refresh, which still only flips ticker state. The ticker itself does
--     all rendering on a clean Lua call chain.
--
-- We intentionally do NOT register SCENARIO_UPDATE / SCENARIO_CRITERIA_UPDATE
-- — they fire on every mob killed during combat, and the 0.5s ticker
-- already covers that progress. Reacting to each one would be the same
-- combat-time-event-chain trap PLAYER_REGEN_DISABLED used to be.
--
-- The split exists because combat-edge events (PLAYER_REGEN_DISABLED in
-- particular) are processed by Blizzard's action-bar code on the same frame
-- — running our layout work from that handler is the kind of thing that
-- leaves SeanKeys taint on subsequent SPELL_UPDATE_COOLDOWN dispatches,
-- which then errors out every time ActionButton:SetCooldown receives a
-- secret value (the cooldown start time).
-- ----------------------------------------------------------------------------

local function Refresh()
	if not f then return end  -- not built yet (pre-PLAYER_LOGIN)
	if GetActiveRun() then
		StartTicker()
		-- Same isolation rationale as the ticker callback above — the
		-- event-driven Refresh path also mutates the HUD frame.
		securecallfunction(Render)
	else
		StopTicker()
		if not InCombatLockdown() then f:Hide() end
	end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("CHALLENGE_MODE_START")
boot:RegisterEvent("CHALLENGE_MODE_RESET")
boot:RegisterEvent("CHALLENGE_MODE_COMPLETED")
boot:RegisterEvent("WORLD_STATE_TIMER_START")
boot:RegisterEvent("WORLD_STATE_TIMER_STOP")
boot:RegisterEvent("ZONE_CHANGED_NEW_AREA")
boot:RegisterEvent("PLAYER_REGEN_DISABLED")
boot:RegisterEvent("PLAYER_REGEN_ENABLED")
boot:SetScript("OnEvent", function(_, event, arg1)
	-- State-only events: never touch frames or call Refresh here. The
	-- 0.5s ticker reads the same state and renders on a clean call chain.
	if event == "PLAYER_LOGIN" then
		-- Pre-build the frame once, inside securecallfunction, so the
		-- CreateFrame + UISpecialFrames mutation happens on a clean call
		-- chain. Same defensive pattern as the EJ pre-load in SeanKeys.lua.
		securecallfunction(BuildFrame)
		return
	elseif event == "WORLD_STATE_TIMER_START" then
		-- This event fires for any world-state timer (BG races, proving
		-- grounds, events). Verify it's a challenge-mode timer before
		-- caching it as ours, or we'll trash a valid activeTimerID with
		-- an unrelated one and the HUD timer will read 0.
		if GetWorldElapsedTime then
			local timerType, elapsed = GetWorldElapsedTime(arg1)
			local accept = IsChallengeTimer(timerType)
			Dbg(string.format("WORLD_STATE_TIMER_START: id=%s type=%s(%s) elapsed=%s expected=%d/%s accept=%s",
				tostring(arg1),
				tostring(timerType), type(timerType),
				tostring(elapsed),
				CHALLENGE_TIMER_TYPE, tostring(CHALLENGE_TIMER_NAME), tostring(accept)))
			if accept then
				activeTimerID = arg1
				lastResolvedLogElapsed = nil  -- arm the "first resolve" log for this run
			end
		else
			Dbg(string.format("WORLD_STATE_TIMER_START: id=%s (GetWorldElapsedTime missing — caching unconditionally)",
				tostring(arg1)))
			activeTimerID = arg1
			lastResolvedLogElapsed = nil
		end
		return
	elseif event == "WORLD_STATE_TIMER_STOP" then
		Dbg(string.format("WORLD_STATE_TIMER_STOP: id=%s our_cached=%s match=%s",
			tostring(arg1), tostring(activeTimerID), tostring(activeTimerID == arg1)))
		if activeTimerID == arg1 then
			activeTimerID = nil
			lastResolvedLogElapsed = nil
		end
		return
	elseif event == "PLAYER_REGEN_DISABLED" then
		RecordCombatStart()
		return
	elseif event == "PLAYER_REGEN_ENABLED" then
		RecordCombatEnd()
		-- Fall through so the HUD can hide when a key ends outside combat.
	elseif event == "CHALLENGE_MODE_START" then
		-- A new key just kicked off. If currentRun is somehow still set
		-- (prior run never cleanly finalized), persist the orphan as
		-- abandoned before clearing for the new attempt.
		if currentRun then FinalizeCurrentRun(false, nil) end
		ResetCombats()
		ResetDeaths()
		EnsureCurrentRunMeta()
	elseif event == "CHALLENGE_MODE_RESET" then
		if currentRun then FinalizeCurrentRun(false, nil) end
		ResetCombats()
		ResetDeaths()
	elseif event == "CHALLENGE_MODE_COMPLETED" then
		-- Completion API returns the canonical end state: timed/over-time and
		-- the keystone upgrade tier. Pull it through to the history entry.
		local info
		if C_ChallengeMode and C_ChallengeMode.GetCompletionInfo then
			local mapID, level, ctime, onTime, keystoneUpgradeLevels = C_ChallengeMode.GetCompletionInfo()
			info = {
				mapID                 = mapID,
				level                 = level,
				time                  = ctime,
				onTime                = onTime,
				keystoneUpgradeLevels = keystoneUpgradeLevels,
			}
		end
		FinalizeCurrentRun(true, info)
	end
	Refresh()
end)

-- ----------------------------------------------------------------------------
-- /sk hudtest
-- ----------------------------------------------------------------------------

local function ToggleTest()
	testMode = not testMode
	if testMode then
		testStartTime = GetTime()
		BuildFrame()
		StartTicker()
		Render()
	else
		StopTicker()
		Refresh() -- falls back to real-state check; hides if not in a key
	end
	return testMode
end

ns.MPlusHud = {
	Refresh = Refresh,
	ToggleTest = ToggleTest,
}
