-- ============================================================================
-- PARRY TRACKER - 3.3.5a (Warmane / AzerothCore API)
-- Boss-Only Detection, Memory-Safe Tracking, Parry Haste Gib Reports
-- v1.11 - Excluded Pets from Chat Reports
-- ============================================================================
local addonNameFromClient, addonTable = ...
local PT = CreateFrame("Frame", "ParryTrackerFrame", UIParent)

-- ============================================================================
-- CONSTANTS & RAID BOSS DATABASE
-- ============================================================================
local PARRY_WINDOW = 2.5       
local SWING_HASTE_THRESH = 1.2 
local MAX_HISTORY = 20         

local FLAG_AFFILIATION_MINE  = 0x00000001
local FLAG_AFFILIATION_PARTY = 0x00000002
local FLAG_AFFILIATION_RAID  = 0x00000004
local FLAG_TYPE_PLAYER       = 0x00000400 
local FLAG_TYPE_PET          = 0x00001000
local FLAG_REACTION_HOSTILE  = 0x00000040

local RAID_TIERS = {
    "Naxxramas", "Obsidian Sanctum", "Eye of Eternity", "Ulduar", 
    "Trial of the Crusader", "Icecrown Citadel", "Ruby Sanctum", "Other"
}

local BOSS_DATA = {
    ["Naxxramas"] = {"Anub'Rekhan", "Grand Widow Faerlina", "Maexxna", "Noth the Plaguebringer", "Heigan the Unclean", "Loatheb", "Instructor Razuvious", "Gothik the Harvester", "Patchwerk", "Grobbulus", "Gluth", "Thaddius", "Feugen", "Stalagg", "Sapphiron", "Kel'Thuzad"},
    ["Obsidian Sanctum"] = {"Sartharion", "Tenebron", "Shadron", "Vesperon"},["Eye of Eternity"] = {"Malygos"},
    ["Ulduar"] = {"Flame Leviathan", "Ignis the Furnace Master", "Razorscale", "XT-002 Deconstructor", "Kologarn", "Auriaya", "Hodir", "Thorim", "Freya", "Mimiron", "General Vezax", "Yogg-Saron", "Algalon the Observer"},["Trial of the Crusader"] = {"Gormok the Impaler", "Acidmaw", "Dreadscale", "Icehowl", "Lord Jaraxxus", "Faction Champions", "Fjola Lightbane", "Eydis Darkbane", "Anub'arak"},
    ["Icecrown Citadel"] = {"Lord Marrowgar", "Lady Deathwhisper", "Deathbringer Saurfang", "Festergut", "Rotface", "Professor Putricide", "Blood Prince Council", "Blood Queen Lana'thel", "Sindragosa", "The Lich King"},["Ruby Sanctum"] = {"Halion"}
}

local NO_HASTE_DEFAULTS = {["Maexxna"] = true, ["Patchwerk"] = true, ["Gluth"] = true,["Thaddius"] = true,["Sapphiron"] = true, ["Feugen"] = true, ["Stalagg"] = true,
    ["Lord Marrowgar"] = true,["Lady Deathwhisper"] = true,["Deathbringer Saurfang"] = true, ["Festergut"] = true,["Rotface"] = true,["Professor Putricide"] = true, ["Blood Prince Council"] = true,["Blood Queen Lana'thel"] = true,["The Lich King"] = true,
    ["Faction Champions"] = true
}

-- ============================================================================
-- STATE & DATA
-- ============================================================================
local DB
local currentEncounter = nil
local inCombat = false
local damageHistory = {} 
local parryHistory = {}  
local lastSwing = {}     
local collapsedDates = {} 
local collapsedRaids = {} 

-- ============================================================================
-- CHAT QUEUE SYSTEM (Details! Style Line-by-Line)
-- ============================================================================
local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[ParryTracker]|r " .. msg) end

local ChatQueue = {}
local ChatFrame = CreateFrame("Frame")
local chatDelay = 0
ChatFrame:SetScript("OnUpdate", function(self, elapsed)
    if #ChatQueue > 0 then
        chatDelay = chatDelay + elapsed
        if chatDelay >= 0.2 then 
            chatDelay = 0
            local msg = table.remove(ChatQueue, 1)
            if GetNumRaidMembers() > 0 then
                SendChatMessage(msg, "RAID")
            else
                Print(msg)
            end
        end
    end
end)

