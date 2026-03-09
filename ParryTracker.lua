-- ============================================================================
-- PARRY TRACKER - 3.3.5a (Warmane / AzerothCore API)
-- Boss-Only Detection, Memory-Safe Tracking, Parry Haste Gib Reports
-- STRICTLY RAID ONLY (Ignores 5-man dungeons completely)
-- ============================================================================
local addonNameFromClient, addonTable = ...
local PT = CreateFrame("Frame", "ParryTrackerFrame", UIParent)

-- ============================================================================
-- CONSTANTS & DEFAULTS
-- ============================================================================
local PARRY_WINDOW = 2.5       
local SWING_HASTE_THRESH = 1.2 
local MAX_HISTORY = 20         

local FLAG_AFFILIATION_MINE  = 0x00000001
local FLAG_AFFILIATION_PARTY = 0x00000002
local FLAG_AFFILIATION_RAID  = 0x00000004
local FLAG_TYPE_PET          = 0x00001000
local FLAG_REACTION_HOSTILE  = 0x00000040

-- ============================================================================
-- STATE & DATA
-- ============================================================================
local DB
local currentEncounter = nil
local inCombat = false
local damageHistory = {} 
local parryHistory = {}  
local lastSwing = {}     

-- ============================================================================
-- UTILITIES & RAID-ONLY FILTERS
-- ============================================================================
local function Print(msg) 
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[ParryTracker]|r " .. msg) 
end

local function IsInGroup(flags) 
    return bit.band(flags, FLAG_AFFILIATION_MINE) > 0 or bit.band(flags, FLAG_AFFILIATION_PARTY) > 0 or bit.band(flags, FLAG_AFFILIATION_RAID) > 0 
end

local function IsPet(flags) 
    return bit.band(flags, FLAG_TYPE_PET) > 0 
end

local function IsHostile(flags) 
    return bit.band(flags, FLAG_REACTION_HOSTILE) > 0 
end

-- Checks if we are actually in a Raid environment (blocks 5-man Warmane LFDs)
local function IsValidRaidEnvironment()
    local inInstance, instanceType = IsInInstance()
    if inInstance then
        return instanceType == "raid"
    end
    -- Allow testing on open world target dummies only if actively in a raid group
    return GetNumRaidMembers() > 0
end

local function Announce(msg)
    if GetNumRaidMembers() > 0 then
        SendChatMessage(msg, "RAID")
    else
        Print(msg) -- Fallback if testing solo
    end
end

-- ============================================================================
-- CORE LOGIC (Combat Parsing & Tracking)
-- ============================================================================
local function StartEncounter(targetName)
    if currentEncounter then return end
    currentEncounter = { name = targetName or "Unknown Boss", startTime = time(), parries = {}, deaths = {} }
    Print("Raid Boss Encounter Started: " .. currentEncounter.name)
end

local function EndEncounter()
    if not currentEncounter then return end
    currentEncounter.endTime = time()
    local hasParries = false
    for _ in pairs(currentEncounter.parries) do hasParries = true break end
    if hasParries or #currentEncounter.deaths > 0 then
        table.insert(DB.encounters, 1, currentEncounter)
        if #DB.encounters > 20 then table.remove(DB.encounters) end
    end
    Print("Encounter Ended: " .. currentEncounter.name)
    currentEncounter = nil
    damageHistory = {}
    parryHistory = {}
    lastSwing = {}
end

local function RecordParry(timestamp, sourceName, destGUID, destName, isPetType)
    if not parryHistory[destGUID] then parryHistory[destGUID] = {} end
    table.insert(parryHistory[destGUID], {ts = timestamp, name = sourceName, pet = isPetType})
    if #parryHistory[destGUID] > MAX_HISTORY then table.remove(parryHistory[destGUID], 1) end

    if currentEncounter then
        if not currentEncounter.parries[sourceName] then
            currentEncounter.parries[sourceName] = { count = 0, pet = isPetType, boss = destName }
        end
        currentEncounter.parries[sourceName].count = currentEncounter.parries[sourceName].count + 1
    end

    if DB.options.announceDef and not DB.options.announceDeathOnly then
        if not isPetType or DB.options.trackPets then
            Announce("[PT] " .. sourceName .. " was parried by " .. destName .. "!")
        end
    end
