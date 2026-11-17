-- Minimal World of Warcraft API mock for testing WarriorPilotLite outside the game.
-- It loads the real addon file into a fresh environment and lets tests fire events,
-- run slash commands, move the clock and inspect frames, font strings and chat output.

local M = {}

-- Stand-in for a Midnight-era "secret value": issecretvalue() is true only for this.
M.SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })

local SPELL_NAMES = {
    [2575] = "Mining", [2576] = "Mining", [3564] = "Mining", [10248] = "Mining",
    [2580] = "Find Minerals", [2656] = "Smelting",
    [6673] = "Battle Shout", [11551] = "Battle Shout",
    [7384] = "Overpower", [78] = "Heroic Strike",
    [2481] = "Find Treasure",
    [72] = "Shield Bash", [5242] = "Battle Shout", [6572] = "Revenge", [1160] = "Demoralizing Shout",
}

local function defaultState()
    return {
        now = 1000,
        class = "WARRIOR",
        level = 10, xp = 100, xpMax = 1000,
        health = 100, healthMax = 100,
        rage = 0, rageMax = 100,
        inCombat = false,
        dead = false,
        known = { [6673] = true }, -- Battle Shout
        auras = {},                -- list of { name =, spellId =, expirationTime = }
        durability = {},           -- [slot] = { current, maximum }
        bags = { [0] = { 16, 0 }, [1] = { 10, 0 } }, -- [bag] = { freeSlots, bagType }
        inGroup = false,
        -- Other units by token ("target", "nameplate1", ...): { level, health, healthMax,
        -- classification, guid, hostile, dead, inCombat, threat, targetsPlayer }
        units = {},
        -- Minimap tracking menu: list of { name, spellID, active }.
        tracking = {},
        exclusiveTracking = false, -- Classic rule: turning one on turns the others off
        blockTracking = false,     -- SetTracking is protected: blocked, nothing changes
        casting = nil,             -- name of the spell being cast, or nil
        faction = "Alliance",
        quests = {},          -- quest log: list of { questID, title, complete }
        completedQuests = {}, -- [questID] = true once turned in
        items = {},           -- [itemID] = count in your bags
        talentPoints = 0,
        trainer = nil,        -- TrainerSpellsBuiltin, as the TrainerSpells addon defines it
    }
end

-- Generic UI object: unknown methods are no-ops, known ones record state.
local Methods = {}
local ObjectMT = {
    __index = function(_, key) return Methods[key] or function() end end,
}

local function newObject(kind, name, parent)
    local object = setmetatable({
        kind = kind, name = name, parent = parent,
        scripts = {}, events = {}, shown = true, mouse = true,
    }, ObjectMT)
    if kind == "FontString" then table.insert(M.fontStrings, object) end
    if kind ~= "FontString" and kind ~= "Texture" then table.insert(M.frames, object) end
    if name then _G[name] = object end
    return object
end

function Methods:SetText(text) self.text = text end
function Methods:GetText() return self.text end
function Methods:SetTextColor(r, g, b) self.color = { r, g, b } end
function Methods:SetScript(event, fn) self.scripts[event] = fn end
function Methods:GetScript(event) return self.scripts[event] end
function Methods:RegisterEvent(event) self.events[event] = true end
function Methods:RegisterUnitEvent(event, unit) self.events[event] = unit or true end
function Methods:UnregisterEvent(event) self.events[event] = nil end
function Methods:Show() self.shown = true end
function Methods:Hide() self.shown = false end
function Methods:IsShown() return self.shown end
function Methods:EnableMouse(enabled) self.mouse = enabled and true or false end
function Methods:SetValue(value) self.value = value end
function Methods:SetBackdropBorderColor(r, g, b) self.border = { r, g, b } end
function Methods:SetMinMaxValues(lo, hi) self.min, self.max = lo, hi end
function Methods:GetCenter() return 0, 0 end
function Methods:CreateFontString() return newObject("FontString", nil, self) end
function Methods:CreateTexture() return newObject("Texture", nil, self) end
function Methods:SetPoint(point, a, b, c, d)
    if rawget(self, "point") then return end -- keep the first anchor; enough to identify labels
    if type(a) == "number" then
        self.point = { point, a, b }
    else
        self.point = { point, c or 0, d or 0 }
    end
