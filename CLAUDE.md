# SeanKeys

A WoW retail addon that aggregates M+ keystone info across the three protocols party members may be broadcasting on, displays it in a unified UI, and previews dungeon loot.

## Deployed location

The live addon lives at **`D:\Blizzard\World of Warcraft\_retail_\Interface\AddOns\SeanKeys\`**. The git repo here (`D:\git\robotsdontdie\wow-seankeys\`) is the source of truth; the deployed copy is what WoW loads. Edit the deployed copy directly while iterating; when stable, copy to the repo and commit.

## What it does

1. **Aggregates keystones** from three rival in-game protocols and shows you everyone's keys regardless of which addon they use.
2. **Spec/role display** via LibSpecialization (same lib DBM/BigWigs use).
3. **Teleport buttons** for dungeons whose portal you've learned.
4. **Score upgrade indicator** — a green up-arrow when timing that key would raise your overall M+ score; tooltip shows the predicted "at least" floor.
5. **Loot preview** — left-click a dungeon name to see spec-filtered drops with real tooltips, split into gear (table) and other items (icon grid).
6. **Click name to copy Raider.IO URL** to clipboard (via popup, since `CopyToClipboard` is protected).

## The "three protocols" problem

Different keystone addons use different addon-message prefixes and wire formats. None of them talk to each other:

| Protocol | Prefix | Used by | Format |
|---|---|---|---|
| **LibKeystone** | `LibKS` | DBM, BigWigs, MDT, Keystone Hero | `<level>,<challengeMapID>,<rating>` |
| **LibOpenRaid** | `LRS` | Details, Plater, OmniCD | Multi-field via LibOpenRaid's commHandler |
| **AstralKeys** | `AstralKeys` | AstralKeys only | `<name>:<class>:<mapID>:<level>:...` |

SeanKeys joins all three networks:
- **LibKeystone**: embedded (`Libs/LibKeystone/`); auto-broadcasts our key and auto-responds to peer requests.
- **LibOpenRaid**: not bundled — accessed via `LibStub:GetLibrary("LibOpenRaid-1.0", true)` if Details (or another LibOpenRaid host) is loaded. Read-only.
- **AstralKeys**: reads the addon's saved-variable global `_G.AstralKeys` directly when AstralKeys is installed.

Incoming data from all three sources merges into a single `keys[playerName]` table, deduped and preferring fresher info.

## File layout

```
SeanKeys/
  SeanKeys.toc                            -- ## Interface: 120005 (Midnight)
  SeanKeys.lua                            -- ~1500 lines, single-file addon
  Libs/
    LibStub/LibStub.lua                   -- standard public-domain stub
    LibKeystone/LibKeystone.lua           -- verbatim copy of DBM's v10
    LibSpecialization/LibSpecialization.lua -- verbatim copy of DBM's