local function QueueAnnounce(msg)
    msg = string.gsub(msg, "|", "-")
    table.insert(ChatQueue, msg)
end

-- ============================================================================
-- UTILITIES
-- ============================================================================
local function IsInGroup(flags) return bit.band(flags, FLAG_AFFILIATION_MINE) > 0 or bit.band(flags, FLAG_AFFILIATION_PARTY) > 0 or bit.band(flags, FLAG_AFFILIATION_RAID) > 0 end
local function IsPet(flags) return bit.band(flags, FLAG_TYPE_PET) > 0 end
local function IsPlayer(flags) return bit.band(flags, FLAG_TYPE_PLAYER) > 0 end
local function IsHostile(flags) return bit.band(flags, FLAG_REACTION_HOSTILE) > 0 end
local function IsValidRaidEnvironment()
    local inInst, instType = IsInInstance()
    if inInst then return instType == "raid" end
    return GetNumRaidMembers() > 0
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
        if #DB.encounters > 40 then table.remove(DB.encounters) end
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
            currentEncounter.parries[sourceName] = { count = 0, pet = isPetType, targets = {} }
        end
        currentEncounter.parries[sourceName].count = currentEncounter.parries[sourceName].count + 1
        currentEncounter.parries[sourceName].targets[destName] = (currentEncounter.parries[sourceName].targets[destName] or 0) + 1
    end

    if DB.options.announceDef and not DB.options.announceDeathOnly then
        if not isPetType or DB.options.trackPets then QueueAnnounce("[PT] " .. sourceName .. " was parried by " .. destName .. "!") end
    end
end

local function RecordDamage(timestamp, sourceGUID, sourceName, destGUID, amount, combatEvent)
    if not damageHistory[destGUID] then damageHistory[destGUID] = {} end
    table.insert(damageHistory[destGUID], {ts = timestamp, sg = sourceGUID, sn = sourceName, amt = amount, type = combatEvent})
    if #damageHistory[destGUID] > MAX_HISTORY then table.remove(damageHistory[destGUID], 1) end
end

local function CheckParryGib(timestamp, deadPlayerGUID, deadPlayerName)
    if not damageHistory[deadPlayerGUID] or not currentEncounter then return end
    
    local killers = {}
    for _, dmg in ipairs(damageHistory[deadPlayerGUID]) do
        if (timestamp - dmg.ts) <= 2.0 and dmg.type == "SWING_DAMAGE" then killers[dmg.sg] = dmg.sn end
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
        if bSet == nil or bSet.haste == true then QueueAnnounce(reportStr) end
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
                        DB.bossSettings[sourceName] = { haste = true, detectedOn = date("%Y-%m-%d %H:%M"), raid = "Other" }
                        Print("Auto-Detected Parry Haste mechanic on: " .. sourceName)
                    end
                    break
                end
            end
        end
    end
end

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
        if select(1, ...) == addonNameFromClient then
            ParryTrackerDB = ParryTrackerDB or { options = { announceDef = false, announceDeathOnly = true, trackPets = false }, bossSettings = {}, encounters = {} }
            DB = ParryTrackerDB
            
            for rName, rBosses in pairs(BOSS_DATA) do
                for _, bName in ipairs(rBosses) do
                    if DB.bossSettings[bName] == nil then 
                        DB.bossSettings[bName] = { haste = not NO_HASTE_DEFAULTS[bName], detectedOn = "Default", raid = rName } 
                    else
                        DB.bossSettings[bName].raid = rName 
                    end
                end
            end
            Print("v1.11 Loaded. Type /parry to open.")
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if IsValidRaidEnvironment() then inCombat = true; scanTimer = 1.0 end
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false; EndEncounter()
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
            if amount then RecordDamage(timestamp, sourceGUID, sourceName, destGUID, amount, combatEvent) end
        end

        if combatEvent == "UNIT_DIED" and isDestGroup and IsPlayer(destFlags) then CheckParryGib(timestamp, destGUID, destName) end
    end
end)