end

local function installGlobals(db)
    local s = M.state
    _G.WarriorPilotLiteDB = db
    _G.WarriorPilotLiteFrame, _G.WarriorPilotExportPopup = nil, nil
    _G.SlashCmdList = {}
    _G.SLASH_WARRIORPILOTLITE1, _G.SLASH_WARRIORPILOTLITE2 = nil, nil
    _G.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
    _G.ChatFontNormal = {}
    _G.NUM_BAG_SLOTS = 4
    _G.LOOT_ITEM_SELF = "You receive loot: %s."
    _G.LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
    _G.date = os.date

    _G.UIParent = newObject("Frame", "UIParent")
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) table.insert(M.chat, msg) end }
    _G.CreateFrame = function(kind, name, parent) return newObject(kind, name, parent) end

    _G.issecretvalue = function(value) return value == M.SECRET end
    _G.GetTime = function() return s.now end
    _G.GetMaxPlayerLevel = function() return 60 end
    _G.InCombatLockdown = function() return s.inCombat end
    -- Unit functions answer for the player by default and for s.units otherwise.
    local function unit(token, playerValue, field)
        if token == nil or token == "player" then return playerValue end
        local u = s.units[token]
        return u and u[field]
    end
    _G.UnitExists = function(token) return token == "player" or s.units[token] ~= nil end
    _G.UnitCanAttack = function(_, token) local u = s.units[token]; return u ~= nil and u.hostile ~= false end
    _G.UnitIsDead = function(token) return unit(token, s.dead, "dead") or false end
    _G.UnitGUID = function(token) local u = s.units[token]; return u and (u.guid or token) end
    _G.UnitClassification = function(token) return unit(token, "normal", "classification") or "normal" end
    _G.UnitThreatSituation = function(_, token) return unit(token, nil, "threat") end
    _G.UnitIsUnit = function(a, b)
        local base = b == "player" and a:match("^(.+)target$")
        if base then local u = s.units[base]; return u ~= nil and u.targetsPlayer == true end
        return a == b
    end
    _G.IsInGroup = function() return s.inGroup end
    _G.UnitAffectingCombat = function(token) return unit(token, s.inCombat, "inCombat") or false end
    _G.UnitIsDeadOrGhost = function() return s.dead end
    _G.UnitClass = function() return s.class:sub(1, 1) .. s.class:sub(2):lower(), s.class end
    _G.UnitLevel = function(token) return unit(token, s.level, "level") end
    _G.UnitXP = function() return s.xp end
    _G.UnitXPMax = function() return s.xpMax end
    _G.UnitHealth = function(token) return unit(token, s.health, "health") end
    _G.UnitHealthMax = function(token) return unit(token, s.healthMax, "healthMax") or 100 end
    _G.UnitPower = function() return s.rage end
    _G.UnitPowerMax = function() return s.rageMax end
    _G.IsPlayerSpell = function(id) return s.known[id] == true end
    _G.GetInventoryItemDurability = function(slot)
        local d = s.durability[slot]
        if d then return d[1], d[2] end
    end

    _G.C_Spell = { GetSpellName = function(id) return SPELL_NAMES[id] end }
    _G.C_UnitAuras = {
        GetAuraDataByIndex = function(_, index) return s.auras[index] end,
    }
    _G.C_Container = {
        GetContainerNumFreeSlots = function(bag)
            local b = s.bags[bag]
            if b then return b[1], b[2] end
            return 0, 0
        end,
    }
    _G.C_Minimap = {
        GetNumTrackingTypes = function() return #s.tracking end,
        GetTrackingInfo = function(index) return s.tracking[index] end,
        SetTracking = function(index, on)
            table.insert(M.trackingCalls, s.tracking[index].name)
            if s.blockTracking then
                M.fire("ADDON_ACTION_BLOCKED", "WarriorPilotLite", "C_Minimap.SetTracking()")
                return
            end
            if on and s.exclusiveTracking then
                for _, info in ipairs(s.tracking) do info.active = false end
            end
            s.tracking[index].active = on
            -- The game reports the change a moment later, not inside the call.
            table.insert(M.timers, { at = s.now, fn = function() M.fire("MINIMAP_UPDATE_TRACKING") end })
        end,
    }
    _G.UnitFactionGroup = function() return s.faction end
    _G.UnitCharacterPoints = function() return s.talentPoints end
    _G.C_Item = { GetItemCount = function(id) return s.items[id] or 0 end }
    _G.C_QuestLog = {
        GetNumQuestLogEntries = function() return #s.quests end,
        GetInfo = function(index)
            local q = s.quests[index]
            return q and { questID = q.questID, title = q.title, isHeader = false }
        end,
        IsComplete = function(id)
            for _, q in ipairs(s.quests) do if q.questID == id then return q.complete == true end end
            return false
        end,
        IsQuestFlaggedCompleted = function(id) return s.completedQuests[id] == true end,
    }
    _G.TrainerSpellsBuiltin = s.trainer
    _G.UnitCastingInfo = function() return s.casting end
    _G.UnitChannelInfo = function() return nil end
    _G.RaidWarningFrame = {}
    _G.RaidNotice_AddMessage = function(_, text) table.insert(M.alerts, text) end
    _G.SOUNDKIT = { RAID_WARNING = 8959 }
    _G.PlaySound = function(id) table.insert(M.sounds, id) end
    _G.C_Timer = {
        After = function(delay, fn) table.insert(M.timers, { at = s.now + delay, fn = fn }) end,
    }
