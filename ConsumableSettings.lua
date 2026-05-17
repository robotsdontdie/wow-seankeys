local ADDON_NAME, ns = ...

-- ============================================================================
-- ConsumableSettings: per-character, per-spec configuration window for the
-- consumables shopping tab. Pick items from each category and set per-item
-- target counts. All edits write through to ns.charDb.consumables[specID].
-- ============================================================================

local FRAME_W = 460
local FRAME_H = 540
local CATEGORY_BLOCK_H = 70
local settingsFrame

local function Dbg(...) if ns.Dbg then ns.Dbg(...) end end

local function CurrentSpecInfo()
	local idx = GetSpecialization()
	if not idx then return nil, "Unknown" end
	local id, name = GetSpecializationInfo(idx)
	return id, name or "Unknown"
end

local function FindEntry(list, itemID)
	for i, e in ipairs(list) do
		if e.itemID == itemID then return i, e end
	end
	return nil, nil
end

local function AddOrUpdate(list, itemID, target)
	local idx, existing = FindEntry(list, itemID)
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

-- Rebuild the rows under each category block. Cheap (a dozen frames tops);
-- recreating on every change keeps the layout simple and avoids stale state.
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

	local list = ns.ConsumablesGetSpecList and ns.ConsumablesGetSpecList(specID)
	if not list then return end

	local y = -8
	for _, cat in ipairs(ns.CONSUMABLE_CATEGORIES) do
		local block = CreateFrame("Frame", nil, settingsFrame.body)
		block:SetPoint("TOPLEFT", 8, y)
		block:SetPoint("TOPRIGHT", -8, y)
		block:SetHeight(28)
		settingsFrame.body:Track(block)

		local heading = block:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		heading:SetPoint("TOPLEFT", 4, -4)
		heading:SetText("|cffffcc00" .. cat.label .. "|r")

		local addBtn = CreateFrame("Button", nil, block, "UIPanelButtonTemplate")
		addBtn:SetSize(70, 20)
		addBtn:SetPoint("TOPRIGHT", -4, -4)
		addBtn:SetText("Add...")
		addBtn:SetScript("OnClick", function(self)
			if not MenuUtil or not MenuUtil.CreateContextMenu then return end
			MenuUtil.CreateContextMenu(self, function(_, root)
				root:CreateTitle("Add " .. cat.label)
				local options = (ns.CURRENT_SEASON_CONSUMABLES and ns.CURRENT_SEASON_CONSUMABLES[cat.key]) or {}
				for _, opt in ipairs(options) do
					local realName = (C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(opt.itemID)) or opt.name
					root:CreateButton(realName, function()
						AddOrUpdate(list[cat.key], opt.itemID, 20)
						Render()
					end)
				end
			end)
		end)

		y = y - 26

		-- Render each configured entry under this category.
		for _, entry in ipairs(list[cat.key] or {}) do
			local rowFrame = CreateFrame("Frame", nil, settingsFrame.body)
			rowFrame:SetPoint("TOPLEFT", 16, y)
			rowFrame:SetPoint("TOPRIGHT", -8, y)
			rowFrame:SetHeight(24)
			settingsFrame.body:Track(rowFrame)

			local icon = rowFrame:CreateTexture(nil, "ARTWORK")
			icon:SetSize(18, 18)
			icon:SetPoint("LEFT", 0, 0)
			icon:SetTexture(GetItemIcon(entry.itemID) or 134400)
			icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

			local name = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
			name:SetWidth(240)
			name:SetJustifyH("LEFT")
			name:SetWordWrap(false)
			local realName = (C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(entry.itemID)) or string.format("Item %d", entry.itemID)
			name:SetText(realName)

			local edit = CreateFrame("EditBox", nil, rowFrame, "InputBoxTemplate")
			edit:SetSize(48, 20)
			edit:SetPoint("LEFT", name, "RIGHT", 8, 0)
			edit:SetAutoFocus(false)
			edit:SetNumeric(true)
			edit:SetMaxLetters(4)
			edit:SetText(tostring(entry.target or 0))
			edit:SetScript("OnTextChanged", function(self)
				local v = tonumber(self:GetText()) or 0
				entry.target = v
			end)
			edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
			edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

			local removeBtn = CreateFrame("Button", nil, rowFrame, "UIPanelCloseButton")
			removeBtn:SetSize(20, 20)
			removeBtn:SetPoint("LEFT", edit, "RIGHT", 4, 0)
			removeBtn:SetScript("OnClick", function()
				Remove(list[cat.key], entry.itemID)
				Render()
			end)

			y = y - 22
		end

		y = y - 8
	end
end
ns.ConsumableSettingsRender = Render

-- A tiny child-tracking helper for the body frame so Render() can release
-- everything and rebuild on each call without losing references.
local function MakeTrackingBody(parent)
	local b = CreateFrame("Frame", nil, parent)
	b:SetPoint("TOPLEFT", 12, -36)
	b:SetPoint("BOTTOMRIGHT", -12, 12)
	b._tracked = {}
	function b:Track(child) self._tracked[#self._tracked + 1] = child end
	function b:ReleaseAllChildren()
		for _, c in ipairs(self._tracked) do c:Hide(); c:SetParent(nil) end
		self._tracked = {}
	end
	return b
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