-- ============================================================================
-- USER INTERFACE
-- ============================================================================
local UI = CreateFrame("Frame", "PT_UI", UIParent)
UI:Hide(); UI:SetWidth(600); UI:SetHeight(480); UI:SetPoint("CENTER", 0, 0)
UI:EnableMouse(true); UI:SetMovable(true); UI:RegisterForDrag("LeftButton")
UI:SetScript("OnDragStart", UI.StartMoving); UI:SetScript("OnDragStop", UI.StopMovingOrSizing)
UI:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 }
})

UI.Title = UI:CreateFontString(nil, "OVERLAY", "GameFontNormal")
UI.Title:SetPoint("TOP", 0, -15); UI.Title:SetText("Parry Tracker v1.11")
UI.CloseBtn = CreateFrame("Button", "PT_CloseButton", UI, "UIPanelCloseButton")
UI.CloseBtn:SetPoint("TOPRIGHT", -5, -5)
UI.Content = CreateFrame("Frame", "PT_ContentFrame", UI)
UI.Content:SetPoint("TOPLEFT", 15, -40); UI.Content:SetPoint("BOTTOMRIGHT", -15, 15)

UI.Tabs = {}
local function SwitchTab(tabIndex)
    for i, tab in ipairs(UI.Tabs) do
        if i == tabIndex then tab.frame:Show(); tab:LockHighlight() else tab.frame:Hide(); tab:UnlockHighlight() end
    end
end
local function CreateTab(index, text, frame)
    local btn = CreateFrame("Button", "PT_TabBtn_"..index, UI, "OptionsButtonTemplate")
    btn:SetWidth(100); btn:SetText(text); btn:SetPoint("TOPLEFT", UI.Content, "TOPLEFT", 182 + ((index-1)*105), 0)
    btn.frame = frame; btn:SetScript("OnClick", function() SwitchTab(index) end)
    table.insert(UI.Tabs, btn); return btn
end

local function CreateScrollList(frameName, parent, width, height)
    local scroll = CreateFrame("ScrollFrame", frameName, parent, "UIPanelScrollFrameTemplate")
    scroll:SetWidth(width); scroll:SetHeight(height)
    local bg = CreateFrame("Frame", nil, scroll)
    bg:SetPoint("TOPLEFT", -5, 5); bg:SetPoint("BOTTOMRIGHT", 25, -5)
    bg:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    bg:SetFrameLevel(scroll:GetFrameLevel() - 1)
    local content = CreateFrame("Frame", frameName.."_Content", scroll)
    content:SetWidth(width - 20); content:SetHeight(height); scroll:SetScrollChild(content)
    return scroll, content
end

-- --- TAB 1: HISTORY ---
local TabHistory = CreateFrame("Frame", "PT_TabHistory", UI.Content)
TabHistory:SetPoint("TOPLEFT", 0, -30); TabHistory:SetPoint("BOTTOMRIGHT", 0, 0)

local searchBox = CreateFrame("EditBox", "PT_SearchBox", TabHistory, "InputBoxTemplate")
searchBox:SetSize(150, 20); searchBox:SetPoint("TOPLEFT", 90, 0); searchBox:SetAutoFocus(false)
searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
local searchLbl = TabHistory:CreateFontString(nil, "OVERLAY", "GameFontNormal")
searchLbl:SetPoint("RIGHT", searchBox, "LEFT", -10, 0); searchLbl:SetText("Search:")

local resetBtn = CreateFrame("Button", "PT_ResetBtn", TabHistory, "OptionsButtonTemplate")
resetBtn:SetSize(100, 22); resetBtn:SetPoint("TOPRIGHT", -100, 0); resetBtn:SetText("Reset DB")
local resetClicks = 0
local ResetTimerFrame = CreateFrame("Frame")
local resetDelay = 0
ResetTimerFrame:SetScript("OnUpdate", function(self, elapsed)
    if resetClicks == 1 then
        resetDelay = resetDelay + elapsed
        if resetDelay > 3.0 then
            resetClicks = 0; resetDelay = 0; PT_ResetBtn:SetText("Reset DB"); self:Hide()
        end
    end
end)
ResetTimerFrame:Hide()

