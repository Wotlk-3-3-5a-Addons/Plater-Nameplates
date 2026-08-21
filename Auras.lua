--[[--------------------------------------------------------------------------
	PlaterWrath - Auras.lua

	Nameplate aura tracking for a client with no nameplate unit tokens.

	Two sources feed the same store:
	  * COMBAT_LOG_EVENT_UNFILTERED, indexed by destination *name*. This is the
	    only way to see auras on a mob you are not targeting. It is name based,
	    so two mobs with the same name in range share a bucket - that is a hard
	    limit of the 3.3.5a client, not something an addon can work around.
	  * UnitAura() on target / focus / mouseover, which is exact. Whenever a
	    plate matches one of those units we use the exact data instead.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local Util  = ns.Util
local Cache = ns.Cache

local Auras = {}
ns.Auras = Auras

local band = bit.band
local AFFILIATION_MINE = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x00000001
local REACTION_HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x00000040

-- [guid] = { [key] = auraTable }
--
-- Keyed by guid, not by name. Name keying meant every mob sharing a name shared
-- one set of auras, so a damage-over-time effect on one training dummy appeared
-- on all of them. The combat log identifies units by guid, so the tracking does
-- too; matching a nameplate to a guid is Core's job.
local store = {}
-- [guid] = last time we touched this bucket, used to expire dead mobs
local touched = {}

Auras.store = store

Auras.SchoolColors = {
	[1]  = { 1.00, 1.00, 1.00 },  -- physical
	[2]  = { 1.00, 0.90, 0.50 },  -- holy
	[4]  = { 1.00, 0.50, 0.00 },  -- fire
	[8]  = { 0.30, 1.00, 0.30 },  -- nature
	[16] = { 0.50, 1.00, 1.00 },  -- frost
	[32] = { 0.50, 0.30, 0.90 },  -- shadow
	[64] = { 1.00, 0.50, 1.00 },  -- arcane
}

Auras.DispelColors = {
	Magic   = { 0.20, 0.60, 1.00 },
	Curse   = { 0.60, 0.00, 1.00 },
	Disease = { 0.60, 0.40, 0.00 },
	Poison  = { 0.00, 0.60, 0.00 },
	none    = { 0.80, 0.00, 0.00 },
}

--------------------------------------------------------------------------------
-- store maintenance
--------------------------------------------------------------------------------

local function KeyFor(spellId, spellName, mine)
	return (spellId or spellName or "?") .. (mine and "@m" or "@o")
end

local function Bucket(guid)
	local b = store[guid]
	if not b then
		b = {}
		store[guid] = b
	end
	touched[guid] = GetTime()
	return b
end

function Auras.Wipe(guid)
	if not guid then return end
	store[guid] = nil
	touched[guid] = nil
end

function Auras.WipeAll()
	for k in pairs(store) do store[k] = nil end
	for k in pairs(touched) do touched[k] = nil end
end

local function AddAura(destGUID, spellId, spellName, school, auraType, amount, mine)
	if not destGUID or destGUID == "" then return end

	local bucket = Bucket(destGUID)
	local key = KeyFor(spellId, spellName, mine)
	local now = GetTime()
	local duration = Cache.GetDuration(spellId, spellName)

	local aura = bucket[key]
	if not aura then
		aura = {}
		bucket[key] = aura
	end

	aura.key      = key
	aura.spellId  = spellId
	aura.name     = spellName
	aura.icon     = Cache.GetIcon(spellId, spellName)
	aura.school   = school
	aura.type     = (auraType == "BUFF") and "BUFF" or "DEBUFF"
	aura.mine     = mine
	aura.count    = (amount and amount > 0) and amount or 1
	aura.applied  = now
	aura.duration = duration
	aura.expires  = duration and (now + duration) or nil
	aura.exact    = false
end

local function RemoveAura(destGUID, spellId, spellName, mine)
	local bucket = destGUID and store[destGUID]
	if not bucket then return end
	bucket[KeyFor(spellId, spellName, mine)] = nil
end

local function SetDose(destGUID, spellId, spellName, mine, amount)
	local bucket = destGUID and store[destGUID]
	if not bucket then return end
	local aura = bucket[KeyFor(spellId, spellName, mine)]
	if aura then aura.count = amount or aura.count end
end

--------------------------------------------------------------------------------
-- combat log
--------------------------------------------------------------------------------

local clFrame = CreateFrame("Frame")
clFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
clFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

clFrame:SetScript("OnEvent", function(self, event, timestamp, subEvent,
	srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags,
	spellId, spellName, spellSchool, auraType, amount)

	if event == "PLAYER_REGEN_ENABLED" then
		-- leaving combat: drop everything that is no longer relevant
		local now = GetTime()
		for guid, t in pairs(touched) do
			if now - t > 5 then Auras.Wipe(guid) end
		end
		return
	end

	-- keep the identity cache fed while we are here
	if srcName then Cache.OnCombatLogUnit(srcGUID, srcName, srcFlags, spellName) end
	if dstName then Cache.OnCombatLogUnit(dstGUID, dstName, dstFlags, nil) end

	if subEvent == "UNIT_DIED" or subEvent == "UNIT_DESTROYED" or subEvent == "PARTY_KILL" then
		Auras.Wipe(dstGUID)
		Cache.ForgetGUID(dstGUID)
		return
	end

	if not spellName then return end

	local mine = srcFlags and band(srcFlags, AFFILIATION_MINE) > 0 or false

	if subEvent == "SPELL_AURA_APPLIED" or subEvent == "SPELL_AURA_REFRESH" then
		AddAura(dstGUID, spellId, spellName, spellSchool, auraType, amount, mine)

	elseif subEvent == "SPELL_AURA_APPLIED_DOSE" then
		AddAura(dstGUID, spellId, spellName, spellSchool, auraType, amount, mine)

	elseif subEvent == "SPELL_AURA_REMOVED_DOSE" then
		SetDose(dstGUID, spellId, spellName, mine, amount)

	elseif subEvent == "SPELL_AURA_REMOVED"
		or subEvent == "SPELL_AURA_BROKEN"
		or subEvent == "SPELL_AURA_BROKEN_SPELL" then
		RemoveAura(dstGUID, spellId, spellName, mine)
	end
end)

--------------------------------------------------------------------------------
-- periodic pruning
--------------------------------------------------------------------------------

Util.NewTicker(1, function()
	local now = GetTime()
	for guid, bucket in pairs(store) do
		local any = false
		for key, aura in pairs(bucket) do
			if aura.expires and aura.expires <= now then
				bucket[key] = nil
			elseif not aura.expires and (now - aura.applied) > 120 then
				-- unknown duration and very old: assume it fell off
				bucket[key] = nil
			else
				any = true
			end
		end
		if not any and (now - (touched[guid] or 0)) > 30 then
			store[guid] = nil
			touched[guid] = nil
		end
	end
end)

--------------------------------------------------------------------------------
-- exact data from a real unit token
--------------------------------------------------------------------------------

local exactBuffer = {}
local logBuffer   = {}

local function ReadUnitAuras(unit, out)
	local playerGUID = UnitGUID("player")
	local n = 0

	for _, filter in ipairs({ "HARMFUL", "HELPFUL" }) do
		for i = 1, 40 do
			local name, _, icon, count, dispelType, duration, expires, caster,
			      isStealable, _, spellId = UnitAura(unit, i, filter)
			if not name then break end
			n = n + 1
			local a = out[n]
			if not a then a = {}; out[n] = a end
			a.key        = (spellId or name) .. "@" .. tostring(caster)
			a.spellId    = spellId
			a.name       = name
			a.icon       = icon
			a.count      = (count and count > 0) and count or 1
			a.dispelType = dispelType
			a.duration   = (duration and duration > 0) and duration or nil
			a.expires    = (expires and expires > 0) and expires or nil
			a.mine       = (caster == "player" or caster == "pet" or caster == "vehicle")
			a.type       = (filter == "HARMFUL") and "DEBUFF" or "BUFF"
			a.exact      = true
			a.school     = nil
		end
	end

	for i = n + 1, #out do out[i] = nil end
	return n
end

-- Every aura currently tracked for any unit sharing this name. Only used when
-- the profile explicitly asks for name matching: it is what caused one mob's
-- auras to appear on another's nameplate.
local function CollectByName(plateName, out)
	for i = #out, 1, -1 do out[i] = nil end
	local set = Cache.guidsByName[plateName]
	if not set then return out end
	for guid in pairs(set) do
		local bucket = store[guid]
		if bucket then
			for _, aura in pairs(bucket) do out[#out + 1] = aura end
		end
	end
	return out
end

-- Returns an array of aura tables for a plate.
-- `guid` is the unit the plate has been matched to, and is what the tracking is
-- keyed by; without one there is no honest answer and we return nothing.
-- `unitToken` is optional; when supplied the exact API data is used instead.
-- `scratch` must be a table owned by the caller: the exact path writes aura
-- tables into it and `result` holds references to them, so sharing one buffer
-- between plates would let one plate's refresh overwrite another's timers.
function Auras.Collect(guid, plateName, unitToken, result, scratch)
	local db = ns.db.auras
	local now = GetTime()

	for i = #result, 1, -1 do result[i] = nil end
	if not db.enabled then return result end

	local source
	if unitToken and UnitExists(unitToken) then
		local buffer = scratch or exactBuffer
		ReadUnitAuras(unitToken, buffer)
		source = buffer

	elseif guid and store[guid] then
		for i = #logBuffer, 1, -1 do logBuffer[i] = nil end
		for _, aura in pairs(store[guid]) do logBuffer[#logBuffer + 1] = aura end
		source = logBuffer

	elseif db.matching == "name" then
		source = CollectByName(plateName, logBuffer)

	else
		-- No unit matched, and we are not willing to guess. Showing another
		-- unit's auras here is worse than showing none.
		return result
	end

	local n = 0
	for i = 1, #source do
		local aura = source[i]
		if aura and aura.name then
			local pass = true

			if aura.type == "BUFF" and not db.showBuffs then pass = false end
			if aura.type == "DEBUFF" and not db.showDebuffs then pass = false end

			if pass then
				if db.filter == "mine" then
					pass = aura.mine and true or false
				elseif db.filter == "whitelist" then
					pass = db.whitelist[aura.name] and true or false
				end
			end

			if pass and db.blacklist[aura.name] then pass = false end
			if pass and aura.expires and aura.expires <= now then pass = false end

			if pass then
				n = n + 1
				result[n] = aura
			end
		end
	end

	-- shortest remaining first, permanent auras last
	table.sort(result, function(a, b)
		local ea = a.expires or math.huge
		local eb = b.expires or math.huge
		if ea == eb then return (a.name or "") < (b.name or "") end
		return ea < eb
	end)

	for i = db.max + 1, #result do result[i] = nil end
	return result
end

function Auras.GetBorderColor(aura)
	if aura.dispelType and Auras.DispelColors[aura.dispelType] then
		return unpack(Auras.DispelColors[aura.dispelType])
	end
	if aura.school and Auras.SchoolColors[aura.school] then
		return unpack(Auras.SchoolColors[aura.school])
	end
	if aura.type == "BUFF" then return 0.25, 0.75, 0.25 end
	return 0.75, 0.15, 0.15
end
