local ADDON_NAME, ns = ...

-- ============================================================================
-- ConsumableSettings: per-character, per-spec configuration window for the
-- consumables shopping tab. A flat list of picked items with inline target
-- count editors and a remove button per row. One "Add" button at the top
-- opens a category-submenu picker. All edits write through to
-- ns.charDb.consumables[specID].
-- ============================================================================

local FRAME_W = 460
local FRAME_H = 540
local ROW_H = 26
local settingsFrame

local function Dbg(...) if ns.Dbg then ns.Dbg(...) end end

local function CurrentSpecInfo()
	local idx = GetSpecialization()
	if not idx then return nil, "Unknown" end
	local id, name = GetSpecializationInfo(idx)
	return id, name or "Unknown"
end

local function CategoryLabel(key)
	for _, cat in ipairs(ns.CONSUMABLE_CATEGORIES or {}) do
		if cat.key == key then return cat.label end
	end
	return key
end

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

local function Remove(list, itemID)
	local idx = FindEntry(list, itemID)
	if idx then table.remove(list, idx) end
end

-- Build the flat display list: { categoryKey, categoryLabel, itemID, entry, list }
-- ordered by CONSUMABLE_CATEGORIES order so categories stay grouped naturally
-- without explicit section dividers. `list` is the underlying table reference
-- so row controls can mutate it directly.
local function BuildFlatList(specList)
	local out = {}
	for _, cat in ipairs(ns.CONSUMABLE_CATEGORIES or {}) do
		for _, entry in ipairs(specList[cat.key] or {}) do
			out[#out + 1] = {
				catKey = cat.key,
				catLabel = cat.label,
				itemID = entry.itemID,
				entry = entry,
				list = specList[cat.key],
			}
		end
	end
	return out
end

-- Rebuild the body each Render. Cheap (~20 frames worst-case) and avoids
-- the bookkeeping of partial updates.
local function Render()
	if not settingsFrame then return end
	local specID, specName = CurrentSpecInfo()
	if settingsFrame.SetTitle then
		settingsFrame:SetTitle("SeanKeys Consumables — " .. (specName or "?"))
	end
	settingsFrame.body:ReleaseAllChildren()

	if not specID then
		local fs = settingsFrame.body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		fs:SetPoint("TOPLEFT", 12, -12)
		fs:SetText("No active specialization.")
		return
	end

	local specList = ns.ConsumablesGetSpecList and ns.ConsumablesGetSpecList(specID)
	if not specList then return end

	local flat = BuildFlatList(specList)
	local y = -8

	if #flat == 0 then
		local hint = settingsFrame.body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		hint:SetPoint("TOPLEFT", 12, y - 4)
		hint:SetWidth(FRAME_W - 60)
		hint:SetJustifyH("LEFT")
		hint:SetText("No consumables picked yet. Use |cffffffffAdd...|r above to start.")
		return
	end

	-- Each row: <category dim> | icon | item name | qty editbox | X remove
	for _, item in ipairs(flat) do
		local rowFrame = CreateFrame("Frame", nil, settingsFrame.body)
		rowFrame:SetPoint("TOPLEFT", 8, y)
		rowFrame:SetPoint("TOPRIGHT", -8, y)
		rowFrame:SetHeight(ROW_H - 2)
		settingsFrame.body:Track(rowFrame)

		local catFs = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		catFs:SetPoint("LEFT", 0, 0)
		catFs:SetWidth(90)
		catFs:SetJustifyH("LEFT")
		catFs:SetText(item.catLabel)

		local icon = rowFrame:CreateTexture(nil, "ARTWORK")
		icon:SetSize(18, 18)
		icon:SetPoint("LEFT", catFs, "RIGHT", 4, 0)
		icon:SetTexture(GetItemIcon(item.itemID) or 134400)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

		local name = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
		name:SetWidth(200)
		name:SetJustifyH("LEFT")
		name:SetWordWrap(false)
		local realName = (C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(item.itemID))
			or string.format("Item %d", item.itemID)
		name:SetText(realName)

		local edit = CreateFrame("EditBox", nil, rowFrame, "InputBoxTemplate")
		edit:SetSize(48, 20)
		edit:SetPoint("LEFT", name, "RIGHT", 8, 0)
		edit:SetAutoFocus(false)
		edit:SetNumeric(true)
		edit:SetMaxLetters(4)
		edit:SetText(tostring(item.entry.target or 0))
		edit:SetScript("OnTextChanged", function(self)
			item.entry.target = tonumber(self:GetText()) or 0
		end)
		edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
		edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

		local removeBtn = CreateFrame("Button", nil, rowFrame, "UIPanelCloseButton")
		removeBtn:SetSize(20, 20)
		removeBtn:SetPoint("LEFT", edit, "RIGHT", 4, 0)
		removeBtn:SetScript("OnClick", function()
			Remove(item.list, item.itemID)
			Render()
			if ns.ConsumablesRefreshRows then ns.ConsumablesRefreshRows() end
		end)

		y = y - ROW_H
	end