resetBtn:SetScript("OnClick", function(self)
    resetClicks = resetClicks + 1
    if resetClicks == 1 then 
        self:SetText("Click Again!"); resetDelay = 0; ResetTimerFrame:Show()
    else 
        DB.encounters = {}; _G["PT_DetailsScroll_Content_Text"]:SetText(""); self:SetText("Cleared!")
        resetClicks = 0; ResetTimerFrame:Hide(); PT_SearchBox:SetText("")
    end
end)

local listScroll, listContent = CreateScrollList("PT_HistoryScroll", TabHistory, 400, 120)
listScroll:SetPoint("TOP", TabHistory, "TOP", -10, -25) 
local detailsScroll, detailsContent = CreateScrollList("PT_DetailsScroll", TabHistory, 420, 200)
detailsScroll:SetPoint("TOP", listScroll, "BOTTOM", 10, -20)
local detailsText = detailsContent:CreateFontString("PT_DetailsScroll_Content_Text", "OVERLAY", "GameFontHighlight")
detailsText:SetPoint("TOPLEFT", 0, -5); detailsText:SetWidth(400); detailsText:SetJustifyH("LEFT"); detailsText:SetJustifyV("TOP")

local function BuildEncounterDetails(enc)
    local str = "|cffffcc00Encounter:|r " .. enc.name .. "\n|cffaaaaaaTime:|r " .. date("%Y-%m-%d %H:%M:%S", enc.startTime) .. "\n\n|cffff0000Parry Leaderboard:|r\n"
    local pList = {}
    for name, data in pairs(enc.parries) do
        if data.boss then data.targets = { [data.boss] = data.count }; data.boss = nil end
        table.insert(pList, {n=name, c=data.count, p=data.pet, tgts=data.targets or {}}) 
    end
    table.sort(pList, function(a,b) return a.c > b.c end)
    
    for _, v in ipairs(pList) do
        local color = v.p and "|cff999999" or "|cffffffff"
        local petTag = v.p and " (Pet)" or ""
        local tgtsStr = ""
        local first = true
        for tName, tCount in pairs(v.tgts) do
            tgtsStr = tgtsStr .. (first and "" or ", ") .. string.format("%d on %s", tCount, tName); first = false
        end
        if tgtsStr == "" then tgtsStr = "Unknown" end
        str = str .. string.format(" - %s%s%s:|r %d parries (%s)\n", color, v.n, petTag, v.c, tgtsStr)
    end
    
    str = str .. "\n|cffff0000Deaths via Parry Haste:|r\n"
    if #enc.deaths == 0 then str = str .. " - None\n" else
        for _, d in ipairs(enc.deaths) do str = str .. string.format(" - [%s] %s (by %s)\n   |cffaaaaaaCausers: %s|r\n", d.time, d.dead, d.boss, d.causers) end
        str = str .. "\n|cff00ccff[Shift-Click] any button above to report encounter to chat.|r\n"
    end
    detailsText:SetText(str)
    detailsContent:SetHeight(detailsText:GetStringHeight() + 20)
end

local function ReportEncounterToChat(enc)
    QueueAnnounce("[PT] Encounter: " .. enc.name .. " (Parry Report)")
    local pList = {}
    for name, data in pairs(enc.parries) do 
        -- THE FIX: Skip all pets in the chat report!
        if not data.pet then
            if data.boss then data.targets = { [data.boss] = data.count }; data.boss = nil end
            table.insert(pList, {n=name, c=data.count, tgts=data.targets or {}}) 
        end
    end
    table.sort(pList, function(a,b) return a.c > b.c end)
    
    if #pList == 0 then
        QueueAnnounce("No player parries recorded.")
    else
        for i, v in ipairs(pList) do
            if i > 8 then QueueAnnounce("...and others."); break end
            local tgtsStr = ""
            local first = true
            for tName, tCount in pairs(v.tgts) do
                tgtsStr = tgtsStr .. (first and "" or ", ") .. string.format("%d on %s", tCount, tName); first = false
            end
            if tgtsStr == "" then tgtsStr = "Unknown" end
            QueueAnnounce(string.format("%d. %s: %d (%s)", i, v.n, v.c, tgtsStr))
        end
    end
    
    if #enc.deaths > 0 then
        QueueAnnounce("--- Deaths via Parry Haste ---")
        for i, d in ipairs(enc.deaths) do
            if i > 4 then QueueAnnounce("...and others."); break end
            QueueAnnounce(string.format("%s killed by %s (Caused by: %s)", d.dead, d.boss, d.causers))
        end
    end
