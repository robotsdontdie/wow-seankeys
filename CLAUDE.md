# SeanKeys

A WoW retail addon that aggregates M+ keystone info across the three protocols party members may be broadcasting on, displays it in a unified UI grouped into three sections (party / alts / guild), previews dungeon loot with a per-character wishlist, and integrates with MDT.

## Deployed location

The WoW AddOn folder **`D:\Blizzard\World of Warcraft\_retail_\Interface\AddOns\SeanKeys\`** is a junction to this repo, so editing files in the repo directly is the same as editing the deployed copy. `/reload` in-game picks up your changes — no copy step needed.

## What it does

1. **Aggregates keystones** from three rival in-game protocols and shows you everyone's keys regardless of which addon they use.
2. **Caches keys** for self + guildies across sessions in account-wide saved variables. Cache-only entries (offline guildies, alts you haven't logged into yet) still show but with a greyed dungeon name.
3. **Three sections** in the main list, separated by thin gold dividers: current party, your account alts, then cached guildies. Sections are dedup'd so a guildie currently in your party only appears once.
4. **Spec/role display** via LibSpecialization (same lib DBM/BigWigs use).
5. **Teleport buttons** for dungeons whose portal you've learned.
6. **Score upgrade indicator** — a green up-arrow when timing that key would raise your overall M+ score; tooltip shows the predicted "at least" floor.
7. **Loot preview** — left-click a dungeon name to see spec-filtered drops with real tooltips, split into gear (table) and other items (icon grid). Trinkets render as `"Strength / On Use"` or `"Haste / Proc"` instead of secondary stats. The class+spec filter is selectable via a dropdown on the loot window's subtitle (defaults to the player's current spec on each open; `MenuUtil` context menu, classes as submenus with specs as radio items).
8. **Per-character wishlist** — click the gold star on any gear row to mark it. A small star appears in the main list next to any dungeon whose wishlisted items might drop (suppressed for the alts section since you can't run those keys on your current character).
9. **MDT integration** — right-click a dungeon name to open MDT to that dungeon (if installed).
10. **Click name to copy Raider.IO URL** to clipboard (via popup, since `CopyToClipboard` is protected).

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

Incoming data from all three sources merges into a single in-memory `keys[normalizedName]` table, deduped and preferring fresher info.

## File layout

```
SeanKeys/
  SeanKeys.toc                            -- ## Interface: 120005 (Midnight)
  Core.lua                                -- debug log, helpers, colors, fonts
  Data.lua                                -- key/spec store + protocol subs + persistence
  Wishlist.lua                            -- per-character wishlist module
  LootWindow.lua                          -- left-click loot preview window
  KeysWindow.lua                          -- main aggregated keys window
  SeanKeys.lua                            -- slim entry: events, slash, season data
  Libs/
    LibStub/LibStub.lua                   -- standard public-domain stub
    LibKeystone/LibKeystone.lua           -- verbatim copy of DBM's v10
    LibSpecialization/LibSpecialization.lua -- verbatim copy of DBM's
