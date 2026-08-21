--[[--------------------------------------------------------------------------
	PlaterWrath - Options.lua
	A self contained options window. No Ace, no config library - 3.3.5a widget
	templates only, so the addon has no dependencies.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local Util      = ns.Util
local Scripting = ns.Scripting

local Options = {}
ns.Options = Options

local uid = 0
local function NextName(prefix)
	uid = uid + 1
	return "PlaterWrath" .. prefix .. uid
end

local function Refresh()
	if ns.Core then ns.Core.FullUpdate() end
end

--------------------------------------------------------------------------------
-- widget factory
--------------------------------------------------------------------------------

local Widgets = {}

local BACKDROP = {
	bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 32,
	insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

local INSET_BACKDROP = {
	bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

function Widgets.Header(parent, text)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	fs:SetText(text)
	fs:SetTextColor(0.3, 0.7, 1)
	return fs, 24
end

function Widgets.Text(parent, text)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetText(text)
	fs:SetJustifyH("LEFT")
	fs:SetWidth(520)
	fs:SetTextColor(0.75, 0.75, 0.75)
	return fs, 16
end

function Widgets.CheckBox(parent, label, tooltip, get, set)
	local cb = CreateFrame("CheckButton", NextName("Check"), parent, "InterfaceOptionsCheckButtonTemplate")
	_G[cb:GetName() .. "Text"]:SetText(label)
	cb.tooltipText = tooltip
	cb:SetScript("OnClick", function(self)
		set(self:GetChecked() and true or false)
		Refresh()
	end)
	cb.PlwRefresh = function() cb:SetChecked(get()) end
	return cb, 26
end

function Widgets.Slider(parent, label, minV, maxV, step, get, set)
	local name = NextName("Slider")
	local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
	s:SetWidth(260)
	s:SetMinMaxValues(minV, maxV)
	s:SetValueStep(step)
	_G[name .. "Low"]:SetText(tostring(minV))
	_G[name .. "High"]:SetText(tostring(maxV))

	local value = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	value:SetPoint("LEFT", s, "RIGHT", 10, 0)

	s:SetScript("OnValueChanged", function(self, v)
		if step >= 1 then v = math.floor(v + 0.5) else v = math.floor(v / step + 0.5) * step end
		_G[name .. "Text"]:SetText(label)
		value:SetText(string.format(step >= 1 and "%d" or "%.2f", v))
		if not self.settingUp then
			set(v)
			Refresh()
		end
	end)

	s.PlwRefresh = function()
		local v = get()
		s.settingUp = true
		s:SetValue(v)
		s.settingUp = nil
		_G[name .. "Text"]:SetText(label)
		value:SetText(string.format(step >= 1 and "%d" or "%.2f", v))
	end
	return s, 42
end

local function ShowColorPicker(r, g, b, a, callback)
	local function apply(restore)
		local nr, ng, nb, na
		if restore then
			nr, ng, nb, na = unpack(restore)
		else
			nr, ng, nb = ColorPickerFrame:GetColorRGB()
			na = OpacitySliderFrame:IsShown() and (1 - OpacitySliderFrame:GetValue()) or (a or 1)
		end
		callback(nr, ng, nb, na)
	end
	ColorPickerFrame.func        = apply
	ColorPickerFrame.opacityFunc = apply
	ColorPickerFrame.cancelFunc  = apply
	ColorPickerFrame.hasOpacity  = (a ~= nil)
	ColorPickerFrame.opacity     = a and (1 - a) or nil
	ColorPickerFrame.previousValues = { r, g, b, a }
	ColorPickerFrame:SetColorRGB(r, g, b)
	ColorPickerFrame:Hide()
	ColorPickerFrame:Show()
end

function Widgets.Color(parent, label, hasAlpha, get, set)
	local f = CreateFrame("Button", nil, parent)
	f:SetWidth(220); f:SetHeight(20)

	local swatch = f:CreateTexture(nil, "OVERLAY")
	swatch:SetTexture(Util.BLANK)
	swatch:SetWidth(16); swatch:SetHeight(16)
	swatch:SetPoint("LEFT", f, "LEFT", 2, 0)

	local border = f:CreateTexture(nil, "BACKGROUND")
	border:SetTexture(Util.BLANK)
	border:SetVertexColor(0, 0, 0, 1)
	border:SetPoint("TOPLEFT", swatch, "TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", swatch, "BOTTOMRIGHT", 1, -1)

	local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", swatch, "RIGHT", 8, 0)
	fs:SetText(label)

	f:SetScript("OnClick", function()
		local c = get()
		ShowColorPicker(c[1], c[2], c[3], hasAlpha and (c[4] or 1) or nil, function(r, g, b, a)
			set(r, g, b, a)
			swatch:SetVertexColor(r, g, b, 1)
			Refresh()
		end)
	end)

	f.PlwRefresh = function()
		local c = get()
		swatch:SetVertexColor(c[1], c[2], c[3], 1)
	end
	return f, 24
end

function Widgets.Dropdown(parent, label, itemsFunc, get, set, width)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetWidth(300); holder:SetHeight(40)

	local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", holder, "TOPLEFT", 18, 0)
	fs:SetText(label)

	local dd = CreateFrame("Frame", NextName("Dropdown"), holder, "UIDropDownMenuTemplate")
	dd:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -16)
	UIDropDownMenu_SetWidth(dd, width or 170)

	local function OnSelect(self)
		set(self.value)
		UIDropDownMenu_SetSelectedValue(dd, self.value)
		UIDropDownMenu_SetText(dd, self:GetText())
		Refresh()
	end

	UIDropDownMenu_Initialize(dd, function()
		local current = get()
		for _, item in ipairs(itemsFunc()) do
			local info = UIDropDownMenu_CreateInfo()
			info.text    = item.text
			info.value   = item.value
			info.func    = OnSelect
			info.checked = (item.value == current)
			UIDropDownMenu_AddButton(info)
		end
	end)

	holder.PlwRefresh = function()
		local current = get()
		UIDropDownMenu_SetSelectedValue(dd, current)
		for _, item in ipairs(itemsFunc()) do
			if item.value == current then UIDropDownMenu_SetText(dd, item.text) end
		end
	end
	holder.dropdown = dd
	return holder, 44
end

function Widgets.EditBox(parent, label, get, set, width)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetWidth(width or 300); holder:SetHeight(38)

	local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", holder, "TOPLEFT", 4, 0)
	fs:SetText(label)

	local eb = CreateFrame("EditBox", NextName("Edit"), holder, "InputBoxTemplate")
	eb:SetPoint("TOPLEFT", holder, "TOPLEFT", 8, -14)
	eb:SetWidth(width or 280); eb:SetHeight(20)
	eb:SetAutoFocus(false)
	eb:SetScript("OnEnterPressed", function(self)
		set(self:GetText())
		self:ClearFocus()
		Refresh()
	end)
	eb:SetScript("OnEditFocusLost", function(self) set(self:GetText()) Refresh() end)
	eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	holder.PlwRefresh = function() eb:SetText(tostring(get() or "")) end
	holder.editBox = eb
	return holder, 40
end

function Widgets.Button(parent, label, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetWidth(width or 120); b:SetHeight(22)
	b:SetText(label)
	b:SetScript("OnClick", onClick)
	return b, 26
end

function Widgets.MultiLineEdit(parent, height, width)
	local scroll = CreateFrame("ScrollFrame", NextName("Scroll"), parent, "UIPanelScrollFrameTemplate")
	scroll:SetWidth(width or 500); scroll:SetHeight(height or 200)

	local bg = CreateFrame("Frame", nil, scroll)
	bg:SetPoint("TOPLEFT", scroll, "TOPLEFT", -6, 6)
	bg:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 6, -6)
	bg:SetBackdrop(INSET_BACKDROP)
	bg:SetBackdropColor(0, 0, 0, 0.9)

	local eb = CreateFrame("EditBox", NextName("MultiEdit"), scroll)
	eb:SetMultiLine(true)
	eb:SetAutoFocus(false)
	eb:SetWidth(width or 500)
	eb:SetHeight(math.max((height or 200) * 3, 500))
	eb:SetFontObject("GameFontHighlightSmall")
	eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	-- FrameXML's scrolling-edit helpers keep the caret in view while typing.
	-- They exist on 3.3.5a, but guard anyway so a UI patch cannot break the box.
	if ScrollingEdit_OnTextChanged then
		eb:SetScript("OnTextChanged", function(self)
			ScrollingEdit_OnTextChanged(self, self:GetParent())
		end)
		eb:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
		eb:SetScript("OnUpdate", function(self, elapsed)
			ScrollingEdit_OnUpdate(self, elapsed, self:GetParent())
		end)
	end

	scroll:SetScrollChild(eb)
	scroll.editBox = eb
	return scroll, (height or 200) + 14
end

--------------------------------------------------------------------------------
-- layout helper
--------------------------------------------------------------------------------

local Layout = {}
Layout.__index = Layout

local function NewLayout(frame)
	return setmetatable({ frame = frame, y = -8, widgets = {} }, Layout)
end

function Layout:Add(widget, height, indent)
	widget:ClearAllPoints()
	widget:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 14 + (indent or 0), self.y)
	self.y = self.y - height
	if widget.PlwRefresh then self.widgets[#self.widgets + 1] = widget end
	return widget
end

function Layout:AddPair(w1, h1, w2, h2)
	w1:ClearAllPoints()
	w1:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 14, self.y)
	w2:ClearAllPoints()
	w2:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 310, self.y)
	self.y = self.y - math.max(h1, h2)
	if w1.PlwRefresh then self.widgets[#self.widgets + 1] = w1 end
	if w2.PlwRefresh then self.widgets[#self.widgets + 1] = w2 end
end

function Layout:Gap(n)
	self.y = self.y - (n or 10)
end

function Layout:Refresh()
	for _, w in ipairs(self.widgets) do
		local ok, err = pcall(w.PlwRefresh)
		if not ok then Util.Error(err) end
	end
end

function Layout:Height()
	return -self.y + 20
end

--------------------------------------------------------------------------------
-- the window
--------------------------------------------------------------------------------

local frame, tabs, panels

local TAB_LIST = {
	"General", "Health Bar", "Cast Bar", "Threat", "Auras", "Unit Types", "Mods", "Profiles",
}

local function CreatePanel()
	local scroll = CreateFrame("ScrollFrame", NextName("PanelScroll"), frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 150, -46)
	scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -34, 16)

	local content = CreateFrame("Frame", nil, scroll)
	content:SetWidth(570)
	content:SetHeight(600)
	scroll:SetScrollChild(content)

	scroll.content = content
	scroll:Hide()
	return scroll
end

local function ShowTab(index)
	for i, panel in ipairs(panels) do
		if i == index then
			panel:Show()
			if panel.layout then panel.layout:Refresh() end
			if panel.OnShow then panel.OnShow() end
		else
			panel:Hide()
		end
		tabs[i]:SetNormalFontObject(i == index and "GameFontHighlight" or "GameFontNormal")
	end
	frame.currentTab = index
end

--------------------------------------------------------------------------------
-- tab builders
--------------------------------------------------------------------------------

local db = function() return ns.db end

local function BuildGeneral(panel)
	local c = panel.content
	local L = NewLayout(c)
	panel.layout = L

	L:Add(Widgets.Header(c, "General"))
	L:Add(Widgets.CheckBox(c, "Enable PlaterWrath", "Turn the whole addon off without disabling it in the addon list.",
		function() return db().enabled end, function(v) db().enabled = v end))
	L:Add(Widgets.CheckBox(c, "Force nameplate CVars", "Disables Blizzard's plate size bloat so nameplates keep a constant size.",
		function() return db().forceBlizzardCVars end,
		function(v) db().forceBlizzardCVars = v; if v then ns.Core.ApplyCVars() end end))
	L:Add(Widgets.Slider(c, "Update interval (seconds)", 0.01, 0.20, 0.01,
		function() return db().updateInterval end, function(v) db().updateInterval = v end))

	L:Gap()
	L:Add(Widgets.Header(c, "Movement"))
	L:Add(Widgets.Text(c, "Higher smoothing makes nameplates drift towards the unit instead of darting around when mobs move quickly. 0 follows the client exactly."))
	L:Add(Widgets.Slider(c, "Movement smoothing", 0, 1.0, 0.05,
		function() return db().smoothing end, function(v) db().smoothing = v end))

	L:Gap()
	L:Add(Widgets.Header(c, "Overlap"))
	L:Add(Widgets.Text(c, "This client does not space nameplates apart on its own, so colliding plates are lifted clear of each other. The plate nearest the camera keeps its position and the ones behind it move up."))
	L:Add(Widgets.CheckBox(c, "Stop nameplates overlapping", nil,
		function() return db().stackPlates end, function(v) db().stackPlates = v end))
	L:Add(Widgets.Slider(c, "Gap between stacked plates", 0, 30, 1,
		function() return db().stackSpacing end, function(v) db().stackSpacing = v end))
	L:Add(Widgets.CheckBox(c, "Keep stacked plates clickable", nil,
		function() return db().clampStack end, function(v) db().clampStack = v end))
	L:Add(Widgets.Text(c, "Nameplates are protected frames, so the client will not let the clickable box move during combat. This caps how far a plate is lifted so its bar stays inside the box it already has, and stays near its unit. Turning it off separates crowded plates more, at the cost of the ones moved furthest not being clickable until the fight ends."))

	L:Gap()
	L:Add(Widgets.Header(c, "Clickable area"))
	L:Add(Widgets.Text(c, "The frame you click to target is Blizzard's plate, not our artwork. Matching its size to the health bar makes the bar clickable, and gives the client's plate spacing the right dimensions so plates stop overlapping."))
	L:Add(Widgets.CheckBox(c, "Resize the clickable area to fit the health bar", nil,
		function() return db().resizeClickArea end, function(v) db().resizeClickArea = v end))
	L:Add(Widgets.Slider(c, "Click width (0 = match bar)", 0, 250, 1,
		function() return db().clickWidth end, function(v) db().clickWidth = v end))
	L:Add(Widgets.Slider(c, "Click height (0 = leave alone)", 0, 80, 1,
		function() return db().clickHeight end, function(v) db().clickHeight = v end))

	L:Gap()
	L:Add(Widgets.Header(c, "Media"))
	L:Add(Widgets.Dropdown(c, "Bar texture", function()
		local t = {}
		for _, m in ipairs(Util.BarTextures) do t[#t + 1] = { text = m.name, value = m.path } end
		return t
	end, function() return db().barTexture end, function(v) db().barTexture = v end))

	L:Add(Widgets.Dropdown(c, "Font", function()
		local t = {}
		for _, m in ipairs(Util.Fonts) do t[#t + 1] = { text = m.name, value = m.path } end
		return t
	end, function() return db().font end, function(v) db().font = v end))

	L:Add(Widgets.Dropdown(c, "Font outline", function()
		local t = {}
		for _, m in ipairs(Util.Outlines) do t[#t + 1] = { text = m.name, value = m.path } end
		return t
	end, function() return db().fontOutline end, function(v) db().fontOutline = v end))

	L:Gap()
	L:Add(Widgets.Header(c, "Target"))
	L:Add(Widgets.CheckBox(c, "Highlight target border", nil,
		function() return db().targetHighlight end, function(v) db().targetHighlight = v end))
	L:Add(Widgets.CheckBox(c, "Show target arrows", nil,
		function() return db().targetIndicator end, function(v) db().targetIndicator = v end))
	L:Add(Widgets.Color(c, "Target highlight color", true,
		function() return db().targetHighlightColor end,
		function(r, g, b, a) db().targetHighlightColor = { r, g, b, a } end))
	L:Add(Widgets.Slider(c, "Target scale", 0.5, 2.0, 0.05,
		function() return db().targetScale end, function(v) db().targetScale = v end))
	L:Add(Widgets.Slider(c, "Target alpha", 0.1, 1.0, 0.05,
		function() return db().targetAlpha end, function(v) db().targetAlpha = v end))
	L:Add(Widgets.Slider(c, "Non-target alpha", 0.1, 1.0, 0.05,
		function() return db().nonTargetAlpha end, function(v) db().nonTargetAlpha = v end))
	L:Add(Widgets.Slider(c, "Alpha with no target", 0.1, 1.0, 0.05,
		function() return db().noTargetAlpha end, function(v) db().noTargetAlpha = v end))

	c:SetHeight(L:Height())
end

local function BuildHealthBar(panel)
	local c = panel.content
	local L = NewLayout(c)
	panel.layout = L

	L:Add(Widgets.Header(c, "Size and position"))
	L:Add(Widgets.Slider(c, "Width", 40, 250, 1,
		function() return db().width end, function(v) db().width = v end))
	L:Add(Widgets.Slider(c, "Height", 4, 40, 1,
		function() return db().height end, function(v) db().height = v end))
	L:Add(Widgets.Slider(c, "Scale", 0.5, 2.0, 0.05,
		function() return db().scale end, function(v) db().scale = v end))
	L:Add(Widgets.Slider(c, "Vertical offset", -60, 60, 1,
		function() return db().yOffset end, function(v) db().yOffset = v end))
	L:Add(Widgets.Slider(c, "Horizontal offset", -60, 60, 1,
		function() return db().xOffset end, function(v) db().xOffset = v end))

	L:Gap()
	L:Add(Widgets.Header(c, "Border and background"))
	L:Add(Widgets.Slider(c, "Border thickness", 0, 4, 1,
		function() return db().borderSize end, function(v) db().borderSize = math.max(1, v) end))
	L:Add(Widgets.Color(c, "Border color", true,
		function() return db().borderColor end,
		function(r, g, b, a) db().borderColor = { r, g, b, a } end))
	L:Add(Widgets.Color(c, "Background color", true,
		function() return db().bgColor end,
		function(r, g, b, a) db().bgColor = { r, g, b, a } end))

	L:Gap()
	L:Add(Widgets.Header(c, "Text"))
	L:Add(Widgets.Slider(c, "Name size", 6, 20, 1,
		function() return db().nameSize end, function(v) db().nameSize = v end))
	L:Add(Widgets.Slider(c, "Level size", 6, 20, 1,
		function() return db().levelSize end, function(v) db().levelSize = v end))
	L:Add(Widgets.Slider(c, "Health text size", 6, 20, 1,
		function() return db().healthSize end, function(v) db().healthSize = v end))
	L:Add(Widgets.Dropdown(c, "Name position", function()
		return { { text = "Above bar", value = "TOP" }, { text = "On bar", value = "CENTER" },
		         { text = "Below bar", value = "BOTTOM" } }
	end, function() return db().nameAnchor end, function(v) db().nameAnchor = v end))
	L:Add(Widgets.CheckBox(c, "Abbreviate long names", "Shadowmoon Warlock becomes S. Warlock.",
		function() return db().abbreviateNames end, function(v) db().abbreviateNames = v end))
	L:Add(Widgets.Slider(c, "Truncate name after (0 = off)", 0, 30, 1,
		function() return db().maxNameLength end, function(v) db().maxNameLength = v end))

	L:Gap()
	L:Add(Widgets.Header(c, "Indicators"))
	L:Add(Widgets.CheckBox(c, "Show raid target icon", nil,
		function() return db().showRaidIcon end, function(v) db().showRaidIcon = v end))
	L:Add(Widgets.Slider(c, "Raid icon size", 8, 40, 1,
		function() return db().raidIconSize end, function(v) db().raidIconSize = v end))
	L:Add(Widgets.Dropdown(c, "Raid icon position", function()
		return { { text = "Left", value = "LEFT" }, { text = "Right", value = "RIGHT" },
		         { text = "Above", value = "TOP" } }
	end, function() return db().raidIconAnchor end, function(v) db().raidIconAnchor = v end))
	L:Add(Widgets.CheckBox(c, "Mark elites with +", nil,
		function() return db().showEliteIcon end, function(v) db().showEliteIcon = v end))
	L:Add(Widgets.CheckBox(c, "Color bar in execute range", nil,
		function() return db().showExecuteRange end, function(v) db().showExecuteRange = v end))
	L:Add(Widgets.Slider(c, "Execute range (%)", 5, 50, 1,
		function() return db().executeRange end, function(v) db().executeRange = v end))
	L:Add(Widgets.Color(c, "Execute color", false,
		function() return db().executeColor end,
		function(r, g, b) db().executeColor = { r, g, b } end))

	c:SetHeight(L:Height())
end

local function BuildCastBar(panel)
	local c = panel.content
	local L = NewLayout(c)
	panel.layout = L
	local cb = function() return db().castBar end

	L:Add(Widgets.Header(c, "Cast Bar"))
	L:Add(Widgets.Text(c, "The cast bar mirrors Blizzard's nameplate cast bar, which is the only cast information a 3.3.5a client exposes for units you are not targeting."))
	L:Gap()
	L:Add(Widgets.CheckBox(c, "Enable cast bar", nil,
		function() return cb().enabled end, function(v) cb().enabled = v end))
	L:Add(Widgets.Slider(c, "Height", 4, 30, 1,
		function() return cb().height end, function(v) cb().height = v end))
	L:Add(Widgets.Slider(c, "Vertical offset", -30, 10, 1,
		function() return cb().yOffset end, function(v) cb().yOffset = v end))
	L:Add(Widgets.CheckBox(c, "Show spell icon", nil,
		function() return cb().showIcon end, function(v) cb().showIcon = v end))
	L:Add(Widgets.Slider(c, "Icon size (0 = match height)", 0, 40, 1,
		function() return cb().iconSize end, function(v) cb().iconSize = v end))
	L:Add(Widgets.CheckBox(c, "Show spell name", nil,
		function() return cb().showName end, function(v) cb().showName = v end))
	L:Add(Widgets.CheckBox(c, "Show cast time", nil,
		function() return cb().showTime end, function(v) cb().showTime = v end))
	L:Add(Widgets.Slider(c, "Font size", 6, 18, 1,
		function() return cb().fontSize end, function(v) cb().fontSize = v end))

	L:Gap()
	L:Add(Widgets.Color(c, "Cast color", false,
		function() return cb().color end, function(r, g, b) cb().color = { r, g, b } end))
	L:Add(Widgets.Color(c, "Channel color", false,
		function() return cb().channelColor end, function(r, g, b) cb().channelColor = { r, g, b } end))
	L:Add(Widgets.Color(c, "Uninterruptible color", false,
		function() return cb().noInterruptColor end, function(r, g, b) cb().noInterruptColor = { r, g, b } end))

	c:SetHeight(L:Height())
end

local function BuildThreat(panel)
	local c = panel.content
	local L = NewLayout(c)
	panel.layout = L
	local t = function() return db().threat end

	L:Add(Widgets.Header(c, "Threat"))
	L:Add(Widgets.Text(c, "Threat state comes from Blizzard's own aggro flash on the plate, plus the real threat API for your current target. Set a unit type's color mode to Threat on the Unit Types tab to use these colors."))
	L:Gap()
	L:Add(Widgets.CheckBox(c, "Enable threat coloring", nil,
		function() return t().enabled end, function(v) t().enabled = v end))
	L:Add(Widgets.Dropdown(c, "Mode", function()
		return {
			{ text = "Damage / Healing", value = "dps" },
			{ text = "Tank",             value = "tank" },
			{ text = "Automatic",        value = "auto" },
		}
	end, function() return t().mode end, function(v) t().mode = v end))
	L:Add(Widgets.Text(c, "Automatic switches to tank logic while you have Defensive Stance, Bear Form, Frost Presence or Righteous Fury."))

	L:Gap()
	L:Add(Widgets.Color(c, "You have aggro", false,
		function() return t().colors.aggro end, function(r, g, b) t().colors.aggro = { r, g, b } end))
	L:Add(Widgets.Color(c, "Gaining / losing aggro", false,
		function() return t().colors.transition end, function(r, g, b) t().colors.transition = { r, g, b } end))
	L:Add(Widgets.Color(c, "Someone else has aggro", false,
		function() return t().colors.noaggro end, function(r, g, b) t().colors.noaggro = { r, g, b } end))

	c:SetHeight(L:Height())
end

local function BuildAuras(panel)
	local c = panel.content
	local L = NewLayout(c)
	panel.layout = L
	local a = function() return db().auras end

	L:Add(Widgets.Header(c, "Auras"))
	L:Add(Widgets.Text(c, "Auras on units you are not targeting are read from the combat log and matched by unit name, because 3.3.5a gives nameplates no unit token. Your target, focus and mouseover use the exact API instead."))
	L:Gap()
	L:Add(Widgets.CheckBox(c, "Enable aura tracking", nil,
		function() return a().enabled end, function(v) a().enabled = v end))
	L:Add(Widgets.Dropdown(c, "Filter", function()
		return {
			{ text = "Only mine",   value = "mine" },
			{ text = "All auras",   value = "all" },
			{ text = "Whitelist",   value = "whitelist" },
		}
	end, function() return a().filter end, function(v) a().filter = v end))
	L:Add(Widgets.CheckBox(c, "Show debuffs", nil,
		function() return a().showDebuffs end, function(v) a().showDebuffs = v end))
	L:Add(Widgets.CheckBox(c, "Show buffs", nil,
		function() return a().showBuffs end, function(v) a().showBuffs = v end))
	L:Add(Widgets.Slider(c, "Icon size", 8, 48, 1,
		function() return a().size end, function(v) a().size = v end))
	L:Add(Widgets.Slider(c, "Maximum icons", 1, 16, 1,
		function() return a().max end, function(v) a().max = v end))
	L:Add(Widgets.Slider(c, "Icons per row", 1, 16, 1,
		function() return a().perRow end, function(v) a().perRow = v end))
	L:Add(Widgets.Slider(c, "Spacing", 0, 10, 1,
		function() return a().spacing end, function(v) a().spacing = v end))
	L:Add(Widgets.Slider(c, "Vertical offset", -20, 60, 1,
		function() return a().yOffset end, function(v) a().yOffset = v end))
	L:Add(Widgets.Dropdown(c, "Grow direction", function()
		return { { text = "Centered", value = "CENTER" }, { text = "Left", value = "LEFT" },
		         { text = "Right", value = "RIGHT" } }
	end, function() return a().growth end, function(v) a().growth = v end))
	L:Add(Widgets.CheckBox(c, "Show timers", nil,
		function() return a().showTimer end, function(v) a().showTimer = v end))
	L:Add(Widgets.Slider(c, "Timer decimals", 0, 3, 1,
		function() return a().timerDecimals end, function(v) a().timerDecimals = v end))
	L:Add(Widgets.Slider(c, "Timer refresh rate (seconds)", 0.02, 0.5, 0.01,
		function() return a().timerRate end, function(v) a().timerRate = v end))
	L:Add(Widgets.CheckBox(c, "Show stacks", nil,
		function() return a().showStacks end, function(v) a().showStacks = v end))
	L:Add(Widgets.CheckBox(c, "Color icon border by school", nil,
		function() return a().borderByType end, function(v) a().borderByType = v end))

	L:Gap()
	L:Add(Widgets.Header(c, "Spell lists"))
	local listMode = { value = "blacklist" }
	L:Add(Widgets.Dropdown(c, "Editing", function()
		return { { text = "Blacklist", value = "blacklist" }, { text = "Whitelist", value = "whitelist" } }
	end, function() return listMode.value end, function(v) listMode.value = v; panel.RefreshList() end))

	local listBox = L:Add(Widgets.MultiLineEdit(c, 120, 480))
	local function pull()
		local names = Util.SortedKeys(a()[listMode.value])
		listBox.editBox:SetText(table.concat(names, "\n"))
	end
	panel.RefreshList = pull

	L:Add(Widgets.Button(c, "Save list", 120, function()
		local t = {}
		for line in (listBox.editBox:GetText() or ""):gmatch("[^\r\n]+") do
			line = strtrim(line)
			if line ~= "" then t[line] = true end
		end
		a()[listMode.value] = t
		Util.Print("saved " .. Util.CountTable(t) .. " spell names to the " .. listMode.value .. ".")
		Refresh()
	end))
	L:Add(Widgets.Text(c, "One spell name per line, exactly as it appears in game."))

	panel.OnShow = pull
	c:SetHeight(L:Height())
end

local function BuildUnitTypes(panel)
	local c = panel.content
	local L = NewLayout(c)
	panel.layout = L

	local current = { key = "enemyNPC" }
	local function cfg() return db().units[current.key] end

	L:Add(Widgets.Header(c, "Unit Types"))
	L:Add(Widgets.Text(c, "Every setting below applies only to the selected unit type. Player detection uses the identity cache, so a player you have never targeted, moused over or seen in the combat log may be treated as an NPC until then."))
	L:Gap()

	L:Add(Widgets.Dropdown(c, "Unit type", function()
		local t = {}
		for _, u in ipairs(ns.UNIT_TYPES) do t[#t + 1] = { text = u.label, value = u.key } end
		return t
	end, function() return current.key end, function(v) current.key = v; panel.layout:Refresh() end, 200))

	L:Gap()
	L:Add(Widgets.CheckBox(c, "Show nameplates for this unit type", nil,
		function() return cfg().show end, function(v) cfg().show = v end))
	L:Add(Widgets.Dropdown(c, "Color mode", function()
		return {
			{ text = "Class color",    value = "class" },
			{ text = "Reaction color", value = "reaction" },
			{ text = "Threat color",   value = "threat" },
			{ text = "Custom color",   value = "custom" },
		}
	end, function() return cfg().colorMode end, function(v) cfg().colorMode = v end))
	L:Add(Widgets.Color(c, "Custom color", false,
		function() return cfg().customColor end, function(r, g, b) cfg().customColor = { r, g, b } end))
	L:Add(Widgets.Slider(c, "Alpha multiplier", 0.1, 1.0, 0.05,
		function() return cfg().alpha end, function(v) cfg().alpha = v end))
	L:Add(Widgets.Slider(c, "Scale multiplier", 0.5, 2.0, 0.05,
		function() return cfg().scale end, function(v) cfg().scale = v end))
	L:Add(Widgets.Dropdown(c, "Health text", function()
		return {
			{ text = "None",             value = "none" },
			{ text = "Percent",          value = "percent" },
			{ text = "Current health",   value = "current" },
			{ text = "Current + percent", value = "both" },
		}
	end, function() return cfg().healthText end, function(v) cfg().healthText = v end))
	L:Add(Widgets.CheckBox(c, "Show name", nil,
		function() return cfg().showName end, function(v) cfg().showName = v end))
	L:Add(Widgets.CheckBox(c, "Show level", nil,
		function() return cfg().showLevel end, function(v) cfg().showLevel = v end))
	L:Add(Widgets.CheckBox(c, "Show auras", nil,
		function() return cfg().showAuras end, function(v) cfg().showAuras = v end))
	L:Add(Widgets.CheckBox(c, "Show cast bar", nil,
		function() return cfg().showCast end, function(v) cfg().showCast = v end))

	c:SetHeight(L:Height())
end

--------------------------------------------------------------------------------
-- mods tab
--------------------------------------------------------------------------------

local function BuildMods(panel)
	local c = panel.content
	local L = NewLayout(c)
	panel.layout = L

	local state = { mod = nil, hook = "Constructor" }

	L:Add(Widgets.Header(c, "Mods and Scripts"))
	L:Add(Widgets.Text(c, "A mod is Lua compiled at runtime and run on every nameplate. Hooks receive (unitFrame, unitName, modTable); OnEvent receives (modTable, event, ...). Option values live in modTable.config and survive a mod update."))
	L:Gap()

	local modPicker = L:Add(Widgets.Dropdown(c, "Mod", function()
		local t = {}
		for _, name in ipairs(Util.SortedKeys(db().mods)) do
			local m = db().mods[name]
			t[#t + 1] = { text = (m.enabled and "" or "|cff888888") .. name, value = name }
		end
		if #t == 0 then t[1] = { text = "no mods yet", value = "" } end
		return t
	end, function() return state.mod or "" end, function(v)
		state.mod = (v ~= "" and v) or nil
		panel.Reload()
	end, 260))

	local rowY = L.y
	local newBtn = Widgets.Button(c, "New", 70, function()
		StaticPopup_Show("PLATERWRATH_NEW_MOD")
	end)
	newBtn:SetPoint("TOPLEFT", c, "TOPLEFT", 300, rowY + 28)

	local delBtn = Widgets.Button(c, "Delete", 70, function()
		if state.mod then
			Scripting.DeleteMod(state.mod)
			state.mod = nil
			panel.Reload()
		end
	end)
	delBtn:SetPoint("LEFT", newBtn, "RIGHT", 4, 0)

	local enableCheck = L:Add(Widgets.CheckBox(c, "Mod enabled", nil,
		function() return state.mod and db().mods[state.mod].enabled end,
		function(v)
			if state.mod then
				db().mods[state.mod].enabled = v
				Scripting.CompileAll()
			end
		end))

	local eventsBox = L:Add(Widgets.EditBox(c, "Events for OnEvent (comma separated)",
		function()
			if not state.mod then return "" end
			return table.concat(db().mods[state.mod].events or {}, ", ")
		end,
		function(text)
			if not state.mod then return end
			local list = {}
			for word in text:gmatch("[^,]+") do
				word = strtrim(word)
				if word ~= "" then list[#list + 1] = word end
			end
			db().mods[state.mod].events = list
			Scripting.CompileAll()
		end, 420))

	local hookPicker = L:Add(Widgets.Dropdown(c, "Hook", function()
		local t = {}
		for _, h in ipairs(Scripting.HOOKS) do
			local has = state.mod and db().mods[state.mod].code[h] and strtrim(db().mods[state.mod].code[h]) ~= ""
			t[#t + 1] = { text = (has and "|cff66ff66" or "") .. h, value = h }
		end
		return t
	end, function() return state.hook end, function(v)
		state.hook = v
		panel.Reload()
	end, 200))

	local codeBox = L:Add(Widgets.MultiLineEdit(c, 220, 500))

	L:Add(Widgets.Button(c, "Save and compile", 160, function()
		if not state.mod then
			Util.Print("select or create a mod first.")
			return
		end
		local mod = db().mods[state.mod]
		mod.code = mod.code or {}
		mod.code[state.hook] = codeBox.editBox:GetText()
		Scripting.CompileAll()
		Util.Print("compiled |cffffd100" .. state.mod .. "|r.")
		panel.Reload()
	end))

	L:Gap()
	L:Add(Widgets.Header(c, "Mod options"))
	L:Add(Widgets.Text(c, "Declared options appear here. Values are stored per profile in modTable.config."))

	-- Option widgets are rebuilt whenever the selected mod changes, so this
	-- block reserves a fixed slot in the layout instead of resizing and
	-- pushing everything below it around.
	local OPTIONS_HEIGHT = 300
	local optionsHolder = CreateFrame("Frame", nil, c)
	optionsHolder:SetWidth(520); optionsHolder:SetHeight(OPTIONS_HEIGHT)
	L:Add(optionsHolder, OPTIONS_HEIGHT)
	local optionWidgets = {}

	local declBox
	local declToggle = L:Add(Widgets.Button(c, "Edit option declarations", 200, function()
		if declBox:IsShown() then declBox:Hide() else declBox:Show() end
	end))
	declBox = L:Add(Widgets.MultiLineEdit(c, 140, 500))
	declBox:Hide()

	L:Add(Widgets.Button(c, "Save declarations", 160, function()
		if not state.mod then return end
		local text = "return " .. (declBox.editBox:GetText() or "{}")
		local chunk, err = loadstring(text)
		if not chunk then Util.Print("|cffff5555" .. tostring(err) .. "|r") return end
		setfenv(chunk, {})
		local ok, result = pcall(chunk)
		if not ok or type(result) ~= "table" then
			Util.Print("|cffff5555declarations must be a Lua table|r")
			return
		end
		db().mods[state.mod].options = result
		Scripting.CompileAll()
		panel.Reload()
	end))

	L:Gap()
	L:Add(Widgets.Header(c, "Import / Export"))
	local ioBox = L:Add(Widgets.MultiLineEdit(c, 100, 500))
	local ioY = L.y
	local expBtn = Widgets.Button(c, "Export mod", 130, function()
		if not state.mod then return end
		ioBox.editBox:SetText(Scripting.Export(state.mod) or "")
		ioBox.editBox:HighlightText()
		ioBox.editBox:SetFocus()
	end)
	expBtn:SetPoint("TOPLEFT", c, "TOPLEFT", 14, ioY)
	local impBtn = Widgets.Button(c, "Import mod", 130, function()
		local name, err = Scripting.Import(ioBox.editBox:GetText())
		if not name then
			Util.Print("|cffff5555" .. tostring(err) .. "|r")
		else
			state.mod = name
			Util.Print("imported |cffffd100" .. name .. "|r")
			panel.Reload()
		end
	end)
	impBtn:SetPoint("LEFT", expBtn, "RIGHT", 6, 0)
	L:Gap(30)

	--------------------------------------------------------------------------
	-- rebuilding the dynamic option widgets
	--------------------------------------------------------------------------
	local function BuildOptionWidgets()
		-- widgets cannot be destroyed on this client, so retire them instead
		for _, w in ipairs(optionWidgets) do
			w:Hide()
			w:ClearAllPoints()
		end
		optionWidgets = {}
		if not state.mod then return end

		local mod = db().mods[state.mod]
		local opts = mod.options or {}
		local y = 0

		for _, opt in ipairs(opts) do
			local w, h
			local key = opt.key
			if opt.type == "label" then
				w, h = Widgets.Header(optionsHolder, opt.label or "")
			elseif opt.type == "blank" then
				w, h = optionsHolder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), 12
			elseif opt.type == "toggle" then
				w, h = Widgets.CheckBox(optionsHolder, opt.label or key, opt.desc,
					function() return mod.config[key] end,
					function(v) mod.config[key] = v; Scripting.CompileAll() end)
			elseif opt.type == "number" then
				w, h = Widgets.Slider(optionsHolder, opt.label or key,
					opt.min or 0, opt.max or 100, opt.step or 1,
					function() return mod.config[key] or opt.default or 0 end,
					function(v) mod.config[key] = v; Scripting.CompileAll() end)
			elseif opt.type == "color" then
				w, h = Widgets.Color(optionsHolder, opt.label or key, false,
					function() return mod.config[key] or opt.default or { 1, 1, 1 } end,
					function(r, g, b) mod.config[key] = { r, g, b }; Scripting.CompileAll() end)
			else -- text
				w, h = Widgets.EditBox(optionsHolder, opt.label or key,
					function() return mod.config[key] or opt.default or "" end,
					function(v) mod.config[key] = v; Scripting.CompileAll() end, 380)
			end

			w:ClearAllPoints()
			w:SetPoint("TOPLEFT", optionsHolder, "TOPLEFT", 0, -y)
			y = y + h
			if w.PlwRefresh then pcall(w.PlwRefresh) end
			optionWidgets[#optionWidgets + 1] = w
		end

		if y > OPTIONS_HEIGHT then
			Util.Print("this mod declares more options than fit on screen; "
				.. "the last few are drawn over the section below.")
		end
	end

	function panel.Reload()
		if state.mod and not db().mods[state.mod] then state.mod = nil end
		if not state.mod then
			local names = Util.SortedKeys(db().mods)
			state.mod = names[1]
		end

		if state.mod then
			local mod = db().mods[state.mod]
			codeBox.editBox:SetText((mod.code and mod.code[state.hook]) or "")
			declBox.editBox:SetText(Scripting.Serialize(mod.options or {}))
		else
			codeBox.editBox:SetText("")
			declBox.editBox:SetText("{}")
		end

		BuildOptionWidgets()
		L:Refresh()
	end

	panel.OnShow = panel.Reload

	StaticPopupDialogs["PLATERWRATH_NEW_MOD"] = {
		text = "Name for the new mod:",
		button1 = ACCEPT, button2 = CANCEL,
		hasEditBox = 1, maxLetters = 60,
		OnAccept = function(self)
			local box = self.editBox or _G[self:GetName() .. "EditBox"]
			local name = strtrim(box:GetText() or "")
			if name == "" then return end
			local mod, err = Scripting.NewMod(name)
			if not mod then Util.Print("|cffff5555" .. tostring(err) .. "|r") return end
			state.mod = name
			panel.Reload()
		end,
		EditBoxOnEnterPressed = function(self)
			local parent = self:GetParent()
			StaticPopupDialogs["PLATERWRATH_NEW_MOD"].OnAccept(parent)
			parent:Hide()
		end,
		timeout = 0, whileDead = 1, hideOnEscape = 1,
	}

	c:SetHeight(1200)
end

--------------------------------------------------------------------------------
-- profiles tab
--------------------------------------------------------------------------------

local function BuildProfiles(panel)
	local c = panel.content
	local L = NewLayout(c)
	panel.layout = L

	L:Add(Widgets.Header(c, "Profiles"))
	local currentLabel = L:Add(Widgets.Text(c, ""))
	currentLabel.PlwRefresh = function()
		currentLabel:SetText("Active profile: |cffffd100" .. ns.Config.GetActiveProfile() .. "|r")
	end
	L.widgets[#L.widgets + 1] = currentLabel

	L:Gap()
	L:Add(Widgets.Dropdown(c, "Use profile", function()
		local t = {}
		for _, name in ipairs(ns.Config.GetProfileList()) do t[#t + 1] = { text = name, value = name } end
		return t
	end, function() return ns.Config.GetActiveProfile() end,
	   function(v) ns.Config.SetProfile(v); panel.layout:Refresh() end, 220))

	local newProfile = L:Add(Widgets.EditBox(c, "Create a new profile", function() return "" end,
		function(text)
			text = strtrim(text or "")
			if text ~= "" then
				ns.Config.SetProfile(text)
				panel.layout:Refresh()
			end
		end, 260))

	L:Add(Widgets.Dropdown(c, "Copy settings from", function()
		local t = {}
		for _, name in ipairs(ns.Config.GetProfileList()) do
			if name ~= ns.Config.GetActiveProfile() then t[#t + 1] = { text = name, value = name } end
		end
		if #t == 0 then t[1] = { text = "no other profiles", value = "" } end
		return t
	end, function() return "" end, function(v)
		if v ~= "" then ns.Config.CopyProfile(v); panel.layout:Refresh() end
	end, 220))

	L:Gap()
	L:Add(Widgets.Button(c, "Reset this profile", 180, function()
		ns.Config.ResetProfile()
		panel.layout:Refresh()
	end))
	L:Add(Widgets.Button(c, "Delete this profile", 180, function()
		ns.Config.DeleteProfile(ns.Config.GetActiveProfile())
		panel.layout:Refresh()
	end))

	L:Gap()
	L:Add(Widgets.Header(c, "Import / Export profile"))
	local box = L:Add(Widgets.MultiLineEdit(c, 160, 500))
	local y = L.y
	local exp = Widgets.Button(c, "Export", 120, function()
		box.editBox:SetText(Scripting.ExportProfile())
		box.editBox:HighlightText()
		box.editBox:SetFocus()
	end)
	exp:SetPoint("TOPLEFT", c, "TOPLEFT", 14, y)
	local imp = Widgets.Button(c, "Import (overwrites active)", 220, function()
		local name, err = Scripting.ImportProfile(box.editBox:GetText())
		if not name then
			Util.Print("|cffff5555" .. tostring(err) .. "|r")
		else
			Util.Print("imported into |cffffd100" .. name .. "|r")
			panel.layout:Refresh()
		end
	end)
	imp:SetPoint("LEFT", exp, "RIGHT", 6, 0)
	L:Gap(34)

	c:SetHeight(L:Height())
end

--------------------------------------------------------------------------------
-- window assembly
--------------------------------------------------------------------------------

local BUILDERS = {
	BuildGeneral, BuildHealthBar, BuildCastBar, BuildThreat,
	BuildAuras, BuildUnitTypes, BuildMods, BuildProfiles,
}

local function CreateWindow()
	frame = CreateFrame("Frame", "PlaterWrathOptionsFrame", UIParent)
	frame:SetWidth(760); frame:SetHeight(560)
	frame:SetPoint("CENTER")
	frame:SetBackdrop(BACKDROP)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("DIALOG")
	frame:Hide()
	tinsert(UISpecialFrames, "PlaterWrathOptionsFrame")

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", frame, "TOP", 0, -16)
	title:SetText("|cff44aaffPlater|r Nameplates  |cff888888Wrath 3.3.5a|r")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)

	local sidebar = CreateFrame("Frame", nil, frame)
	sidebar:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -46)
	sidebar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 16)
	sidebar:SetWidth(126)
	sidebar:SetBackdrop(INSET_BACKDROP)
	sidebar:SetBackdropColor(0, 0, 0, 0.6)

	tabs, panels = {}, {}
	for i, label in ipairs(TAB_LIST) do
		local b = CreateFrame("Button", nil, sidebar)
		b:SetWidth(110); b:SetHeight(24)
		b:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 8, -8 - (i - 1) * 26)
		b:SetNormalFontObject("GameFontNormal")
		b:SetHighlightFontObject("GameFontHighlight")
		b:SetText(label)
		b:GetFontString():SetPoint("LEFT", b, "LEFT", 4, 0)
		b:SetScript("OnClick", function() ShowTab(i) end)
		tabs[i] = b

		local panel = CreatePanel()
		panels[i] = panel
	end

	for i, builder in ipairs(BUILDERS) do
		local ok, err = pcall(builder, panels[i])
		if not ok then Util.Error("options tab " .. TAB_LIST[i] .. ": " .. tostring(err)) end
	end

	ShowTab(1)
end

function Options.Toggle()
	if not frame then CreateWindow() end
	if frame:IsShown() then
		frame:Hide()
	else
		frame:Show()
		ShowTab(frame.currentTab or 1)
	end
end

--------------------------------------------------------------------------------
-- minimap button
--------------------------------------------------------------------------------

local function CreateMinimapButton()
	local b = CreateFrame("Button", "PlaterWrathMinimapButton", Minimap)
	b:SetWidth(31); b:SetHeight(31)
	b:SetFrameStrata("MEDIUM")
	b:SetMovable(true)

	local overlay = b:CreateTexture(nil, "OVERLAY")
	overlay:SetWidth(53); overlay:SetHeight(53)
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetPoint("TOPLEFT")

	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetWidth(20); icon:SetHeight(20)
	icon:SetTexture("Interface\\Icons\\Ability_Warrior_BattleShout")
	icon:SetPoint("TOPLEFT", 7, -6)

	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local function Reposition()
		local angle = math.rad(ns.db.minimapButton.angle or 210)
		b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
	end

	b:RegisterForDrag("LeftButton")
	b:SetScript("OnDragStart", function(self) self.dragging = true end)
	b:SetScript("OnDragStop", function(self) self.dragging = nil end)
	b:SetScript("OnUpdate", function(self)
		if not self.dragging then return end
		local mx, my = Minimap:GetCenter()
		local cx, cy = GetCursorPosition()
		local s = Minimap:GetEffectiveScale()
		cx, cy = cx / s, cy / s
		ns.db.minimapButton.angle = math.deg(math.atan2(cy - my, cx - mx))
		Reposition()
	end)
	b:SetScript("OnClick", function() Options.Toggle() end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Plater Nameplates")
		GameTooltip:AddLine("Click to open options.", 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)

	Reposition()
	if ns.db.minimapButton.hide then b:Hide() end
	Options.minimapButton = b
end

--------------------------------------------------------------------------------
-- slash commands
--------------------------------------------------------------------------------

SLASH_PLATERWRATH1 = "/plater"
SLASH_PLATERWRATH2 = "/plw"
SlashCmdList["PLATERWRATH"] = function(msg)
	msg = strtrim(msg or ""):lower()

	if msg == "" or msg == "config" or msg == "options" then
		Options.Toggle()
	elseif msg == "toggle" then
		ns.db.enabled = not ns.db.enabled
		ns.Core.FullUpdate()
		Util.Print(ns.db.enabled and "enabled." or "disabled.")
	elseif msg == "reset" then
		ns.Config.ResetProfile()
	elseif msg == "minimap" then
		ns.db.minimapButton.hide = not ns.db.minimapButton.hide
		if Options.minimapButton then
			if ns.db.minimapButton.hide then Options.minimapButton:Hide() else Options.minimapButton:Show() end
		end
	elseif msg == "enemy" then
		-- these toggle Blizzard's plates, which are what we draw on top of
		ns.db.showEnemyPlates = not ns.db.showEnemyPlates
		if ns.db.showEnemyPlates then ShowNameplates() else HideNameplates() end
		Util.Print("enemy nameplates " .. (ns.db.showEnemyPlates and "on." or "off."))
	elseif msg == "friendly" then
		ns.db.showFriendlyPlates = not ns.db.showFriendlyPlates
		if ns.db.showFriendlyPlates then ShowFriendNameplates() else HideFriendNameplates() end
		Util.Print("friendly nameplates " .. (ns.db.showFriendlyPlates and "on." or "off."))
	elseif msg == "debug" then
		ns.Core.DebugDump()
	elseif msg == "errors" then
		Util.DumpErrors()
	elseif msg == "wipeauras" then
		ns.Auras.WipeAll()
		Util.Print("aura cache cleared.")
	elseif msg == "status" then
		local n = 0
		for _ in pairs(ns.Core.active) do n = n + 1 end
		Util.Print(("%d plates hooked, %d mods, profile %s"):format(
			n, Util.CountTable(ns.db.mods), ns.Config.GetActiveProfile()))
	else
		Util.Print("commands: |cffffd100/plater|r config, toggle, enemy, friendly, reset, minimap, wipeauras, status, debug, errors")
	end
end

--------------------------------------------------------------------------------

function Options.Initialize()
	CreateMinimapButton()

	-- an entry in the Blizzard interface options that just opens our window
	local panel = CreateFrame("Frame", "PlaterWrathInterfacePanel", UIParent)
	panel.name = "Plater Nameplates"
	local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	fs:SetPoint("TOPLEFT", 16, -16)
	fs:SetText("Plater Nameplates (Wrath)")
	local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	b:SetPoint("TOPLEFT", 16, -50)
	b:SetWidth(180); b:SetHeight(24)
	b:SetText("Open configuration")
	b:SetScript("OnClick", function() Options.Toggle() end)
	InterfaceOptions_AddCategory(panel)
end