end

local function RecordDamage(timestamp, sourceGUID, sourceName, destGUID, amount)
    if not damageHistory[destGUID] then damageHistory[destGUID] = {} end
    table.insert(damageHistory[destGUID], {ts = timestamp, sg = sourceGUID, sn = sourceName, amt = amount})
    if #damageHistory[destGUID] > MAX_HISTORY then table.remove(damageHistory[destGUID], 1) end
end

local function CheckParryGib(timestamp, deadPlayerGUID, deadPlayerName)
    if not damageHistory[deadPlayerGUID] or not currentEncounter then return end
    
    local killers = {}
    for _, dmg in ipairs(damageHistory[deadPlayerGUID]) do
        if (timestamp - dmg.ts) <= 2.0 then killers[dmg.sg] = dmg.sn end
    end

    local parryCausers = {}
    local bossWithHaste = nil

    for killerGUID, killerName in pairs(killers) do
        if parryHistory[killerGUID] then
            for _, parry in ipairs(parryHistory[killerGUID]) do
                if (timestamp - parry.ts) <= PARRY_WINDOW and parry.ts <= timestamp then
                    if not parry.pet or DB.options.trackPets then
                        parryCausers[parry.name] = true
                        bossWithHaste = killerName
                    end
                end
            end
        end
    end

    local causerList = {}
    for name, _ in pairs(parryCausers) do table.insert(causerList, name) end

    if #causerList > 0 and bossWithHaste then
        local causerStr = table.concat(causerList, ", ")
        local reportStr = string.format("[ParryTracker] %s died to %s. Caused by Parry Haste from: %s.", deadPlayerName, bossWithHaste, causerStr)
        
        table.insert(currentEncounter.deaths, { time = date("%H:%M:%S"), dead = deadPlayerName, boss = bossWithHaste, causers = causerStr, report = reportStr })

        local bSet = DB.bossSettings[bossWithHaste]
        if bSet == nil or bSet.haste == true then Announce(reportStr) end
    end
end

local function AutoDetectHaste(timestamp, sourceGUID, sourceName)
    local diff = timestamp - (lastSwing[sourceGUID] or 0)
    lastSwing[sourceGUID] = timestamp

    if diff > 0.1 and diff < SWING_HASTE_THRESH then
        if parryHistory[sourceGUID] then
            for _, parry in ipairs(parryHistory[sourceGUID]) do
                if (timestamp - parry.ts) <= (diff + 0.5) then
                    if not DB.bossSettings[sourceName] then
                        DB.bossSettings[sourceName] = { haste = true, detectedOn = date("%Y-%m-%d %H:%M") }
                        Print("Auto-Detected Parry Haste mechanic on: " .. sourceName)
                    end
                    break
                end
            end
        end
    end
end

-- ============================================================================
-- BOSS DETECTION SCANNER (Raid Only)
-- ============================================================================
local function GetBossName()
    if UnitExists("target") and not UnitIsFriend("player", "target") and UnitLevel("target") == -1 then return UnitName("target") end
    if UnitExists("focus") and not UnitIsFriend("player", "focus") and UnitLevel("focus") == -1 then return UnitName("focus") end
    
    for i = 1, GetNumRaidMembers() do
        local unit = "raid"..i.."target"
        if UnitExists(unit) and not UnitIsFriend("player", unit) and UnitLevel(unit) == -1 then return UnitName(unit) end
    end
    return nil
end

local BossScanner = CreateFrame("Frame")
local scanTimer = 0
BossScanner:SetScript("OnUpdate", function(self, elapsed)
    if not inCombat or currentEncounter then return end
    scanTimer = scanTimer + elapsed
    if scanTimer >= 1.0 then 
        scanTimer = 0
        local bossName = GetBossName()
        if bossName then StartEncounter(bossName) end
    end
end)

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================
PT:RegisterEvent("ADDON_LOADED")
PT:RegisterEvent("PLAYER_REGEN_DISABLED")
PT:RegisterEvent("PLAYER_REGEN_ENABLED")
PT:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

