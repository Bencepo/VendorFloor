-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- /vfloor export: the ledger as JSON in a window, ready to copy (Ctrl+C) and paste
-- into the web page bencepo.github.io/vendorfloor. Nothing is sent anywhere.

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })
local floor = math.floor
local TITLE = "VendorFloor"
local SITE = "bencepo.github.io/vendorfloor"

local function A(t) return setmetatable(t or {}, { __arr = true }) end

local function enc(v, out)
  local t = type(v)
  if t == "nil" then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
    elseif v == math.floor(v) then out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = (string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", "")) end
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
      if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n"
      else return string.format("\\u%04x", c:byte()) end
    end) .. '"'
  elseif t == "table" then
    local n = #v
    local mt = getmetatable(v)
    local isArr = n > 0 or (mt and mt.__arr) or false
    if isArr then for k in pairs(v) do if type(k) ~= "number" then isArr = false break end end end
    if isArr then
      out[#out + 1] = "["
      for i = 1, n do if i > 1 then out[#out + 1] = "," end enc(v[i], out) end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      for k, val in pairs(v) do
        if not first then out[#out + 1] = "," end
        first = false
        enc(tostring(k), out) out[#out + 1] = ":" enc(val, out)
      end
      out[#out + 1] = "}"
    end
  else
    out[#out + 1] = "null"
  end
end

local exportFrame
local function showExport(text, summary)
  if not exportFrame then
    local win = CreateFrame("Frame", "VendorFloorExportFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    win:SetSize(560, 360)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    if win.SetBackdrop then
      win:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    end
    win.title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    win.title:SetPoint("TOPLEFT", 14, -12)
    win.title:SetText(TITLE)
    win.info = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.info:SetPoint("TOPLEFT", 14, -30)
    win.info:SetPoint("RIGHT", -40, 0)
    win.info:SetJustifyH("LEFT")
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    local scroll = CreateFrame("ScrollFrame", "VendorFloorExportScroll", win, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -64)
    scroll:SetPoint("BOTTOMRIGHT", -34, 14)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(500)
    edit:SetMaxLetters(0)
    edit:SetScript("OnEscapePressed", function() win:Hide() end)
    -- keep the text unchanged and selected so Ctrl+C always copies everything
    edit:SetScript("OnTextChanged", function(self, user)
      if user and win.text then self:SetText(win.text) self:HighlightText() end
    end)
    edit:SetScript("OnMouseUp", function(self) self:HighlightText() end)
    scroll:SetScrollChild(edit)
    win.edit = edit
    exportFrame = win
  end
  exportFrame.text = text
  exportFrame.info:SetText((summary or "") .. "\n" .. L["Press Ctrl+C, then paste it at %s. Esc closes."]:format(SITE))
  exportFrame.edit:SetText(text)
  exportFrame:Show()
  exportFrame.edit:SetFocus()
  exportFrame.edit:HighlightText()
end


local MAX_ITEMS = 150

local function buildExport()
	local db = ns.db
	local ledger = VendorFloor_Ledger()
	if not db or not ledger then return nil end
	local days = A()
	local keys = {}
	for k in pairs(ledger.days) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local d = ledger.days[k]
		days[#days + 1] = { d = k, buys = d.buys, spent = d.spent, sold = d.sold, soldCost = d.soldCost }
	end
	local items = {}
	for id, it in pairs(db.items or {}) do
		items[#items + 1] = { id = id, name = it.name, buys = it.buys or 0, units = it.units or 0, spent = it.spent or 0,
			value = it.value or 0, soldUnits = it.soldUnits or 0, sold = it.sold or 0, soldCost = floor(it.soldCost or 0),
			heldSec = it.heldSec and floor(it.heldSec) or nil, heldUnits = it.heldUnits }
	end
	table.sort(items, function(a, b) return (a.sold - a.soldCost) > (b.sold - b.soldCost) end)
	local top = A()
	for i = 1, math.min(#items, MAX_ITEMS) do top[#top + 1] = items[i] end
	local name, realm = UnitName("player"), GetRealmName and GetRealmName() or ""
	return { vendorFloor = 1, version = ns.VERSION, date = date("%Y-%m-%d %H:%M"), ts = time(),
		char = { name = name, realm = realm }, minProfit = db.minProfit,
		total = { buys = ledger.buys, spent = ledger.spent, sold = ledger.sold, soldCost = ledger.soldCost,
			profit = ledger.profit, unsoldUnits = ledger.unsoldUnits, unsoldValue = ledger.unsoldValue },
		days = days, items = top }
end

function ns.ShowExport()
	local ok, data = pcall(buildExport)
	if not ok or not data then
		DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99VendorFloor:|r " .. L["Export failed: %s"]:format(tostring(data)))
		return
	end
	local out = {}
	enc(data, out)
	local summary = L["%d buys, profit %s, still to sell %s"]:format(data.total.buys,
		ns.Money(data.total.profit), ns.Money(data.total.unsoldValue))
	showExport(table.concat(out), summary)
end

---------------------------------------------------------------------------
-- Minimap button and addon menu entry
---------------------------------------------------------------------------

-- A round button at the edge of the minimap. Drag it to move it; the angle is kept in
-- the saved table db (db.angle, db.hide). No libraries needed.
local function MinimapButton(name, icon, db, onClick, onTooltip)
	if not Minimap then return nil end
	local b = CreateFrame("Button", name, Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetSize(20, 20)
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetPoint("TOPLEFT", 7, -5)
	local art = b:CreateTexture(nil, "ARTWORK")
	art:SetSize(17, 17)
	art:SetTexture(icon)
	art:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	art:SetPoint("TOPLEFT", 7, -6)
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetPoint("TOPLEFT")
	local function place()
		local a = math.rad(db.angle or 225)
		local r = (Minimap:GetWidth() / 2) + 10
		b:ClearAllPoints()
		b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
	end
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			db.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
			place()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnClick", function(_, button) onClick(button) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		onTooltip(GameTooltip)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function(self)
		if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
	end)
	place()
	b:SetShown(not db.hide)
	return b
end

-- Minimap icon through LibDataBroker and LibDBIcon (shipped in Libs), so minimap button
-- managers can collect it. The own button above is only used if the libraries are missing.
local function MinimapIcon(name, icon, db, onClick, onTooltip)
	local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
	local dbi = LibStub and LibStub("LibDBIcon-1.0", true)
	if not (ldb and dbi) then return MinimapButton(name .. "MinimapButton", icon, db, onClick, onTooltip) end
	if db.minimapPos == nil and db.angle then db.minimapPos = db.angle % 360 end
	local obj = ldb:GetDataObjectByName(name) or ldb:NewDataObject(name, {
		type = "launcher", label = name, icon = icon,
		OnClick = function(_, button) onClick(button) end,
		OnTooltipShow = function(tip) onTooltip(tip) end,
	})
	if not dbi:IsRegistered(name) then dbi:Register(name, obj, db) end
	return { SetShown = function(_, show) if show then dbi:Show(name) else dbi:Hide(name) end end }
end

local minimapButton

local function MinimapClick(button)
	if button == "RightButton" then
		DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99VendorFloor:|r " .. ns.TotalLine())
	elseif AuctionHouseFrame and AuctionHouseFrame:IsShown() then
		SlashCmdList.VENDORFLOOR("")
	else
		ns.ShowExport()
	end
end

local function MinimapTooltip(tip)
	tip:AddLine("VendorFloor " .. (ns.VERSION or ""))
	local l = VendorFloor_Ledger()
	if l then
		local today = l.days[date("%Y-%m-%d")]
		tip:AddDoubleLine(L["Profit today"], ns.Money(today and floor((today.sold or 0) - (today.soldCost or 0)) or 0), 1, 1, 1, 1, 1, 1)
		tip:AddDoubleLine(L["Profit total"], ns.Money(l.profit), 1, 1, 1, 1, 1, 1)
		tip:AddDoubleLine(L["Still to sell"], ns.Money(l.unsoldValue), 1, 1, 1, 1, 1, 1)
	end
	tip:AddLine(" ")
	tip:AddLine(L["Left-click: ledger for bencepo.github.io/vendorfloor (at the auction house: window)"], 0.6, 0.8, 1, true)
	tip:AddLine(L["Right-click: totals in chat"], 0.6, 0.8, 1)
	tip:AddLine(L["Drag: move. /vfloor minimap: hide or show"], 0.6, 0.8, 1)
end

local function MinimapSettings()
	ns.db.minimap = ns.db.minimap or {}
	return ns.db.minimap
end

function ns.ToggleMinimap()
	local st = MinimapSettings()
	st.hide = not st.hide
	if minimapButton then minimapButton:SetShown(not st.hide) end
	return not st.hide
end

local minimapEvents = CreateFrame("Frame")
minimapEvents:RegisterEvent("PLAYER_LOGIN")
minimapEvents:SetScript("OnEvent", function()
	if not ns.db then return end
	local ok, b = pcall(MinimapIcon, "VendorFloor", "Interface\\Icons\\INV_Misc_Coin_02",
		MinimapSettings(), MinimapClick, MinimapTooltip)
	if ok then
		minimapButton = b
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99VendorFloor:|r minimap button failed: " .. tostring(b))
	end
end)

function VendorFloor_OnCompartmentClick(_, button)
	MinimapClick(button)
end
