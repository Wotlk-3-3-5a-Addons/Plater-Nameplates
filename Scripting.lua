--[[--------------------------------------------------------------------------
	PlaterWrath - Scripting.lua

	The mod / script engine, modelled on Plater's.

	A mod is a table with up to five Lua hooks. Each hook is stored as source
	text and compiled with loadstring() into a sandboxed function:

	    Initialization  function(modTable)                        -- once, on load
	    Constructor     function(unitFrame, unitName, modTable)   -- once per plate
	    OnShow          function(unitFrame, unitName, modTable)
	    OnUpdate        function(unitFrame, unitName, modTable)
	    OnHide          function(unitFrame, unitName, modTable)
	    OnEvent         function(modTable, event, ...)

	Mods can declare options. Option values live in modTable.config and are
	persisted in the profile, so updating a mod's code never wipes the values
	the user picked - same contract as Plater's options system.

	    modTable.config["option1"]

	Supported option types: text, color, number, toggle, label, blank.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local Util = ns.Util

local Scripting = {}
ns.Scripting = Scripting

Scripting.OPTION_TYPES = { "text", "color", "number", "toggle", "label", "blank" }

local HOOKS = { "Initialization", "Constructor", "OnShow", "OnUpdate", "OnHide", "OnEvent" }
Scripting.HOOKS = HOOKS

-- compiled[modName][hookName] = function
local compiled = {}
-- runtime modTable per mod, persists between plates
local runtime = {}

Scripting.compiled = compiled
Scripting.runtime  = runtime

--------------------------------------------------------------------------------
-- public API handed to scripts
--------------------------------------------------------------------------------

local API = {}
PlaterW = API   -- intentionally global: scripts and macros reach it by name
ns.API = API

function API.GetProfile()
	return ns.db
end

function API.SetNameplateColor(unitFrame, r, g, b)
	if not unitFrame then return end
	unitFrame.scriptColor = { r, g, b }
	if unitFrame.healthBar then unitFrame.healthBar:SetStatusBarColor(r, g, b) end
end

function API.ResetNameplateColor(unitFrame)
	if not unitFrame then return end
	unitFrame.scriptColor = nil
end

function API.SetBorderColor(unitFrame, r, g, b, a)
	if unitFrame and unitFrame.healthBorder then
		unitFrame.scriptBorderColor = { r, g, b, a or 1 }
		unitFrame.healthBorder:SetBackdropBorderColor(r, g, b, a or 1)
	end
end

function API.ResetBorderColor(unitFrame)
	if unitFrame then unitFrame.scriptBorderColor = nil end
end

function API.SetScale(unitFrame, scale)
	if unitFrame then unitFrame.scriptScale = scale end
end

function API.SetAlpha(unitFrame, alpha)
	if unitFrame then unitFrame.scriptAlpha = alpha end
end

function API.SetNameText(unitFrame, text)
	if unitFrame and unitFrame.nameText then
		unitFrame.scriptName = text
		unitFrame.nameText:SetText(text)
	end
end

function API.ResetNameText(unitFrame)
	if unitFrame then unitFrame.scriptName = nil end
end

function API.IsTarget(unitFrame)      return unitFrame and unitFrame.isTarget end
function API.IsMouseover(unitFrame)   return unitFrame and unitFrame.isMouseover end
function API.GetHealth(unitFrame)     return unitFrame and unitFrame.health, unitFrame and unitFrame.maxHealth end
function API.GetHealthPercent(unitFrame)
	if not unitFrame or not unitFrame.maxHealth or unitFrame.maxHealth == 0 then return 0 end
	return unitFrame.health / unitFrame.maxHealth * 100
end
function API.GetUnitType(unitFrame)   return unitFrame and unitFrame.unitType end
-- nil until the plate has been matched to a unit; see the Auras tab
function API.GetGUID(unitFrame)       return unitFrame and unitFrame.unitGUID end
function API.GetReaction(unitFrame)   return unitFrame and unitFrame.reaction end
function API.GetClass(unitFrame)      return unitFrame and unitFrame.unitClass end
function API.IsCasting(unitFrame)     return unitFrame and unitFrame.isCasting end
function API.GetCastInfo(unitFrame)
	if not unitFrame or not unitFrame.isCasting then return nil end
	return unitFrame.castName, unitFrame.castIcon, unitFrame.castNoInterrupt
end
function API.GetThreatSituation(unitFrame) return unitFrame and unitFrame.threatSituation end

function API.GetAuras(unitFrame)
	return unitFrame and unitFrame.auraList or {}
end

function API.HasAura(unitFrame, spellName)
	if not unitFrame or not unitFrame.auraList then return false end
	for i = 1, #unitFrame.auraList do
		if unitFrame.auraList[i].name == spellName then return true, unitFrame.auraList[i] end
	end
	return false
end

function API.ForEachPlate(func)
	if not ns.Core then return end
	for plate, frame in pairs(ns.Core.active) do
		if frame:IsShown() then pcall(func, frame, frame.unitName) end
	end
end

function API.Print(...)
	Util.Print(...)
end

--------------------------------------------------------------------------------
-- compiling
--------------------------------------------------------------------------------

local function BuildEnv(modTable)
	local env = {
		Plater    = API,
		PlaterW   = API,
		modTable  = modTable,
		print     = Util.Print,
	}
	setmetatable(env, { __index = _G, __newindex = function(t, k, v) rawset(t, k, v) end })
	return env
end

local function CompileHook(mod, hookName, env)
	local source = mod.code and mod.code[hookName]
	if not source or strtrim(source) == "" then return nil end

	local chunk, err = loadstring("return " .. source, "PlaterMod:" .. mod.name .. ":" .. hookName)
	if not chunk then
		-- allow a plain statement body too, not just an anonymous function
		local wrapped = "return function(...) " .. source .. " end"
		chunk, err = loadstring(wrapped, "PlaterMod:" .. mod.name .. ":" .. hookName)
	end
	if not chunk then
		Util.Error(mod.name .. " / " .. hookName .. ": " .. tostring(err))
		return nil
	end

	setfenv(chunk, env)
	local ok, fn = pcall(chunk)
	if not ok or type(fn) ~= "function" then
		Util.Error(mod.name .. " / " .. hookName .. ": hook did not return a function")
		return nil
	end
	setfenv(fn, env)
	return fn
end

local eventFrame = CreateFrame("Frame")

function Scripting.CompileAll()
	for k in pairs(compiled) do compiled[k] = nil end
	eventFrame:UnregisterAllEvents()

	local wantedEvents = {}

	for name, mod in pairs(ns.db.mods) do
		mod.name = name
		mod.config = mod.config or {}

		-- make sure every declared option has a value
		if mod.options then
			for _, opt in ipairs(mod.options) do
				if opt.key and opt.type ~= "label" and opt.type ~= "blank" then
					if mod.config[opt.key] == nil then
						mod.config[opt.key] = opt.default
					end
				end
			end
		end

		local modTable = runtime[name]
		if not modTable then
			modTable = {}
			runtime[name] = modTable
		end
		modTable.config = mod.config
		modTable.name   = name

		if mod.enabled then
			local env = BuildEnv(modTable)
			local set = {}
			for _, hook in ipairs(HOOKS) do
				set[hook] = CompileHook(mod, hook, env)
			end
			compiled[name] = set

			if set.Initialization then
				local ok, err = pcall(set.Initialization, modTable)
				if not ok then Util.Error(name .. " / Initialization: " .. tostring(err)) end
			end

			if mod.events then
				for _, ev in ipairs(mod.events) do wantedEvents[ev] = true end
			end
		end
	end

	for ev in pairs(wantedEvents) do
		pcall(eventFrame.RegisterEvent, eventFrame, ev)
	end

	-- plates built before a recompile need their Constructor re-run
	if ns.Core then ns.Core.InvalidateConstructors() end
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
	for name, set in pairs(compiled) do
		local mod = ns.db.mods[name]
		if set.OnEvent and mod and mod.events then
			local wants = false
			for _, ev in ipairs(mod.events) do
				if ev == event then wants = true break end
			end
			if wants then
				local ok, err = pcall(set.OnEvent, runtime[name], event, ...)
				if not ok then Util.Error(name .. " / OnEvent: " .. tostring(err)) end
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- dispatch, called by Core
--------------------------------------------------------------------------------

function Scripting.RunHook(hookName, unitFrame)
	if not next(compiled) then return end
	local unitName = unitFrame.unitName
	for name, set in pairs(compiled) do
		local fn = set[hookName]
		if fn then
			local ok, err = pcall(fn, unitFrame, unitName, runtime[name])
			if not ok then Util.Error(name .. " / " .. hookName .. ": " .. tostring(err)) end
		end
	end
end

function Scripting.HasHook(hookName)
	for _, set in pairs(compiled) do
		if set[hookName] then return true end
	end
	return false
end

--------------------------------------------------------------------------------
-- mod management
--------------------------------------------------------------------------------

function Scripting.NewMod(name)
	if ns.db.mods[name] then return nil, "a mod with that name already exists" end
	ns.db.mods[name] = {
		name    = name,
		enabled = true,
		desc    = "",
		events  = {},
		options = {},
		config  = {},
		code    = {
			Constructor = "function(unitFrame, unitName, modTable)\n\t\nend",
			OnUpdate    = "function(unitFrame, unitName, modTable)\n\t\nend",
		},
	}
	Scripting.CompileAll()
	return ns.db.mods[name]
end

function Scripting.DeleteMod(name)
	ns.db.mods[name] = nil
	runtime[name] = nil
	compiled[name] = nil
	Scripting.CompileAll()
end

--------------------------------------------------------------------------------
-- import / export
--------------------------------------------------------------------------------

local function Serialize(value, indent)
	indent = indent or ""
	local t = type(value)
	if t == "string" then
		return string.format("%q", value)
	elseif t == "number" or t == "boolean" then
		return tostring(value)
	elseif t == "table" then
		local parts = { "{\n" }
		local nextIndent = indent .. "\t"
		-- array part first for readability
		local arrayMax = 0
		for i, v in ipairs(value) do
			parts[#parts + 1] = nextIndent .. Serialize(v, nextIndent) .. ",\n"
			arrayMax = i
		end
		local keys = {}
		for k in pairs(value) do
			if not (type(k) == "number" and k >= 1 and k <= arrayMax and math.floor(k) == k) then
				keys[#keys + 1] = k
			end
		end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, k in ipairs(keys) do
			local keyStr
			if type(k) == "string" and k:match("^[%a_][%w_]*$") then
				keyStr = k
			else
				keyStr = "[" .. Serialize(k, nextIndent) .. "]"
			end
			parts[#parts + 1] = nextIndent .. keyStr .. " = " .. Serialize(value[k], nextIndent) .. ",\n"
		end
		parts[#parts + 1] = indent .. "}"
		return table.concat(parts)
	end
	return "nil"
end

Scripting.Serialize = Serialize

function Scripting.Export(name)
	local mod = ns.db.mods[name]
	if not mod then return nil end
	local copy = Util.CopyTable(mod)
	copy.config = nil   -- never export the user's own values
	return "PlaterWrathMod1 " .. Serialize(copy)
end

function Scripting.Import(text, overwriteName)
	if not text then return nil, "nothing to import" end
	text = strtrim(text)
	text = text:gsub("^PlaterWrathMod1%s+", "")

	local chunk, err = loadstring("return " .. text)
	if not chunk then return nil, "could not parse: " .. tostring(err) end
	setfenv(chunk, {})
	local ok, mod = pcall(chunk)
	if not ok or type(mod) ~= "table" or not mod.code then
		return nil, "that does not look like a PlaterWrath mod"
	end

	local name = overwriteName or mod.name or "Imported Mod"
	local existing = ns.db.mods[name]

	mod.name = name
	mod.enabled = (mod.enabled ~= false)
	mod.options = mod.options or {}
	mod.events  = mod.events or {}

	-- keep the values the user already chose (Plater's update contract)
	mod.config = existing and existing.config or {}

	ns.db.mods[name] = mod
	Scripting.CompileAll()
	return name
end

function Scripting.ExportProfile()
	local copy = Util.CopyTable(ns.db)
	return "PlaterWrathProfile1 " .. Serialize(copy)
end

function Scripting.ImportProfile(text, profileName)
	if not text then return nil, "nothing to import" end
	text = strtrim(text):gsub("^PlaterWrathProfile1%s+", "")
	local chunk, err = loadstring("return " .. text)
	if not chunk then return nil, "could not parse: " .. tostring(err) end
	setfenv(chunk, {})
	local ok, profile = pcall(chunk)
	if not ok or type(profile) ~= "table" or not profile.units then
		return nil, "that does not look like a PlaterWrath profile"
	end
	profileName = profileName or ns.Config.GetActiveProfile()
	PlaterWrathDB.profiles[profileName] = Util.ApplyDefaults(profile, ns.defaults)
	ns.Config.SetProfile(profileName)
	return profileName
end

--------------------------------------------------------------------------------
-- shipped example mods (disabled by default, they exist to be read)
--------------------------------------------------------------------------------

function Scripting.InstallExamples()
	local examples = {
		["Example - Execute Range Glow"] = {
			enabled = false,
			desc    = "Turns the health bar a chosen color once the target drops below a health percentage. Demonstrates number and color options.",
			events  = {},
			options = {
				{ key = "label1",    type = "label",  label = "Execute Range Glow" },
				{ key = "threshold", type = "number", label = "Health percent",  desc = "Color the bar below this percent.", default = 20, min = 1, max = 99 },
				{ key = "color",     type = "color",  label = "Bar color",       default = { 0.7, 0.1, 0.7 } },
				{ key = "blank1",    type = "blank" },
				{ key = "onlyEnemy", type = "toggle", label = "Enemies only",    default = true },
			},
			code = {
				OnUpdate = [[function(unitFrame, unitName, modTable)
	local cfg = modTable.config
	if cfg.onlyEnemy and unitFrame.reaction == "friendly" then return end

	local percent = Plater.GetHealthPercent(unitFrame)
	if percent > 0 and percent <= cfg.threshold then
		local c = cfg.color
		Plater.SetNameplateColor(unitFrame, c[1], c[2], c[3])
	else
		Plater.ResetNameplateColor(unitFrame)
	end
end]],
			},
		},

		["Example - Highlight Named Mobs"] = {
			enabled = false,
			desc    = "Scales up and recolors any nameplate whose name is in the list. Demonstrates a text option parsed into a lookup table in Initialization.",
			events  = {},
			options = {
				{ key = "names", type = "text",   label = "Mob names",  desc = "Comma separated.", default = "Explosive Ooze, Shadowmoon Warlock" },
				{ key = "color", type = "color",  label = "Highlight",  default = { 1, 0.3, 0.9 } },
				{ key = "scale", type = "number", label = "Scale",      default = 130, min = 50, max = 250 },
			},
			code = {
				Initialization = [[function(modTable)
	modTable.lookup = {}
	for word in string.gmatch(modTable.config.names or "", "[^,]+") do
		modTable.lookup[strtrim(word)] = true
	end
end]],
				OnUpdate = [[function(unitFrame, unitName, modTable)
	if modTable.lookup and modTable.lookup[unitName] then
		local c = modTable.config.color
		Plater.SetNameplateColor(unitFrame, c[1], c[2], c[3])
		Plater.SetScale(unitFrame, modTable.config.scale / 100)
	end
end]],
			},
		},
	}

	local installed = 0
	for name, mod in pairs(examples) do
		if not ns.db.mods[name] then
			mod.name = name
			mod.config = {}
			ns.db.mods[name] = mod
			installed = installed + 1
		end
	end
	if installed > 0 then Scripting.CompileAll() end
	return installed
end
