local function Secret(v) -- chat hidden by the game (or faked by /cc secret)
  if CopyCatFakeSecret and CopyCatFakeSecret > GetTime() then return true end
  return issecretvalue ~= nil and issecretvalue(v) == true
end
-- Parley: instant-messenger whispers (character + Battle.net) with persistent history
local ADDON = ...
local P = CreateFrame("Frame")
local MAX_MSGS = 500
local db, win, mm, current
local cleanedThisLogin, realLogin = false, false   -- auto-clean state for this login

local defaults = { convos = {}, order = {}, hideInChat = false, sound = true, popup = true,
                   pos = nil, w = 540, h = 340, mmAngle = 200, mmHide = false, tabs = {}, autoClean = true }

local function IsBN(key) return key and key:sub(1, 3) == "BN:" end
local function Disp(key)
  local c = db.convos[key]
  if c and c.display then return c.display end
  return IsBN(key) and key:sub(4):gsub("#.*", "") or (key and key:gsub("%-.*", "")) or "?"
end
local function OwnRealms()
  local r = {}
  local a = GetNormalizedRealmName and GetNormalizedRealmName()
  local b = GetRealmName and GetRealmName()
  if a and a ~= "" then r[a] = true end
  if b and b ~= "" then r[b] = true; r[(b:gsub("[%s%-]", ""))] = true end
  return r
end
-- Character keys are the plain name for your own realm, "Name-Realm" only for other realms.
-- (WoW Forever rejects whispers addressed as "Name-<your own realm>".)
local function Norm(name)
  if not name or name == "" then return end
  local n, realm = name:match("^([^%-]+)%-(.+)$")
  if n and OwnRealms()[realm] then return n end
  return name
end

local function Touch(key)
  for i, n in ipairs(db.order) do if n == key then table.remove(db.order, i) break end end
  table.insert(db.order, 1, key)
end
local function Convo(key)
  local c = db.convos[key]
  if not c then c = { msgs = {}, unread = 0 }; db.convos[key] = c end
  return c
end
local function TotalUnread()
  local n = 0
  for _, c in pairs(db.convos) do n = n + (c.unread or 0) end
  return n
end

---------------------------------------------------------------- Battle.net helpers
local function BNTagFromID(id)
  if not id or not C_BattleNet or not C_BattleNet.GetAccountInfoByID then return end
  local info = C_BattleNet.GetAccountInfoByID(id)
  return info and info.battleTag
end
local function BNIDFromTag(tag)
  if not C_BattleNet or not C_BattleNet.GetFriendAccountInfo then return end
  for i = 1, (BNGetNumFriends() or 0) do
    local info = C_BattleNet.GetFriendAccountInfo(i)
    if info and info.battleTag == tag then return info.bnetAccountID end
  end
end

---------------------------------------------------------------- UI
local RefreshMinimap, RefreshTabs
local tabs, histRows = {}, {}

local MEDIA = "Interface\\AddOns\\Parley\\media\\"
-- Smileys: shown as pictures inside Parley only; the text code is what gets sent.
local EMOJI = {
  { ":)", "smile" }, { ":D", "grin" }, { ";)", "wink" }, { ":(", "sad" },
  { ":P", "tongue" }, { ":O", "surprised" }, { "xD", "laugh" }, { ":|", "neutral" },
  { "B)", "cool" }, { ">:(", "angry" }, { ":'(", "cry" }, { "<3", "heart" },
}
local EMO = {}
for _, e in ipairs(EMOJI) do EMO[e[1]] = e[2]; EMO[e[1]:lower()] = e[2] end
EMO["XD"] = "laugh"

local function Emojify(text)
  -- only whole words are converted, and never anything containing "|" (links, colour codes)
  return (text:gsub("%S+", function(w)
    if w:find("|", 1, true) then return end
    local f = EMO[w] or EMO[w:lower()]
    if f then return "|T" .. MEDIA .. f .. ":0|t" end
  end))
end