PT:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = select(1, ...)
        if loadedAddon == addonNameFromClient then
            ParryTrackerDB = ParryTrackerDB or { options = { announceDef = false, announceDeathOnly = true, trackPets = false }, bossSettings = {}, encounters = {} }
            DB = ParryTrackerDB
            Print("v1.6 Loaded (Raid-Only Mode). Type /parry to open.")
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Completely ignore combat if we are not in a raid
        if IsValidRaidEnvironment() then
            inCombat = true
            scanTimer = 1.0 
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        EndEncounter()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if not inCombat then return end

        local timestamp, combatEvent, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags = select(1, ...)
        local isSourceGroup, isDestGroup = IsInGroup(sourceFlags), IsInGroup(destFlags)
        local isSourceHostile, isDestHostile = IsHostile(sourceFlags), IsHostile(destFlags)

        if isDestHostile and isSourceGroup then
            local missType = nil
            if combatEvent == "SWING_MISSED" then missType = select(9, ...)
            elseif combatEvent == "SPELL_MISSED" or combatEvent == "SPELL_PERIODIC_MISSED" then missType = select(12, ...) end

            if missType == "PARRY" then RecordParry(timestamp, sourceName, destGUID, destName, IsPet(sourceFlags)) end
        end

        if isSourceHostile and isDestGroup then
            local amount = nil
            if combatEvent == "SWING_DAMAGE" then amount = select(9, ...); AutoDetectHaste(timestamp, sourceGUID, sourceName)
            elseif combatEvent == "SPELL_DAMAGE" or combatEvent == "SPELL_PERIODIC_DAMAGE" then amount = select(12, ...) end

            if amount then RecordDamage(timestamp, sourceGUID, sourceName, destGUID, amount) end
        end

        if combatEvent == "UNIT_DIED" and isDestGroup then CheckParryGib(timestamp, destGUID, destName) end
    end
end)

-- ============================================================================
-- USER INTERFACE (Cleaned & Centered Layout)
-- ============================================================================
local UI = CreateFrame("Frame", "PT_UI", UIParent)
UI:Hide()
UI:SetWidth(600)
UI:SetHeight(450)
UI:SetPoint("CENTER", 0, 0)
UI:EnableMouse(true)
UI:SetMovable(true)
UI:RegisterForDrag("LeftButton")
UI:SetScript("OnDragStart", UI.StartMoving)
UI:SetScript("OnDragStop", UI.StopMovingOrSizing)
UI:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})

UI.Title = UI:CreateFontString(nil, "OVERLAY", "GameFontNormal")
UI.Title:SetPoint("TOP", 0, -15)
UI.Title:SetText("Parry Tracker v1.6")

UI.CloseBtn = CreateFrame("Button", "PT_CloseButton", UI, "UIPanelCloseButton")
UI.CloseBtn:SetPoint("TOPRIGHT", -5, -5)

UI.Content = CreateFrame("Frame", "PT_ContentFrame", UI)
UI.Content:SetPoint("TOPLEFT", 15, -40)
UI.Content:SetPoint("BOTTOMRIGHT", -15, 15)

UI.Tabs = {}
local function SwitchTab(tabIndex)
    for i, tab in ipairs(UI.Tabs) do
        if i == tabIndex then tab.frame:Show(); tab:LockHighlight() else tab.frame:Hide(); tab:UnlockHighlight() end
    end
end

local function CreateTab(index, text, frame)
    local btn = CreateFrame("Button", "PT_TabBtn_"..index, UI, "OptionsButtonTemplate")
    btn:SetWidth(100)
    btn:SetText(text)
    btn:SetPoint("TOPLEFT", UI.Content, "TOPLEFT", 182 + ((index-1)*105), 0)
    btn.frame = frame
    btn:SetScript("OnClick", function() SwitchTab(index) end)
    table.insert(UI.Tabs, btn)
    return btn