end

-- Load the addon file fresh. Pass `db` to simulate SavedVariables from a previous run,
-- and `state` to keep the game world (clock, XP, ...) from before a /reload.
function M.load(addonPath, db, overrides, state)
    M.state = state or defaultState()
    for key, value in pairs(overrides or {}) do M.state[key] = value end
    M.frames, M.fontStrings, M.chat, M.timers, M.alerts, M.sounds = {}, {}, {}, {}, {}, {}
    M.trackingCalls = {}
    installGlobals(db)
    local chunk = assert(loadfile(addonPath))
    chunk("WarriorPilotLite", {})
end

function M.fire(event, ...)
    for _, frame in ipairs(M.frames) do
        local handler = frame.scripts.OnEvent
        if frame.events[event] and handler then handler(frame, event, ...) end
    end
end

function M.login(addonPath, db, overrides)
    M.load(addonPath, db, overrides)
    M.fire("PLAYER_ENTERING_WORLD", true, false)
end

function M.reload(addonPath)
    M.fire("PLAYER_LOGOUT")
    M.load(addonPath, _G.WarriorPilotLiteDB, nil, M.state)
    M.fire("PLAYER_ENTERING_WORLD", false, true)
end

-- Log out and back in (not a /reload): the previous session gets archived.
function M.relog(addonPath)
    M.fire("PLAYER_LOGOUT")
    M.load(addonPath, _G.WarriorPilotLiteDB, nil, M.state)
    M.fire("PLAYER_ENTERING_WORLD", true, false)
end

-- Advance the clock, running due C_Timer callbacks and the HUD's 1s OnUpdate.
function M.advance(seconds)
    M.state.now = M.state.now + seconds
    local pending = M.timers
    M.timers = {}
    for _, timer in ipairs(pending) do
        if timer.at <= M.state.now then timer.fn() else table.insert(M.timers, timer) end
    end
    local panel = _G.WarriorPilotLiteFrame
    if panel and panel.scripts.OnUpdate then panel.scripts.OnUpdate(panel, 1) end
end

function M.slash(text)
    M.chat = {}
    _G.SlashCmdList.WARRIORPILOTLITE(text)
    return table.concat(M.chat, "\n")
end

-- Find a font string by its first anchor, e.g. label("TOPLEFT", 18, -278).
function M.label(point, x, y)
    for _, fs in ipairs(M.fontStrings) do
        local p = rawget(fs, "point")
        if p and p[1] == point and p[2] == x and p[3] == y then return fs end
    end
    error(string.format("no label anchored at %s %d,%d", point, x, y), 2)
end

-- The value font string of a HUD metric, found by its caption.
function M.metric(caption)
    for index, fs in ipairs(M.fontStrings) do
        if fs.text == caption then return M.fontStrings[index + 1].text end
    end
    error("no metric captioned " .. caption, 2)
end

function M.frameOfKind(kind)
    for _, frame in ipairs(M.frames) do
        if frame.kind == kind then return frame end
    end
end

return M