```

Load order matches the toc: Libs → Core → Data → Wishlist → LootWindow → KeysWindow → SeanKeys. Cross-file communication goes through the addon namespace `ns` (the second return of `local ADDON_NAME, ns = ...`).

LibStub and LibKeystone are embedded so SeanKeys works even without DBM. LibOpenRaid is intentionally NOT embedded (large, complex; we read it opportunistically when Details loads it).

## What lives where

- **`Core.lua`** — debug ring buffer (`Dbg`, `ShowDebugWindow`), name normalization (`NormalizeName`, `FullName`), display helpers (`GetDungeonName`, `SpecName`, `ClassFromSpec`, `GetClassColor`, `KeyLevelColor`, `SetRoleIcon`, `FormatDuration`, `EstimateMinTimedScore`), Raider.IO URL builder + StaticPopup. All exposed on `ns`.
- **`Data.lua`** — owns `keys`, `selfDungeonBest`, `guildMembers` (exposed on `ns` for cross-file reads). `UpsertKey`/`UpsertSpec` mutate the in-memory store *and* call `PersistEntry` which caches the entry into `ns.db.cache` when the player is in `ns.db.myCharacters` (cat = "self") or in `guildMembers` (cat = "guild"). Protocol subscriptions (LKS callback, LSP group + guild callbacks, LibOpenRaid lazy bind, AstralKeys SV scan) and `PullSelf` live here.
- **`Wishlist.lua`** — backed by `SeanKeysCharDB.wishlist[itemID] = { challengeMapID, name }`. Maintains an O(1) `mapHasWishlist[mapID] = count` derived index, rebuilt on `Init` and on every `Toggle`. Public API: `ns.Wishlist.IsWishlisted`, `Toggle`, `HasItemForDungeon`, `Init`.
- **`LootWindow.lua`** — `CHALLENGE_TO_INSTANCEMAP` season table, EJ resolver (`GetJournalInstance` with 3 fallback paths), `GatherLoot`, `IsGearItem`, `BuildLootFrame`, `ns.ShowLootFor`. Owns the loot frame, gear rows, "other" icon grid, the wishlist star UI, and the class/spec selector dropdown. Holds module-level `active{MapID,KeyLevel,JournalID,ClassID,SpecID}` state; `ShowLootFor` resets these to player defaults each call, `RenderLoot` re-fetches loot from the journal using the current state, and `ShowSpecMenu` opens a `MenuUtil` context menu that mutates spec state and calls `RenderLoot` to refresh in place.
- **`KeysWindow.lua`** — main aggregated window. Owns `mainFrame`, rows, separators, the dynamic section-based layout in `ns.Refresh`, `PopulateRow`, `Toggle`, and the MDT integration (`TryOpenMDT`, `MDT_DungeonIdxFor`, `NormalizeDungeonName`). Custom font `SeanKeysLevelFont` (Skurri 16pt THICKOUTLINE) is created here.
- **`SeanKeys.lua`** — entry point. Holds `TELEPORT_SPELL_BY_CHALLENGEMAP` (season-specific), slash commands, `UpdateDebugButtonVisibility`, and the boot frame with all event registrations.

## Slash commands

- `/sk`, `/seankeys`, or `/keys` — toggle main window
- `/sk refresh` — force re-pull from all protocols
- `/sk debug` — toggle the in-frame "Debug" button (persists in `SeanKeysDB.showDebugButton`)
- `/sk dump` — print current keystone store to chat
- `/sk levels` — log current frame-level state of all SeanKeys windows to the debug log and open the debug window (diagnostic for layering issues)

## Saved variables

`SeanKeysDB` (account-wide):
- `framePos = { relativePoint, x, y }` — main frame position
- `frameHeight` — saved height (resize grip drag)
- `showDebugButton` — `boolean`, defaults `false`
- `myCharacters[fullName] = { class, lastSeen }` — every character on this account that's logged in; used to identify the "alts" section and to flag self for caching
- `cache[fullName] = { level, mapID, rating, class, specID, role, source, lastSeen, category }` — persistent keystone cache for self + guildies

`SeanKeysCharDB` (per-character):
- `wishlist[itemID] = { challengeMapID, name, addedAt }` — wishlisted gear; only keyed by itemID (we don't track ilvl/specifics)

Note: `fullName` here is the canonical `"Name-NormalizedRealm"` form produced by `FullName(...)`, so alts cached on Realm A can be found from Realm B.

## Per-season data tables — UPDATE EACH SEASON

Three places have season-specific data:

1. **`TELEPORT_SPELL_BY_CHALLENGEMAP`** (in `SeanKeys.lua`) — `[challengeMapID] = spellID`. Used by the teleport buttons. Source: `Details\Libs\LibOpenRaid\ThingsToMantain_<Expansion>.lua` → `LIB_OPEN_RAID_MYTHIC_PLUS_TELEPORT_SPELLS`.

2. **`CHALLENGE_TO_INSTANCEMAP`** (in `LootWindow.lua`) — `[challengeMapID] = uiMapID` for journal lookup. Must match what `EJ_GetInstanceForMap` accepts. Source: `DBM-Core\modules\gui\Keystones.lua` → `teleportMap` (first element of each entry). For dungeons with "remix" variants (e.g. Magister's Terrace), use the *original* TBC-era uiMapID — that's what the journal indexes under.

3. **`EstimateMinTimedScore(level)`** (in `Core.lua`) — `155 + 15*(L-2) + 15*(breakpoint bumps at L>=5, 7, 10, 12)`. Source of truth: [MrMythical M+ score calculator](https://mrmythical.com/rating-calculator). If Blizzard tweaks the base score or breakpoint levels, update here. Numbers represent the *par-time* minimum — actual timed runs add 0-15 from time bonus, so this stays a true lower bound for the "at least X" tooltip claim.

## Tricky bits / gotchas

### Frame strata
All three top-level frames are at `MEDIUM` strata with frame levels assigned via `ns.PromoteFrameLevels` at build time: keys = 2000, loot = 2100, debug = 2200. The 100-apart spacing keeps each window's chrome range well clear of the next window's parent level. Earlier versions used HIGH/DIALOG which caused content to render in front of Blizzard panels the user opened on top. MEDIUM matches the standard Blizzard panel level; a high baseline keeps us above other MEDIUM-strata addon overlays — the 2000 floor was chosen specifically because UnhaltedUnitFrames creates a `HighLevelContainer` at level 999 in MEDIUM (where it parks health/resource text, leader/rested icons, etc.), and TweaksUI_Cooldowns child icons climb to ~115 above their level-100 parents. Blizzard panels still render on top because their XML sets `toplevel="true"`, which the frame engine enforces above any fixed level.

`ns.PromoteFrameLevels(frame, baseLevel)` (in Core.lua) recursively assigns each descendant `baseLevel + depth * 10` rather than preserving the template's original relative offsets. This is intentional and surprising: `PortraitFrameTemplate` builds its chrome (PortraitContainer, CloseButton, Inset, ...) at absolute frame levels in the **2300-2530** range with slightly different bases per instance — so a single additive offset stretches each window's chrome into a 4000+ band that overlaps with other SeanKeys windows' chrome bands. The result was visual interleaving: debug's chrome (~4540) covered keys's content (~2001), but keys's chrome (~4500) covered debug's content (~2021). Depth-based assignment collapses each window into a tight, predictable range — keys at 2000-2030, loot at 2100-2130, debug at 2200-2230 — so each window is wholly above the previous one. Later-added content (rows, scroll children) inherits parent+1 (2001, 2101, 2201) and sits below its own window's chrome; that's fine because chrome and content don't share screen geometry. PromoteFrameLevels is taint-safe because it only writes a property on its own frames; it never enumerates or compares siblings the way `:Raise()` does.

Flattening has one wrinkle: the close button was originally one level **above** its sibling `NineSliceFrame` (2509 vs 2499) so the X icon rendered on top of the border art. Collapsing both to the same level lets the border's texture win the render-order tiebreaker and the X disappears. After the depth pass, `PromoteFrameLevels` explicitly lifts `frame.CloseButton` and its subtree to `baseLevel + 50` so the X is reliably on top of the chrome. The +50 lift keeps each window's close button still safely below the next window's parent level (100 apart).

Both `SetToplevel(true)` and `:Raise()` on show were removed because each one propagates SeanKeys taint into UIParent's panel manager:
- `SetToplevel(true)` registers the frame with the panel manager's toplevel walk.
- `:Raise()` forces a sibling frame-level scan among other MEDIUM frames; the panel manager later does its own MEDIUM walk on `ShowUIPanel` and picks up the taint we left behind.

Symptom of the leftover taint: opening the character pane (or any other panel-managed UI) while in an instance with concealed health values intermittently errors with `attempt to compare a secret number value (execution tainted by 'SeanKeys')` deep inside `TextStatusBar.UpdateTextStringWithValues`. It's intermittent because the secret-value compare only happens when player health is concealed (encounters, certain instance content), so the error can't be reproduced just by opening the character pane in town.

`SetFrameLevel(N)` writes a single property on the frame and does not enumerate siblings, so it doesn't propagate taint the way `:Raise()` does. If you ever need a different layering rule (e.g. "always above this other addon"), bump 100 to a higher fixed value rather than reintroducing `:Raise()`.

### Dynamic row layout
Rows in the main window are NOT positioned at fixed offsets at creation — `CreateRow` builds them position-less and `ns.Refresh` assigns `TOPLEFT` per visible row each tick. This is what makes the section separators work: the layout pass walks an items array (`{kind="row"|"sep", section="party|alts|guild"}`) and accumulates a y offset, inserting two pre-built `separators` between non-empty sections. Rows that overflow the visible content area are simply not positioned (and stay hidden).

### Live vs cached key resolution
`EntryFor(fullName)` in `KeysWindow.lua` merges the in-memory `keys[]` store with `ns.db.cache[]`. Three rules:

- **Spec / role / class always come from live when present.** They reflect the current session and shouldn't be overridden by a stale cache.
- **Whichever side has a positive key wins for level/mapID/rating.** `live.level > 0` overrides cached; otherwise `cached.level > 0` is used (and the dungeon name renders greyed to signal stale). The cache is updated on every `UpsertKey` for self/guild via `PersistEntry`, so `cached.level > 0` reliably means "the most recent positive key we ever recorded for this player." This intentionally outranks a live `level=0` broadcast — a `0` from LibOpenRaid's snapshot or a bare-shell entry with `source` accidentally set should not erase a known-good cached key. The trade-off: if a guildie genuinely turns in their key mid-session, we keep displaying the old cached value until a new positive broadcast arrives.
- **`PopulateRow` distinguishes "no key" from "unknown" via `entry.source`.** When both live and cached are at level 0: source set = "no key" (we received an explicit broadcast saying they don't have one); source unset = "unknown" (we have no broadcast on file, e.g. a party member whose addon hasn't reported yet). `CollectPartyNames` creates bare shells (`level=0`, no `source`) for party members so we can render their roster row before any keystone broadcast arrives.

### Secure frames
- **Teleport buttons** use `SecureActionButtonTemplate` with `type="spell"`. Attribute writes are blocked during combat; updates are queued in `pendingButtonUpdates` and applied on `PLAYER_REGEN_ENABLED` (via `ns.ProcessPending`).
- **Anchoring rule**: secure (protected) frames cannot anchor to plain regions (textures/fontstrings). They must anchor to other frames.
- **`CopyToClipboard`** is protected — addons cannot call it. We use a `StaticPopupDialog` with `EditBox` for the Raider.IO URL flow. The field is `self.EditBox` (capital) in modern retail, `self.editBox` in older versions; the code falls back.

### Encounter Journal API
- **Must load `Blizzard_EncounterJournal`** before any `EJ_*` data API works. `EnsureEJLoaded()` does this lazily before the journal lookups in `GetJournalInstance`.
- **`EJ_GetLootInfoByIndex` is gone** in modern retail (12.x). Use `C_EncounterJournal.GetLootInfoByIndex(i)` instead. We probe both.
- **`EJ_GetInstanceForMap(uiMapID)`** is the right entry point but the uiMapID must match what the journal indexes under. For dungeons that have multiple instance variants (Magister's Terrace = 585 original vs 2811 modern), use the original — that's where loot is filed.
- **Fallback ladder** in `GetJournalInstance`: hardcoded table → LibOpenRaid's uiMapID → name-based scan across all journal tiers (saves/restores current tier).

### Item icons / tooltips / slot text
- Use `Item:CreateFromItemLink(link)` (not `:CreateFromItemID(id)`) when the EJ provides a link — the link encodes the preview M+ level, which is lost when going through itemID.
- `C_EncounterJournal.SetPreviewMythicPlusLevel(level)` controls what level the returned links are scaled to. We set it to the clicked row's key level so tooltips show the right ilvl.
- `GameTooltip:SetHyperlink(itemLink)` produces a real Blizzard tooltip with stats, sockets, etc. — use this on icon hover.
- **Cold-cache slot fallback**: `lootInfo.slot` from the EJ is `nil` on the first opening of a dungeon's loot until items are cached. `ResolveSlotText` falls back to `C_Item.GetItemInfoInstant(itemID)` for the `equipLoc` constant and looks up the localized name via `_G[equipLoc]` (e.g. `_G.INVTYPE_2HWEAPON = "Two-Hand"`). A second pass also runs in the `ContinueOnItemLoad` callback so the slot fills in once the item caches.

### Trinket stats display
- For trinkets (`equipLoc == "INVTYPE_TRINKET"`), the stats column reads `"<flat stat> / On Use"` or `"<flat stat> / Proc"`.
- Flat stat: pick Strength/Agility/Intellect/Stamina from `C_Item.GetItemStats` in that order; fall back to first non-zero secondary in `SECONDARY_ORDER`.
- Trigger kind: scan `C_TooltipInfo.GetItemByID(itemID).lines` for a line starting with `ITEM_SPELL_TRIGGER_ONUSE` ("Use:") → "On Use", or `ITEM_SPELL_TRIGGER_ONEQUIP` ("Equip:") → "Proc". Stat sticks (neither prefix found) just show the bare flat stat.

### Gear vs "Other" split
- `IsGearItem(info)` uses `C_Item.GetItemInfoInstant(itemID)` — synchronous, doesn't need item cache, returns reliable `classID` and `equipLoc`. The EJ struct's `typeID`/`equipLocation` are unreliable across versions.
- Gear: `classID` is 2 (Weapon) or 4 (Armor), AND has a real `equipLoc` (not `INVTYPE_NON_EQUIP`/`BAG`).
- Other: everything else (crafting mats, tokens, currency, etc.)

### Wishlist star hover (loot window)
- Each gear row uses an `OnUpdate` poll of `row:IsMouseOver()` (excluding `iconBtn`'s area via `iconBtn:IsMouseOver()`) instead of `OnEnter`/`OnLeave`. The event-based approach left ghost stars when the cursor moved between rows faster than the event loop. Geometry polling is authoritative and trivially cheap (handful of rect comparisons per frame, only while the frame is shown).
- Star uses atlas `auctionhouse-icon-favorite` for both wishlisted (alpha 1.0) and hover preview (alpha 0.45). Earlier attempts with the `-off` outline variant or unicode `☆`/`★` glyphs didn't render reliably.

### Main-list star placement
- The small gold star next to wishlisted dungeons is positioned dynamically in `PopulateRow` using `row.dungeon.text:GetStringWidth() + 3` as the LEFT offset within the dungeon button, capped at `dungeon:GetWidth() - 14` so it never overlaps the level column.
- Suppressed entirely for `section == "alts"` since you can't run those keys on your current character.

### MDT integration (lessons from MDT source)
- `MDT:ShowInterface()` is async (uses `MDT:Async`), so `main_frame` isn't ready immediately after the call. We poll `mdt.main_frame and mdt.main_frame:IsShown()` at 50ms intervals (up to ~2s) before invoking `UpdateToDungeon`.
- **`MDT:UpdateToDungeon(idx, ignoreUpdateMap, init)`** — the second arg is a SKIP flag for the map redraw, not "force". Pass `nil` (or omit) to get the redraw. Earlier we passed `true` thinking it was "force"; that's why the dungeon switched internally but the map didn't update.
- **Do NOT pre-set `mdt.db.currentDungeonIdx = idx`** — `UpdateToDungeon` early-returns with `if idx == db.currentDungeonIdx then return end`, so a pre-set silently no-ops our refresh.
- Idx lookup tries `mdt.zoneIdToDungeonIdx[challengeMapID]` first (most reliable when populated), then falls back to fuzzy name match against `mdt.dungeonList` (lowercase + strip punctuation). The fuzzy match is needed because MDT sometimes spells a dungeon differently from `C_ChallengeMode.GetMapUIInfo` (e.g. "Nexus Point Xenas" vs "Nexus-Point Xenas").

### Player names / cache keys
- `NormalizeName(name)` pipes through `Ambiguate(name, "none")` — gives "Name-Realm" for cross-realm players, "Name" for same realm. Used as the canonical key in the in-memory `keys` store.
- `FullName(name)` always returns `"Name-NormalizedRealm"` form (uses `GetNormalizedRealmName()`). This is the cache key, so account-wide cache works correctly across realms.

### Color / font conventions
- Key level colors (custom, brighter than item-quality stock): green 2-5, blue 6-9, purple 10-11, orange 12+. We deliberately don't call `C_ChallengeMode.GetKeystoneLevelRarityColor` because its breakpoints don't match.
- Key level font: custom `SeanKeysLevelFont` = Skurri 16pt with `THICKOUTLINE`. Skurri is WoW's combat-text font; THICKOUTLINE gives bold weight (Friz Quadrata, the default UI font, has no bold variant).
- Cache-only entries: dungeon name rendered in grey `|cff888888...|r` to signal stale data (but the rest of the row stays in normal colors).

### ESC to close
Every SeanKeys top-level window is an anonymous child of a single named container frame (`SeanKeysContainer`, see `Core.lua` `GetContainer`). The container is the only frame registered in `UISpecialFrames`; its `OnHide` fans the close out to every visible registered window. Per-window globals would each tinge UIParent's panel-manager walks with SeanKeys taint, so the container collapses N taints into one.

**Container visibility must track its children**, not be permanently shown. `ToggleGameMenu()` first calls `CloseAllWindows()`, which walks `UISpecialFrames`; if anything visible gets hidden, the game menu does not open. An always-shown container eats every ESC press — pressing ESC in town does nothing instead of opening the system menu.

The container is shown explicitly at each window's show site (`Toggle`, `ShowLootFor`, `ShowDebugWindow`, HUD `Render`, `ShowCopyUrlPopup`) via `ns.GetContainer():Show()` immediately before the window's own `Show()`. Hiding goes the other way: `RegisterWindow` hooks `OnHide` on each registered window to call `UpdateContainerVisibility`, which hides the container whenever no registered window is visible. Don't try to make the show side automatic with a HookScript on `OnShow` — `Show()` on a frame whose parent is hidden fires OnShow but the template chrome doesn't always render correctly when the show is reactive; explicit ordering (container first, then window) is reliable.

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
- Section separators: 1px gold tint line (`SetColorTexture(0.6, 0.5, 0.2, 0.6)`) inside a 10px-tall frame.
- Role icon texcoords are hardcoded in `ROLE_TEXCOORDS` because `GetTexCoordsForRoleSmallCircle` was removed from retail at some point.
- Upgrade arrow is `Interface\Tooltips\ReforgeGreenArrow` rotated `math.pi/2` CCW (texture ships pointing right).
- Wishlist stars use atlas `auctionhouse-icon-favorite` (the same gold star Blizzard uses on the auction house favorites toggle).
- Main-frame padding: role icon at x=8 (left padding), rating anchored at row-right -16 (right padding); column headers at `role(8) spec(30) Player(52) Key(220) Lvl(458) Rating(494)`. The 4px gap between role→spec mirrors the spec→name gap.

## Testing workflow

1. Edit any of the addon `.lua` files in the repo (or equivalently the deployed location — they're the same).
2. `/reload` in-game.
3. `/sk` to open main window, `/sk debug` to enable the Debug button if you need traces.
4. The Debug window's EditBox is selectable — Ctrl+C to copy log output and paste back here.

## Things explicitly NOT done

- **No scrolling** in loot frame — gear is capped at 10 rows, "other" at 24 icons. If a dungeon ever exceeds, footer hint shows truncation count.
- **No width resize** on the main frame — column layout depends on fixed pixel positions; only height is resizable.
- **No per-dungeon score** transmission — none of the three protocols carry it; only overall season score is on the wire.
- **No automatic addon loading** for AstralKeys / LibOpenRaid hosts — we use them when present, never demand them.
- **No wishlist UI for items that don't drop in any cached dungeon** — wishlist is bound to `challengeMapID` at toggle time; if you wishlist an item and the dungeon rotates out, the entry persists but won't surface a star anywhere until that dungeon comes back.
