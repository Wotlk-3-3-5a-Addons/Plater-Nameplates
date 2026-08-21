--[[--------------------------------------------------------------------------
	PlaterWrath - Config.lua
	Defaults, saved variables and the profile system.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local Util = ns.Util

--------------------------------------------------------------------------------
-- default profile
--------------------------------------------------------------------------------

local unitDefaults = function(colorMode, show)
	return {
		show        = show,
		colorMode   = colorMode,     -- class | reaction | threat | custom
		customColor = { 0.4, 0.4, 0.8 },
		alpha       = 1.0,
		scale       = 1.0,
		showAuras   = true,
		showCast    = true,
		showLevel   = true,
		showName    = true,
		healthText  = "percent",     -- none | percent | current | both
	}
end

ns.defaults = {
	enabled        = true,
	updateInterval = 0.03,

	-- appearance -------------------------------------------------------------
	barTexture   = "Interface\\TargetingFrame\\UI-StatusBar",
	font         = "Fonts\\FRIZQT__.TTF",
	fontOutline  = "OUTLINE",

	width        = 118,
	height       = 12,
	scale        = 1.0,
	yOffset      = 0,
	xOffset      = 0,

	-- movement --------------------------------------------------------------
	-- 0 eases nothing and the plate snaps to the unit every frame; higher
	-- values make plates drift towards the unit instead of darting around.
	smoothing    = 0.35,

	-- anti-overlap. This client does not space nameplates apart, so the addon
	-- lifts colliding plates clear of one another itself.
	stackPlates  = true,
	stackSpacing = 4,
	-- Nameplates are protected frames, so their clickable box cannot be moved
	-- during combat. Capping how far a plate is lifted keeps every bar inside
	-- the box it already has, and keeps it near the body it belongs to.
	clampStack   = true,

	-- clickable area ----------------------------------------------------------
	-- The frame you click to target is Blizzard's plate, not our artwork. Sizing
	-- that frame to match the health bar makes the bar clickable, and gives the
	-- client's own plate stacking the right dimensions so plates stop overlapping.
	resizeClickArea = true,
	clickWidth      = 0,   -- 0 = match the health bar width
	clickHeight     = 0,   -- 0 = leave Blizzard's height alone

	borderSize   = 1,
	borderColor  = { 0, 0, 0, 1 },
	bgColor      = { 0.08, 0.08, 0.08, 0.85 },

	nameSize     = 10,
	levelSize    = 9,
	healthSize   = 9,
	nameAnchor   = "TOP",            -- TOP | CENTER | BOTTOM
	abbreviateNames = false,
	maxNameLength   = 0,             -- 0 = no truncation

	-- target ------------------------------------------------------------------
	targetHighlight      = true,
	targetHighlightColor = { 1, 1, 1, 1 },
	targetScale          = 1.10,
	targetAlpha          = 1.00,
	nonTargetAlpha       = 0.60,
	noTargetAlpha        = 1.00,     -- alpha when the player has no target
	targetIndicator      = true,     -- side arrows on the target plate

	-- cast bar ----------------------------------------------------------------
	castBar = {
		enabled         = true,
		height          = 10,
		yOffset         = -3,
		showIcon        = true,
		showName        = true,
		showTime        = true,
		iconSize        = 0,          -- 0 = match bar height
		color           = { 0.90, 0.70, 0.10 },
		channelColor    = { 0.30, 0.70, 0.90 },
		noInterruptColor= { 0.60, 0.60, 0.60 },
		fontSize        = 9,
	},

	-- threat ------------------------------------------------------------------
	threat = {
		enabled = true,
		mode    = "auto",             -- dps | tank | auto
		colors  = {
			aggro      = { 0.90, 0.15, 0.15 },   -- you are being hit
			transition = { 1.00, 0.75, 0.15 },   -- gaining / losing aggro
			noaggro    = { 0.25, 0.75, 0.30 },   -- someone else has it
		},
		useOffTankColor = false,
	},

	-- auras -------------------------------------------------------------------
	auras = {
		enabled     = true,
		size        = 20,
		max         = 8,
		spacing     = 2,
		yOffset     = 8,
		perRow      = 8,
		growth      = "CENTER",       -- LEFT | CENTER | RIGHT
		showBuffs   = true,
		showDebuffs = true,
		filter      = "mine",         -- mine | all | whitelist
		-- "unit" shows a plate's auras only once it has been matched to an
		-- actual unit. "name" falls back to matching by unit name, which puts
		-- one mob's auras on every other mob sharing its name.
		matching    = "unit",         -- unit | name
		showStacks  = true,
		showTimer   = true,
		timerSize   = 9,
		timerDecimals  = 1,       -- fractional digits, used only below the threshold
		timerThreshold = 2,       -- seconds; above this the timer is whole numbers
		timerRate      = 0.03,    -- how often aura timers redraw, seconds
		stackSize   = 10,
		borderByType= true,           -- color icon border by debuff school
		-- hover an icon for the spell's tooltip, right click to blacklist it.
		-- Costs a small mouse-catching area above each health bar.
		interactive = true,
		blacklist   = {},             -- [spellName] = true
		whitelist   = {},             -- [spellName] = true
	},

	-- indicators --------------------------------------------------------------
	showRaidIcon   = true,
	raidIconSize   = 18,
	raidIconAnchor = "RIGHT",
	showEliteIcon  = true,
	showExecuteRange = false,
	executeRange   = 20,             -- percent
	executeColor   = { 0.7, 0.1, 0.7 },

	-- unit types --------------------------------------------------------------
	units = {
		enemyPlayer    = unitDefaults("class",    true),
		enemyNPC       = unitDefaults("threat",   true),
		neutralNPC     = unitDefaults("reaction", true),
		friendlyPlayer = unitDefaults("class",    true),
		friendlyNPC    = unitDefaults("reaction", true),
	},

	-- scripting ---------------------------------------------------------------
	mods = {},                        -- [name] = mod table, see Scripting.lua

	-- misc --------------------------------------------------------------------
	forceBlizzardCVars = true,        -- disable plate "bloat" so sizes stay fixed
	hideBlizzardArt    = true,
	showEnemyPlates    = true,        -- tracked for /plater enemy
	showFriendlyPlates = false,       -- tracked for /plater friendly
	minimapButton      = { hide = false, angle = 210 },
}

ns.UNIT_TYPES = {
	{ key = "enemyPlayer",    label = "Enemy Player"    },
	{ key = "enemyNPC",       label = "Enemy NPC"       },
	{ key = "neutralNPC",     label = "Neutral NPC"     },
	{ key = "friendlyPlayer", label = "Friendly Player" },
	{ key = "friendlyNPC",    label = "Friendly NPC"    },
}

--------------------------------------------------------------------------------
-- profile handling
--------------------------------------------------------------------------------

local Config = {}
ns.Config = Config

-- ns.db points at the active profile table
ns.db = nil

local function CharKey()
	return (UnitName("player") or "?") .. " - " .. (GetRealmName() or "?")
end

function Config.Initialize()
	if type(PlaterWrathDB) ~= "table" then PlaterWrathDB = {} end
	if type(PlaterWrathCharDB) ~= "table" then PlaterWrathCharDB = {} end

	PlaterWrathDB.profiles = PlaterWrathDB.profiles or {}
	PlaterWrathDB.profileKeys = PlaterWrathDB.profileKeys or {}

	if not PlaterWrathDB.profiles["Default"] then
		PlaterWrathDB.profiles["Default"] = Util.CopyTable(ns.defaults)
	end

	local key = CharKey()
	local wanted = PlaterWrathDB.profileKeys[key] or "Default"
	if not PlaterWrathDB.profiles[wanted] then wanted = "Default" end
	PlaterWrathDB.profileKeys[key] = wanted

	ns.activeProfile = wanted
	ns.db = Util.ApplyDefaults(PlaterWrathDB.profiles[wanted], ns.defaults)
	Config.Migrate(ns.db)
end

-- Runs after defaults are filled in. `dbVersion` is deliberately absent from
-- ns.defaults: if it had a default, ApplyDefaults would stamp the current
-- version onto old profiles and every migration would be skipped.
local DB_VERSION = 3

function Config.Migrate(profile)
	local version = profile.dbVersion or 1

	if version < 2 then
		-- aura timers gained sub-second precision; existing profiles were
		-- saved with whole-second formatting and a slow redraw
		profile.auras.timerDecimals = 3
		profile.auras.timerRate = 0.03
	end

	if version < 3 then
		-- Fractions everywhere turned out to be unreadable. Whole seconds for
		-- most of a timer, fractions only for the last couple of seconds.
		profile.auras.timerDecimals = 1
		profile.auras.timerThreshold = 2
	end

	profile.dbVersion = DB_VERSION
end

function Config.GetProfileList()
	return Util.SortedKeys(PlaterWrathDB.profiles)
end

function Config.GetActiveProfile()
	return ns.activeProfile
end

function Config.SetProfile(name)
	if not PlaterWrathDB.profiles[name] then
		PlaterWrathDB.profiles[name] = Util.CopyTable(ns.defaults)
	end
	PlaterWrathDB.profileKeys[CharKey()] = name
	ns.activeProfile = name
	ns.db = Util.ApplyDefaults(PlaterWrathDB.profiles[name], ns.defaults)
	Config.Migrate(ns.db)
	if ns.Core then ns.Core.FullUpdate() end
	if ns.Scripting then ns.Scripting.CompileAll() end
	Util.Print("profile set to |cffffd100" .. name .. "|r")
end

function Config.CopyProfile(from)
	if not PlaterWrathDB.profiles[from] then return end
	local target = ns.activeProfile
	PlaterWrathDB.profiles[target] = Util.CopyTable(PlaterWrathDB.profiles[from])
	ns.db = Util.ApplyDefaults(PlaterWrathDB.profiles[target], ns.defaults)
	if ns.Core then ns.Core.FullUpdate() end
	if ns.Scripting then ns.Scripting.CompileAll() end
	Util.Print("copied |cffffd100" .. from .. "|r into |cffffd100" .. target .. "|r")
end

function Config.DeleteProfile(name)
	if name == "Default" then
		Util.Print("the Default profile cannot be deleted.")
		return
	end
	PlaterWrathDB.profiles[name] = nil
	for k, v in pairs(PlaterWrathDB.profileKeys) do
		if v == name then PlaterWrathDB.profileKeys[k] = "Default" end
	end
	if ns.activeProfile == name then Config.SetProfile("Default") end
end

function Config.ResetProfile()
	PlaterWrathDB.profiles[ns.activeProfile] = Util.CopyTable(ns.defaults)
	ns.db = PlaterWrathDB.profiles[ns.activeProfile]
	if ns.Core then ns.Core.FullUpdate() end
	if ns.Scripting then ns.Scripting.CompileAll() end
	Util.Print("profile reset.")
end
