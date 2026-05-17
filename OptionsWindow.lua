local ADDON_NAME, ns = ...

-- ============================================================================
-- OptionsWindow: a small per-account options panel. One toggle today
-- (listen-for-ESC). Designed to grow as more user-facing knobs accumulate.
-- ============================================================================

local optionsFrame

local function BuildOptionsFrame()
	if optionsFrame then return optionsFrame end

	-- Anonymous + parented to the SeanKeys container. ESC routes through
	-- the container's OnHide; see Core.lua GetContainer.
	local f = CreateFrame("Frame", nil, ns.GetContainer(), "PortraitFrameTemplate")
	ns.RegisterWindow(f)
	f:SetSize(360, 200)
	f:SetPoint("CENTER")
	f:SetFrameStrata("MEDIUM")
	-- Highest of the SeanKeys windows so an options popup sits over the keys
	-- (2000), loot (2100), and debug (2200) windows. See Core.lua
	-- PromoteFrameLevels for the depth-based layering rationale.
	ns.PromoteFrameLevels(f, 2300)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	if f.SetTitle then f:SetTitle("SeanKeys Options") elseif f.TitleText then f.TitleText:SetText("SeanKeys Options") end
	-- Generic gear icon for the portrait slot.
	if f.SetPortraitToAsset then f:SetPortraitToAsset(136243) end
	if f.Inset and f.Inset.Bg then f.Inset.Bg:SetAlpha(0.7) end
	f:Hide()

	local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", 24, -50)
	local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	lbl:SetPoint("LEFT", cb, "RIGHT", 4, 1)
	lbl:SetText("Listen for ESC to close windows")
	cb:SetScript("OnShow", function(self)
		local on = not ns.db or not ns.db.options or ns.db.options.listenForEsc ~= false
		self:SetChecked(on)
	end)
	cb:SetScript("OnClick", function(self)
		if not ns.db then return end
		ns.db.options = ns.db.options or {}
		ns.db.options.listenForEsc = self:GetChecked() and true or false
	end)

	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 4, -4)
	hint:SetWidth(300)
	hint:SetJustifyH("LEFT")
	hint:SetText("Requires /reload to take effect.")

	optionsFrame = f
	ns.optionsFrame = f
	return f
end

local function Toggle()
	BuildOptionsFrame()
	if optionsFrame:IsShown() then
		optionsFrame:Hide()
	else
		ns.GetContainer():Show()
		optionsFrame:Show()
	end
end

ns.BuildOptionsFrame = BuildOptionsFrame
ns.ToggleOptions = Toggle