end

-- ============================================================================
-- SCROLL LIST HELPER (With explicit Height and Background)
-- ============================================================================
local function CreateScrollList(frameName, parent, width, height)
    local scroll = CreateFrame("ScrollFrame", frameName, parent, "UIPanelScrollFrameTemplate")
    scroll:SetWidth(width)
    scroll:SetHeight(height)
    
    local bg = CreateFrame("Frame", nil, scroll)
    bg:SetPoint("TOPLEFT", -5, 5)
    bg:SetPoint("BOTTOMRIGHT", 25, -5)
    bg:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    bg:SetFrameLevel(scroll:GetFrameLevel() - 1)

    local content = CreateFrame("Frame", frameName.."_Content", scroll)
    content:SetWidth(width - 20)
    content:SetHeight(height)
    scroll:SetScrollChild(content)
    
    return scroll, content
end

-- ============================================================================
-- TAB 1: HISTORY (Centered List Top, Centered Details Bottom)
-- ============================================================================
local TabHistory = CreateFrame("Frame", "PT_TabHistory", UI.Content)
TabHistory:SetPoint("TOPLEFT", 0, -30)
TabHistory:SetPoint("BOTTOMRIGHT", 0, 0)

local listScroll, listContent = CreateScrollList("PT_HistoryScroll", TabHistory, 400, 120)
listScroll:SetPoint("TOP", TabHistory, "TOP", -10, -10) 

local detailsFrame = CreateFrame("Frame", "PT_DetailsFrame", TabHistory)
detailsFrame:SetPoint("TOP", listScroll, "BOTTOM", 10, -20)
detailsFrame:SetSize(450, 200)

local detailsText = detailsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
detailsText:SetPoint("TOPLEFT", 0, 0)
detailsText:SetJustifyH("LEFT")
detailsText:SetJustifyV("TOP")
detailsText:SetWidth(450)

local function BuildEncounterDetails(enc)
    local str = "|cffffcc00Encounter:|r " .. enc.name .. "\n"
    str = str .. "|cffaaaaaaTime:|r " .. date("%Y-%m-%d %H:%M:%S", enc.startTime) .. "\n\n"
    
    str = str .. "|cffff0000Parry Leaderboard:|r\n"
    local pList = {}
    for name, data in pairs(enc.parries) do table.insert(pList, {n=name, c=data.count, p=data.pet, b=data.boss}) end
    table.sort(pList, function(a,b) return a.c > b.c end)
    
    for _, v in ipairs(pList) do
        local color = v.p and "|cff999999" or "|cffffffff"
        local petTag = v.p and " (Pet)" or ""
        str = str .. string.format(" - %s%s%s:|r %d parries (on %s)\n", color, v.n, petTag, v.c, v.b)
    end
    
    str = str .. "\n|cffff0000Deaths via Parry Haste:|r\n"
    if #enc.deaths == 0 then
        str = str .. " - None\n"
    else
        for _, d in ipairs(enc.deaths) do str = str .. string.format(" - [%s] %s (by %s)\n   |cffaaaaaaCausers: %s|r\n", d.time, d.dead, d.boss, d.causers) end
        str = str .. "\n|cff00ccff[Shift-Click] any button above to report encounter to chat.|r\n"
    end
    detailsText:SetText(str)
end

