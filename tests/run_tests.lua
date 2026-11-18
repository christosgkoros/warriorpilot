-- WarriorPilotLite test suite. Run from anywhere with:
--   luajit tests/run_tests.lua
-- (LuaJIT speaks Lua 5.1, the same dialect as the WoW client.)

local dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = dir .. "/?.lua;" .. package.path
local wow = require("wowmock")
local ADDON = dir .. "/../WarriorPilotLite.lua"

local tests = {}
local function test(name, fn) tests[#tests+1] = { name = name, fn = fn } end

local function fail(msg, level) error(msg, (level or 1) + 2) end
local function eq(actual, expected, what)
    if actual ~= expected then
        fail(string.format("%s: expected %q, got %q", what or "value", tostring(expected), tostring(actual)))
    end
end
local function has(text, needle, what)
    if type(text) ~= "string" or not text:find(needle, 1, true) then
        fail(string.format("%s: expected to contain %q, got %q", what or "text", needle, tostring(text)))
    end
end
local function hasNot(text, needle, what)
    if type(text) == "string" and text:find(needle, 1, true) then
        fail(string.format("%s: expected NOT to contain %q, got %q", what or "text", needle, text))
    end
end

-- HUD labels, by anchor (see BuildPanel).
local function ttl() return wow.label("TOPRIGHT", -18, -105).text end
local function sources() return wow.label("TOPLEFT", 18, -256).text end
local function ready() return wow.label("TOPLEFT", 18, -278).text end
local function tip() return wow.label("CENTER", 0, 0).text end
local RECENT = "XP / HOUR (LAST 10 MIN)"

local function login(overrides) wow.login(ADDON, nil, overrides) end
local function gainXP(newXP)
    wow.state.xp = newXP
    wow.fire("PLAYER_XP_UPDATE", "player")
end
local function levelUp(level, xp, xpMax)
    wow.state.level, wow.state.xp, wow.state.xpMax = level, xp, xpMax
end
local function shoutActive(secondsLeft)
    wow.state.auras = { { name = "Battle Shout", spellId = 6673, expirationTime = wow.state.now + secondsLeft } }
end
local function loot(itemID, name, count)
    local link = string.format("|cffffffff|Hitem:%d::::::::|h[%s]|h|r", itemID, name)
    return "You receive loot: " .. link .. (count and ("x" .. count) or "") .. "."
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------

test("builds the HUD for a Warrior and registers slash commands", function()
    login()
    assert(_G.WarriorPilotLiteFrame, "panel not created")
    assert(_G.SlashCmdList.WARRIORPILOTLITE, "slash command not registered")
    eq(_G.SLASH_WARRIORPILOTLITE1, "/wpl", "slash alias")
end)

test("stays disabled for other classes", function()
    login({ class = "MAGE" })
    eq(_G.WarriorPilotLiteFrame, nil, "panel")
    eq(_G.SlashCmdList.WARRIORPILOTLITE, nil, "slash command")
    has(table.concat(wow.chat, "\n"), "designed for Warriors", "chat")
end)

test("takes the XP baseline at PLAYER_ENTERING_WORLD, not at file load", function()
    wow.load(ADDON, nil, { xp = 0 }) -- XP not loaded yet when the file runs
    wow.state.xp = 500
    wow.fire("PLAYER_ENTERING_WORLD", true, false)
    gainXP(600)
    eq(wow.metric("SESSION XP"), "100", "session XP")
end)

test("registers power and spellcast events for the player only", function()
    login()
    local events
    for _, frame in ipairs(wow.frames) do
        if frame.events.PLAYER_XP_UPDATE then events = frame.events end
    end
    eq(events.UNIT_POWER_UPDATE, "player", "UNIT_POWER_UPDATE")
    eq(events.UNIT_SPELLCAST_SUCCEEDED, "player", "UNIT_SPELLCAST_SUCCEEDED")
    eq(events.UNIT_AURA, "player", "UNIT_AURA")
end)

test("defaults the HUD away from screen center", function()
    login()
    local p = rawget(_G.WarriorPilotLiteFrame, "point")
    eq(p[2], -420, "x"); eq(p[3], 120, "y")
end)

---------------------------------------------------------------------------
-- XP tracking
---------------------------------------------------------------------------

test("counts XP gains", function()
    login()
    gainXP(400)
    eq(wow.metric("SESSION XP"), "300", "session XP")
end)

test("counts XP across a level-up", function()
    login()
    gainXP(900)
    levelUp(11, 50, 1200)
    wow.fire("PLAYER_XP_UPDATE", "player")
    eq(wow.metric("SESSION XP"), "950", "session XP") -- 800 + (1000-900) + 50
end)

test("ignores stale XP right after a level-up until XP max changes", function()
    login()
    gainXP(900)
    levelUp(11, 50, 1000) -- level updated, XP max not yet
    wow.fire("PLAYER_XP_UPDATE", "player")
    eq(wow.metric("SESSION XP"), "800", "after stale update")
    wow.state.xpMax = 1200
    wow.fire("PLAYER_XP_UPDATE", "player")
    eq(wow.metric("SESSION XP"), "950", "after real update")
end)

test("credits level-up XP shortly after PLAYER_LEVEL_UP without another XP event", function()
    login()
    gainXP(900)
    levelUp(11, 50, 1200)
    wow.fire("PLAYER_LEVEL_UP", 11)
    wow.advance(1)
    eq(wow.metric("SESSION XP"), "950", "session XP")
end)

test("ignores an XP drop without a level change", function()
    login()
    gainXP(400)
    gainXP(50)
    eq(wow.metric("SESSION XP"), "300", "session XP")
end)

test("shows recent XP/hour and time to level", function()
    login()
    wow.advance(300)
    gainXP(400) -- 300 XP in 5 minutes = 3600/h
    eq(wow.metric(RECENT), "3.6k", "recent XP/hour")
    eq(ttl(), "Level in 10m", "time to level") -- 600 XP left at 3600/h
end)

test("drops old XP from the 10-minute window and falls back to the session average", function()
    login()
    wow.advance(300)
    gainXP(400)
    wow.advance(700) -- the gain is now 11+ minutes old
    eq(wow.metric(RECENT), "0", "recent XP/hour")
    -- Session average: 300 XP / 1000 s = 1080/h; 600 XP left = 2000 s = 34 min.
    eq(ttl(), "Level in 34m", "time to level")
end)

test("hides time to level at max level and shows -- with no XP yet", function()
    login()
    eq(ttl(), "Level in --", "no XP yet")
    wow.state.level = 60
    wow.advance(1)
    eq(ttl(), "", "max level")
end)

test("splits quest XP from kill XP", function()
    login()
    wow.fire("QUEST_TURNED_IN", 123, 250, 0)
    gainXP(350)
    has(sources(), "quests 250", "sources")
    has(sources(), "kills & other 0", "sources")
    gainXP(450)
    has(sources(), "kills & other 100", "sources")
end)

test("ignores secret quest XP rewards", function()
    login()
    wow.fire("QUEST_TURNED_IN", 123, wow.SECRET, 0)
    has(sources(), "quests 0", "sources")
end)

---------------------------------------------------------------------------
-- Persistence and history
---------------------------------------------------------------------------

test("keeps the session across /reload", function()
    login()
    gainXP(400)
    wow.advance(120)
    wow.reload(ADDON)
    eq(wow.metric("SESSION XP"), "300", "session XP after reload")
    has(wow.slash("stats"), "Session: 02:0", "session clock continues")
    eq(_G.WarriorPilotLiteDB.history, nil, "nothing archived on reload")
end)

test("archives the session on a fresh login and starts a new one", function()
    login()
    gainXP(400)
    wow.advance(600)
    wow.relog(ADDON)
    eq(wow.metric("SESSION XP"), "0", "new session XP")
    local history = _G.WarriorPilotLiteDB.history
    eq(#history, 1, "history length")
    eq(history[1].xpGained, 300, "archived XP")
    eq(history[1].duration, 600, "archived duration")
    has(wow.slash("history"), "XP 300", "history output")
end)

test("does not archive short empty sessions", function()
    login()
    wow.advance(60)
    wow.relog(ADDON)
    eq(_G.WarriorPilotLiteDB.history, nil, "history")
end)

test("/wpl reset archives the current session", function()
    login()
    gainXP(400)
    has(wow.slash("reset"), "archived", "reset output")
    eq(#_G.WarriorPilotLiteDB.history, 1, "history length")
    eq(wow.metric("SESSION XP"), "0", "session XP")
end)

test("caps history at 100 sessions, dropping the oldest", function()
    local history = {}
    for i = 1, 100 do history[i] = { xpGained = i, duration = 600 } end
    local db = { history = history, session = { xpGained = 999, duration = 600 } }
    wow.login(ADDON, db)
    eq(#db.history, 100, "history length")
    eq(db.history[1].xpGained, 2, "oldest dropped")
    eq(db.history[100].xpGained, 999, "newest appended")
end)

test("restores a session saved by 1.1.0 without the newer fields", function()
    local db = { session = {
        xpGained = 10, duration = 50, startedAt = 1, lastXP = 100, lastXPMax = 1000,
        lastLevel = 10, deaths = 0, miningCasts = 0, oreLooted = 0, ores = {},
    } }
    wow.load(ADDON, db)
    wow.fire("PLAYER_ENTERING_WORLD", false, true)
    has(sources(), "quests 0", "sources")
    eq(wow.metric(RECENT), "0", "recent XP/hour")
end)

---------------------------------------------------------------------------
-- Time per level
---------------------------------------------------------------------------

test("records time, XP and deaths per level", function()
    login()
    wow.advance(600)
    levelUp(11, 50, 1200)
    wow.fire("PLAYER_LEVEL_UP", 11)
    wow.advance(1)
    local levels = _G.WarriorPilotLiteDB.levels
    eq(levels[10].seconds, 600, "level 10 time")
    eq(levels[10].partial, true, "level 10 seen mid-way")
    eq(levels[10].xp, 900, "level 10 XP")
    eq(levels[11].partial, false, "level 11 seen from the start")
    eq(levels[11].xp, 50, "level 11 XP")

    wow.advance(300)
    wow.fire("PLAYER_DEAD")
    wow.fire("QUEST_TURNED_IN", 1, 200, 0)
    eq(levels[11].deaths, 1, "level 11 deaths")
    eq(levels[11].questXP, 200, "level 11 quest XP")
    local out = wow.slash("levels")
    has(out, "Level 10*: 10:00", "levels output")
    has(out, "Level 11: 05:01", "levels output")
end)

test("does not double-count level time across /reload", function()
    login()
    wow.advance(300)
    wow.reload(ADDON)
    wow.advance(100)
    wow.slash("levels") -- flushes the running stretch
    eq(_G.WarriorPilotLiteDB.levels[10].seconds, 400, "level 10 time")
end)

test("exports session and per-level data", function()
    login()
    wow.fire("QUEST_TURNED_IN", 1, 200, 0)
    gainXP(300)
    wow.slash("export")
    local text = wow.frameOfKind("EditBox").text
    has(text, "QuestXP=200", "export")
    has(text, "RecentXPPerHour=", "export")
    has(text, "Levels(level:seconds:xp:questXP:deaths)=10*:", "export")
end)

---------------------------------------------------------------------------
-- Mining and ore
---------------------------------------------------------------------------

test("counts mining casts of any rank by spell name", function()
    login()
    wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 2575)
    wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 10248)
    eq(wow.metric("MINING CASTS"), "2", "mining casts")
end)

test("ignores Smelting, Find Minerals, other units and secret spell IDs", function()
    login()
    wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 2656)
    wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 2580)
    wow.fire("UNIT_SPELLCAST_SUCCEEDED", "party1", "guid", 2575)
    wow.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", wow.SECRET)
    eq(wow.metric("MINING CASTS"), "0", "mining casts")
end)