end
ns.ConsumableSettingsRender = Render

-- A tiny child-tracking helper for the body frame so Render() can release
-- everything and rebuild on each call without losing references.
local function MakeTrackingBody(parent)
	local b = CreateFrame("Frame", nil, parent)
	b:SetPoint("TOPLEFT", 12, -64)
	b:SetPoint("BOTTOMRIGHT", -12, 12)
	b._tracked = {}
	function b:Track(child) self._tracked[#self._tracked + 1] = child end
	function b:ReleaseAllChildren()
		for _, c in ipairs(self._tracked) do c:Hide(); c:SetParent(nil) end
		self._tracked = {}
	end
	return b
end

local function ShowAddMenu(button)
	if not MenuUtil or not MenuUtil.CreateContextMenu then return end
	local specID = (CurrentSpecInfo())
	if not specID then return end
	local specList = ns.ConsumablesGetSpecList and ns.ConsumablesGetSpecList(specID)
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
					Render()
					if ns.ConsumablesRefreshRows then ns.ConsumablesRefreshRows() end
				end)
			end
		end
	end)
end

local function BuildSettingsFrame()
	if settingsFrame then return settingsFrame end
	local f = CreateFrame("Frame", nil, ns.GetContainer(), "PortraitFrameTemplate")
	ns.RegisterWindow(f)
	f:SetSize(FRAME_W, FRAME_H)
	f:SetPoint("CENTER")
	f:SetFrameStrata("MEDIUM")
	-- 2400 sits above keys (2000), loot (2100), debug (2200), options (2300).
	-- See Core.lua PromoteFrameLevels for the layering rationale.
	ns.PromoteFrameLevels(f, 2400)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	if f.SetPortraitToAsset then f:SetPortraitToAsset(134419) end -- generic flask icon
	if f.Inset and f.Inset.Bg then f.Inset.Bg:SetAlpha(0.7) end
	f:Hide()

	-- Single "Add..." button at the top, above the flat list.
	local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	addBtn:SetSize(90, 22)
	addBtn:SetPoint("TOPLEFT", 16, -34)
	addBtn:SetText("Add...")
	addBtn:SetScript("OnClick", function(self) ShowAddMenu(self) end)

	f.body = MakeTrackingBody(f)
	f:SetScript("OnShow", function() Render() end)

	settingsFrame = f
	ns.consumableSettingsFrame = f
	return f
end
ns.BuildConsumableSettingsFrame = BuildSettingsFrame

local function Toggle()
	BuildSettingsFrame()
	if settingsFrame:IsShown() then
		settingsFrame:Hide()
	else
		ns.GetContainer():Show()
		settingsFrame:Show()
		-- Refresh the AH tab rows too if it's open — the configured list may
		-- have changed.
		if ns.ConsumablesRefreshRows then ns.ConsumablesRefreshRows() end
	end
end
ns.ToggleConsumableSettings = Toggle