end

local historyButtons = {}
local function UpdateHistoryList()
    for _, btn in pairs(historyButtons) do btn:Hide() end
    if not DB or not DB.encounters then return end
    
    local filter = string.lower(searchBox:GetText() or "")
    local renderData = {}
    local dateGroups = {}
    
    for _, enc in ipairs(DB.encounters) do
        if filter == "" or string.find(string.lower(enc.name), filter) then
            local dStr = date("%Y-%m-%d", enc.startTime)
            if not dateGroups[dStr] then dateGroups[dStr] = {}; table.insert(renderData, {isDate = true, dStr = dStr}) end
            table.insert(dateGroups[dStr], enc)
        end
    end
    
    local y = 0
    local btnIndex = 1
    for _, group in ipairs(renderData) do
        local dStr = group.dStr
        local dBtn = historyButtons[btnIndex]
        if not dBtn then dBtn = CreateFrame("Button", "PT_HistBtn_Date_"..btnIndex, listContent, "OptionsListButtonTemplate"); historyButtons[btnIndex] = dBtn end
        dBtn:SetWidth(380); dBtn:SetHeight(20); dBtn:SetPoint("TOP", listContent, "TOP", 0, -y)
        dBtn:SetNormalFontObject("GameFontNormal"); dBtn:SetHighlightFontObject("GameFontHighlight")
        
        local isCollapsed = collapsedDates[dStr]
        dBtn:SetText((isCollapsed and "[+] " or "[-] ") .. dStr)
        dBtn:SetScript("OnClick", function() collapsedDates[dStr] = not collapsedDates[dStr]; UpdateHistoryList() end)
        dBtn:Show(); y = y + 20; btnIndex = btnIndex + 1
        
        if not isCollapsed then
            for _, enc in ipairs(dateGroups[dStr]) do
                local eBtn = historyButtons[btnIndex]
                if not eBtn then eBtn = CreateFrame("Button", "PT_HistBtn_Enc_"..btnIndex, listContent, "OptionsListButtonTemplate"); historyButtons[btnIndex] = eBtn end
                eBtn:SetWidth(360); eBtn:SetHeight(20); eBtn:SetPoint("TOP", listContent, "TOP", 10, -y)
                eBtn:SetNormalFontObject("GameFontNormalSmall"); eBtn:SetHighlightFontObject("GameFontHighlightSmall")
                eBtn:SetText(date("%H:%M", enc.startTime) .. " - " .. enc.name)
                eBtn:SetScript("OnClick", function(self)
                    if IsShiftKeyDown() then ReportEncounterToChat(enc) else BuildEncounterDetails(enc) end
                end)
                eBtn:Show(); y = y + 20; btnIndex = btnIndex + 1
            end
        end
    end
    listContent:SetHeight(y + 10)
end
searchBox:SetScript("OnTextChanged", UpdateHistoryList)
resetBtn:HookScript("OnClick", function(self) if resetClicks == 0 then UpdateHistoryList() end end)

-- --- TAB 2: OPTIONS ---
local TabOptions = CreateFrame("Frame", "PT_TabOptions", UI.Content)
TabOptions:SetPoint("TOPLEFT", 0, -30); TabOptions:SetPoint("BOTTOMRIGHT", 0, 0); TabOptions:Hide()

local function CreateCheckbox(frameName, parent, label, key, yOffset)
    local cb = CreateFrame("CheckButton", frameName, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 160, yOffset); _G[frameName.."Text"]:SetText(label)
    cb:SetScript("OnShow", function(self) if DB then self:SetChecked(DB.options[key]) end end)
    cb:SetScript("OnClick", function(self) if DB then DB.options[key] = self:GetChecked() and true or false end end)
    return cb
end

CreateCheckbox("PT_OptCB_Announce", TabOptions, "Announce parries to chat automatically", "announceDef", -20)
CreateCheckbox("PT_OptCB_Deaths", TabOptions, "Only announce if it causes a death", "announceDeathOnly", -50)
CreateCheckbox("PT_OptCB_Pets", TabOptions, "Track Pet Parries", "trackPets", -80)

