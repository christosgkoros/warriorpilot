-- WarriorPilot Lite 1.5.0 for World of Warcraft: Forever (Interface 16001)
-- Free, readable addon. Never casts, targets, moves or performs protected actions.
-- The one thing it changes is minimap tracking, kept on out of combat (/wpl track).
-- Important for modern WoW: player Rage can be a "secret value" during combat.
-- We pass Rage directly to the native StatusBar and never inspect/compare it.

local VERSION = "1.5.0"
local MAX_HISTORY = 100
-- Default HUD spot: left of the character so it doesn't block clicks on mobs/nodes.
local DEFAULT_X, DEFAULT_Y = -420, 120
-- XP/hour on the HUD uses this rolling window so it reacts to how you play now.
local RECENT_WINDOW = 600

-- Between-pulls readiness thresholds (checked out of combat only).
local READY = {
    healthPct = 60,     -- eat/bandage below this before the next pull
    durabilityPct = 25, -- warn when the most-worn item drops below this
    freeBagSlots = 3,   -- warn at or below this many free general bag slots
    shoutSeconds = 20,  -- warn when Battle Shout has less than this left
}
local BATTLE_SHOUT_ID = 6673 -- rank 1; buffs are matched by name so every rank counts
local battleShoutName

-- In-combat danger check. It only reads values the game hasn't made secret;
-- anything it can't read is skipped, so it never guesses from hidden data.
local FIGHT = {
    window = 8,         -- seconds of health history used to predict who drops first
    minWindow = 3,      -- need at least this much history before predicting
    minDrop = 5,        -- you must have lost this much health % in the window to be "losing"
    margin = 1.25,      -- you must be clearly losing before it says flee
    fleeEnemies = 4,    -- this many enemies on you (solo) is a flee
    fleeEliteLevels = 2, -- a solo elite this many levels above you is a flee
    riskyLevels = 3,    -- a normal mob this many levels above you is risky
    lowHealthPct = 30,  -- with no prediction available, flee below this health
}
local FIGHT_COLORS = {
    [0] = {0.55, 0.85, 0.55},
    [1] = {1.0, 0.62, 0.25},
    [2] = {1.0, 0.25, 0.22},
}
local BORDER_COLOR = {0.32, 0.35, 0.40}
local fight -- { samples = {...}, alerted = bool } while in combat

local WPL = {}
local session
local saved
local panel
local rageBar
local xpBar
local labels = {}
local tick = 0
local lastTipChange = 0
local isWarrior = false
-- Time-per-level tracking: when the current stretch at levelMarkLevel started.
local levelMark
local levelMarkLevel

local ORE = {
    [2770] = "Copper", [2771] = "Tin", [2775] = "Silver",
    [2772] = "Iron", [2776] = "Gold", [3858] = "Mithril",
    [7911] = "Truesilver", [10620] = "Thorium", [11370] = "Dark Iron",
    [3340] = "Incendicite", [4278] = "Lesser Bloodstone", [18562] = "Elementium",
}

-- Mining gathering casts are matched by spell NAME (as GatherMate2 does), so every
-- rank/ID counts. Find Minerals and Smelting have different names and are ignored.
-- Each successful gathering cast is an attempt, NOT a unique depleted vein.
local MINING_SPELL_ID = 2575
local miningName

-- The tip rotates on its own this often; clicking it shows the next one right away.
local TIP_ROTATE_SECONDS = 180

-- `spell` = only show once the character knows that spell (any rank counts).
-- Keep each tip under ~90 characters so it fits on two lines of the tip bar.
local TIPS = {
    -- Core habits
    { text = "Keep Battle Shout active while leveling." },
    { text = "Do not queue Heroic Strike on every swing; save some Rage." },
    { text = "A strong, up-to-date two-handed weapon makes leveling much smoother." },
    { text = "Use food and bandages to cut recovery time between fights." },
    { text = "Prioritize survival over a risky extra mob: deaths erase XP/hour gains." },
    { text = "Rage decays out of combat: chain pulls quickly to carry it into the next fight." },
    { text = "Taking hits also builds Rage, so tough mobs fill your bar faster." },
    { text = "Mobs at or slightly below your level give the best XP for the risk." },
    { text = "Mobs a few levels above you hit harder and you miss more often." },
    { text = "Strength is the best leveling stat; Agility adds crit, dodge and armor." },
    { text = "Weapon upgrades usually matter more than armor upgrades for a Warrior." },
    { text = "Consider carrying a shield for difficult pulls and dungeon tanking." },

    -- Abilities, shown once learned
    { text = "Use Charge to open a fight: it closes distance, stuns and gives Rage.", spell = 100 },
    { text = "Rend pays off on longer fights; skip it on mobs that die in a few hits.", spell = 772 },
    { text = "Thunder Clap slows the attacks of nearby enemies when you pull two.", spell = 6343 },
    { text = "Use Hamstring to stop fleeing enemies from pulling extra mobs.", spell = 1715 },
    { text = "Bloodrage trades a little health for Rage; use it right after Charge.", spell = 2687 },
    { text = "Overpower is cheap and can't be dodged: use it right after a dodge.", spell = 7384 },
    { text = "Shield Bash interrupts spellcasters, but needs a shield equipped.", spell = 72 },
    { text = "Demoralizing Shout lowers enemy attack power; worth it against groups.", spell = 1160 },
    { text = "In Defensive Stance, Revenge hits hard after you block, dodge or parry.", spell = 6572 },
    { text = "Switching stances costs most of your Rage; only switch when it's worth it.", spell = 71 },
    { text = "Sunder Armor is mostly for tanking; solo, spend Rage on damage instead.", spell = 7386 },
    { text = "In groups, Taunt pulls a mob off the healer instantly.", spell = 355 },
    { text = "Disarm cuts the damage of armed humanoids; great against hard elites.", spell = 676 },
    { text = "Cleave replaces Heroic Strike when two enemies stand together.", spell = 845 },
    { text = "Retaliation can save a bad multi-mob pull; it has a long cooldown.", spell = 20230 },
    { text = "Intimidating Shout fears nearby enemies, but they may run into more mobs.", spell = 5246 },
    { text = "Execute turns spare Rage into big damage once the target is below 20%.", spell = 5308 },
    { text = "Shield Wall heavily cuts damage taken for a few seconds; needs a shield.", spell = 871 },
    { text = "Berserker Stance adds crit but you take more damage; best solo with a 2H.", spell = 2458 },
    { text = "Intercept is a Charge you can use in combat to catch runners.", spell = 20252 },
    { text = "Slam pauses your swing: cast it right after an auto-attack lands.", spell = 1464 },
    { text = "Berserker Rage breaks and prevents Fear: save it for mobs that fear.", spell = 18499 },
    { text = "Whirlwind hits up to four nearby enemies; pull two or three mobs for it.", spell = 1680 },
    { text = "Pummel interrupts casters from Berserker Stance, no shield needed.", spell = 6552 },
    { text = "Sweeping Strikes with Cleave or Whirlwind makes two-mob pulls fast.", spell = 12292 },
    { text = "Mortal Strike is your main damage button: use it on cooldown.", spell = 12294 },
    { text = "Bloodthirst is your main damage button and heals you a little.", spell = 23881 },
    { text = "Recklessness makes every hit crit for a short time; save it for emergencies.", spell = 1719 },

    -- Route, upkeep and economy
    { text = "Mining is usually fastest when its nodes sit near your quest route." },
    { text = "Mining plus Blacksmithing lets you make sharpening stones for extra damage." },
    { text = "Train First Aid: bandages are your best way to recover without food." },
    { text = "Keep a stack of food for your level; cheap inn food saves minutes per hour." },
    { text = "Visit your trainer on new levels; TrainerSpells shows what's available." },
    { text = "Turn in quests in batches and pick up new ones on the same trip." },
    { text = "Use Questie's map icons to plan one loop through nearby quests." },
    { text = "Pull casters around a corner so they have to come to you." },
    { text = "Pull mobs back to cleared ground so patrols don't join the fight." },
    { text = "Sell grey items before heading out: bag space is XP time." },
    { text = "Repair before long sessions: broken gear gives none of its stats." },
    { text = "Rested XP doubles kill XP; log out in an inn or city to build it." },
    { text = "Set your Hearthstone so the end of a quest loop lands you near turn-ins." },
    { text = "Use /wpl levels to see which levels were slow and rethink the route there." },
    { text = "Use /wpl lock so clicks pass through the HUD." },
}