test("counts ore from your own loot messages", function()
    login()
    wow.fire("CHAT_MSG_LOOT", loot(2770, "Copper Ore", 3))
    wow.fire("CHAT_MSG_LOOT", loot(2771, "Tin Ore"))
    wow.fire("CHAT_MSG_LOOT", loot(3340, "Incendicite Ore", 2))
    local out = wow.slash("stats")
    has(out, "ore looted 6", "stats")
    has(out, "Copper 3", "breakdown")
    has(out, "Incendicite 2", "breakdown")
end)

test("ignores other players' loot, non-ore items and secret messages", function()
    login()
    local copper = string.format("|cffffffff|Hitem:%d::::::::|h[%s]|h|r", 2770, "Copper Ore")
    wow.fire("CHAT_MSG_LOOT", "Bob receives loot: " .. copper .. "x5.")
    wow.fire("CHAT_MSG_LOOT", loot(2589, "Linen Cloth", 2))
    wow.fire("CHAT_MSG_LOOT", wow.SECRET)
    has(wow.slash("stats"), "ore looted 0", "stats")
end)

---------------------------------------------------------------------------
-- Readiness
---------------------------------------------------------------------------

test("says Ready to pull when everything is fine", function()
    login()
    shoutActive(120)
    wow.advance(1)
    eq(ready(), "Ready to pull", "readiness")
end)