local RACE_TEX = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Races"
local RACE_TC = {
  HUMAN = { 0, 0.125, 0, 0.25 }, DWARF = { 0.125, 0.25, 0, 0.25 }, GNOME = { 0.25, 0.375, 0, 0.25 },
  NIGHTELF = { 0.375, 0.5, 0, 0.25 }, TAUREN = { 0, 0.125, 0.25, 0.5 }, SCOURGE = { 0.125, 0.25, 0.25, 0.5 },
  TROLL = { 0.25, 0.375, 0.25, 0.5 }, ORC = { 0.375, 0.5, 0.25, 0.5 },
}
local function RaceCoords(race, sex)
  if not race then return end
  local key = race:upper() .. "_" .. (sex == 3 and "FEMALE" or "MALE")
  if RACE_ICON_TCOORDS and RACE_ICON_TCOORDS[key] then return unpack(RACE_ICON_TCOORDS[key]) end
  local tc = RACE_TC[race:upper()]
  if not tc then return end
  local v = sex == 3 and 0.5 or 0          -- female row sits in the lower half of the texture
  return tc[1], tc[2], tc[3] + v, tc[4] + v
end

local function SaveInfo(c, race, raceL, cls, clsL, sex)
  if race and race ~= "" then c.race, c.raceL, c.sex = race, raceL, sex end
  if cls and cls ~= "" then c.class, c.classL = cls, clsL end
end

local function Format(key, m)
  local who = m.dir == "in" and ("|cffff80ff" .. Disp(key) .. "|r") or "|cff80c0ffMe|r"
  local col = IsBN(key) and "|cff00c8ff" or ""
  return ("|cff888888[%s]|r %s: %s%s|r"):format(date("%H:%M", m.t), who, col, Emojify(m.text))
end

local function IsOpenTab(key)
  for i, k in ipairs(db.tabs) do if k == key then return i end end
end
local function OpenTab(key)
  if not IsOpenTab(key) then table.insert(db.tabs, key) end
end

