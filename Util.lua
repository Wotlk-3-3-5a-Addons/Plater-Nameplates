--[[--------------------------------------------------------------------------
	PlaterWrath - Util.lua
	Small helpers shared by the rest of the addon. No external libraries so the
	addon stays self contained on a 3.3.5a client.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local Util = {}
ns.Util = Util

--------------------------------------------------------------------------------
-- table helpers
--------------------------------------------------------------------------------

function Util.CopyTable(src)
	local dst = {}
	for k, v in pairs(src) do
		if type(v) == "table" then
			dst[k] = Util.CopyTable(v)
		else
			dst[k] = v
		end
	end
	return dst
end

-- fills missing keys of `target` from `defaults`, recursing into subtables
function Util.ApplyDefaults(target, defaults)
	if type(target) ~= "table" then target = {} end
	for k, v in pairs(defaults) do
		if type(v) == "table" then
			target[k] = Util.ApplyDefaults(target[k], v)
		elseif target[k] == nil then
			target[k] = v
		end
	end
	return target
end

function Util.CountTable(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

function Util.SortedKeys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

--------------------------------------------------------------------------------
-- media (only textures/fonts that ship with the 3.3.5a client, so the addon
-- never needs to carry binary media of its own)
--------------------------------------------------------------------------------

Util.BarTextures = {
	{ name = "Blizzard",  path = "Interface\\TargetingFrame\\UI-StatusBar" },
	{ name = "Flat",      path = "Interface\\Buttons\\WHITE8X8" },
	{ name = "Smooth",    path = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" },
	{ name = "Skills",    path = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar" },
	{ name = "Chat",      path = "Interface\\ChatFrame\\ChatFrameBackground" },
}

Util.Fonts = {
	{ name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
	{ name = "Arial Narrow",  path = "Fonts\\ARIALN.TTF" },
	{ name = "Skurri",        path = "Fonts\\skurri.ttf" },
	{ name = "Morpheus",      path = "Fonts\\MORPHEUS.TTF" },
}

Util.Outlines = {
	{ name = "None",         path = "" },
	{ name = "Outline",      path = "OUTLINE" },
	{ name = "Thick",        path = "THICKOUTLINE" },
	{ name = "Monochrome",   path = "OUTLINE, MONOCHROME" },
}

Util.BLANK = "Interface\\Buttons\\WHITE8X8"

--------------------------------------------------------------------------------
-- formatting
--------------------------------------------------------------------------------

function Util.ShortNumber(value)
	if not value then return "" end
	if value >= 1000000 then
		return string.format("%.1fm", value / 1000000)
	elseif value >= 1000 then
		return string.format("%.1fk", value / 1000)
	end
	return tostring(math.floor(value))
end

-- Whole seconds for most of a timer's life, switching to fractions only for the
-- last stretch of it, which is the part worth reading precisely. `threshold` is
-- where that switch happens and `decimals` how many digits appear after it.
--
-- Precision everywhere is worse than it sounds: a number changing in its third
-- decimal every frame reads as noise, and the digits that matter - is this
-- about to fall off - get lost in it.
function Util.FormatTime(seconds, decimals, threshold)
	if not seconds or seconds <= 0 then return "" end

	if seconds >= 3600 then
		return string.format("%dh", math.floor(seconds / 3600 + 0.5))
	elseif seconds >= 60 then
		return string.format("%dm", math.floor(seconds / 60 + 0.5))
	end

	decimals = decimals or 0
	threshold = threshold or 0

	if decimals > 0 and seconds < threshold then
		return string.format("%." .. decimals .. "f", seconds)
	end
	return string.format("%d", math.floor(seconds + 0.5))
end

function Util.ColorToHex(r, g, b)
	return string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
end

function Util.Colorize(text, r, g, b)
	return "|cff" .. Util.ColorToHex(r, g, b) .. text .. "|r"
end

--------------------------------------------------------------------------------
-- reaction / class colors
--------------------------------------------------------------------------------

Util.ReactionColors = {
	friendly = { 0.20, 0.75, 0.20 },
	neutral  = { 0.90, 0.85, 0.20 },
	hostile  = { 0.85, 0.20, 0.20 },
	tapped   = { 0.55, 0.55, 0.55 },
}

-- 3.3.5a ships RAID_CLASS_COLORS but the values are slightly washed out for a
-- couple of classes; keep our own so nameplates read well at distance.
Util.ClassColors = {
	DEATHKNIGHT = { 0.77, 0.12, 0.23 },
	DRUID       = { 1.00, 0.49, 0.04 },
	HUNTER      = { 0.67, 0.83, 0.45 },
	MAGE        = { 0.41, 0.80, 0.94 },
	PALADIN     = { 0.96, 0.55, 0.73 },
	PRIEST      = { 1.00, 1.00, 1.00 },
	ROGUE       = { 1.00, 0.96, 0.41 },
	SHAMAN      = { 0.00, 0.44, 0.87 },
	WARLOCK     = { 0.58, 0.51, 0.79 },
	WARRIOR     = { 0.78, 0.61, 0.43 },
}

function Util.GetClassColor(class)
	local c = class and Util.ClassColors[class]
	if c then return c[1], c[2], c[3] end
	return 0.7, 0.7, 0.7
end

--------------------------------------------------------------------------------
-- shared OnUpdate ticker (3.3.5a has no C_Timer)
--------------------------------------------------------------------------------

local tickers = {}
local tickerFrame = CreateFrame("Frame")
tickerFrame:SetScript("OnUpdate", function(self, elapsed)
	for i = #tickers, 1, -1 do
		local t = tickers[i]
		if t.cancelled then
			table.remove(tickers, i)
		else
			t.elapsed = t.elapsed + elapsed
			if t.elapsed >= t.interval then
				t.elapsed = 0
				local ok, err = pcall(t.callback)
				if not ok then ns.Util.Error(err) end
			end
		end
	end
end)

function Util.NewTicker(interval, callback)
	local t = { interval = interval, elapsed = 0, callback = callback }
	tickers[#tickers + 1] = t
	return t
end

function Util.CancelTicker(t)
	if t then t.cancelled = true end
end

-- one-shot delayed call
local delayed = {}
Util.NewTicker(0.05, function()
	if #delayed == 0 then return end
	local now = GetTime()
	for i = #delayed, 1, -1 do
		if delayed[i].at <= now then
			local fn = delayed[i].fn
			table.remove(delayed, i)
			pcall(fn)
		end
	end
end)

function Util.After(delay, fn)
	delayed[#delayed + 1] = { at = GetTime() + delay, fn = fn }
end

--------------------------------------------------------------------------------
-- output
--------------------------------------------------------------------------------

local PREFIX = "|cff44aaffPlater|r: "

function Util.Print(...)
	local msg = ""
	for i = 1, select("#", ...) do
		msg = msg .. tostring((select(i, ...))) .. " "
	end
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

-- Errors are deduplicated: most of what this addon runs is on a per-frame
-- loop, so an unlucky one would otherwise print thousands of identical lines.
-- The full list stays available through /plater errors.
local errorsShown = {}
Util.errorLog = {}

function Util.Error(err)
	err = tostring(err)

	local entry = errorsShown[err]
	if entry then
		entry.count = entry.count + 1
		return
	end

	entry = { text = err, count = 1 }
	errorsShown[err] = entry
	Util.errorLog[#Util.errorLog + 1] = entry
	if #Util.errorLog > 30 then table.remove(Util.errorLog, 1) end

	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. "|cffff5555error|r " .. err)
end

function Util.DumpErrors()
	if #Util.errorLog == 0 then
		Util.Print("no errors recorded this session.")
		return
	end
	Util.Print("|cffff5555" .. #Util.errorLog .. " distinct error(s) this session:|r")
	for i = 1, #Util.errorLog do
		local e = Util.errorLog[i]
		DEFAULT_CHAT_FRAME:AddMessage(string.format("  |cffffd100[x%d]|r %s", e.count, e.text))
	end
end

--------------------------------------------------------------------------------
-- widget helpers
--------------------------------------------------------------------------------

local BACKDROP_BORDER = {
	edgeFile = "Interface\\Buttons\\WHITE8X8",
	edgeSize = 1,
}

-- a 1px (or n px) solid border drawn as an overlay frame so it never gets
-- clipped by the status bar fill
function Util.CreateBorder(parent, size)
	local border = CreateFrame("Frame", nil, parent)
	border:SetPoint("TOPLEFT", parent, "TOPLEFT", -size, size)
	border:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", size, -size)
	border:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = size })
	border:SetBackdropBorderColor(0, 0, 0, 1)
	border.size = size
	return border
end

function Util.ResizeBorder(border, size)
	if border.size == size then return end
	border.size = size
	border:ClearAllPoints()
	border:SetPoint("TOPLEFT", border:GetParent(), "TOPLEFT", -size, size)
	border:SetPoint("BOTTOMRIGHT", border:GetParent(), "BOTTOMRIGHT", size, -size)
	border:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = size })
end

function Util.SetFont(fontString, path, size, outline)
	local ok = fontString:SetFont(path, size, outline ~= "" and outline or nil)
	if not ok then
		fontString:SetFont("Fonts\\FRIZQT__.TTF", size, outline ~= "" and outline or nil)
	end
end
