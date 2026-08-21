--[[--------------------------------------------------------------------------
	PlaterWrath - Cache.lua

	3.3.5a nameplates carry no unit token, so the only thing we ever get from a
	plate is a *name string*. Everything else (is this a player? what class?
	how long does this debuff last?) has to be learned from somewhere else and
	remembered. That is what this file does.

	Sources, in order of trust:
	  1. real unit tokens we can inspect  (target / mouseover / focus / party / raid)
	  2. combat log object flags          (player vs npc, hostile vs friendly)
	  3. class-defining spell casts       (only unambiguous spells)
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local Util = ns.Util

local Cache = {}
ns.Cache = Cache

Cache.class      = {}   -- [name] = "MAGE"
Cache.isPlayer   = {}   -- [name] = true/false
Cache.guid       = {}   -- [name] = most recently seen guid with that name
Cache.duration   = {}   -- [spellId] = duration learned from a real UnitAura scan
Cache.icon       = {}   -- [spellId] = icon path

-- Several units can share a name - four wolves, a row of training dummies - so
-- one name maps to a set of guids, not a single one. Aura tracking depends on
-- telling them apart, so keep both directions.
Cache.guidsByName = {}  -- [name] = { [guid] = lastSeen }
Cache.nameByGUID  = {}  -- [guid] = name

local band = bit.band
local TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x00000400
local CONTROL_PLAYER = COMBATLOG_OBJECT_CONTROL_PLAYER or 0x00000100

--------------------------------------------------------------------------------
-- class defining spells
-- Only spells that exactly one class in 3.3.5a can cast. Keyed by spell *name*
-- because private-server spell ids drift, names do not.
--------------------------------------------------------------------------------

Cache.classSpells = {
	-- Death Knight
	["Death Coil"]          = "DEATHKNIGHT",  ["Icy Touch"]         = "DEATHKNIGHT",
	["Plague Strike"]       = "DEATHKNIGHT",  ["Blood Strike"]      = "DEATHKNIGHT",
	["Death Grip"]          = "DEATHKNIGHT",  ["Frost Fever"]       = "DEATHKNIGHT",
	["Blood Plague"]        = "DEATHKNIGHT",  ["Howling Blast"]     = "DEATHKNIGHT",
	["Obliterate"]          = "DEATHKNIGHT",  ["Scourge Strike"]    = "DEATHKNIGHT",
	-- Druid
	["Moonfire"]            = "DRUID",        ["Insect Swarm"]      = "DRUID",
	["Wrath"]               = "DRUID",        ["Starfire"]          = "DRUID",
	["Rejuvenation"]        = "DRUID",        ["Regrowth"]          = "DRUID",
	["Mangle"]              = "DRUID",        ["Rip"]               = "DRUID",
	["Rake"]                = "DRUID",        ["Lacerate"]          = "DRUID",
	["Entangling Roots"]    = "DRUID",        ["Cyclone"]           = "DRUID",
	["Faerie Fire"]         = "DRUID",        ["Swipe"]             = "DRUID",
	-- Hunter
	["Serpent Sting"]       = "HUNTER",       ["Arcane Shot"]       = "HUNTER",
	["Steady Shot"]         = "HUNTER",       ["Explosive Shot"]    = "HUNTER",
	["Hunter's Mark"]       = "HUNTER",       ["Aimed Shot"]        = "HUNTER",
	["Multi-Shot"]          = "HUNTER",       ["Wing Clip"]         = "HUNTER",
	["Concussive Shot"]     = "HUNTER",       ["Chimera Shot"]      = "HUNTER",
	-- Mage
	["Frostbolt"]           = "MAGE",         ["Fireball"]          = "MAGE",
	["Arcane Blast"]        = "MAGE",         ["Arcane Missiles"]   = "MAGE",
	["Polymorph"]           = "MAGE",         ["Frost Nova"]        = "MAGE",
	["Living Bomb"]         = "MAGE",         ["Pyroblast"]         = "MAGE",
	["Blizzard"]            = "MAGE",         ["Counterspell"]      = "MAGE",
	["Ice Lance"]           = "MAGE",         ["Scorch"]            = "MAGE",
	-- Paladin
	["Judgement of Light"]  = "PALADIN",      ["Consecration"]      = "PALADIN",
	["Hammer of Justice"]   = "PALADIN",      ["Holy Light"]        = "PALADIN",
	["Flash of Light"]      = "PALADIN",      ["Crusader Strike"]   = "PALADIN",
	["Divine Storm"]        = "PALADIN",      ["Avenger's Shield"]  = "PALADIN",
	["Repentance"]          = "PALADIN",      ["Exorcism"]          = "PALADIN",
	-- Priest
	["Shadow Word: Pain"]   = "PRIEST",       ["Mind Blast"]        = "PRIEST",
	["Mind Flay"]           = "PRIEST",       ["Vampiric Touch"]    = "PRIEST",
	["Devouring Plague"]    = "PRIEST",       ["Power Word: Shield"]= "PRIEST",
	["Renew"]               = "PRIEST",       ["Smite"]             = "PRIEST",
	["Psychic Scream"]      = "PRIEST",       ["Holy Fire"]         = "PRIEST",
	-- Rogue
	["Sinister Strike"]     = "ROGUE",        ["Eviscerate"]        = "ROGUE",
	["Backstab"]            = "ROGUE",        ["Mutilate"]          = "ROGUE",
	["Rupture"]             = "ROGUE",        ["Garrote"]           = "ROGUE",
	["Kidney Shot"]         = "ROGUE",        ["Cheap Shot"]        = "ROGUE",
	["Gouge"]               = "ROGUE",        ["Kick"]              = "ROGUE",
	["Hemorrhage"]          = "ROGUE",        ["Envenom"]           = "ROGUE",
	-- Shaman
	["Lightning Bolt"]      = "SHAMAN",       ["Chain Lightning"]   = "SHAMAN",
	["Earth Shock"]         = "SHAMAN",       ["Flame Shock"]       = "SHAMAN",
	["Frost Shock"]         = "SHAMAN",       ["Lava Burst"]        = "SHAMAN",
	["Stormstrike"]         = "SHAMAN",       ["Chain Heal"]        = "SHAMAN",
	["Healing Wave"]        = "SHAMAN",       ["Wind Shear"]        = "SHAMAN",
	-- Warlock
	["Corruption"]          = "WARLOCK",      ["Curse of Agony"]    = "WARLOCK",
	["Immolate"]            = "WARLOCK",      ["Unstable Affliction"] = "WARLOCK",
	["Haunt"]               = "WARLOCK",      ["Shadow Bolt"]       = "WARLOCK",
	["Incinerate"]          = "WARLOCK",      ["Conflagrate"]       = "WARLOCK",
	["Fear"]                = "WARLOCK",      ["Chaos Bolt"]        = "WARLOCK",
	["Death Coil"]          = nil,            -- ambiguous with DK, removed
	-- Warrior
	["Mortal Strike"]       = "WARRIOR",      ["Bloodthirst"]       = "WARRIOR",
	["Heroic Strike"]       = "WARRIOR",      ["Shield Slam"]       = "WARRIOR",
	["Rend"]                = "WARRIOR",      ["Thunder Clap"]      = "WARRIOR",
	["Sunder Armor"]        = "WARRIOR",      ["Overpower"]         = "WARRIOR",
	["Whirlwind"]           = "WARRIOR",      ["Devastate"]         = "WARRIOR",
	["Shattering Throw"]    = "WARRIOR",      ["Charge"]            = "WARRIOR",
}

--------------------------------------------------------------------------------
-- fallback aura durations (by spell name, enUS)
-- Combat log never tells us how long an aura lasts. We learn real durations
-- whenever the unit happens to be our target, but until then these keep the
-- timers on the icons honest for the auras people actually watch.
--------------------------------------------------------------------------------

Cache.fallbackDuration = {
	-- warlock
	["Corruption"] = 18, ["Curse of Agony"] = 24, ["Immolate"] = 15,
	["Unstable Affliction"] = 15, ["Haunt"] = 12, ["Curse of the Elements"] = 300,
	["Curse of Doom"] = 60, ["Fear"] = 20, ["Conflagrate"] = 6,
	-- priest
	["Shadow Word: Pain"] = 18, ["Vampiric Touch"] = 15, ["Devouring Plague"] = 24,
	["Holy Fire"] = 7, ["Psychic Scream"] = 8, ["Shackle Undead"] = 50,
	-- druid
	["Moonfire"] = 12, ["Insect Swarm"] = 12, ["Rip"] = 16, ["Rake"] = 9,
	["Lacerate"] = 15, ["Entangling Roots"] = 27, ["Cyclone"] = 6,
	["Faerie Fire"] = 300, ["Hibernate"] = 40, ["Pounce Bleed"] = 18,
	["Mangle"] = 60, ["Demoralizing Roar"] = 30, ["Infected Wounds"] = 12,
	-- mage
	["Living Bomb"] = 12, ["Pyroblast"] = 12, ["Frostbite"] = 5, ["Frost Nova"] = 8,
	["Polymorph"] = 50, ["Ignite"] = 4, ["Fireball"] = 8, ["Improved Scorch"] = 30,
	["Winter's Chill"] = 15, ["Deep Freeze"] = 5,
	-- rogue
	["Rupture"] = 16, ["Garrote"] = 18, ["Kidney Shot"] = 6, ["Cheap Shot"] = 4,
	["Blind"] = 10, ["Sap"] = 60, ["Gouge"] = 4, ["Expose Armor"] = 30,
	["Deadly Poison"] = 12, ["Crippling Poison"] = 12, ["Wound Poison"] = 15,
	["Hemorrhage"] = 15,
	-- warrior
	["Rend"] = 15, ["Deep Wounds"] = 6, ["Sunder Armor"] = 30, ["Hamstring"] = 15,
	["Demoralizing Shout"] = 30, ["Thunder Clap"] = 30, ["Mortal Strike"] = 10,
	["Shattering Throw"] = 10, ["Piercing Howl"] = 6,
	-- hunter
	["Serpent Sting"] = 15, ["Hunter's Mark"] = 300, ["Explosive Shot"] = 2,
	["Freezing Trap"] = 20, ["Wyvern Sting"] = 12, ["Concussive Shot"] = 4,
	["Wing Clip"] = 10, ["Viper Sting"] = 8, ["Scorpid Sting"] = 20,
	-- paladin
	["Hammer of Justice"] = 6, ["Repentance"] = 60, ["Judgement of Light"] = 20,
	["Judgement of Wisdom"] = 20, ["Avenger's Shield"] = 3, ["Turn Evil"] = 20,
	["Holy Shock"] = 3, ["Consecration"] = 8,
	-- shaman
	["Flame Shock"] = 18, ["Frost Shock"] = 8, ["Earthbind"] = 5, ["Hex"] = 60,
	["Stormstrike"] = 12,
	-- death knight
	["Frost Fever"] = 15, ["Blood Plague"] = 15, ["Chains of Ice"] = 10,
	["Strangulate"] = 5, ["Hungering Cold"] = 10, ["Ebon Plague"] = 15,
	["Icy Touch"] = 15, ["Unholy Blight"] = 10,
	-- generic
	["Stun"] = 3, ["Bleed"] = 15,
}

--------------------------------------------------------------------------------
-- learning from real unit tokens
--------------------------------------------------------------------------------

local SCAN_UNITS = { "target", "focus", "mouseover", "pet", "player" }

function Cache.LearnUnit(unit)
	if not unit or not UnitExists(unit) then return end
	local name = UnitName(unit)
	if not name then return end

	local isPlayer = UnitIsPlayer(unit) and true or false
	Cache.isPlayer[name] = isPlayer
	Cache.SeeUnit(UnitGUID(unit), name)

	if isPlayer then
		local _, class = UnitClass(unit)
		if class then Cache.class[name] = class end
	else
		Cache.class[name] = nil
	end

	-- while we have a real token, harvest exact aura durations
	Cache.LearnAuraDurations(unit)
end

function Cache.LearnAuraDurations(unit)
	for i = 1, 40 do
		local aname, _, icon, _, _, duration, _, _, _, _, spellId = UnitAura(unit, i, "HARMFUL")
		if not aname then break end
		if duration and duration > 0 then
			if spellId then Cache.duration[spellId] = duration end
			Cache.fallbackDuration[aname] = duration
		end
		if spellId and icon then Cache.icon[spellId] = icon end
	end
	for i = 1, 40 do
		local aname, _, icon, _, _, duration, _, _, _, _, spellId = UnitAura(unit, i, "HELPFUL")
		if not aname then break end
		if duration and duration > 0 then
			if spellId then Cache.duration[spellId] = duration end
			Cache.fallbackDuration[aname] = duration
		end
		if spellId and icon then Cache.icon[spellId] = icon end
	end
end

function Cache.ScanGroup()
	local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
	if raid > 0 then
		for i = 1, raid do Cache.LearnUnit("raid" .. i) end
		return
	end
	local party = GetNumPartyMembers and GetNumPartyMembers() or 0
	for i = 1, party do Cache.LearnUnit("party" .. i) end
end

--------------------------------------------------------------------------------
-- learning from the combat log
--------------------------------------------------------------------------------

function Cache.SeeUnit(guid, name)
	if not guid or guid == "" or not name or name == "" then return end
	Cache.guid[name] = guid
	Cache.nameByGUID[guid] = name
	local set = Cache.guidsByName[name]
	if not set then
		set = {}
		Cache.guidsByName[name] = set
	end
	set[guid] = GetTime()
end

function Cache.ForgetGUID(guid)
	if not guid then return end
	local name = Cache.nameByGUID[guid]
	if name and Cache.guidsByName[name] then
		Cache.guidsByName[name][guid] = nil
	end
	Cache.nameByGUID[guid] = nil
end

function Cache.GetNameForGUID(guid)
	return guid and Cache.nameByGUID[guid]
end

-- The guid for this name, but only when there is exactly one candidate that has
-- been seen recently. With two mobs sharing a name there is no safe answer, and
-- guessing is what put one mob's damage-over-time icons on another's nameplate.
function Cache.UniqueGUIDForName(name)
	local set = name and Cache.guidsByName[name]
	if not set then return nil end

	local cutoff = GetTime() - 60
	local found, count = nil, 0
	for guid, seen in pairs(set) do
		if seen >= cutoff then
			count = count + 1
			if count > 1 then return nil end
			found = guid
		end
	end
	return found
end

function Cache.OnCombatLogUnit(guid, name, flags, spellName)
	if not name or name == "" then return end
	Cache.SeeUnit(guid, name)

	if flags then
		local isPlayer = band(flags, TYPE_PLAYER) > 0
		-- do not let a flag downgrade something a real token already confirmed
		if Cache.isPlayer[name] == nil then
			Cache.isPlayer[name] = isPlayer
		elseif isPlayer then
			Cache.isPlayer[name] = true
		end
	end

	if spellName and not Cache.class[name] then
		local class = Cache.classSpells[spellName]
		if class and Cache.isPlayer[name] then
			Cache.class[name] = class
		end
	end
end

--------------------------------------------------------------------------------
-- lookups used by the nameplate engine
--------------------------------------------------------------------------------

function Cache.GetClass(name)
	return Cache.class[name]
end

function Cache.IsPlayer(name)
	local v = Cache.isPlayer[name]
	if v == nil then return false end
	return v
end

function Cache.GetDuration(spellId, spellName)
	if spellId and Cache.duration[spellId] then return Cache.duration[spellId] end
	if spellName and Cache.fallbackDuration[spellName] then return Cache.fallbackDuration[spellName] end
	return nil
end

function Cache.GetIcon(spellId, spellName)
	if spellId and Cache.icon[spellId] then return Cache.icon[spellId] end
	if spellId then
		local _, _, icon = GetSpellInfo(spellId)
		if icon then Cache.icon[spellId] = icon; return icon end
	end
	if spellName then
		local _, _, icon = GetSpellInfo(spellName)
		if icon then return icon end
	end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

--------------------------------------------------------------------------------
-- event plumbing
--------------------------------------------------------------------------------

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
f:RegisterEvent("PLAYER_FOCUS_CHANGED")
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:RegisterEvent("UNIT_AURA")
f:SetScript("OnEvent", function(self, event, arg1)
	if event == "PLAYER_TARGET_CHANGED" then
		Cache.LearnUnit("target")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		Cache.LearnUnit("mouseover")
	elseif event == "PLAYER_FOCUS_CHANGED" then
		Cache.LearnUnit("focus")
	elseif event == "UNIT_AURA" then
		if arg1 == "target" or arg1 == "focus" or arg1 == "mouseover" then
			Cache.LearnAuraDurations(arg1)
		end
	else
		Cache.ScanGroup()
	end
end)

-- slow background sweep so party/raid stay warm and target durations refresh
Util.NewTicker(2, function()
	for _, unit in ipairs(SCAN_UNITS) do
		if UnitExists(unit) then Cache.LearnUnit(unit) end
	end
end)

-- Drop guids we have not seen in a while. Without this the name-to-guid sets
-- only ever grow, and a name that has had many mobs through it would never look
-- unambiguous again, so plates for a lone mob of that name would stop matching.
Util.NewTicker(20, function()
	local cutoff = GetTime() - 120
	for name, set in pairs(Cache.guidsByName) do
		local remaining = 0
		for guid, seen in pairs(set) do
			if seen < cutoff then
				set[guid] = nil
				Cache.nameByGUID[guid] = nil
			else
				remaining = remaining + 1
			end
		end
		if remaining == 0 then Cache.guidsByName[name] = nil end
	end
end)
