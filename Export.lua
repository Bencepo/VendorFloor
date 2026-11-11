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
