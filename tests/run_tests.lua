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

test("shows In combat during fights and updates as soon as combat ends", function()
    login()
    shoutActive(120)
    wow.state.inCombat = true
    wow.fire("PLAYER_REGEN_DISABLED")
    eq(ready(), "In combat", "in combat")
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
-- Tips and HUD controls
---------------------------------------------------------------------------

test("never shows the Overpower tip before learning it, and never repeats a tip", function()
    login({ known = { [6673] = true } })
    local previous = tip()
    for _ = 1, 20 do
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
    for _ = 1, 10 do
        wow.slash("tip")
        if tip():find("Overpower", 1, true) then seen = true end
    end
    assert(seen, "Overpower tip never shown")
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