test("warns when Battle Shout is missing or ending", function()
    login()
    wow.advance(1)
    eq(ready(), "Battle Shout missing", "missing")
    shoutActive(10)
    wow.advance(1)
    eq(ready(), "Battle Shout ending", "ending")
end)

test("skips the Battle Shout check when unknown or unreadable", function()
    login({ known = {} })
    wow.advance(1)
    eq(ready(), "Ready to pull", "spell not known")
    wow.state.known = { [6673] = true }
    wow.state.auras = { { name = wow.SECRET, expirationTime = wow.SECRET } }
    wow.advance(1)
    eq(ready(), "Ready to pull", "secret aura")
end)

test("warns about low health, worn gear and full bags together", function()
    login({ health = 40, durability = { [16] = { 10, 100 }, [5] = { 80, 100 } },
            bags = { [0] = { 2, 0 }, [1] = { 20, 0x0400 } } }) -- bag 1 is a profession bag
    shoutActive(120)
    wow.advance(1)
    eq(ready(), "Eat/bandage (40% HP)  ·  Repair soon (10%)  ·  Bags: 2 free", "readiness")
end)

test("flags broken gear and ignores secret health", function()
    login({ health = wow.SECRET, durability = { [1] = { 0, 50 } } })
    shoutActive(120)
    wow.advance(1)
    eq(ready(), "Broken gear!", "readiness")
end)

test("shows the fight verdict during fights and updates as soon as combat ends", function()
    login()
    shoutActive(120)
    wow.state.inCombat = true
    wow.fire("PLAYER_REGEN_DISABLED")
    eq(ready(), "Fight looks OK", "in combat")
    wow.state.inCombat = false
    wow.fire("PLAYER_REGEN_ENABLED")
    eq(ready(), "Ready to pull", "after combat")
end)

test("updates right away when a buff drops out of combat", function()
    login()
    shoutActive(120)
    wow.advance(1)
    wow.state.auras = {}
    wow.fire("UNIT_AURA", "player")
    eq(ready(), "Battle Shout missing", "readiness")
end)

test("shows nothing while dead", function()
    login({ dead = true })
    wow.advance(1)
    eq(ready(), "", "readiness")
end)

---------------------------------------------------------------------------
-- Fight danger / flee warning
---------------------------------------------------------------------------