local bossOptTitle = TabOptions:CreateFontString(nil, "OVERLAY", "GameFontNormal")
bossOptTitle:SetPoint("TOP", TabOptions, "TOP", -60, -120); bossOptTitle:SetText("Boss Settings:")

local optSearch = CreateFrame("EditBox", "PT_OptSearch", TabOptions, "InputBoxTemplate")
optSearch:SetSize(120, 20); optSearch:SetPoint("LEFT", bossOptTitle, "RIGHT", 15, 0); optSearch:SetAutoFocus(false)
optSearch:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local bossScroll, bossContent = CreateScrollList("PT_BossScroll", TabOptions, 400, 180)
bossScroll:SetPoint("TOP", bossOptTitle, "BOTTOM", 60, -10)

local optRaidHeaders = {}
local optBossCheckboxes = {}

local function UpdateBossOptions()
    for _, child in pairs(optRaidHeaders) do child:Hide() end
    for _, child in pairs(optBossCheckboxes) do child:Hide() end
    if not DB or not DB.bossSettings then return end
    
    local filter = string.lower(optSearch:GetText() or "")
    local groupedData = {}
    
    for bName, bData in pairs(DB.bossSettings) do
        if filter == "" or string.find(string.lower(bName), filter) then
            local rName = bData.raid or "Other"
            if not groupedData[rName] then groupedData[rName] = {} end
            table.insert(groupedData[rName], bName)
        end
    end
    
    local y = 0
    for _, tier in ipairs(RAID_TIERS) do
        if groupedData[tier] then
            table.sort(groupedData[tier])
            
            local rBtn = optRaidHeaders[tier]
            if not rBtn then 
                rBtn = CreateFrame("Button", "PT_OptRaidBtn_"..string.gsub(tier, "[^%w]", ""), bossContent, "OptionsListButtonTemplate")
                optRaidHeaders[tier] = rBtn 
            end
            rBtn:SetWidth(380); rBtn:SetHeight(20); rBtn:SetPoint("TOP", bossContent, "TOP", 0, -y)
            rBtn:SetNormalFontObject("GameFontNormal"); rBtn:SetHighlightFontObject("GameFontHighlight")
            
            local isCollapsed = collapsedRaids[tier]
            rBtn:SetText((isCollapsed and "[+] " or "[-] ") .. tier)
            rBtn:SetScript("OnClick", function() collapsedRaids[tier] = not collapsedRaids[tier]; UpdateBossOptions() end)
            rBtn:Show(); y = y + 20
            
            if not isCollapsed then
                for _, bName in ipairs(groupedData[tier]) do
                    local cbName = "PT_OptBossCB_" .. string.gsub(bName, "[^%w]", "")
                    local cb = optBossCheckboxes[bName]
                    if not cb then 
                        cb = CreateFrame("CheckButton", cbName, bossContent, "UICheckButtonTemplate")
                        optBossCheckboxes[bName] = cb 
                    end
                    cb:SetPoint("TOPLEFT", bossContent, "TOPLEFT", 20, -y)
                    _G[cb:GetName().."Text"]:SetText(bName)
                    cb:SetChecked(DB.bossSettings[bName].haste)
                    cb:SetScript("OnClick", function(self) DB.bossSettings[bName].haste = self:GetChecked() and true or false end)
                    cb:Show(); y = y + 25
                end
            end
        end
    end
    bossContent:SetHeight(y + 10)
end
TabOptions:SetScript("OnShow", UpdateBossOptions)
optSearch:SetScript("OnTextChanged", UpdateBossOptions)

CreateTab(1, "History", TabHistory)
CreateTab(2, "Options", TabOptions)
SwitchTab(1)

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================
SLASH_PARRYTRACKER1 = "/parry"; SLASH_PARRYTRACKER2 = "/pt"
SlashCmdList["PARRYTRACKER"] = function()
    if UI:IsShown() then UI:Hide() else
        UpdateHistoryList()
        if DB and DB.encounters and #DB.encounters > 0 then BuildEncounterDetails(DB.encounters[1]) end
        UI:Show()
    end
end