local function Print(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffc46b[WarriorPilot]|r " .. message)
    end
end

local function Secret(value)
    return issecretvalue and issecretvalue(value)
end

local function Number(value)
    if type(value) == "number" and not Secret(value) then return value end
    return nil
end

local function SpellName(spellID)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(spellID) end
    if GetSpellInfo then return (GetSpellInfo(spellID)) end
    return nil
end

local function FormatTime(seconds)
    seconds = math.max(0, math.floor(seconds))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then return string.format("%dh %02dm", hours, minutes) end
    return string.format("%02d:%02d", minutes, secs)
end

local function FormatNumber(number)
    if number >= 1000000 then return string.format("%.2fm", number / 1000000) end
    if number >= 1000 then return string.format("%.1fk", number / 1000) end
    return tostring(math.floor(number))
end

local function GetElapsed()
    return session and math.max(1, GetTime() - session.startedAt) or 1
end

local function XPPerHour()
    return session and math.floor(session.xpGained * 3600 / GetElapsed() + 0.5) or 0
end

local function RecentXPPerHour()
    if not session then return 0 end
    local cutoff = GetTime() - RECENT_WINDOW
    local recent = session.recent
    while recent[1] and recent[1].t < cutoff do table.remove(recent, 1) end
    local sum = 0
    for _, entry in ipairs(recent) do sum = sum + entry.xp end
    return math.floor(sum * 3600 / math.min(RECENT_WINDOW, GetElapsed()) + 0.5)
end

local function FormatETA(seconds)
    local minutes = math.ceil(seconds / 60)
    if minutes >= 60 then return string.format("%dh %02dm", math.floor(minutes / 60), minutes % 60) end
    return string.format("%dm", minutes)
end

local function TipAvailable(index)
    local spellID = TIPS[index].spell
    if not spellID then return true end
    -- Without IsPlayerSpell we can't tell, so ability tips stay hidden.
    return IsPlayerSpell and IsPlayerSpell(spellID) or false
end

local function AddonTip()
    local index = TIPS[saved.tipIndex] and saved.tipIndex or 1
    -- Advance past tips for spells the character doesn't know yet. The resolved
    -- index is stored so the next click never repeats the same tip.
    for _ = 1, #TIPS do
        if TipAvailable(index) then break end
        index = index % #TIPS + 1
    end
    saved.tipIndex = index
    return TIPS[index].text
end

local function NextTip()
    saved.tipIndex = (saved.tipIndex or 1) % #TIPS + 1
    lastTipChange = GetTime()
    if labels.tip then labels.tip:SetText(AddonTip()) end
end

-- The live session is stored in WarriorPilotLiteDB.session so it survives /reload.
-- On a fresh login the previous one is archived into WarriorPilotLiteDB.history,
-- which WoW writes to WTF/Account/<account>/<realm>/<character>/SavedVariables/.
local function NewSession()
    local xp = Number(UnitXP("player")) or 0
    local xpMax = Number(UnitXPMax("player")) or 1
    local level = Number(UnitLevel("player")) or 1
    session = {
        date = date("%Y-%m-%d %H:%M"),
        startedAt = GetTime(),
        duration = 0,
        startLevel = level,
        xpGained = 0,
        questXP = 0,
        recent = {}, -- {t = GetTime(), xp = gained} within RECENT_WINDOW
        lastXP = xp,
        lastXPMax = xpMax,
        lastLevel = level,
        deaths = 0,
        miningCasts = 0,
        oreLooted = 0,
        ores = {},
    }
    saved.session = session
end

-- Per-character stats for each level, kept across sessions in WarriorPilotLiteDB.levels.
-- "partial" means the addon didn't see the whole level (e.g. installed mid-level).
local function LevelEntry(level, enteredByLevelUp)
    saved.levels = saved.levels or {}
    local entry = saved.levels[level]
    if not entry then
        entry = { seconds = 0, xp = 0, questXP = 0, deaths = 0, partial = not enteredByLevelUp }
        saved.levels[level] = entry
    end
    return entry
end

local function FlushLevelTime()
    if not levelMark then return end
    local now = GetTime()
    local entry = LevelEntry(levelMarkLevel)
    entry.seconds = entry.seconds + math.max(0, now - levelMark)
    levelMark = now
end

local function ArchiveSession(stored)
    if type(stored) ~= "table" or type(stored.xpGained) ~= "number" then return end
    local duration = stored.duration or 0
    -- Skip empty sessions such as quick logins to check mail.
    if stored.xpGained == 0 and (stored.oreLooted or 0) == 0 and duration < 300 then return end
    saved.history = saved.history or {}
    table.insert(saved.history, {
        date = stored.date,
        duration = duration,
        startLevel = stored.startLevel,
        endLevel = stored.lastLevel,
        xpGained = stored.xpGained,
        questXP = stored.questXP,
        xpPerHour = math.floor(stored.xpGained * 3600 / math.max(1, duration) + 0.5),
        deaths = stored.deaths,
        miningCasts = stored.miningCasts,
        oreLooted = stored.oreLooted,
        ores = stored.ores,
    })
    while #saved.history > MAX_HISTORY do table.remove(saved.history, 1) end
end

local function StartSession(isReloadingUi)
    local stored = saved.session
    if isReloadingUi and type(stored) == "table" and type(stored.xpGained) == "number" then
        session = stored
        session.startedAt = GetTime() - (session.duration or 0)
        session.ores = session.ores or {}
        -- Fields added in 1.2.0; sessions saved by 1.1.0 lack them.
        session.recent = session.recent or {}
        session.questXP = session.questXP or 0
    else
        ArchiveSession(stored)
        NewSession()
    end
    levelMark = GetTime()
    levelMarkLevel = session.lastLevel
    LevelEntry(levelMarkLevel, false)
end

local function SampleXP()
    if not session then return end
    local xp = Number(UnitXP("player"))
    local xpMax = Number(UnitXPMax("player"))
    local level = Number(UnitLevel("player"))
    if not xp or not xpMax or not level then return end

    local gained = 0
    if level > session.lastLevel then
        -- XP max grows every level; if it hasn't changed yet the XP values are stale.
        if xpMax == session.lastXPMax then return end
        -- This also works when the player earned XP toward the new level.
        local finished = math.max(0, session.lastXPMax - session.lastXP)
        local oldEntry = LevelEntry(session.lastLevel)
        oldEntry.xp = oldEntry.xp + finished
        local newEntry = LevelEntry(level, true)
        newEntry.xp = newEntry.xp + xp
        gained = finished + xp
    elseif xp >= session.lastXP then
        gained = xp - session.lastXP
        local entry = LevelEntry(level)
        entry.xp = entry.xp + gained
    else
        -- XP dropped but the level wasn't updated yet: wait for the next event.
        return
    end

    if gained > 0 then table.insert(session.recent, { t = GetTime(), xp = gained }) end
    session.xpGained = session.xpGained + math.max(0, gained)
    session.lastXP = xp
    session.lastXPMax = xpMax
    session.lastLevel = level
end

local function MakeLabel(parent, text, size, color)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetFont(STANDARD_TEXT_FONT, size or 12, "")
    label:SetJustifyH("LEFT")
    if color then label:SetTextColor(color[1], color[2], color[3]) end
    label:SetText(text or "")
    return label
end

local function MakeBar(parent, y, fill)
    local back = parent:CreateTexture(nil, "BACKGROUND")
    back:SetColorTexture(0.15, 0.17, 0.22, 1)
    back:SetPoint("TOPLEFT", 18, y)
    back:SetPoint("TOPRIGHT", -18, y)
    back:SetHeight(12)

    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(fill[1], fill[2], fill[3])
    bar:SetMinMaxValues(0, 100)
    bar:SetValue(0)
    bar:SetPoint("TOPLEFT", back, "TOPLEFT", 1, -1)
    bar:SetPoint("BOTTOMRIGHT", back, "BOTTOMRIGHT", -1, 1)
    return bar
end

local function MakeMetric(parent, x, y, caption)
    local left = MakeLabel(parent, caption, 10, {0.60, 0.66, 0.72})
    left:SetPoint("TOPLEFT", x, y)
    local value = MakeLabel(parent, "0", 17, {0.96, 0.97, 0.98})
    value:SetPoint("TOPLEFT", x, y - 15)
    return value
end

local function BuildPanel()
    panel = CreateFrame("Frame", "WarriorPilotLiteFrame", UIParent, "BackdropTemplate")
    panel:SetSize(310, 345)
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    panel:SetBackdropColor(0.055, 0.068, 0.085, 0.95)
    panel:SetBackdropBorderColor(BORDER_COLOR[1], BORDER_COLOR[2], BORDER_COLOR[3], 1)
    panel:SetFrameStrata("MEDIUM")
    panel:SetPoint("CENTER", UIParent, "CENTER", saved.x or DEFAULT_X, saved.y or DEFAULT_Y)
    -- When locked, the panel ignores the mouse so clicks pass through to the world.
    panel:EnableMouse(not saved.locked)

    panel:SetScript("OnDragStart", function(self)
        if not saved.locked then self:StartMoving() end
    end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x, y = self:GetCenter()
        local cx, cy = UIParent:GetCenter()
        if x and y and cx and cy then
            saved.x = math.floor(x - cx + 0.5)
            saved.y = math.floor(y - cy + 0.5)
        end
    end)

    local accent = panel:CreateTexture(nil, "ARTWORK")
    accent:SetColorTexture(0.86, 0.27, 0.22, 1)
    accent:SetPoint("TOPLEFT", 0, 0)
    accent:SetPoint("TOPRIGHT", 0, 0)
    accent:SetHeight(4)

    local title = MakeLabel(panel, "WARRIORPILOT", 15, {1.0, 0.77, 0.39})
    title:SetPoint("TOPLEFT", 18, -17)
    local lite = MakeLabel(panel, "LITE  /  FOREVER", 9, {0.57, 0.64, 0.71})
    lite:SetPoint("TOPRIGHT", -32, -21)

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetSize(23, 23)
    close:SetPoint("TOPRIGHT", -2, -8)
    close:SetScript("OnClick", function()
        saved.visible = false
        panel:Hide()
        Print("Hidden. Type /wpl show to reopen.")
    end)

    labels.name = MakeLabel(panel, "", 11, {0.75, 0.81, 0.88})
    labels.name:SetPoint("TOPLEFT", 18, -42)

    labels.rage = MakeLabel(panel, "RAGE", 10, {0.78, 0.82, 0.86})
    labels.rage:SetPoint("TOPLEFT", 18, -65)
    rageBar = MakeBar(panel, -80, {0.85, 0.29, 0.25})

    labels.xp = MakeLabel(panel, "XP", 10, {0.78, 0.82, 0.86})
    labels.xp:SetPoint("TOPLEFT", 18, -105)
    labels.ttl = MakeLabel(panel, "", 10, {0.66, 0.71, 0.78})
    labels.ttl:SetPoint("TOPRIGHT", -18, -105)
    labels.ttl:SetJustifyH("RIGHT")
    xpBar = MakeBar(panel, -120, {0.38, 0.65, 0.95})

    labels.xphr = MakeMetric(panel, 18, -148, "XP / HOUR (LAST 10 MIN)")
    labels.total = MakeMetric(panel, 165, -148, "SESSION XP")
    labels.deaths = MakeMetric(panel, 18, -193, "DEATHS")
    labels.mine = MakeMetric(panel, 165, -193, "MINING CASTS")

    labels.ores = MakeLabel(panel, "Ore looted: 0", 11, {0.83, 0.85, 0.91})
    labels.ores:SetPoint("TOPLEFT", 18, -237)
    labels.clock = MakeLabel(panel, "00:00", 11, {0.66, 0.71, 0.78})
    labels.clock:SetPoint("TOPRIGHT", -18, -237)

    labels.sources = MakeLabel(panel, "", 11, {0.83, 0.85, 0.91})
    labels.sources:SetPoint("TOPLEFT", 18, -256)

    labels.ready = MakeLabel(panel, "", 11, {0.55, 0.85, 0.55})
    labels.ready:SetPoint("TOPLEFT", 18, -278)
    labels.ready:SetWidth(274)

    local tipButton = CreateFrame("Button", nil, panel)
    tipButton:SetPoint("BOTTOMLEFT", 18, 11)
    tipButton:SetPoint("BOTTOMRIGHT", -18, 11)
    tipButton:SetHeight(27)
    tipButton:EnableMouse(true)
    tipButton:SetScript("OnClick", NextTip)
    local tipBackground = tipButton:CreateTexture(nil, "BACKGROUND")
    tipBackground:SetAllPoints()
    tipBackground:SetColorTexture(0.15, 0.18, 0.23, 0.85)
    labels.tip = MakeLabel(tipButton, "", 10, {0.94, 0.79, 0.49})
    labels.tip:SetWidth(267)
    labels.tip:SetJustifyH("CENTER")
    labels.tip:SetPoint("CENTER", tipButton, "CENTER", 0, 0)
    labels.tip:SetText(AddonTip())
    lastTipChange = GetTime()
    tipButton:SetScript("OnEnter", function() tipBackground:SetColorTexture(0.22, 0.26, 0.32, 1) end)
    tipButton:SetScript("OnLeave", function() tipBackground:SetColorTexture(0.15, 0.18, 0.23, 0.85) end)

    panel:SetScript("OnUpdate", function(_, elapsed)
        tick = tick + elapsed
        if tick < 1 then return end
        tick = 0
        WPL.Refresh()
        if GetTime() - lastTipChange >= TIP_ROTATE_SECONDS then NextTip() end
    end)

    if saved.visible == false then panel:Hide() end
end

local function RefreshRage()
    if not rageBar then return end
    -- Player Rage is a primary power: its numeric value may be secret in combat.
    -- This is a display-only pass-through, not combat decision logic.
    local rageMax = UnitPowerMax("player", 1)
    if not Secret(rageMax) and type(rageMax) == "number" and rageMax > 0 then
        rageBar:SetMinMaxValues(0, rageMax)
    else
        rageBar:SetMinMaxValues(0, 100)
    end
    rageBar:SetValue(UnitPower("player", 1))
end

-- Seconds of Battle Shout left: 0 if missing, math.huge if it never expires,
-- nil if it can't be read (e.g. secret values), so we never raise a false alarm.
local function BattleShoutRemaining()
    battleShoutName = battleShoutName or SpellName(BATTLE_SHOUT_ID)
    if not battleShoutName then return nil end
    for i = 1, 40 do
        local name, expirationTime
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not aura then break end
            name, expirationTime = aura.name, aura.expirationTime
        elseif UnitBuff then
            local auraName, _, _, _, _, expires = UnitBuff("player", i)
            if not auraName then break end
            name, expirationTime = auraName, expires
        else
            return nil
        end
        if Secret(name) then return nil end
        if name == battleShoutName then
            expirationTime = Number(expirationTime)
            if not expirationTime then return nil end
            if expirationTime == 0 then return math.huge end
            return math.max(0, expirationTime - GetTime())
        end
    end
    return 0
end

local function LowestDurabilityPct()
    local lowest
    for slot = 1, 18 do
        local current, maximum = GetInventoryItemDurability(slot)
        current, maximum = Number(current), Number(maximum)
        if current and maximum and maximum > 0 then
            local pct = current * 100 / maximum
            if not lowest or pct < lowest then lowest = pct end
        end
    end
    return lowest
end

local function FreeBagSlots()
    local getFree = C_Container and C_Container.GetContainerNumFreeSlots or GetContainerNumFreeSlots
    if not getFree then return nil end
    local free = 0
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local slots, bagType = getFree(bag)
        -- bagType 0 is a general bag; ammo, soul and profession bags don't count.
        if Number(slots) and bagType == 0 then free = free + slots end
    end
    return free
end

local function SetReadiness(text, color)
    labels.ready:SetTextColor(color[1], color[2], color[3])
    labels.ready:SetText(text)
end

-- True only for a readable, truthy value; secret values count as "don't know".
local function Yes(value)
    if Secret(value) then return false end
    return value and true or false
end

local function HealthPct(unit)
    local health, healthMax = Number(UnitHealth(unit)), Number(UnitHealthMax(unit))
    if health and healthMax and healthMax > 0 then return health * 100 / healthMax end
    return nil
end

local function IsLiveEnemy(unit)
    if not Yes(UnitExists(unit)) or not Yes(UnitCanAttack("player", unit)) then return false end
    local dead = UnitIsDead(unit)
    return not Secret(dead) and not dead
end

-- In combat with the player: on its threat table, or targeting the player.
local function IsOnYou(unit)
    if not IsLiveEnemy(unit) or not Yes(UnitAffectingCombat(unit)) then return false end
    if UnitThreatSituation and Yes(UnitThreatSituation("player", unit)) then return true end
    return Yes(UnitIsUnit(unit .. "target", "player"))
end

-- Counted from enemy nameplates, so it needs nameplates turned on (V key).
local function EnemiesOnYou()
    local count = 0
    for i = 1, 40 do
        if IsOnYou("nameplate" .. i) then count = count + 1 end
    end
    if count == 0 and IsLiveEnemy("target") and Yes(UnitAffectingCombat("target")) then count = 1 end
    return count
end

-- In a group extra mobs and elites are expected, so the solo-only checks are skipped.
local function IsSolo()
    return not (IsInGroup and Yes(IsInGroup()))
end

-- Risk visible at the pull: enemy count, target level and elite status.
-- Returns 0 ok / 1 risky / 2 flee, the reasons, and whether the target is skull-level.
local function AssessPull(enemies)
    local level, reasons = 0, {}
    local function add(danger, reason)
        level = math.max(level, danger)
        reasons[#reasons+1] = reason
    end
    local solo = IsSolo()
    if solo and enemies >= FIGHT.fleeEnemies then
        add(2, enemies .. " enemies on you")
    elseif solo and enemies >= 2 then
        add(1, enemies .. " enemies")
    end
    if not IsLiveEnemy("target") then return level, reasons, false end
    local targetLevel, myLevel = Number(UnitLevel("target")), Number(UnitLevel("player"))
    if targetLevel == -1 then return 2, reasons, true end
    local class = UnitClassification("target")
    local elite = not Secret(class) and (class == "elite" or class == "rareelite" or class == "worldboss")
    local diff = targetLevel and myLevel and targetLevel - myLevel
    if elite and solo and diff and diff >= FIGHT.fleeEliteLevels then
        add(2, string.format("elite +%d", diff))
    elseif elite and solo then
        add(1, "elite")
    elseif diff and diff >= FIGHT.riskyLevels then
        add(1, string.format("+%d levels", diff))
    end
    return level, reasons, false
end

local function Seconds(value)
    if value == math.huge then return "--" end
    return string.format("~%ds", math.ceil(value))
end

-- Records health and predicts who drops first from the last few seconds:
-- your health vs your target's, plus a fresh mob for every extra enemy on you.
-- Damage taken is scaled from the enemy count it was taken at to the count now,
-- so adds that just joined are judged at once instead of after a new trend builds.
local function HealthRace(enemies)
    local now = GetTime()
    local me = HealthPct("player")
    if not me then return nil end
    local guid = IsLiveEnemy("target") and UnitGUID("target") or nil
    if Secret(guid) then guid = nil end
    local them = guid and HealthPct("target")
    local samples = fight.samples
    table.insert(samples, { t = now, me = me, them = them, guid = guid, enemies = enemies })
    while samples[1] and samples[1].t < now - FIGHT.window do table.remove(samples, 1) end

    local first = samples[1]
    if not them or now - first.t < FIGHT.minWindow then return nil end
    -- Oldest reading of the current target; switching targets restarts its history.
    local firstThem
    for _, sample in ipairs(samples) do
        if sample.guid == guid and sample.them then firstThem = sample; break end
    end
    local span = now - firstThem.t
    if span < FIGHT.minWindow then return nil end

    local seen = 0
    for _, sample in ipairs(samples) do seen = seen + sample.enemies end
    local myLoss = (first.me - me) * enemies / (seen / #samples)
    local myRate = myLoss / (now - first.t)
    local theirRate = (firstThem.them - them) / span
    local myTime = myRate > 0 and me / myRate or math.huge
    local theirTime = theirRate > 0 and (them + (enemies - 1) * 100) / theirRate or math.huge

    if myLoss >= FIGHT.minDrop and myTime * FIGHT.margin < theirTime then
        return 2, string.format("FLEE! You die in %s, enemies in %s", Seconds(myTime), Seconds(theirTime))
    elseif myLoss >= FIGHT.minDrop and myTime < theirTime * FIGHT.margin then
        return 1, string.format("Close fight: you %s, enemies %s", Seconds(myTime), Seconds(theirTime))
    elseif myTime == math.huge then
        return 0, "Winning"
    end
    return 0, string.format("Winning: you %s, enemies %s", Seconds(myTime), Seconds(theirTime))
end

local function FightAlert(text, color)
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, text, { r = color[1], g = color[2], b = color[3] })
    elseif UIErrorsFrame then
        UIErrorsFrame:AddMessage(text, color[1], color[2], color[3])
    end
    if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
end

local function SetBorder(color)
    if panel then panel:SetBackdropBorderColor(color[1], color[2], color[3], 1) end
end

local function EndFight()
    if not fight then return end
    fight = nil
    SetBorder(BORDER_COLOR)
end

-- Runs every second in combat: a verdict on the readiness line, a red HUD border
-- while it says flee, one center-screen flee warning + sound per fight, and a
-- center-screen warning whenever adds join you while solo.
local function RefreshFight()
    fight = fight or { samples = {}, alerted = false, enemies = 1 }
    local enemies = EnemiesOnYou()
    -- Highest count seen, so a nameplate flickering in and out doesn't re-alert.
    local adds = 0
    if enemies > fight.enemies then
        adds = IsSolo() and enemies - fight.enemies or 0
        fight.enemies = enemies
    end
    local pullLevel, reasons, skull = AssessPull(enemies)
    local raceLevel, raceText = HealthRace(math.max(1, enemies))

    local level, text
    if skull then
        level, text = 2, "FLEE! Skull-level target"
    elseif raceLevel then
        -- The health trend decides, but pull risks stay visible as context.
        level = math.max(raceLevel, math.min(pullLevel, 1))
        text = raceText
        if raceLevel < 2 and #reasons > 0 then text = text .. "  ·  " .. table.concat(reasons, ", ") end
    else
        local me = HealthPct("player")
        level = pullLevel
        if pullLevel > 0 then
            text = (pullLevel == 2 and "FLEE! " or "Risky: ") .. table.concat(reasons, ", ")
        end
        if me and me < FIGHT.lowHealthPct then
            level, text = 2, string.format("FLEE! Health at %d%%", math.floor(me))
        end
        if not text then
            -- Nothing readable to judge by (e.g. secret health): stay neutral.
            if not me then SetReadiness("In combat", {0.60, 0.66, 0.72}); return end
            text = "Fight looks OK"
        end
    end

    SetReadiness(text, FIGHT_COLORS[level])
    SetBorder(level == 2 and FIGHT_COLORS[2] or BORDER_COLOR)
    if adds > 0 then
        -- Adds always get a warning that carries the verdict, flee or not.
        if level == 2 then fight.alerted = true end
        FightAlert(string.format("+%d add%s! %s", adds, adds > 1 and "s" or "", text),
            FIGHT_COLORS[math.max(level, 1)])
    elseif level == 2 and not fight.alerted then
        fight.alerted = true
        FightAlert(text, FIGHT_COLORS[2])
    end
end

-- Minimap tracking kept on out of combat, in priority order. Types this character
-- doesn't have (Find Treasure is a Dwarf racial) simply aren't in the tracking list.
local KEEP_TRACKING = { 2580, 2481 } -- Find Minerals, Find Treasure
local TRACKING = {
    gap = 1.5,   -- seconds between any two switches (the global cooldown)
    retry = 5,   -- seconds before turning the same type on again
    window = 60, -- this many seconds of attempts are remembered...
    fights = 3,  -- ...and this many re-enables in it mean two types switch each other off
}
local trackingTries = {}   -- [spellID] = times it was turned on, within the window
local trackingGaveUp = {}  -- [spellID] = true once it keeps switching a higher one off
local trackingBlocked = false
local trackingPending = false
local lastTrackingSwitch = -math.huge

-- The wanted tracking types this character has, highest priority first.
local function WantedTracking()
    local found = {}
    if not (C_Minimap and C_Minimap.GetNumTrackingTypes and C_Minimap.GetTrackingInfo) then return found end
    local count = Number(C_Minimap.GetNumTrackingTypes()) or 0
    for _, spellID in ipairs(KEEP_TRACKING) do
        local name = SpellName(spellID)
        for index = 1, count do
            local info = C_Minimap.GetTrackingInfo(index)
            if info and not Secret(info.active)
                and (info.spellID == spellID or (name and info.name == name)) then
                found[#found+1] = { index = index, spellID = spellID, name = info.name, active = info.active }
                break
            end
        end
    end
    return found
end

local KeepTracking
local function KeepTrackingSoon(delay)
    if trackingPending then return end
    trackingPending = true
    C_Timer.After(delay, function() trackingPending = false; KeepTracking() end)
end

-- Turns one wanted type back on per pass: where tracking is a cast, the next one
-- has to wait for the global cooldown. Combat, death and casts wait for later.
function KeepTracking()
    if not saved or saved.keepTracking == false or trackingBlocked then return end
    if not (C_Minimap and C_Minimap.SetTracking) then return end
    if InCombatLockdown() or UnitIsDeadOrGhost("player") then return end
    -- Never interrupt a mining cast.
    if (UnitCastingInfo and UnitCastingInfo("player")) or (UnitChannelInfo and UnitChannelInfo("player")) then
        KeepTrackingSoon(1)
        return
    end
    local now = GetTime()
    if now - lastTrackingSwitch < TRACKING.gap then
        KeepTrackingSoon(lastTrackingSwitch + TRACKING.gap - now)
        return
    end
    local managed = {}
    for _, entry in ipairs(WantedTracking()) do
        if not trackingGaveUp[entry.spellID] then managed[#managed+1] = entry end
    end
    for _, entry in ipairs(managed) do
        if not entry.active then
            local tries = trackingTries[entry.spellID] or {}
            trackingTries[entry.spellID] = tries
            while tries[1] and tries[1] < now - TRACKING.window do table.remove(tries, 1) end
            local wait = tries[#tries] and tries[#tries] + TRACKING.retry - now
            if wait and wait > 0 then
                KeepTrackingSoon(wait)
                return
            end
            if #tries >= TRACKING.fights and #managed > 1 then
                -- Only one can be on at a time here: keep the highest priority one.
                for i = 2, #managed do trackingGaveUp[managed[i].spellID] = true end
                trackingTries[managed[1].spellID] = {}
                Print(string.format("Only one tracking type can be on at a time; keeping %s on.", managed[1].name))
                KeepTrackingSoon(1)
                return
            end
            tries[#tries+1] = now
            lastTrackingSwitch = now
            C_Minimap.SetTracking(entry.index, true)
            KeepTrackingSoon(TRACKING.gap)
            return
        end
    end
end

-- Out of combat: the between-pulls checklist. In combat: the fight verdict.
local function RefreshReadiness()
    if not labels.ready then return end
    if UnitIsDeadOrGhost("player") then
        EndFight()
        SetReadiness("", {1, 1, 1})
        return
    end
    local inCombat = UnitAffectingCombat("player")
    if Secret(inCombat) or inCombat then
        RefreshFight()
        return
    end
    EndFight()
    KeepTracking()

    local alerts = {}
    if trackingBlocked and saved.keepTracking ~= false then
        -- The game wouldn't let us switch it on, so remind instead.
        for _, entry in ipairs(WantedTracking()) do
            if not entry.active then alerts[#alerts+1] = entry.name .. " off" end
        end
    end
    if not IsPlayerSpell or IsPlayerSpell(BATTLE_SHOUT_ID) then
        local remaining = BattleShoutRemaining()
        if remaining == 0 then
            alerts[#alerts+1] = "Battle Shout missing"
        elseif remaining and remaining < READY.shoutSeconds then
            alerts[#alerts+1] = "Battle Shout ending"
        end
    end

    local pct = HealthPct("player")
    if pct and pct < READY.healthPct then
        alerts[#alerts+1] = string.format("Eat/bandage (%d%% HP)", math.floor(pct))
    end

    local durability = LowestDurabilityPct()
    if durability and durability < 1 then
        alerts[#alerts+1] = "Broken gear!"
    elseif durability and durability < READY.durabilityPct then
        alerts[#alerts+1] = string.format("Repair soon (%d%%)", math.floor(durability))
    end

    local free = FreeBagSlots()
    if free and free <= READY.freeBagSlots then
        alerts[#alerts+1] = string.format("Bags: %d free", free)
    end

    if #alerts == 0 then
        SetReadiness("Ready to pull", {0.55, 0.85, 0.55})
    else
        SetReadiness(table.concat(alerts, "  ·  "), {1.0, 0.62, 0.25})
    end
end

function WPL.Refresh()
    if not panel or not session or not isWarrior then return end

    RefreshRage()
    RefreshReadiness()

    local currentXP = Number(UnitXP("player")) or 0
    local maxXP = Number(UnitXPMax("player")) or 1
    xpBar:SetMinMaxValues(0, math.max(1, maxXP))
    xpBar:SetValue(math.min(currentXP, maxXP))

    local level = Number(UnitLevel("player")) or "?"
    labels.name:SetText("Warrior  |  Level " .. tostring(level))
    labels.xp:SetText(string.format("XP   %s / %s", FormatNumber(currentXP), FormatNumber(maxXP)))
    local recentRate = RecentXPPerHour()
    labels.xphr:SetText(FormatNumber(recentRate))
    -- Fall back to the session average until the last 10 minutes have any XP.
    local rate = recentRate > 0 and recentRate or XPPerHour()
    local isMaxLevel = GetMaxPlayerLevel and level == GetMaxPlayerLevel()
    if isMaxLevel or maxXP <= 1 then
        labels.ttl:SetText("")
    elseif rate > 0 then
        labels.ttl:SetText("Level in " .. FormatETA((maxXP - currentXP) * 3600 / rate))
    else
        labels.ttl:SetText("Level in --")
    end
    labels.total:SetText(FormatNumber(session.xpGained))
    labels.sources:SetText(string.format("XP from quests %s  ·  kills & other %s",
        FormatNumber(session.questXP), FormatNumber(math.max(0, session.xpGained - session.questXP))))
    labels.deaths:SetText(tostring(session.deaths))
    labels.mine:SetText(tostring(session.miningCasts))
    labels.ores:SetText("Ore looted: " .. tostring(session.oreLooted))
    labels.clock:SetText(FormatTime(GetElapsed()))
end

local function IsSelfLootMessage(message)
    if type(message) ~= "string" or Secret(message) then return false end
    -- Blizzard's self-loot global strings are localized and start with a stable prefix.
    for _, template in ipairs({LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE}) do
        if type(template) == "string" then
            local prefix = template:match("^(.-)%%s")
            if prefix and prefix ~= "" and message:sub(1, #prefix) == prefix then return true end
        end
    end
    -- Fallback for English clients whose globals are unavailable at this point.
    return message:sub(1, 17) == "You receive loot:"
end

local function TrackLoot(message)
    if not IsSelfLootMessage(message) then return end
    local itemID = tonumber(message:match("|Hitem:(%d+)"))
    if not itemID or not ORE[itemID] then return end
    -- Typical Blizzard loot string: "You receive loot: [Ore]x3."
    local count = tonumber(message:match("[xX](%d+)[%.!%s]*$")) or 1
    count = math.min(10000, math.max(1, count))
    session.oreLooted = session.oreLooted + count
    session.ores[itemID] = (session.ores[itemID] or 0) + count
    WPL.Refresh()
end

local function TrackMiningCast(unit, castGUID, spellID)
    if unit ~= "player" or Secret(spellID) then return end
    miningName = miningName or SpellName(MINING_SPELL_ID)
    local name = SpellName(spellID)
    if Secret(name) then return end
    if name and name == miningName then
        session.miningCasts = session.miningCasts + 1
        if saved.debug then Print("Mining cast detected: spell " .. tostring(spellID)) end
        WPL.Refresh()
    elseif saved.debug then
        Print("Player cast: " .. tostring(name) .. " (" .. tostring(spellID) .. ")")
    end
end

local function ShowStats()
    local summary = string.format(
        "Session: %s | XP %s (%s/h, last 10 min %s/h) | quest XP %s | deaths %d | mining casts %d | ore looted %d",
        FormatTime(GetElapsed()), FormatNumber(session.xpGained),
        FormatNumber(XPPerHour()), FormatNumber(RecentXPPerHour()), FormatNumber(session.questXP),
        session.deaths, session.miningCasts, session.oreLooted
    )
    Print(summary)
    local parts = {}
    for id, name in pairs(ORE) do
        local amount = session.ores[id]
        if amount and amount > 0 then parts[#parts+1] = name .. " " .. amount end
    end
    if #parts > 0 then Print("Ore breakdown: " .. table.concat(parts, ", ")) end
end

local function ShowHistory()
    local history = saved.history
    if not history or #history == 0 then
        Print("No archived sessions yet. Sessions are archived when you log in again or /wpl reset.")
        return
    end
    Print(string.format("Last sessions (%d stored in SavedVariables):", #history))
    for i = math.max(1, #history - 4), #history do
        local h = history[i]
        Print(string.format("%s | %s | lvl %s-%s | XP %s (%s/h) | deaths %d | ore %d",
            tostring(h.date or "?"), FormatTime(h.duration or 0),
            tostring(h.startLevel or "?"), tostring(h.endLevel or "?"),
            FormatNumber(h.xpGained or 0), FormatNumber(h.xpPerHour or 0),
            h.deaths or 0, h.oreLooted or 0))
    end
end

local function SortedLevels()
    FlushLevelTime()
    local list = {}
    for level in pairs(saved.levels or {}) do list[#list+1] = level end
    table.sort(list)
    return list
end

local function ShowLevels()
    local list = SortedLevels()
    if #list == 0 then Print("No level data yet."); return end
    Print("Time per level (* = addon didn't see the whole level; includes AFK time):")
    for _, level in ipairs(list) do
        local e = saved.levels[level]
        local questPct = e.xp > 0 and math.floor(e.questXP * 100 / e.xp + 0.5) or 0
        Print(string.format("Level %d%s: %s | XP %s (%d%% quests) | deaths %d",
            level, e.partial and "*" or "", FormatTime(e.seconds),
            FormatNumber(e.xp), math.min(100, questPct), e.deaths))
    end
end

local function ExportStats()
    local parts = {
        "WarriorPilot Lite v" .. VERSION,
        "Date=" .. tostring(session.date or "?"),
        "Level=" .. tostring(Number(UnitLevel("player")) or "?"),
        "SessionSeconds=" .. tostring(math.floor(GetElapsed())),
        "XP=" .. tostring(session.xpGained),
        "QuestXP=" .. tostring(session.questXP),
        "XPPerHour=" .. tostring(XPPerHour()),
        "RecentXPPerHour=" .. tostring(RecentXPPerHour()),
        "Deaths=" .. tostring(session.deaths),
        "MiningCasts=" .. tostring(session.miningCasts),
        "OreLooted=" .. tostring(session.oreLooted),
    }
    for id, name in pairs(ORE) do
        local amount = session.ores[id]
        if amount and amount > 0 then parts[#parts+1] = name .. "=" .. amount end
    end
    -- Compact per-level history: level:seconds:xp:questXP:deaths (* = partial level).
    local levelParts = {}
    for _, level in ipairs(SortedLevels()) do
        local e = saved.levels[level]
        levelParts[#levelParts+1] = string.format("%d%s:%d:%d:%d:%d",
            level, e.partial and "*" or "", math.floor(e.seconds), e.xp, e.questXP, e.deaths)
    end
    if #levelParts > 0 then
        parts[#parts+1] = "Levels(level:seconds:xp:questXP:deaths)=" .. table.concat(levelParts, ",")
    end
    local export = table.concat(parts, " | ")
    if not WPL.exportBox then
        local pop = CreateFrame("Frame", "WarriorPilotExportPopup", UIParent, "BackdropTemplate")
        pop:SetSize(540, 90)
        pop:SetPoint("CENTER")
        pop:SetFrameStrata("DIALOG")
        pop:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Buttons\\WHITE8X8", edgeSize=1})
        pop:SetBackdropColor(0.06, 0.07, 0.09, 0.98)
        pop:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        local heading = MakeLabel(pop, "Copy with Ctrl+C / Cmd+C, then paste into ChatGPT", 12, {1,0.77,0.39})
        heading:SetPoint("TOPLEFT", 16, -14)
        -- Single line on purpose: InputBoxTemplate is styled for one line, and
        -- Ctrl+C still copies the whole highlighted text.
        local edit = CreateFrame("EditBox", nil, pop, "InputBoxTemplate")
        edit:SetSize(500, 24)
        edit:SetPoint("TOP", pop, "TOP", 0, -42)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetScript("OnEscapePressed", function() pop:Hide() end)
        local close = CreateFrame("Button", nil, pop, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -3, -4)
        close:SetScript("OnClick", function() pop:Hide() end)
        WPL.exportBox = pop
        WPL.exportEdit = edit
    end
    WPL.exportEdit:SetText(export)
    WPL.exportBox:Show()
    WPL.exportEdit:SetFocus()
    WPL.exportEdit:HighlightText()
end

local function Cmd(text)
    local command = (text or ""):lower():match("^%s*(.-)%s*$")
    if command == "" or command == "toggle" then
        saved.visible = not panel:IsShown()
        if saved.visible then panel:Show() else panel:Hide() end
    elseif command == "show" then
        saved.visible = true; panel:Show()
    elseif command == "hide" then
        saved.visible = false; panel:Hide()
    elseif command == "reset" then
        session.duration = math.floor(GetElapsed())
        ArchiveSession(session)
        NewSession(); WPL.Refresh(); Print("Session archived and statistics reset.")
    elseif command == "lock" then
        saved.locked = not saved.locked
        panel:EnableMouse(not saved.locked)
        Print(saved.locked and "HUD locked. Clicks now pass through it." or "HUD unlocked. Drag with the left mouse button.")
    elseif command == "tip" then
        NextTip()
    elseif command == "stats" then
        ShowStats()
    elseif command == "history" then
        ShowHistory()
    elseif command == "levels" then
        ShowLevels()
    elseif command == "export" then
        ExportStats()
    elseif command == "center" then
        saved.x, saved.y = 0, 0
        panel:ClearAllPoints(); panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        panel:Show(); saved.visible = true
    elseif command == "track" then
        saved.keepTracking = saved.keepTracking == false
        trackingGaveUp, trackingTries = {}, {}
        Print(saved.keepTracking and "Keeping Find Minerals / Find Treasure on." or "No longer changing minimap tracking.")
        KeepTracking()
    elseif command == "debug" then
        saved.debug = not saved.debug
        Print(saved.debug and "Mining debug ON (prints spell IDs)." or "Mining debug OFF.")
    elseif command == "help" then
        Print("/wpl [toggle | show | hide | stats | history | levels | export | reset | tip | lock | center | track | debug | help]")
        Print("Ore is counted from YOUR loot messages. Mining casts are attempts, not unique veins.")
    else
        Print("Unknown command. Type /wpl help.")
    end
end

local events = CreateFrame("Frame")
-- Initialize on the first PLAYER_ENTERING_WORLD rather than ADDON_LOADED: by then
-- the player's XP and level are reliable, so the XP baseline can't start at 0.
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        local _, isReloadingUi = ...
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        local _, class = UnitClass("player")
        if class ~= "WARRIOR" then
            Print("WarriorPilot Lite is designed for Warriors; HUD disabled for this character.")
            return
        end
        isWarrior = true
        WarriorPilotLiteDB = WarriorPilotLiteDB or {}
        saved = WarriorPilotLiteDB
        StartSession(isReloadingUi)
        BuildPanel()
        SLASH_WARRIORPILOTLITE1 = "/wpl"
        SLASH_WARRIORPILOTLITE2 = "/warriorpilot"
        SlashCmdList["WARRIORPILOTLITE"] = Cmd

        self:RegisterEvent("PLAYER_XP_UPDATE")
        self:RegisterEvent("PLAYER_LEVEL_UP")
        self:RegisterEvent("PLAYER_DEAD")
        self:RegisterEvent("PLAYER_LOGOUT")
        self:RegisterEvent("CHAT_MSG_LOOT")
        self:RegisterEvent("QUEST_TURNED_IN")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
        -- Unit events filtered to the player so other units' power changes are ignored.
        self:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
        self:RegisterUnitEvent("UNIT_MAXPOWER", "player")
        self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        self:RegisterUnitEvent("UNIT_AURA", "player")
        -- Tracking can switch off on death or by hand, and the HUD may be hidden.
        self:RegisterEvent("MINIMAP_UPDATE_TRACKING")
        self:RegisterEvent("PLAYER_ALIVE")
        self:RegisterEvent("PLAYER_UNGHOST")
        self:RegisterEvent("ADDON_ACTION_BLOCKED")
        WPL.Refresh()
        Print("Loaded. /wpl help for commands. Drag to reposition.")
        return
    end

    if not session then return end
    if event == "PLAYER_XP_UPDATE" then
        SampleXP()
        WPL.Refresh()
    elseif event == "PLAYER_LEVEL_UP" then
        -- Close out the time spent on the old level and start the new one.
        local newLevel = Number((...))
        FlushLevelTime()
        if newLevel then
            levelMarkLevel = newLevel
            LevelEntry(newLevel, true)
        end
        -- The XP snapshot may still be from the previous level here. Sample a moment
        -- later so the gain shows without waiting for the next kill; SampleXP
        -- ignores stale values, so this can't double-count.
        C_Timer.After(1, function() SampleXP(); WPL.Refresh() end)
        if labels.tip then labels.tip:SetText(AddonTip()) end
    elseif event == "PLAYER_DEAD" then
        session.deaths = session.deaths + 1
        local entry = LevelEntry(levelMarkLevel)
        entry.deaths = entry.deaths + 1
        WPL.Refresh()
    elseif event == "QUEST_TURNED_IN" then
        local _, xpReward = ...
        local xp = Number(xpReward)
        if xp and xp > 0 then
            session.questXP = session.questXP + xp
            local entry = LevelEntry(levelMarkLevel)
            entry.questXP = entry.questXP + xp
            WPL.Refresh()
        end
    elseif event == "PLAYER_LOGOUT" then
        -- Fires on logout and /reload, just before SavedVariables are written.
        session.duration = math.floor(GetElapsed())
        FlushLevelTime()
    elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
        RefreshReadiness()
    elseif event == "MINIMAP_UPDATE_TRACKING" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        KeepTracking()
    elseif event == "ADDON_ACTION_BLOCKED" then
        local addon = ...
        if addon == "WarriorPilotLite" and not trackingBlocked then
            trackingBlocked = true
            Print("The game won't let addons switch tracking on. The HUD will remind you instead.")
            RefreshReadiness()
        end
    elseif event == "UNIT_AURA" then
        -- Out of combat only: Battle Shout falling off should show right away.
        if not InCombatLockdown() then RefreshReadiness() end
    elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXPOWER" then
        RefreshRage()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        TrackMiningCast(...)
    elseif event == "CHAT_MSG_LOOT" then
        TrackLoot(...)
    end
end)
