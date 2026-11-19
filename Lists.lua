-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Two small windows in Blizzard's look, opened from the menu: the watchlist (items you
-- want at or below a price of your own) and the ignore list (items hidden with a
-- right-click). Both replace chat commands.

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })
local GetItemInfo = ns.GetItemInfo
local floor, max, min = math.floor, math.max, math.min

local ROW_H, ROWS = 24, 10

local function DB() return ns.db end

local function Money(copper)
	return ns.Money and ns.Money(copper) or tostring(floor(copper or 0))
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99VendorFloor:|r " .. msg)
end

-- Item ID from a link, a number or the name of an item the client knows.
local function ItemID(text)
	text = strtrim(text or "")
	if text == "" then return nil end
	local id = tonumber(text:match("item:(%d+)") or text)
	if id then return id end
	local _, link = GetItemInfo(text)
	return link and tonumber(link:match("item:(%d+)"))
end

---------------------------------------------------------------------------
-- A list window: title, optional top area, rows with icon, text, detail and a remove button
---------------------------------------------------------------------------

local function ListWindow(name, title, topHeight)
	local ok, w = pcall(CreateFrame, "Frame", name, UIParent, "BasicFrameTemplateWithInset")
	if not ok or not w then
		w = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
		w:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 } })
		local close = CreateFrame("Button", nil, w, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -4, -4)
	end
	w:SetSize(420, 70 + topHeight + ROWS * ROW_H)
	w:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
	w:SetFrameStrata("DIALOG")
	w:SetToplevel(true)
	w:SetClampedToScreen(true)
	w:SetMovable(true)
	w:EnableMouse(true)
	w:RegisterForDrag("LeftButton")
	w:SetScript("OnDragStart", w.StartMoving)
	w:SetScript("OnDragStop", w.StopMovingOrSizing)
	local t = w.TitleText or w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	if not w.TitleText then t:SetPoint("TOP", 0, -16) end
	t:SetText(title)
	tinsert(UISpecialFrames, name) -- Escape closes it

	w.offset, w.rows = 0, {}
	local top = -30 - topHeight
	for i = 1, ROWS do
		local row = CreateFrame("Frame", nil, w)
		row:SetHeight(ROW_H)
		row:SetPoint("TOPLEFT", 14, top - (i - 1) * ROW_H)
		row:SetPoint("RIGHT", w, "RIGHT", -14, 0)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(ROW_H - 4, ROW_H - 4)
		row.icon:SetPoint("LEFT", 2, 0)
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		row.remove:SetSize(70, 20)
		row.remove:SetPoint("RIGHT", 0, 0)
		row.remove:SetText(L["Remove"])
		row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.detail:SetPoint("RIGHT", row.remove, "LEFT", -8, 0)
		row.detail:SetJustifyH("RIGHT")
		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
		row.text:SetPoint("RIGHT", row.detail, "LEFT", -6, 0)
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		row:EnableMouse(true)
		row:SetScript("OnEnter", function(self)
			if not self.id then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink("item:" .. self.id)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function(self)
			if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
		end)
		w.rows[i] = row
	end
	w.empty = w:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	w.empty:SetPoint("TOPLEFT", 20, top - 8)
	w.empty:SetPoint("RIGHT", w, "RIGHT", -20, 0)
	w.empty:SetJustifyH("LEFT")
	w.count = w:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	w.count:SetPoint("BOTTOMLEFT", 16, 14)
	w:EnableMouseWheel(true)
	w:SetScript("OnMouseWheel", function(self, delta)
		self.offset = self.offset - delta * 3
		self:Fill()
	end)

	-- items: { id, text, detail, remove = function }
	function w:Fill()
		local items = self:Items()
		self.offset = max(0, min(self.offset, max(#items - ROWS, 0)))
		for i, row in ipairs(self.rows) do
			local it = items[i + self.offset]
			row.id = it and it.id
			if it then
				local _, link, _, _, _, _, _, _, _, icon = GetItemInfo(it.id)
				row.icon:SetTexture(icon or 134400)
				row.text:SetText(link or it.text or ("item:" .. it.id))
				row.detail:SetText(it.detail or "")
				row.remove:SetScript("OnClick", function()
					it.remove()
					self:Fill()
					if ns.RefreshWindow then ns.RefreshWindow() end
				end)
				row:Show()
			else
				row:Hide()
			end
		end
		self.empty:SetShown(#items == 0)
		self.count:SetText(#items > ROWS and L["%d–%d of %d"]:format(self.offset + 1, min(self.offset + ROWS, #items), #items)
			or "")
	end
	w:SetScript("OnShow", function(self) self:Fill() end)
	w:Hide()
	return w
end

local function ByName(list)
	table.sort(list, function(a, b) return (a.text or ""):lower() < (b.text or ""):lower() end)
	return list
end

---------------------------------------------------------------------------
-- Ignore list
---------------------------------------------------------------------------

local ignoreWin

function ns.ToggleIgnoreList()
	if not ignoreWin then
		ignoreWin = ListWindow("VendorFloorIgnoreFrame", L["VendorFloor: ignore list"], 0)
		ignoreWin.empty:SetText(L["No hidden items. Right-click a find in the list to hide that item."])
		function ignoreWin:Items()
			local db, list = DB(), {}
			for id, name in pairs(db and db.ignore or {}) do
				list[#list + 1] = { id = id, text = type(name) == "string" and name or GetItemInfo(id),
					remove = function() db.ignore[id] = nil end }
			end
			return ByName(list)
		end
		local clear = CreateFrame("Button", nil, ignoreWin, "UIPanelButtonTemplate")
		clear:SetSize(120, 22)
		clear:SetPoint("BOTTOMRIGHT", -14, 10)
		clear:SetText(L["Show all again"])
		clear:SetScript("OnClick", function()
			local db = DB()
			if db then db.ignore = {} end
			ignoreWin:Fill()
			if ns.RefreshWindow then ns.RefreshWindow() end
		end)
	end
	ignoreWin:SetShown(not ignoreWin:IsShown())
end

---------------------------------------------------------------------------
-- Watchlist: itemID -> { max = copper per unit, qty = units still wanted (0: any), name }
---------------------------------------------------------------------------

local wishWin

local function WishDetail(want)
	local text = L["up to %s"]:format(Money(want.max))
	if (want.qty or 0) > 0 then text = text .. "  ·  " .. L["%d× wanted"]:format(want.qty) end
	return text
end

-- After a watchlist purchase: count down the units still wanted; done when none are left.
function ns.WishBought(itemID, qty, mode)
	local db = DB()
	if mode ~= "wish" or not (db and db.wishlist and db.wishlist[itemID]) then return end
	local want = db.wishlist[itemID]
	if (want.qty or 0) <= 0 then return end
	want.qty = want.qty - (qty or 1)
	if want.qty <= 0 then
		db.wishlist[itemID] = nil
		Print(L["Watchlist: %s complete, removed from the list."]:format(select(2, GetItemInfo(itemID)) or want.name or itemID))
	end
	if wishWin and wishWin:IsShown() then wishWin:Fill() end
end

local function InputBox(parent, width, label)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetSize(width, 22)
	box:SetAutoFocus(false)
	box:SetFontObject("GameFontHighlight")
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("BOTTOMLEFT", box, "TOPLEFT", -4, 2)
	fs:SetText(label)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	return box
end

-- Shift-click on an item puts its link into the focused item field.
local itemBox
local function InsertLink(link)
	if itemBox and itemBox:HasFocus() and link then
		itemBox:SetText(link)
		return true
	end
end
if ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", InsertLink) end
if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil, "InsertLink", InsertLink) end

function ns.ToggleWishlist()
	if not wishWin then
		wishWin = ListWindow("VendorFloorWishlistFrame", L["VendorFloor: watchlist"], 58)
		wishWin.empty:SetText(L["Nothing watched yet. Shift-click an item into the field above, set your price limit and click \"Add\"."])
		function wishWin:Items()
			local db, list = DB(), {}
			for id, want in pairs(db and db.wishlist or {}) do
				list[#list + 1] = { id = id, text = want.name or GetItemInfo(id), detail = WishDetail(want),
					remove = function() db.wishlist[id] = nil end }
			end
			return ByName(list)
		end
		itemBox = InputBox(wishWin, 170, L["Item (shift-click, name or ID)"])
		itemBox:SetPoint("TOPLEFT", 22, -54)
		local priceBox = InputBox(wishWin, 90, L["Max. price/unit"])
		wishWin.priceBox = priceBox
		priceBox:SetPoint("LEFT", itemBox, "RIGHT", 12, 0)
		local qtyBox = InputBox(wishWin, 40, L["Units"])
		qtyBox:SetPoint("LEFT", priceBox, "RIGHT", 12, 0)
		qtyBox:SetNumeric(true)
		local add = CreateFrame("Button", nil, wishWin, "UIPanelButtonTemplate")
		add:SetSize(64, 22)
		add:SetPoint("LEFT", qtyBox, "RIGHT", 8, 0)
		add:SetText(L["Add"])
		add:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine(L["Add to watchlist"])
			GameTooltip:AddLine(L["Price per unit, e.g. 50s or 1g 20s. Units: how many you want in total, empty for any number."], 1, 1, 1, true)
			GameTooltip:Show()
		end)
		add:SetScript("OnLeave", function(self)
			if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
		end)
		local function Add()
			local db = DB()
			local id = ItemID(itemBox:GetText())
			local price = ns.ParseMoney and ns.ParseMoney(priceBox:GetText())
			if not id then
				Print(L["Item not recognised. Shift-click it into the field, or type its exact name or ID."])
				return
			end
			if not price or price < 1 then
				Print(L["Amount not recognised. Examples: 50%s, 5s, 1g 20s"]:format(ns.COPPER or "c"))
				return
			end
			db.wishlist = db.wishlist or {}
			db.wishlist[id] = { max = price, qty = tonumber(qtyBox:GetText()) or 0, name = GetItemInfo(id) }
			itemBox:SetText("")
			priceBox:SetText("")
			qtyBox:SetText("")
			itemBox:ClearFocus()
			priceBox:ClearFocus()
			qtyBox:ClearFocus()
			wishWin:Fill()
			if ns.RefreshWindow then ns.RefreshWindow() end
		end
		add:SetScript("OnClick", Add)
		for _, box in ipairs({ itemBox, priceBox, qtyBox }) do box:SetScript("OnEnterPressed", Add) end
	end
	wishWin:SetShown(not wishWin:IsShown())
end

-- From a find's right-click menu: the watchlist with the item and its price filled in.
function ns.WishPrefill(itemID, price)
	if not wishWin then ns.ToggleWishlist() end
	wishWin:Show()
	local _, link = GetItemInfo(itemID)
	itemBox:SetText(link or tostring(itemID))
	wishWin.priceBox:SetText(price and ns.PlainMoney and ns.PlainMoney(price) or "")
	wishWin.priceBox:SetFocus()
end