local encounterButtons = {}
local function UpdateHistoryList()
    for _, btn in ipairs(encounterButtons) do btn:Hide() end
    if not DB or not DB.encounters then return end
    for i, enc in ipairs(DB.encounters) do
        local btn = encounterButtons[i]
        if not btn then
            btn = CreateFrame("Button", "PT_HistBtn_"..i, listContent, "OptionsListButtonTemplate")
            btn:SetWidth(380)
            btn:SetHeight(20)
            btn:SetPoint("TOP", listContent, "TOP", 0, -(i-1)*20)
            btn:SetNormalFontObject("GameFontNormalSmall")
            btn:SetHighlightFontObject("GameFontHighlightSmall")
            encounterButtons[i] = btn
        end
        btn:SetText(date("%H:%M", enc.startTime) .. " - " .. enc.name)
        btn:SetScript("OnClick", function(self, button)
            if IsShiftKeyDown() then
                local report = "[PT] Encounter: " .. enc.name .. " | Parries: "
                local pList = {}
                for name, data in pairs(enc.parries) do table.insert(pList, string.format("%s(%d)", name, data.count)) end
                Announce(report .. table.concat(pList, ", "))
            else
                BuildEncounterDetails(enc)
            end
        end)
        btn:Show()
    end
end

-- ============================================================================
-- TAB 2: OPTIONS (Everything Centered)
-- ============================================================================
local TabOptions = CreateFrame("Frame", "PT_TabOptions", UI.Content)
TabOptions:SetPoint("TOPLEFT", 0, -30)
TabOptions:SetPoint("BOTTOMRIGHT", 0, 0)
TabOptions:Hide()

local function CreateCheckbox(frameName, parent, label, key, yOffset)
    local cb = CreateFrame("CheckButton", frameName, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 160, yOffset)
    _G[frameName.."Text"]:SetText(label)
    cb:SetScript("OnShow", function(self) if DB then self:SetChecked(DB.options[key]) end end)
    cb:SetScript("OnClick", function(self) if DB then DB.options[key] = self:GetChecked() and true or false end end)
    return cb
end

local cb1 = CreateCheckbox("PT_OptCB_Announce", TabOptions, "Announce parries to chat automatically", "announceDef", -20)
local cb2 = CreateCheckbox("PT_OptCB_Deaths", TabOptions, "Only announce if it causes a death", "announceDeathOnly", -50)
local cb3 = CreateCheckbox("PT_OptCB_Pets", TabOptions, "Track Pet Parries", "trackPets", -80)

local bossOptTitle = TabOptions:CreateFontString(nil, "OVERLAY", "GameFontNormal")
bossOptTitle:SetPoint("TOP", TabOptions, "TOP", 0, -130)
bossOptTitle:SetText("Boss Parry Haste Settings (Auto-Detected shown below):")

local bossScroll, bossContent = CreateScrollList("PT_BossScroll", TabOptions, 400, 160)
bossScroll:SetPoint("TOP", bossOptTitle, "BOTTOM", -10, -10)

local bossButtons = {}
local function UpdateBossOptions()
    for _, child in pairs(bossButtons) do child:Hide() end
    if not DB or not DB.bossSettings then return end
    local y = 0
    for bossName, data in pairs(DB.bossSettings) do
        local cbName = "PT_BossCB_" .. string.gsub(bossName, "[^%w]", "")
        local cb = bossButtons[bossName]
        if not cb then
            cb = CreateFrame("CheckButton", cbName, bossContent, "UICheckButtonTemplate")
            bossButtons[bossName] = cb
        end
        cb:SetPoint("TOPLEFT", bossContent, "TOPLEFT", 20, y)
        _G[cbName.."Text"]:SetText(bossName .. " (Detected: " .. (data.detectedOn or "Manual") .. ")")
        cb:SetChecked(data.haste)
        cb:SetScript("OnClick", function(self) DB.bossSettings[bossName].haste = self:GetChecked() and true or false end)
        cb:Show()
        y = y - 30
    end
end

TabOptions:SetScript("OnShow", UpdateBossOptions)

CreateTab(1, "History", TabHistory)
CreateTab(2, "Options", TabOptions)
SwitchTab(1)

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================
SLASH_PARRYTRACKER1 = "/parry"
SLASH_PARRYTRACKER2 = "/pt"
SlashCmdList["PARRYTRACKER"] = function()
    if UI:IsShown() then UI:Hide() else
        UpdateHistoryList()
        if DB and DB.encounters and #DB.encounters > 0 then BuildEncounterDetails(DB.encounters[1]) end
        UI:Show()
    end
end