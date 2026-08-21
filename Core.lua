--[[--------------------------------------------------------------------------
	PlaterWrath - Core.lua

	The nameplate engine.

	On 3.3.5a a nameplate is an anonymous frame parented to WorldFrame. There is
	no NAME_PLATE_UNIT_ADDED event and no nameplateN unit token, so the engine
	works the way every WotLK nameplate addon has to:

	  1. watch WorldFrame:GetNumChildren() for new children
	  2. recognise the ones that are nameplates by their Blizzard artwork
	  3. hide Blizzard's art (alpha 0 - the widgets stay readable, which is how
	     we keep getting health, reaction, threat, cast and raid icon state)
	  4. build our own frame parented to WorldFrame and anchored to the plate,
	     so Blizzard's distance fading cannot touch our alpha
	  5. poll everything on a throttled OnUpdate

	Everything the addon knows about a unit that is not on the plate itself
	(class, player vs npc, aura durations) comes from Cache.lua.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local Util      = ns.Util
local Cache     = ns.Cache
local Auras     = ns.Auras
local Scripting = ns.Scripting

local Core = {}
ns.Core = Core

Core.active   = {}   -- [plate] = unitFrame
Core.allPlates = {}  -- [plate] = true

-- A unit has exactly one nameplate, so a guid may be bound to exactly one
-- frame. Keeping the reverse map makes that enforceable in one lookup, and
-- enforcing it is what stops two plates claiming the same unit's auras.
Core.guidOwner = {}  -- [guid] = unitFrame
-- how many visible plates currently carry each name, rebuilt every tick
Core.nameCounts = {}

local WorldFrame  = WorldFrame
local UnitExists  = UnitExists
local UnitName    = UnitName
local GetTime     = GetTime

local constructorGeneration = 1

--------------------------------------------------------------------------------
-- plate identification
--------------------------------------------------------------------------------

local function LooksLikeNameplateTexture(region)
	if region:GetObjectType() ~= "Texture" then return false end
	local path = region:GetTexture()
	if type(path) ~= "string" then return false end
	return path:lower():find("nameplate") ~= nil
end

local function IsNamePlate(frame)
	if frame.isPlaterWrathFrame then return false end
	if frame:GetName() then return false end
	if frame:GetObjectType() ~= "Frame" then return false end

	local health, cast = frame:GetChildren()
	if not health or not cast then return false end
	if health:GetObjectType() ~= "StatusBar" then return false end
	if cast:GetObjectType() ~= "StatusBar" then return false end

	-- the border texture proves this is Blizzard's plate and not some other
	-- addon's WorldFrame child
	for i = 1, select("#", health:GetRegions()) do
		if LooksLikeNameplateTexture((select(i, health:GetRegions()))) then return true end
	end
	for i = 1, select("#", frame:GetRegions()) do
		if LooksLikeNameplateTexture((select(i, frame:GetRegions()))) then return true end
	end
	return false
end

--------------------------------------------------------------------------------
-- region classification
--
-- The documented 3.3.5a layout is
--     healthBar regions : threatGlow, healthBorder, highlight, name, level,
--                         bossIcon, raidIcon, eliteIcon
--     castBar   regions : castBorder, castNoStop, spellIcon, spellText, shadow
-- We take that order first and fall back to inspecting every region if the
-- client (or a private-server UI patch) put them somewhere else.
--------------------------------------------------------------------------------

local function ClassifyByOrder(o, health, cast, plate)
	local g, hb, hl, nm, lv, boss, raid, elite = health:GetRegions()
	if nm and nm:GetObjectType() == "FontString" and lv and lv:GetObjectType() == "FontString" then
		o.threatGlow, o.healthBorder, o.highlight = g, hb, hl
		o.name, o.level = nm, lv
		o.bossIcon, o.raidIcon, o.eliteIcon = boss, raid, elite
		return true
	end
	return false
end

local function ClassifyByInspection(o, health, cast, plate)
	local fontStrings, textures = {}, {}

	local function collect(frame)
		if not frame then return end
		for i = 1, select("#", frame:GetRegions()) do
			local reg = select(i, frame:GetRegions())
			local t = reg:GetObjectType()
			if t == "FontString" then
				fontStrings[#fontStrings + 1] = reg
			elseif t == "Texture" then
				textures[#textures + 1] = reg
			end
		end
	end
	collect(health)
	collect(plate)

	for _, tex in ipairs(textures) do
		local path = tex:GetTexture()
		path = (type(path) == "string") and path:lower() or ""
		if path:find("nameplate%-glow") then
			o.threatGlow = o.threatGlow or tex
		elseif path:find("raidtargeticon") or path:find("raidtargetingicon") then
			o.raidIcon = o.raidIcon or tex
		elseif path:find("elite") then
			o.eliteIcon = o.eliteIcon or tex
		elseif path:find("skull") then
			o.bossIcon = o.bossIcon or tex
		elseif path:find("nameplate%-border") then
			if tex:GetBlendMode() == "ADD" then
				o.highlight = o.highlight or tex
			else
				o.healthBorder = o.healthBorder or tex
			end
		end
	end

	-- whichever font string holds a number is the level
	for _, fs in ipairs(fontStrings) do
		local text = fs:GetText()
		if text and tonumber(text) then
			o.level = o.level or fs
		else
			o.name = o.name or fs
		end
	end
	if not o.name and fontStrings[1] then o.name = fontStrings[1] end
	if not o.level and fontStrings[2] then o.level = fontStrings[2] end
end

local function ClassifyCast(o, cast)
	local b1, b2, r3, r4, r5 = cast:GetRegions()
	if r4 and r4:GetObjectType() == "FontString" and r3 and r3:GetObjectType() == "Texture" then
		o.castBorder, o.castNoStop, o.spellIcon, o.spellText, o.castShadow = b1, b2, r3, r4, r5
		return
	end
	for i = 1, select("#", cast:GetRegions()) do
		local reg = select(i, cast:GetRegions())
		if reg:GetObjectType() == "FontString" then
			o.spellText = o.spellText or reg
		else
			local path = reg:GetTexture()
			path = (type(path) == "string") and path:lower() or ""
			if path:find("nameplate") or path:find("castingbar") then
				if not o.castBorder then o.castBorder = reg
				elseif not o.castNoStop then o.castNoStop = reg end
			else
				o.spellIcon = o.spellIcon or reg
			end
		end
	end
end

local function CountFontStrings(frame)
	local n = 0
	for i = 1, select("#", frame:GetRegions()) do
		if select(i, frame:GetRegions()):GetObjectType() == "FontString" then n = n + 1 end
	end
	return n
end

local function ClassifyPlate(plate)
	local first, second = plate:GetChildren()
	if not first or not second then return {} end

	-- Blizzard's order is health then cast, but do not take that on faith: the
	-- health bar carries two font strings (name and level), the cast bar one.
	local health, cast = first, second
	if CountFontStrings(second) > CountFontStrings(first) then
		health, cast = second, first
	end

	local o = { health = health, cast = cast }
	if not ClassifyByOrder(o, health, cast, plate) then
		ClassifyByInspection(o, health, cast, plate)
	end
	ClassifyCast(o, cast)

	o.allRegions = {}
	Core.BuildProtected(o)
	Core.CollectRegions(plate, o)
	return o
end

-- Every region Blizzard draws, wherever it lives. Which frame owns the border /
-- name / level artwork varies between 3.3.5a builds, and the client can create
-- regions after we first look, so this walks the whole plate rather than
-- trusting a snapshot taken at hook time. It recurses: a border drawn by a
-- grandchild is exactly the sort of thing that survives a one-level sweep and
-- leaves an empty outline floating on screen.
-- Widgets whose state we still read after hiding them, so they must keep their
-- texture and their contents. Everything else can simply lose its texture.
function Core.BuildProtected(o)
	local p = {}
	local function add(r) if r then p[r] = true end end

	add(o.threatGlow)   -- vertex colour tells us the threat situation
	add(o.raidIcon)     -- tex coords tell us which marker
	add(o.highlight)    -- shown state tells us about mouseover
	add(o.eliteIcon)
	add(o.bossIcon)
	add(o.name)
	add(o.level)
	add(o.spellIcon)    -- we copy the cast icon straight off it
	add(o.spellText)
	add(o.castNoStop)
	-- the status bar fills carry the colours we read reaction and health from
	if o.health then add(o.health:GetStatusBarTexture()) end
	if o.cast   then add(o.cast:GetStatusBarTexture())   end

	o.protected = p
end

function Core.CollectRegions(plate, o)
	local all = o.allRegions
	for i = #all, 1, -1 do all[i] = nil end

	local frames = o.frames
	if not frames then frames = {}; o.frames = frames end
	for i = #frames, 1, -1 do frames[i] = nil end

	local function walk(frame, depth)
		for i = 1, select("#", frame:GetRegions()) do
			all[#all + 1] = select(i, frame:GetRegions())
		end
		if depth >= 4 then return end
		for i = 1, select("#", frame:GetChildren()) do
			local child = select(i, frame:GetChildren())
			if child and not child.isPlaterWrathFrame then
				frames[#frames + 1] = child
				walk(child, depth + 1)
			end
		end
	end

	walk(plate, 0)

	-- Precompute which textures can be blanked outright. Alpha alone loses to
	-- anything the client animates: UI-TargetingFrame-Flash rewrites its own
	-- alpha every frame, so a nameplate-shaped glow stayed on screen no matter
	-- how often we zeroed it. Clearing the texture is not something the client
	-- puts back.
	local nilable = o.nilable
	if not nilable then nilable = {}; o.nilable = nilable end
	for i = #nilable, 1, -1 do nilable[i] = nil end

	local protected = o.protected
	for i = 1, #all do
		local r = all[i]
		if r:GetObjectType() == "Texture" and not (protected and protected[r]) then
			nilable[#nilable + 1] = r
		end
	end
end

--------------------------------------------------------------------------------
-- hiding Blizzard's plate
--
-- SetAlpha(0) instead of SetTexture(nil): the widgets keep every property we
-- need to read (status bar color, vertex color of the threat glow, shown state
-- of the mouseover highlight, tex coords of the raid icon) and simply stop
-- drawing. Blizzard's C side only ever sets alpha on the plate frame itself,
-- so our zero on the children survives.
--------------------------------------------------------------------------------

-- Run unconditionally on every update tick. Sampling a couple of representative
-- widgets to decide whether anything needs re-hiding was too clever: the client
-- restores its artwork piecemeal, so whichever widget you do not sample is the
-- one that reappears. Blanking the lot outright is a few dozen SetAlpha calls
-- per plate and removes the whole class of stray-artwork bug.
local function HideBlizzardArt(o)
	local frames = o.frames
	if frames then
		for i = 1, #frames do frames[i]:SetAlpha(0) end
	end
	if o.health then o.health:SetAlpha(0) end
	if o.cast then o.cast:SetAlpha(0) end
	local all = o.allRegions
	if all then
		for i = 1, #all do all[i]:SetAlpha(0) end
	end

	-- alpha is not enough for anything the client animates; clear the texture
	local nilable = o.nilable
	if nilable then
		for i = 1, #nilable do
			local r = nilable[i]
			if r:GetTexture() then r:SetTexture(nil) end
		end
	end
end

--------------------------------------------------------------------------------
-- building our nameplate
--------------------------------------------------------------------------------

local function CreateAuraIcon(parent, index)
	-- A Button rather than a Frame so the icon can answer the one question its
	-- artwork cannot: what is this. Several spells share a texture, and a
	-- blacklist that matches on exact names is unusable if the names are not
	-- visible anywhere.
	local icon = CreateFrame("Button", nil, parent)
	icon:SetFrameLevel(parent:GetFrameLevel() + 1)
	icon:RegisterForClicks("RightButtonUp")

	icon:SetScript("OnEnter", function(self)
		if not self.auraName then return end
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		local shown = false
		if self.spellId then
			shown = pcall(GameTooltip.SetHyperlink, GameTooltip, "spell:" .. self.spellId)
		end
		if not shown then GameTooltip:SetText(self.auraName, 1, 1, 1) end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cff88bbffRight click|r to hide this aura on nameplates.", 1, 1, 1)
		GameTooltip:Show()
	end)

	icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

	icon:SetScript("OnClick", function(self)
		if not self.auraName then return end
		ns.db.auras.blacklist[self.auraName] = true
		Core.FullUpdate()
		GameTooltip:Hide()
		Util.Print(("|cffffd100%s|r hidden. |cffffd100/plater unblacklist %s|r puts it back.")
			:format(self.auraName, self.auraName))
	end)

	icon.texture = icon:CreateTexture(nil, "ARTWORK")
	icon.texture:SetAllPoints(icon)
	icon.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	icon.border = Util.CreateBorder(icon, 1)
	icon.border:SetFrameLevel(icon:GetFrameLevel() + 1)

	icon.timer = icon:CreateFontString(nil, "OVERLAY")
	icon.timer:SetPoint("BOTTOM", icon, "BOTTOM", 0, -2)

	icon.stacks = icon:CreateFontString(nil, "OVERLAY")
	icon.stacks:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, 0)

	icon:Hide()
	return icon
end

local function CreateUnitFrame(plate)
	local f = CreateFrame("Frame", nil, WorldFrame)
	f.isPlaterWrathFrame = true
	f:SetFrameStrata("BACKGROUND")
	f:SetFrameLevel(1)
	f:SetWidth(120)
	f:SetHeight(12)
	f:Hide()

	-- health ------------------------------------------------------------------
	local hb = CreateFrame("StatusBar", nil, f)
	hb:SetPoint("CENTER", f, "CENTER", 0, 0)
	hb:SetFrameLevel(f:GetFrameLevel() + 1)
	hb:SetMinMaxValues(0, 1)
	hb:SetValue(1)
	f.healthBar = hb

	hb.bg = hb:CreateTexture(nil, "BACKGROUND")
	hb.bg:SetAllPoints(hb)
	hb.bg:SetTexture(Util.BLANK)

	f.healthBorder = Util.CreateBorder(hb, 1)
	f.healthBorder:SetFrameLevel(hb:GetFrameLevel() + 2)

	-- a soft outer glow used for the target highlight
	f.targetGlow = hb:CreateTexture(nil, "BACKGROUND")
	f.targetGlow:SetTexture(Util.BLANK)
	f.targetGlow:SetPoint("TOPLEFT", hb, "TOPLEFT", -3, 3)
	f.targetGlow:SetPoint("BOTTOMRIGHT", hb, "BOTTOMRIGHT", 3, -3)
	f.targetGlow:Hide()

	-- text --------------------------------------------------------------------
	f.nameText = hb:CreateFontString(nil, "OVERLAY")
	f.nameText:SetPoint("BOTTOM", hb, "TOP", 0, 2)

	f.levelText = hb:CreateFontString(nil, "OVERLAY")
	f.levelText:SetPoint("RIGHT", hb, "LEFT", -3, 0)

	f.healthText = hb:CreateFontString(nil, "OVERLAY")
	f.healthText:SetPoint("CENTER", hb, "CENTER", 0, 0)

	-- indicators ---------------------------------------------------------------
	f.raidIcon = hb:CreateTexture(nil, "OVERLAY")
	f.raidIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
	f.raidIcon:Hide()

	f.leftArrow = hb:CreateTexture(nil, "OVERLAY")
	f.leftArrow:SetTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
	f.leftArrow:SetWidth(16); f.leftArrow:SetHeight(16)
	f.leftArrow:SetPoint("RIGHT", hb, "LEFT", -4, 0)
	f.leftArrow:Hide()

	f.rightArrow = hb:CreateTexture(nil, "OVERLAY")
	f.rightArrow:SetTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
	f.rightArrow:SetWidth(16); f.rightArrow:SetHeight(16)
	f.rightArrow:SetPoint("LEFT", hb, "RIGHT", 4, 0)
	f.rightArrow:Hide()

	-- cast bar ------------------------------------------------------------------
	local cb = CreateFrame("StatusBar", nil, f)
	cb:SetFrameLevel(f:GetFrameLevel() + 1)
	cb:SetMinMaxValues(0, 1)
	cb:Hide()
	f.castBar = cb

	cb.bg = cb:CreateTexture(nil, "BACKGROUND")
	cb.bg:SetAllPoints(cb)
	cb.bg:SetTexture(Util.BLANK)
	cb.bg:SetVertexColor(0.05, 0.05, 0.05, 0.9)

	cb.border = Util.CreateBorder(cb, 1)
	cb.border:SetFrameLevel(cb:GetFrameLevel() + 2)

	cb.icon = cb:CreateTexture(nil, "OVERLAY")
	cb.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	cb.iconBorder = Util.CreateBorder(cb, 1)   -- reused below, repositioned

	cb.text = cb:CreateFontString(nil, "OVERLAY")
	cb.text:SetPoint("LEFT", cb, "LEFT", 3, 0)
	cb.text:SetJustifyH("LEFT")

	cb.timeText = cb:CreateFontString(nil, "OVERLAY")
	cb.timeText:SetPoint("RIGHT", cb, "RIGHT", -3, 0)
	cb.timeText:SetJustifyH("RIGHT")

	-- auras ---------------------------------------------------------------------
	local af = CreateFrame("Frame", nil, f)
	af:SetFrameLevel(f:GetFrameLevel() + 3)
	af:SetWidth(1); af:SetHeight(1)
	af.icons = {}
	f.auraFrame = af

	f.auraList = {}
	f.plate = plate
	-- provisional anchor; ApplyPosition replaces this CENTER point every frame
	f:SetPoint("CENTER", plate, "CENTER", 0, 0)
	return f
end

--------------------------------------------------------------------------------
-- applying settings to a frame (only when settings actually changed)
--------------------------------------------------------------------------------

local function ApplySettings(f)
	local db = ns.db
	f.settingsGeneration = Core.settingsGeneration

	f:SetWidth(db.width)
	f:SetHeight(db.height)

	local hb = f.healthBar
	hb:SetWidth(db.width)
	hb:SetHeight(db.height)
	hb:SetStatusBarTexture(db.barTexture)
	hb.bg:SetVertexColor(db.bgColor[1], db.bgColor[2], db.bgColor[3], db.bgColor[4])

	Util.ResizeBorder(f.healthBorder, math.max(1, db.borderSize))
	f.healthBorder:SetBackdropBorderColor(db.borderColor[1], db.borderColor[2],
		db.borderColor[3], db.borderColor[4])

	Util.SetFont(f.nameText,   db.font, db.nameSize,   db.fontOutline)
	Util.SetFont(f.levelText,  db.font, db.levelSize,  db.fontOutline)
	Util.SetFont(f.healthText, db.font, db.healthSize, db.fontOutline)

	f.nameText:ClearAllPoints()
	if db.nameAnchor == "CENTER" then
		f.nameText:SetPoint("CENTER", hb, "CENTER", 0, 0)
	elseif db.nameAnchor == "BOTTOM" then
		f.nameText:SetPoint("TOP", hb, "BOTTOM", 0, -2)
	else
		f.nameText:SetPoint("BOTTOM", hb, "TOP", 0, 2)
	end

	f.raidIcon:SetWidth(db.raidIconSize)
	f.raidIcon:SetHeight(db.raidIconSize)
	f.raidIcon:ClearAllPoints()
	if db.raidIconAnchor == "LEFT" then
		f.raidIcon:SetPoint("RIGHT", hb, "LEFT", -4, 0)
	elseif db.raidIconAnchor == "TOP" then
		f.raidIcon:SetPoint("BOTTOM", hb, "TOP", 0, 6)
	else
		f.raidIcon:SetPoint("LEFT", hb, "RIGHT", 4, 0)
	end

	f.targetGlow:SetVertexColor(db.targetHighlightColor[1], db.targetHighlightColor[2],
		db.targetHighlightColor[3], (db.targetHighlightColor[4] or 1) * 0.35)

	-- cast bar
	local cb = f.castBar
	local c = db.castBar
	cb:ClearAllPoints()
	cb:SetPoint("TOP", hb, "BOTTOM", 0, c.yOffset)
	cb:SetWidth(db.width)
	cb:SetHeight(c.height)
	cb:SetStatusBarTexture(db.barTexture)
	Util.SetFont(cb.text,     db.font, c.fontSize, db.fontOutline)
	Util.SetFont(cb.timeText, db.font, c.fontSize, db.fontOutline)

	local iconSize = (c.iconSize and c.iconSize > 0) and c.iconSize or c.height
	cb.icon:SetWidth(iconSize)
	cb.icon:SetHeight(iconSize)
	cb.icon:ClearAllPoints()
	cb.icon:SetPoint("RIGHT", cb, "LEFT", -3, 0)
	cb.iconBorder:ClearAllPoints()
	cb.iconBorder:SetPoint("TOPLEFT", cb.icon, "TOPLEFT", -1, 1)
	cb.iconBorder:SetPoint("BOTTOMRIGHT", cb.icon, "BOTTOMRIGHT", 1, -1)
	cb.iconBorder:SetBackdropBorderColor(0, 0, 0, 1)

	-- auras
	local a = db.auras
	f.auraFrame:ClearAllPoints()
	if a.growth == "LEFT" then
		f.auraFrame:SetPoint("BOTTOMRIGHT", hb, "TOPRIGHT", 0, a.yOffset)
	elseif a.growth == "RIGHT" then
		f.auraFrame:SetPoint("BOTTOMLEFT", hb, "TOPLEFT", 0, a.yOffset)
	else
		f.auraFrame:SetPoint("BOTTOM", hb, "TOP", 0, a.yOffset)
	end
	for _, icon in ipairs(f.auraFrame.icons) do
		icon:SetWidth(a.size)
		icon:SetHeight(a.size)
		Util.SetFont(icon.timer,  db.font, a.timerSize, db.fontOutline)
		Util.SetFont(icon.stacks, db.font, a.stackSize, db.fontOutline)
	end

end

--------------------------------------------------------------------------------
-- positioning
--
-- Our frame is a WorldFrame child rather than a child of the plate, so it has
-- to be placed by hand. We place it off the plate frame, which is the thing the
-- client actually moves to follow the unit, plus a one-off calibration that
-- records where Blizzard's health bar sits inside that frame. A 3.3.5a plate is
-- much taller than its health bar because it reserves room for the name and the
-- cast bar, so plate CENTER on its own lands well above the bar.
--
-- Calibrating against the plate rather than anchoring to the health bar matters
-- once we start resizing the plate for the click area: the health bar may move
-- when its parent is resized, the plate's own centre does not.
--------------------------------------------------------------------------------

-- Nothing is cached. An earlier version measured the health bar's offset from
-- the plate's centre once, globally, and reused it for every plate - so a
-- single bad reading, taken from a plate the client had not finished placing,
-- put every nameplate on screen hundreds of pixels away from its unit for the
-- rest of the session. Read both centres live, per plate, every frame.

-- Move the plate's clickable box onto the health bar.
--
-- You cannot target from a frame of our own: that needs either a unit token,
-- which 3.3.5a nameplates do not have, or a secure button whose macro text
-- would have to be rewritten as units change - and secure attributes cannot be
-- changed in combat, which is precisely when nameplates matter. So the click
-- has to land on Blizzard's plate frame, and the plate frame has to be made to
-- cover wherever we have drawn the bar.
--
-- Two steps, and the first is the one that was missing: grow the frame until it
-- contains the bar, then trim it back to the bar's outline with insets. Insets
-- alone were not enough. Asking for a rect outside the frame's own bounds means
-- negative insets, and this client does not appear to honour those, so an
-- offset bar ended up with its hit box still sitting up at the unit.
local function ApplyClickBox(f)
	local db, plate = ns.db, f.plate

	-- Nameplates are protected frames: they are what you click to target, so
	-- the client will not let insecure code touch their geometry while you are
	-- in combat. Attempting it anyway is what raises "Interface action failed
	-- because of an AddOn", and the resize silently does not take. Set the box
	-- out of combat, where it is allowed, and leave it alone until combat ends.
	if InCombatLockdown() then
		f.clickPending = true
		return
	end
	f.clickPending = nil

	f.origPlateW = f.origPlateW or plate:GetWidth()
	f.origPlateH = f.origPlateH or plate:GetHeight()

	if not db.resizeClickArea then
		plate:SetWidth(f.origPlateW)
		plate:SetHeight(f.origPlateH)
		plate:SetHitRectInsets(0, 0, 0, 0)
		f.clickW, f.clickH = nil, nil
		return
	end

	local health = f.regions.health
	if not health then return end

	local ps = plate:GetEffectiveScale()
	if not ps or ps == 0 then return end
	local fs = f:GetEffectiveScale() or ps

	local px, py = plate:GetCenter()
	local hx, hy = health:GetCenter()
	if not px or not hx then return end

	-- where our bar sits relative to the plate's centre, in the plate's units
	local dx = (hx - px) + (db.xOffset * fs) / ps
	local dy = (hy - py) + (db.yOffset * fs + (f.stackY or 0)) / ps

	local boxW = ((db.clickWidth  > 0) and db.clickWidth  or db.width)  * fs / ps
	local boxH = ((db.clickHeight > 0) and db.clickHeight or db.height) * fs / ps

	-- Grow only, and in steps. Resizing can move the health bar we measured dx
	-- and dy from, so a size derived from those could chase its own tail;
	-- monotonic growth converges after a frame or two instead of oscillating.
	-- Oversizing costs nothing because the insets below trim it back to the bar.
	local function quantize(v) return math.ceil(v / 16) * 16 end
	local w = math.min(600, math.max(f.clickW or 0, quantize(math.max(f.origPlateW, 2 * math.abs(dx) + boxW))))
	local h = math.min(600, math.max(f.clickH or 0, quantize(math.max(f.origPlateH, 2 * math.abs(dy) + boxH))))

	if f.clickW ~= w or f.clickH ~= h then
		plate:SetWidth(w)
		plate:SetHeight(h)
		f.clickW, f.clickH = w, h
	end

	-- Derive the insets from the size the frame actually has, not the size we
	-- asked for. The client rewrites plate geometry, so a resize may simply not
	-- take, and computing a hit box against a rect the frame does not have puts
	-- the clickable area somewhere else entirely. Its natural size is roomy, so
	-- in practice there is plenty to trim.
	local pw = plate:GetWidth() / 2
	local ph = plate:GetHeight() / 2
	plate:SetHitRectInsets(
		dx - boxW / 2 + pw,      -- left
		pw - dx - boxW / 2,      -- right
		ph - dy - boxH / 2,      -- top
		dy - boxH / 2 + ph)      -- bottom
end

-- Where this plate's artwork wants to be, in screen pixels, before stacking and
-- before easing. Also records the footprint the stacking pass needs.
local function ComputeTarget(f)
	local db = ns.db
	local plate = f.plate

	-- Blizzard's health bar is the reference: it is the widget we are replacing,
	-- so sitting exactly on it is by definition correct, and it needs no
	-- knowledge of how the plate frame is laid out or anchored.
	-- Note the deliberately plain call. Written as `health and health:GetCenter()`
	-- the `and` truncates the call to a single return value, so the y coordinate
	-- silently comes back nil however healthy the frame is.
	local health = f.regions.health
	if not health then
		f.baseX, f.baseY = nil, nil
		return false
	end

	local hx, hy = health:GetCenter()
	if not hx or not hy then
		f.baseX, f.baseY = nil, nil
		return false
	end

	-- Screen pixels, and deliberately without the user's offsets: these values
	-- exist to compare plates against each other, and an offset every plate
	-- shares cannot change which of them collide.
	local ps = health:GetEffectiveScale()
	local fs = f:GetEffectiveScale()

	f.baseX = hx * ps
	f.baseY = hy * ps

	-- The footprint is what the plate actually occupies on screen, not just the
	-- bar: the name is drawn above the bar and is often wider than it, so two
	-- plates whose bars merely sit side by side can still have their names run
	-- into each other.
	local nameW = 0
	if f.nameText and f.nameText:IsShown() then
		nameW = f.nameText:GetStringWidth() or 0
	end

	f.halfW = (math.max(db.width, nameW) * fs) / 2
	f.halfH = ((db.height + db.nameSize + 4) * fs) / 2

	-- How far this bar can be lifted and still sit inside its plate's clickable
	-- box. The client will not let us move that box during combat, so anything
	-- beyond this is a bar you cannot click until the fight ends.
	local plateH = (f.plate:GetHeight() or 0) * ps
	f.stackLimit = math.max(0, plateH / 2 - (db.height * fs) / 2 - 2)
	return true
end

-- The client does not space plates apart on this version, so we do it. Plates
-- are laid out lowest first and each one lifted until it clears everything
-- already placed. Two things then temper the result:
--
--   * a run of colliding plates is recentred on where it started, so a group
--     spreads both ways rather than growing upwards off its units. This halves
--     how far any one plate has to travel, which matters most at range, where
--     mobs bunch up on screen and the raw lift can carry a bar well away from
--     the body it belongs to.
--   * each lift is capped to what its plate's clickable box can still cover,
--     because that box cannot be moved during combat.
local stackList = {}
local stackParent = {}

local function ClusterRoot(i)
	while stackParent[i] ~= i do
		stackParent[i] = stackParent[stackParent[i]]
		i = stackParent[i]
	end
	return i
end

local function ClusterJoin(a, b)
	local ra, rb = ClusterRoot(a), ClusterRoot(b)
	if ra ~= rb then stackParent[rb] = ra end
end

local function StackPlates()
	local db = ns.db

	for i = #stackList, 1, -1 do stackList[i] = nil end
	for _, f in pairs(Core.active) do
		-- a plate with no footprint cannot take part in collision testing, and
		-- letting one in would take the whole pass down with a nil arithmetic
		if f:IsShown() and f.baseX and f.baseY and f.halfW and f.halfH then
			stackList[#stackList + 1] = f
			f.stackTargetY = 0
		end
	end

	local n = #stackList
	if not db.stackPlates or n < 2 then return end

	table.sort(stackList, function(a, b) return a.baseY < b.baseY end)

	for i = 1, n do stackParent[i] = i end
	for i = n + 1, #stackParent do stackParent[i] = nil end

	local spacing = db.stackSpacing
	for i = 2, n do
		local a = stackList[i]
		local ay = a.baseY
		local passes = 0
		local moved = true
		while moved and passes < 12 do
			moved = false
			passes = passes + 1
			for j = 1, i - 1 do
				local b = stackList[j]
				local by = b.baseY + (b.stackTargetY or 0)
				-- The gap counts horizontally as well. Testing for strict
				-- overlap left plates that were merely touching edge to edge
				-- exactly where they were, which still reads as one run-on bar.
				if math.abs(a.baseX - b.baseX) < (a.halfW + b.halfW + spacing)
					and math.abs(ay - by) < (a.halfH + b.halfH + spacing) then
					ay = by + b.halfH + a.halfH + spacing
					moved = true
					ClusterJoin(i, j)
				end
			end
		end
		a.stackTargetY = ay - a.baseY
	end

	-- Recentre each run of colliding plates on where it started. Without this
	-- the whole group climbs away from its units, and the more crowded the
	-- screen the further it climbs.
	local sum, count = {}, {}
	for i = 1, n do
		local root = ClusterRoot(i)
		sum[root] = (sum[root] or 0) + stackList[i].stackTargetY
		count[root] = (count[root] or 0) + 1
	end
	for i = 1, n do
		local root = ClusterRoot(i)
		stackList[i].stackTargetY = stackList[i].stackTargetY - sum[root] / count[root]
	end

	-- Keep every bar inside the hit box its plate already has. That box is
	-- fixed for the duration of a fight, so a bar lifted past it is a bar you
	-- cannot click until combat drops.
	if db.clampStack then
		for i = 1, n do
			local f = stackList[i]
			local limit = f.stackLimit or 0
			if limit > 0 then
				if f.stackTargetY > limit then
					f.stackTargetY = limit
				elseif f.stackTargetY < -limit then
					f.stackTargetY = -limit
				end
			end
		end
	end
end

local function ApplyPosition(f, dt)
	if not f.baseX then return end
	local db = ns.db

	-- ease the stacking offset on its own short curve so plates slide apart
	-- rather than popping when a neighbour appears
	local wanted = f.stackTargetY or 0
	if not f.stackY then
		f.stackY = wanted
	else
		f.stackY = f.stackY + (wanted - f.stackY) * (1 - math.exp(-dt / 0.10))
	end

	local targetX, targetY = f.baseX, f.baseY + f.stackY

	local tau = db.smoothing * 0.30
	if not f.smoothX or tau <= 0
		or math.abs(targetX - f.smoothX) > 200
		or math.abs(targetY - f.smoothY) > 200 then
		-- no history, easing off, or the plate was recycled onto a different
		-- unit somewhere else on screen: snap rather than slide across
		f.smoothX, f.smoothY = targetX, targetY
	else
		local k = 1 - math.exp(-dt / tau)
		f.smoothX = f.smoothX + (targetX - f.smoothX) * k
		f.smoothY = f.smoothY + (targetY - f.smoothY) * k
	end

	-- Anchor to Blizzard's health bar and express everything else as a delta
	-- from it.
	--
	-- Placing the frame at an absolute screen position measured from
	-- WorldFrame's bottom-left assumed that corner is screen (0,0) and that the
	-- pixels-to-frame-units conversion is exact, and got both slightly wrong, so
	-- plates landed a long way to the side of their unit - the further from the
	-- corner, the bigger the miss. Anchoring to the widget we are replacing
	-- makes the base position correct by construction, and only the easing lag,
	-- the stacking lift and the user's offsets pass through a scale conversion.
	-- Those are small, so any error in them is small too.
	local health = f.regions.health
	if not health then return end

	local fs = f:GetEffectiveScale()
	local dx = (f.smoothX - f.baseX) / fs + db.xOffset
	local dy = (f.smoothY - f.baseY) / fs + db.yOffset

	f:ClearAllPoints()
	f:SetPoint("CENTER", health, "CENTER", dx, dy)
end

--------------------------------------------------------------------------------
-- reaction / unit type
--------------------------------------------------------------------------------

local function GetReaction(r, g, b)
	if g > 0.7 and r < 0.3 then return "friendly" end
	if r > 0.7 and g > 0.7 then return "neutral" end
	if r > 0.7 and g < 0.3 then return "hostile" end
	if r > 0.4 and r < 0.7 and math.abs(r - g) < 0.15 and math.abs(g - b) < 0.15 then return "tapped" end
	return "hostile"
end

local function GetUnitType(reaction, isPlayer)
	if reaction == "friendly" then
		return isPlayer and "friendlyPlayer" or "friendlyNPC"
	elseif reaction == "neutral" then
		return "neutralNPC"
	else
		return isPlayer and "enemyPlayer" or "enemyNPC"
	end
end

--------------------------------------------------------------------------------
-- threat
--------------------------------------------------------------------------------

local TANK_AURAS = {
	["Defensive Stance"]  = true,
	["Bear Form"]         = true,
	["Dire Bear Form"]    = true,
	["Frost Presence"]    = true,
	["Righteous Fury"]    = true,
}

local playerIsTank = false
local function UpdateTankState()
	playerIsTank = false
	for i = 1, 40 do
		local name = UnitBuff("player", i)
		if not name then break end
		if TANK_AURAS[name] then playerIsTank = true break end
	end
end
Util.NewTicker(1, UpdateTankState)

-- returns "aggro" | "transition" | "noaggro" | nil
local function GetThreatSituation(f, isTarget)
	if isTarget then
		local situation = UnitThreatSituation and UnitThreatSituation("player", "target")
		if situation then
			if situation >= 3 then return "aggro"
			elseif situation >= 1 then return "transition"
			else return "noaggro" end
		end
	end

	local glow = f.regions.threatGlow
	if not glow or not glow:IsShown() then return nil end

	local r, g = glow:GetVertexColor()
	if r and r > 0.8 and g and g < 0.45 then return "aggro" end
	return "transition"
end

local function ThreatColor(situation)
	local t = ns.db.threat
	local tankMode = (t.mode == "tank") or (t.mode == "auto" and playerIsTank)

	if tankMode then
		-- for a tank, holding aggro is the good outcome
		if situation == "aggro" then return t.colors.noaggro
		elseif situation == "transition" then return t.colors.transition
		else return t.colors.aggro end
	else
		if situation == "aggro" then return t.colors.aggro
		elseif situation == "transition" then return t.colors.transition
		else return t.colors.noaggro end
	end
end

--------------------------------------------------------------------------------
-- aura display
--------------------------------------------------------------------------------

local function UpdateAuras(f)
	local db = ns.db.auras
	local af = f.auraFrame

	if not db.enabled or not f.unitCfg.showAuras then
		for _, icon in ipairs(af.icons) do icon:Hide() end
		af:Hide()
		return
	end

	Auras.Collect(f.unitGUID, f.unitName, f.auraList)

	local count = #f.auraList
	f.auraCount = count
	local now = GetTime()

	for i = 1, count do
		local icon = af.icons[i]
		if not icon then
			icon = CreateAuraIcon(af, i)
			icon:SetWidth(db.size)
			icon:SetHeight(db.size)
			Util.SetFont(icon.timer,  ns.db.font, db.timerSize, ns.db.fontOutline)
			Util.SetFont(icon.stacks, ns.db.font, db.stackSize, ns.db.fontOutline)
			af.icons[i] = icon
		end

		local aura = f.auraList[i]
		icon.texture:SetTexture(aura.icon)
		icon.auraName = aura.name
		icon.spellId  = aura.spellId
		icon:EnableMouse(db.interactive and true or false)

		if db.borderByType then
			icon.border:SetBackdropBorderColor(Auras.GetBorderColor(aura))
		else
			icon.border:SetBackdropBorderColor(0, 0, 0, 1)
		end

		if db.showStacks and aura.count and aura.count > 1 then
			icon.stacks:SetText(aura.count)
		else
			icon.stacks:SetText("")
		end

		if db.showTimer and aura.expires then
			local remain = aura.expires - now
			icon.timer:SetText(Util.FormatTime(remain, db.timerDecimals, db.timerThreshold))
			if remain <= 3 then
				icon.timer:SetTextColor(1, 0.3, 0.3)
			else
				icon.timer:SetTextColor(1, 1, 1)
			end
		else
			icon.timer:SetText("")
		end

		icon:Show()
	end

	for i = count + 1, #af.icons do af.icons[i]:Hide() end

	if count == 0 then
		af:Hide()
		f.auraCount = 0
		return
	end

	-- lay the row out
	local perRow = math.max(1, db.perRow)
	local step = db.size + db.spacing
	local inRow = math.min(count, perRow)
	local rowWidth = inRow * step - db.spacing

	af:SetWidth(rowWidth)
	af:SetHeight(db.size * math.ceil(count / perRow))

	for i = 1, count do
		local icon = af.icons[i]
		local col = (i - 1) % perRow
		local row = math.floor((i - 1) / perRow)
		icon:ClearAllPoints()
		if db.growth == "LEFT" then
			icon:SetPoint("BOTTOMRIGHT", af, "BOTTOMRIGHT", -col * step, row * step)
		else
			-- CENTER and RIGHT both grow rightwards; the frame itself is anchored
			-- to the middle of the plate and sized to the row, so this centres.
			icon:SetPoint("BOTTOMLEFT", af, "BOTTOMLEFT", col * step, row * step)
		end
	end

	af:Show()
end

-- Only the countdown text, no filtering or re-sorting. Split out from
-- UpdateAuras so timers can tick at display rate without paying for a full
-- collect, filter and sort every frame.
local function RefreshAuraTimers(f)
	local db = ns.db.auras
	if not db.showTimer then return end

	local count = f.auraCount or 0
	if count == 0 then return end

	local icons = f.auraFrame.icons
	local now = GetTime()

	for i = 1, count do
		local icon = icons[i]
		local aura = f.auraList[i]
		if icon and aura and icon:IsShown() then
			if aura.expires then
				local remain = aura.expires - now
				icon.timer:SetText(Util.FormatTime(remain, db.timerDecimals, db.timerThreshold))
				if remain <= 3 then
					icon.timer:SetTextColor(1, 0.3, 0.3)
				else
					icon.timer:SetTextColor(1, 1, 1)
				end
			else
				icon.timer:SetText("")
			end
		end
	end
end

--------------------------------------------------------------------------------
-- cast bar
--------------------------------------------------------------------------------

local function UpdateCastBar(f)
	local db = ns.db.castBar
	local cb = f.castBar
	local orig = f.regions.cast

	if not db.enabled or not f.unitCfg.showCast or not orig or not orig:IsShown() then
		if cb:IsShown() then cb:Hide() end
		f.isCasting = false
		f.castName, f.castIcon, f.castNoInterrupt = nil, nil, nil
		f.prevCastValue = nil
		return
	end

	local minValue, maxValue = orig:GetMinMaxValues()
	local value = orig:GetValue()
	if not value or not maxValue or maxValue <= 0 then
		cb:Hide()
		f.isCasting = false
		return
	end

	local channeling = false
	if f.prevCastValue and value < f.prevCastValue - 0.001 then channeling = true end
	f.prevCastValue = value
	f.isChanneling = channeling

	cb:SetMinMaxValues(minValue, maxValue)
	cb:SetValue(value)

	local noInterrupt = f.regions.castNoStop and f.regions.castNoStop:IsShown()
	local color
	if noInterrupt then
		color = db.noInterruptColor
	elseif channeling then
		color = db.channelColor
	else
		color = db.color
	end
	cb:SetStatusBarColor(color[1], color[2], color[3])

	local spellName = f.regions.spellText and f.regions.spellText:GetText() or ""
	cb.text:SetText(db.showName and spellName or "")

	if db.showTime then
		local remain = channeling and value or (maxValue - value)
		cb.timeText:SetText(string.format("%.1f", math.max(0, remain)))
	else
		cb.timeText:SetText("")
	end

	if db.showIcon and f.regions.spellIcon then
		local tex = f.regions.spellIcon:GetTexture()
		if tex then
			cb.icon:SetTexture(tex)
			cb.icon:Show()
			cb.iconBorder:Show()
		else
			cb.icon:Hide()
			cb.iconBorder:Hide()
		end
	else
		cb.icon:Hide()
		cb.iconBorder:Hide()
	end

	f.isCasting = true
	f.castName = spellName
	f.castIcon = cb.icon:GetTexture()
	f.castNoInterrupt = noInterrupt and true or false

	if not cb:IsShown() then cb:Show() end
end

--------------------------------------------------------------------------------
-- the per-plate update
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- guid binding
--------------------------------------------------------------------------------

local function UnbindGUID(f)
	if f.unitGUID and Core.guidOwner[f.unitGUID] == f then
		Core.guidOwner[f.unitGUID] = nil
	end
	f.unitGUID, f.guidName = nil, nil
end

-- Binding is exclusive. Reading a guid off the target or the mouseover can
-- briefly land on the wrong plate - two mobs share a name, both are near full
-- alpha for a frame while the client fades them - and a stale binding would
-- then quietly feed one unit's auras to another plate for as long as it lived.
-- Handing the guid over rather than copying it makes that self-correcting.
local function BindGUID(f, guid, name)
	if f.unitGUID == guid then
		f.guidName = name
		return
	end

	UnbindGUID(f)

	local previous = Core.guidOwner[guid]
	if previous and previous ~= f then UnbindGUID(previous) end

	f.unitGUID, f.guidName = guid, name
	Core.guidOwner[guid] = f
end

local function TruncateName(name)
	local db = ns.db
	if db.abbreviateNames then
		local words = {}
		for word in name:gmatch("%S+") do words[#words + 1] = word end
		if #words > 1 then
			for i = 1, #words - 1 do
				words[i] = words[i]:sub(1, 1) .. "."
			end
			name = table.concat(words, " ")
		end
	end
	if db.maxNameLength > 0 and name:len() > db.maxNameLength then
		name = name:sub(1, db.maxNameLength) .. ".."
	end
	return name
end

local function UpdatePlate(f)
	local db = ns.db
	local r = f.regions

	if f.settingsGeneration ~= Core.settingsGeneration then ApplySettings(f) end

	local dt = Core.tickInterval or 0.03

	-- Blizzard restores its own artwork as unit state changes and when a plate
	-- is recycled onto a new unit, so blank it every tick, and re-walk the plate
	-- twice a second to pick up widgets that did not exist when we hooked it.
	f.hideElapsed = (f.hideElapsed or 0) + dt
	if f.hideElapsed >= 0.5 then
		f.hideElapsed = 0
		Core.CollectRegions(f.plate, r)
	end
	HideBlizzardArt(r)

	-- identity ---------------------------------------------------------------
	local name = r.name and r.name:GetText() or ""
	f.unitName = name

	local isPlayer = Cache.IsPlayer(name)
	local class    = Cache.GetClass(name)
	f.unitClass = class

	local br, bg, bb = r.health:GetStatusBarColor()
	local reaction = GetReaction(br, bg, bb)
	f.reaction = reaction

	local unitType = GetUnitType(reaction, isPlayer)
	f.unitType = unitType
	local cfg = db.units[unitType]
	f.unitCfg = cfg

	if not db.enabled or not cfg.show then
		if f:IsShown() then f:Hide() end
		return
	end

	-- target / mouseover ------------------------------------------------------
	local hasTarget = UnitExists("target")
	-- decided once per tick across all plates, so exactly one can be the target
	local isTarget = (Core.targetFrame == f)
	f.isTarget = isTarget
	f.isMouseover = (r.highlight and r.highlight:IsShown()) and true or false

	-- Match the plate to an actual unit.
	--
	-- A nameplate carries no unit token, but whenever it happens to be the unit
	-- we are targeting, hovering or focusing we can read its guid exactly, and
	-- a plate keeps serving the same unit until the client recycles it. So one
	-- moment of contact binds it for as long as it lives, which is enough:
	-- casting anything at a mob means targeting it first.
	local guid
	if isTarget then
		guid = UnitGUID("target")
	elseif f.isMouseover then
		guid = UnitGUID("mouseover")
	elseif UnitExists("focus") and UnitName("focus") == name then
		guid = UnitGUID("focus")
	end

	if guid then
		BindGUID(f, guid, name)
	elseif f.unitGUID and f.guidName ~= name then
		-- recycled onto a different unit; the old binding is meaningless now
		UnbindGUID(f)
	end

	if not f.unitGUID then
		-- The name-based shortcut, and it needs both halves of "unambiguous".
		--
		-- Knowing only one guid for a name is not enough: line up two mobs with
		-- the same name, hit one, and its guid is the only one the combat log
		-- has ever mentioned - so both plates would claim it, and both would
		-- show the one mob's auras. Require that this is also the only plate on
		-- screen wearing the name, and that no other plate already owns the guid.
		if (Core.nameCounts[name] or 0) <= 1 then
			local unique = Cache.UniqueGUIDForName(name)
			if unique and not Core.guidOwner[unique] then
				BindGUID(f, unique, name)
			end
		end
	end

	-- health ------------------------------------------------------------------
	local health = r.health:GetValue() or 0
	local minH, maxH = r.health:GetMinMaxValues()
	maxH = (maxH and maxH > 0) and maxH or 1
	f.health, f.maxHealth = health, maxH
	local percent = health / maxH * 100

	f.healthBar:SetMinMaxValues(0, maxH)
	f.healthBar:SetValue(health)

	-- threat ------------------------------------------------------------------
	local situation = nil
	if db.threat.enabled then
		situation = GetThreatSituation(f, isTarget)
	end
	f.threatSituation = situation

	-- color -------------------------------------------------------------------
	local cr, cg, cb2
	if reaction == "tapped" then
		cr, cg, cb2 = unpack(Util.ReactionColors.tapped)
	elseif cfg.colorMode == "custom" then
		cr, cg, cb2 = unpack(cfg.customColor)
	elseif cfg.colorMode == "class" and class then
		cr, cg, cb2 = Util.GetClassColor(class)
	elseif cfg.colorMode == "threat" and situation then
		cr, cg, cb2 = unpack(ThreatColor(situation))
	else
		cr, cg, cb2 = unpack(Util.ReactionColors[reaction] or Util.ReactionColors.hostile)
	end

	if db.showExecuteRange and reaction ~= "friendly" and percent <= db.executeRange then
		cr, cg, cb2 = unpack(db.executeColor)
	end

	f.healthBar:SetStatusBarColor(cr, cg, cb2)
	f.baseColor = f.baseColor or {}
	f.baseColor[1], f.baseColor[2], f.baseColor[3] = cr, cg, cb2

	-- border / target highlight ------------------------------------------------
	if isTarget and db.targetHighlight then
		local c = db.targetHighlightColor
		f.healthBorder:SetBackdropBorderColor(c[1], c[2], c[3], c[4] or 1)
		f.targetGlow:Show()
	else
		local c = db.borderColor
		f.healthBorder:SetBackdropBorderColor(c[1], c[2], c[3], c[4] or 1)
		f.targetGlow:Hide()
	end

	if isTarget and db.targetIndicator then
		f.leftArrow:Show(); f.rightArrow:Show()
	else
		f.leftArrow:Hide(); f.rightArrow:Hide()
	end

	-- text ---------------------------------------------------------------------
	if cfg.showName then
		f.nameText:SetText(TruncateName(name))
		f.nameText:Show()
		if cfg.colorMode == "class" and class then
			f.nameText:SetTextColor(Util.GetClassColor(class))
		else
			f.nameText:SetTextColor(1, 1, 1)
		end
	else
		f.nameText:Hide()
	end

	if cfg.showLevel and r.level then
		local levelText = r.level:GetText()
		local isBoss = r.bossIcon and r.bossIcon:IsShown()
		local isElite = r.eliteIcon and r.eliteIcon:IsShown()
		if isBoss then
			f.levelText:SetText("??")
			f.levelText:SetTextColor(1, 0.1, 0.1)
		elseif levelText then
			f.levelText:SetText(levelText .. ((isElite and db.showEliteIcon) and "+" or ""))
			f.levelText:SetTextColor(r.level:GetTextColor())
		else
			f.levelText:SetText("")
		end
		f.levelText:Show()
	else
		f.levelText:Hide()
	end

	local mode = cfg.healthText
	if mode == "none" then
		f.healthText:SetText("")
	elseif mode == "percent" then
		f.healthText:SetText(string.format("%d%%", percent))
	elseif mode == "current" then
		f.healthText:SetText(Util.ShortNumber(health))
	else
		f.healthText:SetText(string.format("%s  %d%%", Util.ShortNumber(health), percent))
	end

	-- raid icon -----------------------------------------------------------------
	if db.showRaidIcon and r.raidIcon and r.raidIcon:IsShown() then
		f.raidIcon:SetTexCoord(r.raidIcon:GetTexCoord())
		f.raidIcon:Show()
	else
		f.raidIcon:Hide()
	end

	-- cast + auras ---------------------------------------------------------------
	UpdateCastBar(f)

	f.auraElapsed = (f.auraElapsed or 0) + dt
	if f.auraElapsed >= (db.auras.timerRate or 0.05) or f.forceAuraUpdate then
		f.auraElapsed = 0
		f.forceAuraUpdate = nil
		UpdateAuras(f)
	end

	-- frame level so the target sits above everything else ------------------------
	local wantLevel = isTarget and 8 or 1
	if f:GetFrameLevel() ~= wantLevel then
		f:SetFrameLevel(wantLevel)
		f.healthBar:SetFrameLevel(wantLevel + 1)
		f.healthBorder:SetFrameLevel(wantLevel + 2)
		f.castBar:SetFrameLevel(wantLevel + 1)
		f.castBar.border:SetFrameLevel(wantLevel + 2)
		f.auraFrame:SetFrameLevel(wantLevel + 3)
	end

	-- scripts ---------------------------------------------------------------------
	f.scriptScale, f.scriptAlpha = nil, nil
	Scripting.RunHook("OnUpdate", f)

	-- final scale / position / alpha -------------------------------------------------
	-- scale first: ApplyPosition divides by the frame's effective scale
	local scale = db.scale * cfg.scale * (isTarget and db.targetScale or 1)
	if f.scriptScale then scale = f.scriptScale end
	if math.abs((f.curScale or 0) - scale) > 0.001 then
		f:SetScale(scale)
		f.curScale = scale
	end

	-- the hit box follows the bar's size, scale, offset and stacking, so
	-- recompute it whenever any of those move rather than every frame
	local stackY = math.floor((f.stackY or 0) + 0.5)
	if f.clickPending or f.hitScale ~= scale
		or f.hitGeneration ~= Core.settingsGeneration
		or f.hitStackY ~= stackY then
		f.hitScale = scale
		f.hitGeneration = Core.settingsGeneration
		f.hitStackY = stackY
		ApplyClickBox(f)
	end

	local alpha
	if not hasTarget then
		alpha = db.noTargetAlpha
	elseif isTarget then
		alpha = db.targetAlpha
	else
		alpha = db.nonTargetAlpha
	end
	alpha = alpha * cfg.alpha
	if f.scriptAlpha then alpha = f.scriptAlpha end
	if math.abs((f.curAlpha or -1) - alpha) > 0.001 then
		f:SetAlpha(alpha)
		f.curAlpha = alpha
	end

	if not f:IsShown() then f:Show() end
end

--------------------------------------------------------------------------------
-- plate lifecycle
--------------------------------------------------------------------------------

local function OnPlateShow(plate)
	local f = Core.active[plate]
	if not f then return end

	HideBlizzardArt(f.regions)

	f.prevCastValue = nil
	f.forceAuraUpdate = true
	f.curAlpha, f.curScale = nil, nil
	-- a recycled plate belongs to a different unit somewhere else on screen;
	-- drop the easing history so it snaps into place instead of gliding there
	f.smoothX, f.smoothY = nil, nil
	f.scriptColor, f.scriptBorderColor, f.scriptName = nil, nil, nil
	-- a recycled plate serves a different unit; release the old identity so it
	-- cannot inherit the previous occupant's auras
	if f.unitGUID and Core.guidOwner[f.unitGUID] == f then
		Core.guidOwner[f.unitGUID] = nil
	end
	f.unitGUID, f.guidName = nil, nil

	if f.constructorGeneration ~= constructorGeneration then
		f.constructorGeneration = constructorGeneration
		f.unitName = f.regions.name and f.regions.name:GetText() or ""
		Scripting.RunHook("Constructor", f)
	end

	f.unitName = f.regions.name and f.regions.name:GetText() or ""
	Scripting.RunHook("OnShow", f)

	UpdatePlate(f)
end

local function OnPlateHide(plate)
	local f = Core.active[plate]
	if not f then return end
	Scripting.RunHook("OnHide", f)
	f:Hide()
end

local function InitializePlate(plate)
	if Core.allPlates[plate] then return true end

	local regions = ClassifyPlate(plate)
	-- do not mark the plate as handled if we could not read it: leaving it
	-- unmarked means the next scan tries again rather than abandoning a plate
	-- that would then keep drawing Blizzard's artwork forever
	if not regions.health then return false end
	Core.allPlates[plate] = true

	local f = CreateUnitFrame(plate)
	f.regions = regions
	Core.active[plate] = f

	HideBlizzardArt(regions)
	ApplySettings(f)

	plate:HookScript("OnShow", OnPlateShow)
	plate:HookScript("OnHide", OnPlateHide)

	if plate:IsShown() then OnPlateShow(plate) end
	return true
end

--------------------------------------------------------------------------------
-- WorldFrame scanning + main loop
--------------------------------------------------------------------------------

-- Rejections are never permanent. A frame examined at the wrong moment - before
-- the client has finished populating it - would otherwise be written off for the
-- rest of the session and keep drawing Blizzard's artwork forever, which is
-- exactly how a stray plate border ends up floating on screen with nothing in
-- it. Retesting an unhooked child costs one early-exiting predicate.
local function ScanWorldFrame()
	local count = WorldFrame:GetNumChildren()
	for i = 1, count do
		local child = select(i, WorldFrame:GetChildren())
		if child and not child.plwHooked and not child.isPlaterWrathFrame then
			if IsNamePlate(child) and InitializePlate(child) then
				child.plwHooked = true
			end
		end
	end
end

Core.settingsGeneration = 1
Core.tickInterval = 0.03

local runner = CreateFrame("Frame")
local sinceUpdate, sinceScan, sinceTimers = 0, 0, 0

runner:SetScript("OnUpdate", function(self, elapsed)
	-- nothing may touch plates before the saved variables are loaded
	if not ns.db then return end

	sinceScan = sinceScan + elapsed
	if sinceScan >= 0.1 then
		sinceScan = 0
		local ok, err = pcall(ScanWorldFrame)
		if not ok then Util.Error(err) end
	end

	-- The expensive pass: colours, text, auras, threat, cast bar. Throttled,
	-- because none of it needs to run at display rate.
	sinceUpdate = sinceUpdate + elapsed
	if sinceUpdate >= ns.db.updateInterval then
		Core.tickInterval = sinceUpdate
		sinceUpdate = 0

		-- Survey every plate before updating any of them, because two of the
		-- decisions below cannot be made by a plate looking only at itself.
		--
		-- Which plate is the target: the client marks it by leaving it at full
		-- alpha while the others fade, but during that fade more than one plate
		-- is briefly at full alpha, and with two mobs sharing a name the name
		-- does not separate them either. A plate that wrongly decides it is the
		-- target binds itself to the target's unit, and since binding is
		-- exclusive that quietly steals the identity - and the auras - from the
		-- plate that actually owned it. Pick exactly one winner here instead,
		-- preferring whichever plate already holds the target's guid.
		--
		-- How many plates share each name: needed for the name-matching
		-- shortcut, which is only safe when a name identifies one plate.
		local counts = Core.nameCounts
		wipe(counts)

		local targetName = UnitExists("target") and UnitName("target") or nil
		local targetGUID = targetName and UnitGUID("target") or nil
		local best, bestScore = nil, 0

		for plate, f in pairs(Core.active) do
			if plate:IsShown() and f.regions and f.regions.name then
				local plateName = f.regions.name:GetText()
				if plateName and plateName ~= "" then
					counts[plateName] = (counts[plateName] or 0) + 1

					if targetName and plateName == targetName then
						local alpha = plate:GetAlpha()
						if alpha >= 0.99 then
							-- an established binding outranks any alpha reading
							local score = (f.unitGUID == targetGUID) and 2 or alpha
							if score > bestScore then best, bestScore = f, score end
						end
					end
				end
			end
		end

		Core.targetFrame = best

		for plate, f in pairs(Core.active) do
			if plate:IsShown() then
				local ok, err = pcall(UpdatePlate, f)
				if not ok then Util.Error(err) end
			elseif f:IsShown() then
				f:Hide()
			end
		end
	end

	-- Movement runs every rendered frame. Easing a position on the throttled
	-- tick above only moves plates ~30 times a second, which reads as stepping
	-- rather than gliding however gentle the easing is.
	sinceTimers = sinceTimers + elapsed
	local doTimers = sinceTimers >= (ns.db.auras.timerRate or 0.03)
	if doTimers then sinceTimers = 0 end

	-- Three phases: work out where each plate wants to be, resolve collisions
	-- between them, then ease each one towards its resolved spot.
	-- Guarded, because this runs on every rendered frame: an unprotected error
	-- in here does not fail once, it fails sixty times a second.
	-- Each phase is guarded separately. Sharing one pcall across all three meant
	-- a single frame failing to work out its target silently skipped stacking
	-- and positioning for every plate on screen - and because errors are
	-- deduplicated, it said so once and then looked like a missing feature
	-- rather than a fault.
	local ok, err = pcall(function()
		for _, f in pairs(Core.active) do
			if f:IsShown() then ComputeTarget(f) end
		end
	end)
	if not ok then Util.Error("ComputeTarget: " .. tostring(err)) end

	ok, err = pcall(StackPlates)
	if not ok then Util.Error("StackPlates: " .. tostring(err)) end

	ok, err = pcall(function()
		for _, f in pairs(Core.active) do
			if f:IsShown() then
				ApplyPosition(f, elapsed)
				if doTimers then RefreshAuraTimers(f) end
			end
		end
	end)
	if not ok then Util.Error("ApplyPosition: " .. tostring(err)) end
end)

--------------------------------------------------------------------------------
-- public helpers
--------------------------------------------------------------------------------

function Core.FullUpdate()
	Core.settingsGeneration = Core.settingsGeneration + 1
	-- the filter lists are matched through an index, so rebuild it here: every
	-- path that edits them ends up calling this
	if Auras.RebuildFilterIndex then Auras.RebuildFilterIndex() end
	for _, f in pairs(Core.active) do
		f.curAlpha, f.curScale = nil, nil
		f.forceAuraUpdate = true
		-- click box growth is monotonic, so clear it or it can never shrink
		-- back after the bar is made smaller
		f.clickW, f.clickH = nil, nil
	end
end

function Core.InvalidateConstructors()
	constructorGeneration = constructorGeneration + 1
end

-- Prints the exact widget layout of one live nameplate. This is how we find
-- out where a given client build keeps the border, name and level artwork
-- instead of assuming a region order.
function Core.DebugDump()
	local target
	for plate, f in pairs(Core.active) do
		if plate:IsShown() then target = plate break end
	end
	if not target then
		Util.Print("no visible nameplate to dump - get a mob on screen first.")
		return
	end

	local f = Core.active[target]

	local function describe(region)
		local kind = region:GetObjectType()
		local detail
		if kind == "FontString" then
			detail = "text=" .. tostring(region:GetText())
		else
			local path = region:GetTexture()
			detail = "tex=" .. tostring(path) .. " blend=" .. tostring(region:GetBlendMode())
		end
		return string.format("      %s  %s  shown=%s alpha=%.2f",
			kind, detail, tostring(region:IsShown()), region:GetAlpha())
	end

	local function dumpFrame(label, frame)
		if not frame then Util.Print("  " .. label .. ": nil") return end
		Util.Print(string.format("  %s: %s %dx%d alpha=%.2f regions=%d",
			label, frame:GetObjectType(), frame:GetWidth(), frame:GetHeight(),
			frame:GetAlpha(), select("#", frame:GetRegions())))
		for i = 1, select("#", frame:GetRegions()) do
			Util.Print(describe((select(i, frame:GetRegions()))))
		end
	end

	Util.Print("---- nameplate dump ----")
	Util.Print(string.format("  plate: %dx%d alpha=%.2f children=%d",
		target:GetWidth(), target:GetHeight(), target:GetAlpha(), target:GetNumChildren()))
	dumpFrame("plate regions", target)
	dumpFrame("health", f.regions.health)
	dumpFrame("cast", f.regions.cast)
	Util.Print(string.format("  classified: name=%s level=%s border=%s glow=%s highlight=%s raid=%s",
		tostring(f.regions.name ~= nil), tostring(f.regions.level ~= nil),
		tostring(f.regions.healthBorder ~= nil), tostring(f.regions.threatGlow ~= nil),
		tostring(f.regions.highlight ~= nil), tostring(f.regions.raidIcon ~= nil)))
	Util.Print(string.format("  total regions blanked: %d", #(f.regions.allRegions or {})))
	local px, py = target:GetCenter()
	local hx, hy
	if f.regions.health then hx, hy = f.regions.health:GetCenter() end
	if px and hx and hy then
		Util.Print(string.format("  health bar relative to plate centre: dx=%.1f dy=%.1f", hx - px, hy - py))
	else
		Util.Print("  health bar centre unavailable")
	end
	Util.Print(string.format("  plate size now %dx%d, original %s x %s",
		target:GetWidth(), target:GetHeight(),
		tostring(f.origPlateW and math.floor(f.origPlateW)),
		tostring(f.origPlateH and math.floor(f.origPlateH))))
	Util.Print(string.format("  hit rect insets: %.1f %.1f %.1f %.1f",
		target:GetHitRectInsets()))
	Util.Print(string.format("  stack offset: %.1f px   frames walked: %d   textures cleared: %d",
		f.stackY or 0, #(f.regions.frames or {}), #(f.regions.nilable or {})))
	Util.Print(string.format("  in combat: %s   click box pending: %s",
		tostring(InCombatLockdown() and true or false), tostring(f.clickPending and true or false)))
	Util.Print(string.format("  matched unit: %s   plates sharing this name: %d   auras shown: %d",
		tostring(f.unitGUID or "not matched"),
		Core.nameCounts[f.unitName or ""] or 0, f.auraCount or 0))

	Util.Print(string.format("  stacking %s, gap %d, %d plate(s) taking part:",
		ns.db.stackPlates and "|cff66ff66on|r" or "|cffff5555off|r",
		ns.db.stackSpacing, #stackList))
	for i = 1, #stackList do
		local s = stackList[i]
		Util.Print(string.format("    [%d] %-16s base=(%.0f,%.0f) half=(%.0f,%.0f) lift=%.1f limit=%.1f",
			i, tostring(s.unitName), s.baseX or -1, s.baseY or -1,
			s.halfW or -1, s.halfH or -1, s.stackTargetY or 0, s.stackLimit or 0))
	end
	Util.Print("---- end ----")
end

-- Other addons that draw on WotLK nameplates. Anything they add is their
-- artwork, not ours, so it does not answer to this addon's filters - which
-- looks exactly like a blacklist that refuses to work.
local NAMEPLATE_ADDONS = {
	"PlateBuffs", "TidyPlates", "Aloft", "dNamePlates", "caelNamePlates",
	"Kui_Nameplates", "TinyPlates", "NeatPlates", "ElvUI",
}

function Core.GetConflicts()
	local found
	for _, name in ipairs(NAMEPLATE_ADDONS) do
		if IsAddOnLoaded(name) then
			found = found or {}
			found[#found + 1] = name
		end
	end
	return found
end

function Core.CountAuraIcons()
	local total = 0
	for _, f in pairs(Core.active) do
		if f:IsShown() then total = total + (f.auraCount or 0) end
	end
	return total
end

function Core.GetPlateByName(name)
	for _, f in pairs(Core.active) do
		if f:IsShown() and f.unitName == name then return f end
	end
	return nil
end

--------------------------------------------------------------------------------
-- cvars so plate geometry stays constant
--------------------------------------------------------------------------------

local function ApplyCVars()
	if not ns.db.forceBlizzardCVars then return end
	for _, cvar in ipairs({ "bloatnameplates", "bloattest", "bloatthreat" }) do
		pcall(SetCVar, cvar, "0")
	end
	pcall(SetCVar, "ShowClassColorInNameplate", "1")
end

Core.ApplyCVars = ApplyCVars

--------------------------------------------------------------------------------
-- startup
--------------------------------------------------------------------------------

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		ns.Config.Initialize()
		ns.Scripting.InstallExamples()
		ns.Scripting.CompileAll()
		if ns.Options and ns.Options.Initialize then ns.Options.Initialize() end
	elseif event == "PLAYER_ENTERING_WORLD" then
		if not ns.db then ns.Config.Initialize() end
		ApplyCVars()
		Cache.LearnUnit("player")
		Cache.ScanGroup()
		Core.FullUpdate()

		local conflicts = Core.GetConflicts()
		if conflicts and not Core.warnedConflicts then
			Core.warnedConflicts = true
			Util.Print("|cffff5555" .. table.concat(conflicts, ", ")
				.. " is also drawing on nameplates.|r Icons it adds are its own, so they "
				.. "ignore this addon's blacklist and cannot be removed from here. "
				.. "Disable it if you are seeing auras that will not go away.")
		end
	end
end)