local RED = { 1.0, 0.25, 0.22 }
local function mob(fields)
    local u = { level = 10, health = 100, healthMax = 100, guid = "mob", inCombat = true, threat = 3 }
    for k, v in pairs(fields or {}) do u[k] = v end
    return u
end
local function pull(target, overrides)
    login(overrides)
    shoutActive(120)
    wow.state.units.target = target
    wow.state.inCombat = true
    wow.fire("PLAYER_REGEN_DISABLED")
end
-- One second of fighting: you lose `myLoss`% health, the target `theirLoss`%.
local function trade(myLoss, theirLoss, seconds)
    for _ = 1, seconds or 1 do
        wow.state.health = wow.state.health - myLoss
        local t = wow.state.units.target
        if t.health ~= wow.SECRET then t.health = t.health - theirLoss end
        wow.advance(1)
    end
end
local function border() return _G.WarriorPilotLiteFrame.border end

test("says flee when you are losing the health race, and alerts once", function()
    pull(mob())
    trade(8, 4, 5) -- you: 60% at 8%/s, target: 80% at 4%/s
    eq(ready(), "FLEE! You die in ~8s, enemies in ~20s", "verdict")
    eq(border()[1], RED[1], "border turns red")
    eq(#wow.alerts, 1, "center-screen alert")
    eq(#wow.sounds, 1, "alert sound")
    trade(8, 4, 2)
    eq(#wow.alerts, 1, "alerts only once per fight")
end)

test("says winning when the target drops faster", function()
    pull(mob())
    trade(2, 10, 5)
    has(ready(), "Winning: you ~", "verdict")
    eq(#wow.alerts, 0, "no alert")
end)

test("says winning when you are not losing health", function()
    pull(mob())
    trade(0, 10, 4)
    eq(ready(), "Winning", "verdict")
end)

test("calls an even trade a close fight", function()
    pull(mob())
    trade(5, 5, 5)
    eq(ready(), "Close fight: you ~15s, enemies ~15s", "verdict")
end)

test("counts every enemy on you, not just the target", function()
    pull(mob())
    trade(5, 10, 5) -- alone this is a clear win: 15 s vs 5 s
    has(ready(), "Winning", "one enemy")

    pull(mob())
    wow.state.units.nameplate1 = mob({ guid = "mob" })
    wow.state.units.nameplate2 = mob({ guid = "add1", threat = nil, targetsPlayer = true })
    wow.state.units.nameplate3 = mob({ guid = "add2" })
    wow.state.units.nameplate4 = mob({ guid = "bystander", inCombat = false })
    trade(5, 10, 5) -- three enemies: (50 + 200) / 10 = 25 s to kill them all
    eq(ready(), "FLEE! You die in ~14s, enemies in ~25s", "three enemies") -- first reading was 1 enemy
end)

test("warns at the pull about many enemies, before any health data", function()
    pull(mob())
    for i = 1, 4 do wow.state.units["nameplate" .. i] = mob({ guid = "m" .. i }) end
    wow.advance(1)
    eq(ready(), "FLEE! 4 enemies on you", "four enemies")
    eq(#wow.alerts, 1, "alert")

    pull(mob())
    wow.state.units.nameplate1 = mob({ guid = "a" })
    wow.state.units.nameplate2 = mob({ guid = "b" })
    wow.advance(1)
    eq(ready(), "Risky: 2 enemies", "two enemies")
end)

-- `count` adds show up on nameplates 2.. (nameplate1 is the first mob).
local function addsJoin(count)
    for i = 2, count + 1 do wow.state.units["nameplate" .. i] = mob({ guid = "add" .. i }) end
end

test("judges flee the moment adds join, from the damage one mob was doing", function()
    pull(mob())
    wow.state.units.nameplate1 = mob({ guid = "mob" })
    trade(3, 10, 4)
    has(ready(), "Winning", "one enemy")
    eq(#wow.alerts, 0, "no alert yet")

    addsJoin(2)
    trade(9, 10, 1) -- 3%/s per mob, now three of them
    eq(wow.alerts[1], "+2 adds! " .. ready(), "adds alert carries the verdict")
    has(ready(), "FLEE! You die in ~", "verdict")
    eq(#wow.sounds, 1, "alert sound")
    trade(9, 10, 2)
    eq(#wow.alerts, 1, "no second flee alert")
end)

test("says fight on when you can still win against the adds", function()
    pull(mob())
    wow.state.units.nameplate1 = mob({ guid = "mob" })
    trade(1, 15, 4)
    addsJoin(2)
    trade(3, 15, 1)
    has(wow.alerts[1], "+2 adds! Winning: you ~", "adds alert")
    eq(border()[1], 0.32, "border stays normal")
end)

test("adds alerts ignore flickering nameplates and groups", function()
    pull(mob())
    wow.state.units.nameplate1 = mob({ guid = "mob" })
    trade(1, 5, 4)
    addsJoin(1)
    wow.advance(1)
    eq(#wow.alerts, 1, "one add")
    wow.state.units.nameplate2 = nil
    wow.advance(1)
    addsJoin(1)
    wow.advance(1)
    eq(#wow.alerts, 1, "a flickering nameplate doesn't re-alert")
    addsJoin(2)
    wow.advance(1)
    eq(#wow.alerts, 2, "a genuinely new add alerts")

    pull(mob(), { inGroup = true })
    wow.state.units.nameplate1 = mob({ guid = "mob" })
    addsJoin(2)
    wow.advance(1)
    eq(#wow.alerts, 0, "no adds alert in a group")
end)

test("flags a skull-level target as flee right away", function()
    pull(mob({ level = -1 }))
    eq(ready(), "FLEE! Skull-level target", "verdict")
    trade(1, 10, 5)
    eq(ready(), "FLEE! Skull-level target", "health trend doesn't override a skull")
end)

test("flags solo elites and higher-level mobs, but not elites in a group", function()
    pull(mob({ level = 12, classification = "elite" }))
    eq(ready(), "FLEE! elite +2", "solo elite +2")
    pull(mob({ level = 10, classification = "elite" }))
    eq(ready(), "Risky: elite", "solo elite")
    pull(mob({ level = 13 }))
    eq(ready(), "Risky: +3 levels", "normal +3")
    pull(mob({ level = 12, classification = "elite" }), { inGroup = true })
    eq(ready(), "Fight looks OK", "elite in a group")
end)

test("keeps pull risks as context next to a winning trend", function()
    pull(mob({ level = 10, classification = "elite" }))
    trade(2, 10, 5)
    has(ready(), "Winning: you ~", "verdict")
    has(ready(), "·  elite", "context")
end)

test("restarts the target's history when you switch targets", function()
    pull(mob())
    trade(5, 10, 5)
    wow.state.units.target = mob({ guid = "other" })
    wow.advance(1)
    eq(ready(), "Fight looks OK", "no prediction yet for the new target")
end)

test("says flee on low health when no prediction is possible", function()
    pull(nil, { health = 25 })
    eq(ready(), "FLEE! Health at 25%", "verdict")
end)

test("stays neutral when health is secret", function()
    pull(mob({ health = wow.SECRET }), { health = wow.SECRET })
    wow.advance(5)
    eq(ready(), "In combat", "verdict")
    eq(#wow.alerts, 0, "no alert")
end)

test("ignores a secret target health and still judges the pull", function()
    pull(mob({ health = wow.SECRET, level = 13 }))
    trade(8, 0, 5)
    eq(ready(), "Risky: +3 levels", "verdict")
end)

test("resets the border and alert after the fight", function()
    pull(mob({ level = -1 }))
    eq(#wow.alerts, 1, "first fight alert")
    wow.state.inCombat = false
    wow.fire("PLAYER_REGEN_ENABLED")
    eq(ready(), "Ready to pull", "after combat")
    eq(border()[1], 0.32, "border back to normal")
    wow.state.inCombat = true
    wow.fire("PLAYER_REGEN_DISABLED")
    eq(#wow.alerts, 2, "next fight alerts again")
end)

---------------------------------------------------------------------------
-- Minimap tracking
---------------------------------------------------------------------------

local function trackingMenu(withTreasure)
    local menu = {
        { name = "Find Herbs", spellID = 2383, active = false },
        { name = "Find Minerals", spellID = 2580, active = false },
    }
    if withTreasure then menu[#menu+1] = { name = "Find Treasure", spellID = 2481, active = false } end
    return menu
end
local function tracked(name)
    for _, info in ipairs(wow.state.tracking) do
        if info.name == name then return info.active end
    end
end

test("turns Find Minerals and Find Treasure on at login, one per global cooldown", function()
    login({ tracking = trackingMenu(true) })
    eq(tracked("Find Minerals"), true, "minerals right away")
    eq(tracked("Find Treasure"), false, "treasure waits for the GCD")
    wow.advance(2)
    eq(tracked("Find Treasure"), true, "treasure")
    eq(tracked("Find Herbs"), false, "other types untouched")
    wow.advance(10)
    eq(#wow.trackingCalls, 2, "nothing more to do")
end)

test("only uses the tracking types this character has", function()
    login({ tracking = trackingMenu(false) })
    wow.advance(3)
    eq(tracked("Find Minerals"), true, "minerals")
    eq(#wow.trackingCalls, 1, "no Find Treasure to turn on")
end)

test("turns tracking back on after combat, death or switching it off by hand", function()
    login({ tracking = trackingMenu(true) })
    wow.advance(2)

    wow.state.inCombat = true
    wow.fire("PLAYER_REGEN_DISABLED")
    wow.state.tracking[2].active = false
    wow.fire("MINIMAP_UPDATE_TRACKING")
    wow.advance(6)
    eq(tracked("Find Minerals"), false, "left alone in combat")
    wow.state.inCombat = false
    wow.fire("PLAYER_REGEN_ENABLED")
    eq(tracked("Find Minerals"), true, "back on after combat")

    wow.advance(6)
    wow.state.dead = true
    wow.state.tracking[2].active, wow.state.tracking[3].active = false, false
    wow.fire("MINIMAP_UPDATE_TRACKING")
    eq(tracked("Find Minerals"), false, "not while dead")
    wow.state.dead = false
    wow.fire("PLAYER_UNGHOST")
    wow.advance(2)
    eq(tracked("Find Minerals"), true, "minerals after reviving")
    eq(tracked("Find Treasure"), true, "treasure after reviving")
end)

test("never interrupts a cast to turn tracking on", function()
    login({ tracking = trackingMenu(true), casting = "Mining" })
    eq(tracked("Find Minerals"), false, "waits during the cast")
    wow.state.casting = nil
    wow.advance(1)
    eq(tracked("Find Minerals"), true, "after the cast")
end)

test("keeps only Find Minerals when the game allows one tracking type at a time", function()
    login({ tracking = trackingMenu(true), exclusiveTracking = true })
    wow.chat = {}
    for _ = 1, 60 do wow.advance(1) end
    eq(tracked("Find Minerals"), true, "minerals wins")
    eq(tracked("Find Treasure"), false, "treasure given up")
    local calls = #wow.trackingCalls
    for _ = 1, 60 do wow.advance(1) end
    eq(#wow.trackingCalls, calls, "stops switching back and forth")
    has(table.concat(wow.chat, "\n"), "keeping Find Minerals on", "explains once")
end)

test("/wpl track stops changing tracking, and turns it back on", function()
    login({ tracking = trackingMenu(true) })
    has(wow.slash("track"), "No longer changing", "off")
    wow.advance(5)
    eq(tracked("Find Treasure"), false, "left off")
    has(wow.slash("track"), "Keeping Find Minerals", "on")
    wow.advance(2)
    eq(tracked("Find Treasure"), true, "turned on again")
    wow.reload(ADDON)
    eq(_G.WarriorPilotLiteDB.keepTracking, true, "setting saved")
end)

test("reminds instead when the game blocks switching tracking", function()
    login({ tracking = trackingMenu(true), blockTracking = true })
    wow.advance(5)
    eq(#wow.trackingCalls, 1, "tries once")
    has(ready(), "Find Minerals off", "reminder")
    has(ready(), "Find Treasure off", "reminder")
end)

---------------------------------------------------------------------------
-- Next steps guide
---------------------------------------------------------------------------

local TRAINER = { WARRIOR = {
    [1] = { [6673] = { cost = 10, rank = 1 } },
    [12] = { [72] = { cost = 900, rank = 1 }, [5242] = { cost = 900, rank = 2 }, [7384] = { cost = 900, rank = 1 } },
    [14] = { [6572] = { cost = 1100, rank = 1 }, [1160] = { cost = 1100, rank = 1 } },
} }
-- The HUD's NEXT STEPS lines, top to bottom, without color codes.
local function steps()
    local lines = {}
    for i = 1, 4 do
        local text = wow.label("TOPLEFT", 18, -303 - 15 * i).text or ""
        lines[i] = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    end
    return lines
end
local function stepsText() return table.concat(steps(), "\n") end
local function level12(overrides)
    local state = { level = 12, trainer = TRAINER }
    for k, v in pairs(overrides or {}) do state[k] = v end
    login(state)
end

test("lists trainer skills you can learn now, with the cost, and the zone", function()
    level12()
    local lines = steps()
    eq(lines[1], "Train  Battle Shout 2, Overpower, Shield Bash (27s)", "train")
    eq(lines[2], "Zone  Loch Modan (Thelsamar), or Westfall / Darkshore (12-18)", "zone after the actions")
    eq(lines[3], "", "unused lines stay empty")
end)

test("shows the next skill level once everything is trained", function()
    level12({ known = { [6673] = true, [72] = true, [5242] = true, [7384] = true } })
    has(stepsText(), "Next  at 14: Demoralizing Shout, Revenge", "next skills")
    hasNot(stepsText(), "Train", "nothing to train")
end)

test("puts quests ready to turn in first, and drops them once turned in", function()
    level12({
        quests = { { questID = 1681, title = "Ironband's Compound" }, { questID = 267, title = "The Trogg Threat" } },
        items = { [6800] = 1 },
    })
    eq(steps()[1], "Turn in  Umbral Ore to Tormus Deepforge (Ironforge)", "item in bags")

    wow.state.quests = { { questID = 267, title = "The Trogg Threat", complete = true } }
    wow.state.completedQuests[1681] = true
    wow.fire("QUEST_TURNED_IN", 1681, 0)
    wow.advance(1)
    eq(steps()[1], "Turn in  1 done: The Trogg Threat", "other finished quests")
end)

test("guides the Hall of Thanes run until its quest is turned in", function()
    level12({ level = 13, known = { [6673] = true, [72] = true, [5242] = true, [7384] = true },
        quests = { { questID = 96393, title = "Old Ironforge Incursion" } } })
    has(stepsText(), "Quest  Hall of Thanes: kill Durgen Dirgehammer", "quest")
    has(stepsText(), "Dungeon  Hall of Thanes (13-18)", "dungeon")

    wow.state.quests = {}
    wow.state.completedQuests[96393] = true
    wow.fire("QUEST_REMOVED", 96393)
    wow.advance(1)
    hasNot(stepsText(), "Hall of Thanes (13-18)", "dungeon done")
    has(stepsText(), "Quest  Important Heirlooms: Thom Filch", "pickup still listed")
end)

test("updates the zone, dungeon and skills as you level", function()
    level12({ known = { [6673] = true, [72] = true, [5242] = true, [7384] = true } })
    levelUp(14, 0, 12000)
    wow.fire("PLAYER_LEVEL_UP", 14)
    wow.advance(1)
    has(stepsText(), "Train  Demoralizing Shout, Revenge (22s)", "level 14 skills")
    levelUp(23, 0, 30000)
    wow.fire("PLAYER_LEVEL_UP", 23)
    wow.advance(1)
    has(stepsText(), "Zone  Wetlands (Menethil Harbor) (21-25)", "level 23 zone")
    has(stepsText(), "Dungeon  Blackfathom Deeps (22-28)", "level 23 dungeon")
end)

test("reminds about unspent talent points first and keeps four lines", function()
    level12({ talentPoints = 2, items = { [6800] = 1 },
        quests = { { questID = 1681, title = "Ironband's Compound" }, { questID = 96393, title = "Old Ironforge Incursion" } } })
    local lines = steps()
    eq(lines[1], "Talents  Spend 2 points", "talents")
    eq(lines[2], "Turn in  Umbral Ore to Tormus Deepforge (Ironforge)", "turn in")
    eq(lines[3], "Train  Battle Shout 2, Overpower, Shield Bash (27s)", "train")
    has(lines[4], "Zone  Loch Modan", "zone always last")
end)

-- A cut-down Forever tree: Arms, Fury, Protection.
local function talentTabs(spent)
    spent = spent or {}
    local function t(name, tier, column, maxRank, prereq)
        return { name = name, tier = tier, column = column, maxRank = maxRank, rank = spent[name], prereq = prereq }
    end
    return {
        { talents = {
            t("Improved Rend", 1, 1, 3), t("Deflection", 1, 2, 5),
            t("Improved Tactical Mastery", 2, 1, 3), t("Anger Management", 2, 2, 1),
            t("Deep Wounds", 3, 1, 3), t("Two-Handed Specialization", 3, 2, 5),
            t("Bloodthrill", 4, 1, 2, { 3, 1 }), t("Spearing Strike", 4, 2, 1),
        } },
        { talents = { t("Cruelty", 1, 1, 5), t("Booming Voice", 1, 2, 5) } },
        { talents = { t("Shield Specialization", 1, 1, 5), t("Iron Will", 1, 2, 5) } },
    }
end
local function talentLine()
    for _, line in ipairs(steps()) do if line:find("^Talents") then return line end end
end

test("names the next leveling talent for your unspent points", function()
    level12({ talentPoints = 1, talentTabs = talentTabs() })
    eq(talentLine(), "Talents  Improved Rend 1/3", "one point")
    login({ level = 14, talentPoints = 5, talentTabs = talentTabs() })
    eq(talentLine(), "Talents  Improved Rend 3/3, Deflection 2/5", "Deflection capped until tier 2")
    login({ level = 16, talentPoints = 7, talentTabs = talentTabs() })
    eq(talentLine(), "Talents  Improved Rend 3/3, Deflection 2/5, Improved Tactical Mastery 2/3", "tier 2 opens")
end)

test("plans the next points through tiers and prerequisites", function()
    login({ level = 20, talentPoints = 1,
        talentTabs = talentTabs({ ["Improved Rend"] = 3, ["Deflection"] = 3, ["Improved Tactical Mastery"] = 3,
            ["Anger Management"] = 1 }) })
    eq(talentLine(), "Talents  Deep Wounds 1/3", "tier 3")
    local out = wow.slash("talents")
    has(out, "Talents: Deep Wounds 1/3", "now")
    has(out, "Next talents (Arms): Deep Wounds 3/3, Two-Handed Specialization 3/5", "Bloodthrill waits for Deep Wounds 3/3 and tier 4")
end)

test("leaves points past the plan to you", function()
    login({ level = 20, talentPoints = 2, talentTabs = {
        { talents = { { name = "Improved Rend", tier = 1, column = 1, maxRank = 1 } } } } })
    eq(talentLine(), "Talents  Improved Rend 1/1, +1 your pick", "rest is yours")
end)

test("announces the talent pick when you level up", function()
    login({ level = 10, talentTabs = talentTabs() })
    wow.chat = {}
    wow.state.talentPoints = 1
    levelUp(11, 0, 1200)
    wow.fire("PLAYER_LEVEL_UP", 11)
    wow.advance(1)
    eq(wow.alerts[#wow.alerts], "Talent point: Improved Rend 1/3", "center screen")
    has(table.concat(wow.chat, "\n"), "Talent point: Improved Rend 1/3 (Arms leveling build", "chat")
end)

test("picks the build from your spent points, your weapons, or /wpl build", function()
    login({ level = 12, talentPoints = 1, talentTabs = talentTabs(), equipped = { [17] = 2129 },
        equipLocs = { [2129] = "INVTYPE_SHIELD" } })
    eq(talentLine(), "Talents  Shield Specialization 1/5", "shield: Protection")
    login({ level = 12, talentPoints = 1, talentTabs = talentTabs({ ["Improved Rend"] = 2 }),
        equipped = { [17] = 2129 }, equipLocs = { [2129] = "INVTYPE_SHIELD" } })
    eq(talentLine(), "Talents  Improved Rend 3/3", "spent points win over the shield")
    wow.slash("build fury")
    wow.advance(1)
    eq(talentLine(), "Talents  Cruelty 1/5", "chosen build")
    wow.slash("build auto")
    wow.advance(1)
    eq(talentLine(), "Talents  Improved Rend 3/3", "back to auto")
end)

test("keeps the guide working when the talent API errors, and /wpl probe records it", function()
    level12({ talentPoints = 2, talentTabs = talentTabs() })
    _G.GetTalentInfo = function() error("Usage: GetTalentInfo(query)") end
    wow.fire("CHARACTER_POINTS_CHANGED")
    wow.advance(1)
    eq(talentLine(), "Talents  Spend 2 points", "falls back to the point count")
    has(stepsText(), "Zone  Loch Modan", "rest of the guide")
    has(wow.slash("talents"), "Next steps at level 12:", "/wpl talents still prints")
    has(wow.slash("probe"), "Talent probe saved", "probe")
    local probe = table.concat(_G.WarriorPilotLiteDB.probe, "\n")
    has(probe, "GetTalentInfo(1,1): ERROR", "records the error")
    has(probe, "GetNumTalents(1): 8", "records results")
    has(probe, "C_SpecializationInfo: missing", "records missing APIs")
end)

test("works without TrainerSpells and skips the Alliance route for the Horde", function()
    login({ level = 12 })
    hasNot(stepsText(), "Train", "no trainer data")
    has(stepsText(), "Zone  Loch Modan", "zone")
    login({ level = 12, faction = "Horde" })
    hasNot(stepsText(), "Zone", "no Alliance route for the Horde")
end)

test("/wpl guide prints every next step", function()
    level12({ items = { [6800] = 1 }, quests = { { questID = 1681, title = "Ironband's Compound" } } })
    local out = wow.slash("guide")
    has(out, "Next steps at level 12:", "header")
    has(out, "Train now: Battle Shout 2, Overpower, Shield Bash (27s)", "train")
    has(out, "New skills at 14: Demoralizing Shout, Revenge", "next")
    has(out, "Turn in: Umbral Ore to Tormus Deepforge", "turn in")
    hasNot(out, "Pick up: Important Heirlooms", "Hall of Thanes pickups wait for level 13")
    has(out, "Zone: Loch Modan (Thelsamar), or Westfall / Darkshore (12-18); then Redridge Mountains (Lakeshire) at 18", "zones")
    has(out, "Focus: Weapon damage is nearly all of your damage", "focus")
end)

---------------------------------------------------------------------------
-- Tips and HUD controls
---------------------------------------------------------------------------

test("never shows the Overpower tip before learning it, and never repeats a tip", function()
    login({ known = { [6673] = true } })
    local previous = tip()
    for _ = 1, 100 do
        wow.slash("tip")
        local current = tip()
        hasNot(current, "Overpower", "tip")
        assert(current ~= previous, "tip repeated: " .. current)
        previous = current
    end
end)

test("shows the Overpower tip once it is learned", function()
    login({ known = { [6673] = true, [7384] = true } })
    local seen = false
    for _ = 1, 100 do
        wow.slash("tip")
        if tip():find("Overpower", 1, true) then seen = true end
    end
    assert(seen, "Overpower tip never shown")
end)

local KNOWS_EVERYTHING = setmetatable({}, { __index = function() return true end })

test("has plenty of tips, each short enough for the tip bar", function()
    login({ known = KNOWS_EVERYTHING })
    local seen, count = {}, 0
    for _ = 1, 200 do
        wow.slash("tip")
        local text = tip()
        assert(#text <= 90, string.format("tip too long (%d chars): %s", #text, text))
        if not seen[text] then seen[text], count = true, count + 1 end
    end
    assert(count >= 50, "only " .. count .. " distinct tips")
end)

test("a new character only sees tips for abilities it knows", function()
    login({ known = {} })
    for _ = 1, 100 do
        wow.slash("tip")
        for _, ability in ipairs({ "Charge", "Execute", "Whirlwind", "Mortal Strike" }) do
            hasNot(tip(), ability, "tip")
        end
    end
end)

test("rotates the tip every 3 minutes", function()
    login()
    local first = tip()
    wow.advance(170)
    eq(tip(), first, "before 3 minutes")
    wow.advance(10)
    assert(tip() ~= first, "tip did not rotate after 3 minutes")
end)

test("clicking a tip restarts the rotation timer", function()
    login()
    wow.advance(150)
    wow.slash("tip")
    local clicked = tip()
    wow.advance(60) -- 210 s since login, but only 60 s since the click
    eq(tip(), clicked, "tip after click")
    wow.advance(120)
    assert(tip() ~= clicked, "tip did not rotate 3 minutes after the click")
end)

test("/wpl lock lets clicks pass through the panel", function()
    login()
    local panel = _G.WarriorPilotLiteFrame
    eq(panel.mouse, true, "unlocked")
    wow.slash("lock")
    eq(panel.mouse, false, "locked")
    wow.slash("lock")
    eq(panel.mouse, true, "unlocked again")
end)

test("restores the lock state on login", function()
    wow.login(ADDON, { locked = true })
    eq(_G.WarriorPilotLiteFrame.mouse, false, "locked panel")
end)

---------------------------------------------------------------------------

local passed, failed = 0, 0
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print("  ok    " .. t.name)
    else
        failed = failed + 1
        print("  FAIL  " .. t.name .. "\n        " .. tostring(err))
    end
end
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