local function FindUnit(key)
  if not key or IsBN(key) then return end
  local list = { "target" }
  if IsInRaid() then for i = 1, 40 do list[#list + 1] = "raid" .. i end
  else for i = 1, 4 do list[#list + 1] = "party" .. i end end
  for _, u in ipairs(list) do
    if UnitExists(u) and UnitIsPlayer(u) and Norm(GetUnitName(u, true)) == key then return u end
  end
end

local function RefreshHeader()
  if not win then return end
  local p = win.portrait
  p:SetTexCoord(0, 1, 0, 1)
  if not current then
    win.title:SetText("Parley"); win.sub:SetText("")
    p:SetTexture("Interface\\ICONS\\INV_Letter_15")
    return
  end
  local c = Convo(current)
  local unit = FindUnit(current)
  if unit then
    local raceL, race = UnitRace(unit)
    local clsL, cls = UnitClass(unit)
    SaveInfo(c, race, raceL, cls, clsL, UnitSex(unit))
    SetPortraitTexture(p, unit)                 -- live portrait while grouped or targeted
  elseif c.race and RaceCoords(c.race, c.sex) then
    p:SetTexture(RACE_TEX); p:SetTexCoord(RaceCoords(c.race, c.sex))
  else
    p:SetTexture("Interface\\ICONS\\INV_Misc_QuestionMark")
  end
  win.title:SetText(Disp(current))
  local parts = {}
  if IsBN(current) then parts[#parts + 1] = "|cff00c8ffBattle.net|r" end
  if c.raceL then parts[#parts + 1] = c.raceL end
  if c.classL then
    local cc = c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
    local hex = cc and cc.colorStr or "ffffffff"
    parts[#parts + 1] = "|c" .. hex .. c.classL .. "|r"
  end
  win.sub:SetText(table.concat(parts, " · "))
end
P.RefreshHeader = RefreshHeader

local function RefreshMessages()
  if not win then return end
  win.msgs:Clear()
  RefreshHeader()
  if not current then return end
  for _, m in ipairs(Convo(current).msgs) do win.msgs:AddMessage(Format(current, m)) end
  win.msgs:ScrollToBottom()
end

RefreshTabs = function()
  if RefreshMinimap then RefreshMinimap() end
  if not win then return end
  for _, t in ipairs(tabs) do t:Hide() end
  local n = #db.tabs
  if n == 0 then return end
  local avail = win.tabbar:GetWidth()
  local w = math.min(120, math.floor(avail / n))
  local first = 1
  if w < 60 then                       -- too many: show the newest that fit, keep current visible
    w = 60
    local fit = math.max(1, math.floor(avail / w))
    first = n - fit + 1
    local ci = IsOpenTab(current)
    if ci and ci < first then first = ci end
  end
  local slot = 0
  for i = first, n do
    slot = slot + 1
    if slot * w > avail + 1 then break end
    local key = db.tabs[i]
    local t = tabs[slot]
    if not t then
      t = CreateFrame("Button", nil, win.tabbar, "BackdropTemplate")
      t:SetHeight(22)
      t:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
      t:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
      t.text = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      t.text:SetPoint("LEFT", 6, 0); t.text:SetPoint("RIGHT", -16, 0); t.text:SetJustifyH("LEFT"); t.text:SetWordWrap(false)
      t.x = CreateFrame("Button", nil, t, "UIPanelCloseButton"); t.x:SetSize(18, 18); t.x:SetPoint("RIGHT", 1, 0)
      t:SetScript("OnClick", function(self) P.Open(self.key) end)
      t.x:SetScript("OnClick", function(self) P.AskCloseTab(self:GetParent().key) end)
      tabs[slot] = t
    end
    t.key = key
    t:SetWidth(w - 2)
    t:ClearAllPoints(); t:SetPoint("BOTTOMLEFT", (slot - 1) * w, 0)
    local c = db.convos[key]
    local label = (IsBN(key) and "|cff00c8ff" or "|cffffffff") .. Disp(key) .. "|r"
    if c and c.unread > 0 then label = "|cffffd100" .. Disp(key) .. " (" .. c.unread .. ")|r" end
    t.text:SetText(label)
    if key == current then t:SetBackdropColor(0.25, 0.25, 0.35, 1); t:SetBackdropBorderColor(1, 0.82, 0, 1)
    else t:SetBackdropColor(0.08, 0.08, 0.1, 0.9); t:SetBackdropBorderColor(0.5, 0.5, 0.5, 1) end
    t:Show()
  end
end

local function SavePos()
  local p, _, rp, x, y = win:GetPoint()
  db.pos = { p, rp, x, y }; db.w, db.h = win:GetSize()
end

local function Send(text)
  if not current or not text or not text:match("%S") then return end
  if IsBN(current) then
    local id = Convo(current).bnID
    if not id or BNTagFromID(id) ~= current:sub(4) then id = BNIDFromTag(current:sub(4)) end
    if id then Convo(current).bnID = id; BNSendWhisper(id, text)
    else print("|cffff80ffParley|r: " .. Disp(current) .. " is not on your Battle.net friends list.") end
  else
    SendChatMessage(text, "WHISPER", nil, current)
  end
end

-- History popup: every saved conversation, click to reopen as a tab
local function ShowHistory()
  local h = win.hist
  if h:IsShown() then h:Hide() return end
  for _, r in ipairs(histRows) do r:Hide() end
  local n = 0
  for i, key in ipairs(db.order) do
    if i > 20 then break end
    n = i
    local r = histRows[i]
    if not r then
      r = CreateFrame("Button", nil, h)
      r:SetSize(150, 18); r:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 18)
      r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
      r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.text:SetAllPoints(); r.text:SetJustifyH("LEFT")
      r:SetScript("OnClick", function(self) h:Hide(); P.Open(self.key) end)
      histRows[i] = r
    end
    r.key = key
    r.text:SetText((IsBN(key) and "|cff00c8ff" or "") .. Disp(key) .. "|r |cff888888(" .. #Convo(key).msgs .. ")|r")
    r:Show()
  end
  if n == 0 then return end
  h:SetHeight(12 + n * 18)
  h:Show()
end

local function Build()
  win = CreateFrame("Frame", "ParleyFrame", UIParent, "BackdropTemplate")
  win:SetSize(db.w, db.h)
  if db.pos then win:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4]) else win:SetPoint("CENTER") end
  win:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  win:SetBackdropColor(0.05, 0.05, 0.08, 0.92)
  win:SetMovable(true); win:SetResizable(true); win:EnableMouse(true); win:SetClampedToScreen(true)
  if win.SetResizeBounds then win:SetResizeBounds(300, 210) elseif win.SetMinResize then win:SetMinResize(300, 210) end
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving)
  win:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePos() end)
  win:SetFrameStrata("HIGH")
  tinsert(UISpecialFrames, "ParleyFrame")

  win.portrait = win:CreateTexture(nil, "ARTWORK")
  win.portrait:SetSize(40, 40); win.portrait:SetPoint("TOPLEFT", 10, -8)
  if win.CreateMaskTexture then
    local mask = win:CreateMaskTexture()
    mask:SetTexture(MEDIA .. "mask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")  -- bundled circle mask
    mask:SetAllPoints(win.portrait)
    win.portrait:AddMaskTexture(mask)
  end
  local ring = win:CreateTexture(nil, "OVERLAY")
  ring:SetTexture(MEDIA .. "ring"); ring:SetSize(48, 48); ring:SetPoint("CENTER", win.portrait)

  win.title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  win.title:SetPoint("TOPLEFT", win.portrait, "TOPRIGHT", 10, -4); win.title:SetPoint("RIGHT", -100, 0); win.title:SetJustifyH("LEFT")
  win.sub = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  win.sub:SetPoint("TOPLEFT", win.title, "BOTTOMLEFT", 0, -4); win.sub:SetPoint("RIGHT", -100, 0); win.sub:SetJustifyH("LEFT")
  win.sub:SetTextColor(0.7, 0.7, 0.7)
  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 0, 0)

  local hb = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  hb:SetSize(60, 20); hb:SetPoint("RIGHT", close, "LEFT", 0, 0); hb:SetText("History")
  hb:SetScript("OnClick", ShowHistory)

  win.hist = CreateFrame("Frame", nil, win, "BackdropTemplate")
  win.hist:SetWidth(162); win.hist:SetPoint("TOPRIGHT", hb, "BOTTOMRIGHT", 0, -2)
  win.hist:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  win.hist:SetBackdropColor(0, 0, 0, 0.95); win.hist:SetFrameLevel(win:GetFrameLevel() + 20); win.hist:Hide()

  win.tabbar = CreateFrame("Frame", nil, win)
  win.tabbar:SetPoint("TOPLEFT", 8, -56); win.tabbar:SetPoint("TOPRIGHT", -8, -56); win.tabbar:SetHeight(22)
  win.tabbar:SetScript("OnSizeChanged", function() RefreshTabs() end)

  win.input = CreateFrame("EditBox", "ParleyInput", win, "InputBoxTemplate")
  local eb = CreateFrame("Button", nil, win)
  eb:SetSize(22, 22); eb:SetPoint("BOTTOMRIGHT", -18, 10)
  eb:SetNormalTexture(MEDIA .. "smile")
  eb:SetHighlightTexture(MEDIA .. "smile", "ADD")
  win.input:SetPoint("BOTTOMLEFT", 16, 10); win.input:SetPoint("BOTTOMRIGHT", eb, "BOTTOMLEFT", -6, 0)

  local pick = CreateFrame("Frame", nil, win, "BackdropTemplate")
  pick:SetSize(4 * 28 + 12, 3 * 28 + 12); pick:SetPoint("BOTTOMRIGHT", eb, "TOPRIGHT", 0, 4)
  pick:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  pick:SetBackdropColor(0, 0, 0, 0.95); pick:SetFrameLevel(win:GetFrameLevel() + 20); pick:Hide()
  for i, e in ipairs(EMOJI) do
    local b = CreateFrame("Button", nil, pick)
    b:SetSize(24, 24)
    b:SetPoint("TOPLEFT", 6 + ((i - 1) % 4) * 28, -6 - math.floor((i - 1) / 4) * 28)
    b:SetNormalTexture(MEDIA .. e[2]); b:SetHighlightTexture(MEDIA .. e[2], "ADD")
    b:SetScript("OnClick", function()
      local t = win.input:GetText()
      local pre = (t ~= "" and not t:match("%s$")) and " " or ""
      win.input:Insert(pre .. e[1] .. " ")
      win.input:SetFocus(); pick:Hide()
    end)
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(e[1]); GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
  end
  eb:SetScript("OnClick", function() pick:SetShown(not pick:IsShown()) end)
  win.pick = pick
  win.input:SetHeight(22); win.input:SetAutoFocus(false); win.input:SetMaxLetters(255)
  win.input:SetScript("OnEnterPressed", function(self) Send(self:GetText()); self:SetText("") end)
  win.input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  win.msgs = CreateFrame("ScrollingMessageFrame", nil, win)
  win.msgs:SetPoint("TOPLEFT", win.tabbar, "BOTTOMLEFT", 4, -6)
  win.msgs:SetPoint("BOTTOMRIGHT", win.input, "TOPRIGHT", 0, 6)
  win.msgs:SetFontObject(ChatFontNormal); win.msgs:SetJustifyH("LEFT")
  win.msgs:SetFading(false); win.msgs:SetMaxLines(MAX_MSGS); win.msgs:SetHyperlinksEnabled(true)
  win.msgs:EnableMouseWheel(true)
  win.msgs:SetScript("OnMouseWheel", function(self, d)
    if d > 0 then if IsShiftKeyDown() then self:ScrollToTop() else self:ScrollUp() end
    else if IsShiftKeyDown() then self:ScrollToBottom() else self:ScrollDown() end end
  end)
  win.msgs:SetScript("OnHyperlinkClick", function(_, link, text, button) SetItemRef(link, text, button) end)

  local grip = CreateFrame("Button", nil, win)
  grip:SetSize(14, 14); grip:SetPoint("BOTTOMRIGHT", -2, 2)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetScript("OnMouseDown", function() win:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function() win:StopMovingOrSizing(); SavePos() end)

  win:SetScript("OnShow", function() if current then Convo(current).unread = 0 end; RefreshTabs() end)
  win:SetScript("OnHide", function() win.hist:Hide(); win.pick:Hide() end)
  win:Hide()