```

LibStub and LibKeystone are embedded so SeanKeys works even without DBM. LibOpenRaid is intentionally NOT embedded (large, complex; we read it opportunistically when Details loads it).

## Architecture in SeanKeys.lua

Top-to-bottom:

1. **Module locals** — `keys`, `selfDungeonBest`, `rows`, frames, etc.
2. **Debug log** — ring buffer + `Dbg(...)` helper; `ShowDebugWindow()` builds a lazy frame with a scrollable, copyable EditBox.
3. **Helpers** — Raider.IO URL, role icons, class colors, key-level color, secondaries from `C_Item.GetItemStats`, dungeon-name lookup.
4. **Data store** — `UpsertKey(name, level, mapID, rating, source, class)` and `UpsertSpec(name, specID, role)`. Both prefer non-zero/real info over zeroes.
5. **Protocol subscriptions** — LibKeystone callback, LibSpec callback (group + guild), LibOpenRaid lazy bind, AstralKeys scan, "self" pull.
6. **Main UI** — `BuildFrame` (PortraitFrameTemplate, resizable height-only), `CreateRow`, `Refresh` (party first then everyone else by level desc), `Toggle`.
7. **Loot preview** — `GetJournalInstance` (3 fallback paths!), `GatherLoot`, `BuildLootFrame`, `ShowLootFor(challengeMapID, keyLevel)`.
8. **Slash commands** — `/sk`, `/sk refresh`, `/sk debug`, `/sk dump`.
9. **Event handlers** — ADDON_LOADED, PLAYER_LOGIN, GROUP_ROSTER_UPDATE, CHALLENGE_MODE_COMPLETED, PLAYER_REGEN_ENABLED, PLAYER_SPECIALIZATION_CHANGED.

## Slash commands

- `/sk` or `/seankeys` — toggle main window
- `/sk refresh` — force re-pull from all protocols
- `/sk debug` — toggle the in-frame "Debug" button (persists in `SeanKeysDB.showDebugButton`)
- `/sk dump` — print current keystone store to chat

## Saved variables

`SeanKeysDB` (account-wide):
- `framePos = { relativePoint, x, y }` — main frame position
- `frameHeight` — saved height (resize grip drag)
- `showDebugButton` — `boolean`, defaults `false`

## Per-season data tables — UPDATE EACH SEASON

Three places in `SeanKeys.lua` have season-specific data:

1. **`TELEPORT_SPELL_BY_CHALLENGEMAP`** — `[challengeMapID] = spellID`. Used by the teleport buttons. Source: `Details\Libs\LibOpenRaid\ThingsToMantain_<Expansion>.lua` → `LIB_OPEN_RAID_MYTHIC_PLUS_TELEPORT_SPELLS`.

2. **`CHALLENGE_TO_INSTANCEMAP`** — `[challengeMapID] = uiMapID` for journal lookup. Must match what `EJ_GetInstanceForMap` accepts. Source: `DBM-Core\modules\gui\Keystones.lua` → `teleportMap` (first element of each entry). For dungeons with "remix" variants (e.g. Magister's Terrace), use the *original* TBC-era uiMapID — that's what the journal indexes under.

3. **`EstimateMinTimedScore(level)`** — `155 + 15*(L-2) + 15*(breakpoint bumps at L>=5, 7, 10, 12)`. Source of truth: [MrMythical M+ score calculator](https://mrmythical.com/rating-calculator). If Blizzard tweaks the base score or breakpoint levels, update here. Numbers represent the *par-time* minimum — actual timed runs add 0-15 from time bonus, so this stays a true lower bound for the "at least X" tooltip claim.

## Tricky bits / gotchas

### Frame strata
All three top-level frames (main, loot, debug) are at `MEDIUM` strata with `SetToplevel(true)` and `Raise()` on show. Earlier versions used HIGH/DIALOG which caused content to render in front of Blizzard panels the user opened on top. MEDIUM matches the standard Blizzard panel level (character pane, spellbook, etc.).

### Secure frames
- **Teleport buttons** use `SecureActionButtonTemplate` with `type="spell"`. Attribute writes are blocked during combat; updates are queued in `pendingButtonUpdates` and applied on `PLAYER_REGEN_ENABLED`.
- **Anchoring rule**: secure (protected) frames cannot anchor to plain regions (textures/fontstrings). They must anchor to other frames. The name button is anchored to `row` directly (not to the role-icon texture) for this reason.
- **`CopyToClipboard`** is protected — addons cannot call it. We use a `StaticPopupDialog` with `EditBox` for the Raider.IO URL flow. The field is `self.EditBox` (capital) in modern retail, `self.editBox` in older versions; the code falls back.

### Encounter Journal API
- **Must load `Blizzard_EncounterJournal`** before any `EJ_*` data API works. `EnsureEJLoaded()` does this lazily before the journal lookups in `GetJournalInstance`.
- **`EJ_GetLootInfoByIndex` is gone** in modern retail (12.x). Use `C_EncounterJournal.GetLootInfoByIndex(i)` instead. We probe both.
- **`EJ_GetInstanceForMap(uiMapID)`** is the right entry point but the uiMapID must match what the journal indexes under. For dungeons that have multiple instance variants (Magister's Terrace = 585 original vs 2811 modern), use the original — that's where loot is filed.
- **Fallback ladder** in `GetJournalInstance`: hardcoded table → LibOpenRaid's uiMapID → name-based scan across all journal tiers (saves/restores current tier).

### Item icons / tooltips
- Use `Item:CreateFromItemLink(link)` (not `:CreateFromItemID(id)`) when the EJ provides a link — the link encodes the preview M+ level, which is lost when going through itemID.
- `C_EncounterJournal.SetPreviewMythicPlusLevel(level)` controls what level the returned links are scaled to. We set it to the clicked row's key level so tooltips show the right ilvl.
- `GameTooltip:SetHyperlink(itemLink)` produces a real Blizzard tooltip with stats, sockets, etc. — use this on icon hover.

### Gear vs "Other" split
- `IsGearItem(info)` uses `C_Item.GetItemInfoInstant(itemID)` — synchronous, doesn't need item cache, returns reliable `classID` and `equipLoc`. The EJ struct's `typeID`/`equipLocation` are unreliable across versions.
- Gear: `classID` is 2 (Weapon) or 4 (Armor), AND has a real `equipLoc` (not `INVTYPE_NON_EQUIP`/`BAG`).
- Other: everything else (crafting mats, tokens, currency, etc.)

### Player names
Always pipe through `Ambiguate(name, "none")` — gives "Name-Realm" for cross-realm players, "Name" for same realm. Used as the canonical key in `keys`.

### Combat lockdown
- Resize grip uses `f:StartSizing("BOTTOMRIGHT")` — fine in combat.
- Secure attribute changes are queued via `pendingButtonUpdates`.
- Whisper popup and dialogs are unaffected.

## Visual styling notes

- Frame chrome: `PortraitFrameTemplate` (matches character sheet / spellbook).
- Loot window portrait: `C_ChallengeMode.GetMapUIInfo(challengeMapID)`'s 4th return (the dungeon's texture FileDataID).
- Loot window title: `"<Dungeon Name> Loot"`.
- Inset alpha lowered to **0.7** to feel less heavy than default.
- Row stripe alphas: `0.08` (even rows) and `0.05` (odd) — bumped from the original `0.04/0.0` for visibility on the inset.
- Role icon texcoords are hardcoded in `ROLE_TEXCOORDS` because `GetTexCoordsForRoleSmallCircle` was removed from retail at some point.
- Upgrade arrow is `Interface\Tooltips\ReforgeGreenArrow` rotated `math.pi/2` CCW (texture ships pointing right).

## Testing workflow

1. Edit `SeanKeys.lua` in the deployed location.
2. `/reload` in-game.
3. `/sk` to open main window, `/sk debug` to enable the Debug button if you need traces.
4. The Debug window's EditBox is selectable — Ctrl+C to copy log output and paste back here.

## Things explicitly NOT done

- **No scrolling** in loot frame — gear is capped at 10 rows, "other" at 24 icons. If a dungeon ever exceeds, footer hint shows truncation count.
- **No width resize** on the main frame — column layout depends on fixed pixel positions; only height is resizable.
- **No per-dungeon score** transmission — none of the three protocols carry it; only overall season score is on the wire.
- **No automatic addon loading** for AstralKeys / LibOpenRaid hosts — we use them when present, never demand them.