end

function P.Open(key)
  if not win then Build() end
  if key then current = key end
  if current and not IsOpenTab(current) and not key then current = nil end
  current = current or db.tabs[#db.tabs]
  if current then OpenTab(current); Convo(current).unread = 0 end
  win:Show(); RefreshTabs(); RefreshMessages()
  if key then win.input:SetFocus() end
end

function P.Toggle() if win and win:IsShown() then win:Hide() else P.Open() end end

function P.CloseTab(key)
  local i = IsOpenTab(key)
  if i then table.remove(db.tabs, i) end
  if current == key then current = db.tabs[i] or db.tabs[#db.tabs] end
  if current then Convo(current).unread = 0 end
  RefreshTabs(); RefreshMessages()
end

function P.DeleteConvo(key)
  P.CloseTab(key)
  db.convos[key] = nil
  for i, n in ipairs(db.order) do if n == key then table.remove(db.order, i) break end end
  if win and win.hist:IsShown() then win.hist:Hide() end
  RefreshTabs()
end

StaticPopupDialogs["PARLEY_CLOSE_TAB"] = {
  text = "Close chat with %s.\n\nDelete the saved history too?",
  button1 = "Delete",
  button2 = "Keep",
  OnAccept = function(_, key) P.DeleteConvo(key) end,
  OnCancel = function(_, key) P.CloseTab(key) end,
  timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

function P.AskCloseTab(key)
  local dlg = StaticPopup_Show("PARLEY_CLOSE_TAB", Disp(key))
  if dlg then dlg.data = key else P.CloseTab(key) end
end

---------------------------------------------------------------- Minimap button
local function PlaceMM()
  local a = math.rad(db.mmAngle)
  local r = db.mmRadius or ((Minimap:GetWidth() / 2) + 10)
  mm:ClearAllPoints()
  mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function BuildMinimap()
  mm = CreateFrame("Button", "ParleyMinimapButton", Minimap)
  mm:SetSize(31, 31); mm:SetFrameStrata("MEDIUM"); mm:SetFrameLevel(8)
  mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local bg = mm:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background"); bg:SetVertexColor(0, 0, 0, 1)
  bg:SetSize(24, 24); bg:SetPoint("TOPLEFT", 7, -5)
  local icon = mm:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\ChatFrame\\UI-ChatWhisperIcon"); icon:SetSize(18, 18); icon:SetPoint("TOPLEFT", 7, -6)
  local border = mm:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); border:SetSize(50, 50); border:SetPoint("TOPLEFT")
  mm.badge = mm:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  mm.badge:SetPoint("BOTTOMRIGHT", -2, 2); mm.badge:SetTextColor(1, 0.82, 0)
  mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  mm:RegisterForDrag("LeftButton")
  mm:SetScript("OnClick", function(_, btn)
    if btn == "RightButton" then SlashCmdList.PARLEY("help") else P.Toggle() end
  end)
  mm:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local s = Minimap:GetEffectiveScale()
      local cx, cy = GetCursorPosition()
      local dx, dy = cx / s - mx, cy / s - my
      db.mmAngle = math.deg(math.atan2(dy, dx))
      PlaceMM()
    end)
  end)
  mm:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  mm:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Parley")
    local n = TotalUnread()
    GameTooltip:AddLine(n > 0 and (n .. " unread") or "No unread messages", 1, 1, 1)
    GameTooltip:AddLine("Left-click: open  |  Right-click: commands  |  Drag: move", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  mm:SetScript("OnLeave", GameTooltip_Hide)
  PlaceMM()
end

RefreshMinimap = function()
  if not mm then return end
  mm:SetShown(not db.mmHide)
  local n = TotalUnread()
  mm.badge:SetText(n > 0 and n or "")
end

---------------------------------------------------------------- Events
local function Store(key, dir, text, display, bnID, guid)
  if not db or not key then return end
  local c = Convo(key)
  if guid and guid ~= "" and GetPlayerInfoByGUID then
    local clsL, cls, raceL, race, sex = GetPlayerInfoByGUID(guid)
    SaveInfo(c, race, raceL, cls, clsL, sex)
  end
  if display then c.display = display end
  if bnID then c.bnID = bnID end
  table.insert(c.msgs, { t = time(), dir = dir, text = text })
  while #c.msgs > MAX_MSGS do table.remove(c.msgs, 1) end
  Touch(key)
  OpenTab(key)
  local visible = win and win:IsShown() and current == key
  if dir == "in" and not visible then
    c.unread = c.unread + 1
    if db.sound then PlaySound(IsBN(key) and (SOUNDKIT.UI_BNET_TOAST or 18019) or (SOUNDKIT.TELL_MESSAGE or 3081)) end
    if db.popup and not InCombatLockdown() and not (win and win:IsShown()) then
      P.Open(key); return
    end
  end
  if visible then win.msgs:AddMessage(Format(key, c.msgs[#c.msgs])); RefreshHeader() end
  RefreshTabs()
end

local function HandleBN(dir, text, bnID)
  if Secret(bnID) then return end
  if Secret(text) then text = "(hidden by game)" end
  local tag = BNTagFromID(bnID)
  if not tag then return end
  Store("BN:" .. tag, dir, text, (tag:gsub("#.*", "")), bnID)
end

P:RegisterEvent("ADDON_LOADED")
P:RegisterEvent("PLAYER_LOGIN")
P:RegisterEvent("CHAT_MSG_WHISPER")
P:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
P:RegisterEvent("CHAT_MSG_BN_WHISPER")
P:RegisterEvent("CHAT_MSG_BN_WHISPER_INFORM")
P:RegisterEvent("FRIENDLIST_UPDATE")
P:RegisterEvent("PLAYER_ENTERING_WORLD")
P:RegisterEvent("PLAYER_TARGET_CHANGED")
P:RegisterEvent("GROUP_ROSTER_UPDATE")
P:RegisterEvent("UNIT_PORTRAIT_UPDATE")
P:SetScript("OnEvent", function(_, ev, ...)
  if ev == "ADDON_LOADED" then
    if ... ~= ADDON then return end
    ParleyDB = ParleyDB or {}
    for k, v in pairs(defaults) do if ParleyDB[k] == nil then ParleyDB[k] = v end end
    db = ParleyDB
    if not db.chatShownV2 then db.hideInChat = false; db.chatShownV2 = true end  -- one-time: show whispers in main chat again
  elseif ev == "PLAYER_LOGIN" then
    P.MigrateKeys()
    BuildMinimap(); RefreshMinimap()
  elseif ev == "CHAT_MSG_WHISPER" then
    local text, sender = ...; if Secret(sender) then return end; if Secret(text) then text = "(hidden by game)" end; local k = Norm(sender); Store(k, "in", text, (sender:gsub("%-.*", "")), nil, (select(12, ...)))
  elseif ev == "CHAT_MSG_WHISPER_INFORM" then
    local text, target = ...; if Secret(target) then return end; if Secret(text) then text = "(hidden by game)" end; local k = Norm(target); Store(k, "out", text, (target:gsub("%-.*", "")), nil, (select(12, ...)))
  elseif ev == "CHAT_MSG_BN_WHISPER" then
    HandleBN("in", (...), (select(13, ...)))
  elseif ev == "CHAT_MSG_BN_WHISPER_INFORM" then
    HandleBN("out", (...), (select(13, ...)))
  elseif ev == "PLAYER_ENTERING_WORLD" then
    local isInitialLogin = ...
    if isInitialLogin and not cleanedThisLogin then   -- real login only, never on /reload or zoning
      realLogin = true
      if C_FriendList and C_FriendList.ShowFriends then C_FriendList.ShowFriends() end  -- ask the server for the friends list
    end
  elseif ev == "FRIENDLIST_UPDATE" then
    P.AutoClean()     -- runs once, after the friends list has loaded, so friends are never removed by mistake
  elseif ev == "PLAYER_TARGET_CHANGED" or ev == "GROUP_ROSTER_UPDATE" or ev == "UNIT_PORTRAIT_UPDATE" then
    if win and win:IsShown() then RefreshHeader() end
  end
end)

-- Auto-clean: at login, remove short one-sided chats (no reply either way) from earlier sessions.
-- Friends-list and Battle.net friends are never removed.
function P.AutoClean()
  if cleanedThisLogin or not realLogin or not db.autoClean then return end
  if not (C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetFriendInfoByIndex) then return end
  cleanedThisLogin = true
  local friends = {}
  for i = 1, C_FriendList.GetNumFriends() or 0 do
    local info = C_FriendList.GetFriendInfoByIndex(i)
    if info and info.name then friends[Norm(info.name)] = true end
  end
  local removed, keys = 0, {}
  for key in pairs(db.convos) do keys[#keys + 1] = key end
  for _, key in ipairs(keys) do
    local msgs = db.convos[key].msgs
    if not IsBN(key) and not friends[key] and #msgs <= 3 then
      local oneSided = true
      for i = 2, #msgs do if msgs[i].dir ~= msgs[1].dir then oneSided = false break end end
      if oneSided then
        db.convos[key] = nil
        for _, list in ipairs({ db.order, db.tabs }) do
          for i = #list, 1, -1 do if list[i] == key then table.remove(list, i) end end
        end
        if current == key then current = nil end
        removed = removed + 1
      end
    end
  end
  if removed > 0 then
    print("|cffff80ffParley|r: removed " .. removed .. " short unanswered chat" .. (removed == 1 and "" or "s") .. ". (/im autoclean to turn off)")
    RefreshTabs(); RefreshMessages()
  end
end

function P.MigrateKeys()
  local own = OwnRealms()
  local keys = {}
  for key in pairs(db.convos) do keys[#keys + 1] = key end   -- don't modify the table while iterating it
  for _, key in ipairs(keys) do
    local c = db.convos[key]
    if not IsBN(key) then
      local n, realm = key:match("^([^%-]+)%-(.+)$")
      if n and own[realm] then
        local dest = db.convos[n]
        if dest then
          for _, m in ipairs(c.msgs) do table.insert(dest.msgs, m) end
          table.sort(dest.msgs, function(x, y) return x.t < y.t end)
          while #dest.msgs > MAX_MSGS do table.remove(dest.msgs, 1) end
          dest.unread = (dest.unread or 0) + (c.unread or 0)
        else
          db.convos[n] = c
        end
        db.convos[key] = nil
        for _, list in ipairs({ db.order, db.tabs }) do
          for i = #list, 1, -1 do
            if list[i] == key then
              local dup = false
              for _, k in ipairs(list) do if k == n then dup = true end end
              if dup then table.remove(list, i) else list[i] = n end
            end
          end
        end
      end
    end
  end
end

local function Filter() return db and db.hideInChat end
for _, e in ipairs({ "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM" }) do
  ChatFrame_AddMessageEventFilter(e, Filter)
end

---------------------------------------------------------------- Slash
SLASH_PARLEY1, SLASH_PARLEY2 = "/parley", "/im"
SlashCmdList.PARLEY = function(msg)
  msg = msg or ""
  local cmd = msg:match("^(%S*)"):lower()
  local function say(s) print("|cffff80ffParley|r: " .. s) end
  if cmd == "" then P.Toggle()
  elseif cmd == "chat" then db.hideInChat = not db.hideInChat; say("whispers in main chat: " .. (db.hideInChat and "hidden" or "shown"))
  elseif cmd == "sound" then db.sound = not db.sound; say("sound " .. (db.sound and "on" or "off"))
  elseif cmd == "popup" then db.popup = not db.popup; say("auto-open " .. (db.popup and "on" or "off"))
  elseif cmd == "autoclean" then db.autoClean = not db.autoClean; say("auto-remove short unanswered chats at login: " .. (db.autoClean and "on" or "off"))
  elseif cmd == "minimap" then db.mmHide = not db.mmHide; RefreshMinimap(); say("minimap button " .. (db.mmHide and "hidden" or "shown"))
  elseif cmd == "clear" then db.convos, db.order, db.tabs, current = {}, {}, {}, nil; RefreshTabs(); RefreshMessages(); say("history cleared")
  elseif cmd == "resetbutton" then db.mmAngle = 200; if mm then PlaceMM() end; say("minimap button reset")
  elseif cmd == "reset" then db.pos = nil; if win then win:ClearAllPoints(); win:SetPoint("CENTER"); SavePos() end; say("window reset")
  elseif cmd == "help" then
    say("/im — toggle  |  /im Name — open chat with Name")
    say("/im chat | sound | popup | minimap | autoclean — toggle options;  /im clear — wipe history;  /im reset — recenter window;  /im resetbutton — reset minimap button")
  else
    -- WoW Forever names can be "First Last", so use the whole text and capitalise each word
    local name = msg:match("^%s*(.-)%s*$"):gsub("%s+", " ")
    name = name:gsub("(%S)(%S*)", function(a, b) return a:upper() .. b end)
    P.Open(Norm(name))
  end
end
