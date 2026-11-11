-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Finds auction house listings priced below what a vendor pays and buys them on
-- click or key press. Standalone, no libraries. It touches neither Auctionator nor
-- the Blizzard window: it only sends its own auction house queries and shows its
-- own window. Every purchase needs a click or key press of its own.

local ADDON, ns = ...
local L = ns.L
local AH = C_AuctionHouse
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local floor, min, max = math.floor, math.min, math.max

local VERSION = GetMetadata and GetMetadata(ADDON, "Version") or ""
if VERSION == "" or VERSION:find("^@") then VERSION = "dev" end

local PREFIX = "|cff33ff99VendorFloor:|r "
local ROWS, ROW_HEIGHT = 12, 20
local SEND_TIMEOUT = 15

local defaults = {
	minProfit = 100,      -- minimum profit per unit in copper (distance to the vendor price): 1 silver
	minProfitSilver = 1,  -- the same in silver, for the slider in the settings
	sound = true,         -- sound on a new find
	loop = false,         -- continuous mode: scan again after each round
	interval = 20,        -- seconds between two rounds
}
local db

local deals, order = {}, {}   -- confirmed finds: by key and as a sorted list
local queue, queued = {}, {}  -- finds still to be checked (list and by key)
local pendingInfo = {}        -- itemID -> browse result whose item data is still loading
local pendingBuys = {}        -- auctionID -> item purchase waiting for confirmation
local scan = { active = false, seen = 0, round = 0 }
local buy = {}                -- state of the find being checked or bought
local session = { buys = 0, spent = 0, value = 0 }
local selected
local pendingSend, lastSend, sentAt, tries = nil, nil, nil, 0
local ahOpen = false
local offset = 0
local statusText = ""
local lastSound = 0
local ui

local StartScan, StopScan, Verify, ResetBuy, Refresh

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

local function Money(copper)
	copper = floor(copper or 0)
	if copper < 0 then copper = 0 end
	local g, s, c = floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
	local text = ""
	if g > 0 then text = ("|cffffd700%dg|r "):format(g) end
	if g > 0 or s > 0 then text = text .. ("|cffc7c7cf%ds|r "):format(s) end
	return text .. ("|cffeda55f%d%s|r"):format(c, ns.COPPER)
end

-- Amount without colours, for the input field: "1g 20s 5c"
local function PlainMoney(copper)
	copper = floor(copper or 0)
	local g, s, c = floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
	local parts = {}
	if g > 0 then parts[#parts + 1] = g .. "g" end
	if s > 0 then parts[#parts + 1] = s .. "s" end
	if c > 0 or #parts == 0 then parts[#parts + 1] = c .. ns.COPPER end
	return table.concat(parts, " ")
end

-- Reads "5s", "1g 20s", "50c", "50k" or a bare number (copper). nil when nothing is readable.
local function ParseMoney(text)
	text = (text or ""):lower()
	if tonumber(text) then return floor(tonumber(text)) end
	local total, found = 0, false
	for number, unit in text:gmatch("(%d+)%s*([gskc])") do
		local value = tonumber(number)
		if unit == "g" then value = value * 10000 elseif unit == "s" then value = value * 100 end
		total, found = total + value, true
	end
	return found and total or nil
end

local function SetStatus(msg)
	statusText = msg or ""
	if ui then ui.status:SetText(statusText) end
end

---------------------------------------------------------------------------
-- Queries: only one at a time, and only once the auction house is ready
---------------------------------------------------------------------------

local function Send(fn)
	pendingSend, lastSend = fn, fn
end

local SORTS = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }

local function BrowseQuery()
	local filters = {}
	for _, name in ipairs({ "PoorQuality", "CommonQuality", "UncommonQuality", "RareQuality",
		"EpicQuality", "LegendaryQuality", "ArtifactQuality" }) do
		local value = Enum.AuctionHouseFilter and Enum.AuctionHouseFilter[name]
		if value ~= nil then filters[#filters + 1] = value end
	end
	return { searchString = "", minLevel = 0, maxLevel = 0, filters = filters, itemClassFilters = {}, sorts = SORTS }
end

---------------------------------------------------------------------------
-- Finds
---------------------------------------------------------------------------

local function DealKey(key)
	return (key.itemID or 0) .. ":" .. (key.itemLevel or 0) .. ":" .. (key.itemSuffix or 0) .. ":" .. (key.battlePetSpeciesID or 0)
end

local function RemoveDeal(d)
	d.dropped = true
	deals[d.k] = nil
	for i = #order, 1, -1 do
		if order[i] == d then table.remove(order, i) end
	end
	if selected == d then selected = nil end
end

-- Best total profit first.
local function SortDeals()
	table.sort(order, function(a, b)
		local pa, pb = a.profit or 0, b.profit or 0
		if pa ~= pb then return pa > pb end
		return a.k < b.k
	end)
end

-- Vendor price per unit; nil while the item data is still loading.
local function VendorPrice(item)
	local name, link, _, _, _, _, _, _, _, icon, sell = GetItemInfo(item)
	if not name then return nil end
	return sell or 0, name, link, icon
end

local function IsIgnored(itemID)
	return db.ignore and db.ignore[itemID] and true or false
end

-- Take the find into the list and announce it.
local function Confirm(d)
	if d.dropped or deals[d.k] then return end
	deals[d.k] = d
	order[#order + 1] = d
	Print(L["%s below vendor price: %d× for %s each, vendor pays %s"]:format(d.link or d.name, d.count or 1,
		Money(d.price), Money(d.vendor)))
	if db.sound and GetTime() - lastSound > 2 then
		lastSound = GetTime()
		PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
	end
end

-- Every candidate is checked against its real auctions before it is listed: an item
-- may have bid-only auctions, and for stackable goods the check counts how many units
-- lie below the vendor price. Once per round.
local function Enqueue(d)
	if d.queuedRound == scan.round then return end
	d.queuedRound = scan.round
	queue[#queue + 1] = d
end

local function Evaluate(result)
	local key = result.itemKey
	local id, price = key.itemID, result.minPrice
	if IsIgnored(id) then return end
	local vendor, name, link, icon = VendorPrice(id)
	if vendor == nil then
		pendingInfo[id] = result
		if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
		return
	end
	if vendor <= 0 or vendor - price < db.minProfit then return end
	local k = DealKey(key)
	local d = deals[k] or queued[k]
	if not d then
		d = { k = k }
		queued[k] = d
	end
	d.key, d.id, d.vendor, d.listed = key, id, vendor, result.totalQuantity or 0
	d.name, d.link, d.icon, d.stale, d.dropped = name, link, icon, false, nil
	d.price = d.price or price
	Enqueue(d)
end

local function Process(results)
	if type(results) ~= "table" then return end
	for _, result in ipairs(results) do
		local key = result.itemKey
		if key and key.itemID and result.minPrice and result.minPrice > 0 then
			scan.seen = scan.seen + 1
			Evaluate(result)
		end
	end
end

-- Set the minimum distance to the vendor price (copper per unit). Finds below it leave the list.
local function SetMinProfit(copper)
	db.minProfit = max(floor(copper), 1)
	db.minProfitSilver = floor(db.minProfit / 100)
	for i = #order, 1, -1 do
		local d = order[i]
		if d.vendor - d.price < db.minProfit and d ~= buy.deal then RemoveDeal(d) end
	end
	if ui then ui.profit:SetText(PlainMoney(db.minProfit)) end
	SetStatus(L["Minimum profit per unit: %s"]:format(Money(db.minProfit)))
	Refresh()
end

-- Hide an item for good (right-click on a row).
local function Ignore(d)
	db.ignore = db.ignore or {}
	db.ignore[d.id] = d.name or true
	RemoveDeal(d)
	for _, other in pairs(deals) do
		if other.id == d.id then RemoveDeal(other) end
	end
	Print(L["Hidden: %s. /vfloor ignore clear shows it again."]:format(d.link or d.name or d.id))
	Refresh()
end

---------------------------------------------------------------------------
-- Ledger: what was bought, for how much, and what a vendor pays for it
---------------------------------------------------------------------------

local function LedgerText(t)
	return t.buys, Money(t.spent), Money(t.value), Money(t.value - t.spent)
end

local function Record(cost, value)
	session.buys, session.spent, session.value = session.buys + 1, session.spent + cost, session.value + value
	local total = db.total
	total.buys, total.spent, total.value = total.buys + 1, total.spent + cost, total.value + value
	if ui then ui.ledger:SetText(L["Session: %d buys, spent %s, vendor value %s, profit %s"]:format(LedgerText(session))) end
end

---------------------------------------------------------------------------
-- Scan: the whole auction house item list, page by page
---------------------------------------------------------------------------

StartScan = function()
	if not ahOpen then
		Print(L["The auction house must be open."])
		return
	end
	if buy.state then return end
	scan.active, scan.seen, scan.nextAt = true, 0, nil
	scan.round = scan.round + 1
	tries = 0
	wipe(queue)
	wipe(queued)
	for _, d in ipairs(order) do d.stale = true end
	Send(function() AH.SendBrowseQuery(BrowseQuery()) end)
	SetStatus(L["Scanning …"])
	Refresh()
end

StopScan = function(msg)
	scan.active, scan.nextAt = false, nil
	pendingSend, sentAt = nil, nil
	if msg then SetStatus(msg) end
	Refresh()
end

local function RoundDone()
	SetStatus(L["Round done: %d items read, %d below vendor price."]:format(scan.seen, #order))
	if db.loop then scan.nextAt = GetTime() + db.interval end
end

local function FinishScan()
	scan.active, sentAt = false, nil
	for i = #order, 1, -1 do
		local d = order[i]
		if d.stale and d ~= buy.deal then RemoveDeal(d) end
	end
	if queue[1] then
		SetStatus(L["%d items read. Checking %d candidates …"]:format(scan.seen, #queue))
	else
		RoundDone()
	end
	Refresh()
end

local function ContinueScan()
	sentAt, tries = nil, 0
	if AH.HasFullBrowseResults() then
		FinishScan()
	else
		Send(function() AH.RequestMoreBrowseResults() end)
		SetStatus(L["Scanning … %d items read, %d finds"]:format(scan.seen, #order + #queue))
		Refresh()
	end
end

---------------------------------------------------------------------------
-- Checking and buying: read the item's real auctions first
---------------------------------------------------------------------------

local function CancelQuote()
	if AH.CancelCommoditiesPurchase then pcall(AH.CancelCommoditiesPurchase) end
end

ResetBuy = function(msg)
	wipe(buy)
	if msg then SetStatus(msg) end
	if db.loop and ahOpen and ui and ui:IsShown() and not queue[1] then scan.nextAt = GetTime() + 5 end
	Refresh()
end

-- purpose "buy": the find was clicked and is to be bought.
-- purpose "check": the round checks whether the find is real.
Verify = function(d, purpose)
	if not ahOpen then return end
	if scan.active then StopScan() end
	purpose = purpose or "buy"
	if purpose == "buy" then scan.nextAt = nil end
	wipe(buy)
	buy.state, buy.deal, buy.t, buy.purpose = "verifying", d, GetTime(), purpose
	tries = 0
	Send(function() AH.SendSearchQuery(d.key, SORTS, true) end)
	if purpose == "check" then
		SetStatus(L["Checking: %s (%d left)"]:format(d.link or d.name or "?", #queue))
	else
		SetStatus(L["Checking %s …"]:format(d.link or d.name or "?"))
	end
	Refresh()
end

-- Result of a check: with real offers into the list, without them out of it.
-- offer: { unit = cheapest unit price, count = units below vendor price, profit = total profit }
local function FinishCheck(d, offer)
	if offer then
		d.price, d.count, d.profit = offer.unit, offer.count, offer.profit
		Confirm(d)
		SortDeals()
	elseif deals[d.k] then
		RemoveDeal(d)
	end
	queued[d.k] = nil
	wipe(buy)
	if not queue[1] and not scan.active then RoundDone() end
	Refresh()
end

-- Stackable goods (one price per unit): how many units lie below the vendor price?
-- limit: the gold that may be spent (nil: no limit, for the check).
local function CommodityOffer(d, limit)
	local count, cost, first = 0, 0, nil
	for i = 1, AH.GetNumCommoditySearchResults(d.id) do
		local info = AH.GetCommoditySearchResultInfo(d.id, i)
		if not info or not info.unitPrice or d.vendor - info.unitPrice < db.minProfit then break end
		local n = (info.quantity or 0) - (info.numOwnerItems or 0)
		if limit then n = min(n, floor((limit - cost) / info.unitPrice)) end
		if n > 0 then
			first = first or info.unitPrice
			count, cost = count + n, cost + n * info.unitPrice
		end
	end
	if count <= 0 then return nil end
	return { unit = first, count = count, cost = cost, profit = count * d.vendor - cost }
end

-- Single items: all auctions with a buyout below the vendor price.
-- Bid-only auctions (buyoutAmount 0) are left out. best: the cheapest of them per unit.
local function ItemOffer(d)
	local best, count, profit = nil, 0, 0
	for i = 1, AH.GetNumItemSearchResults(d.key) do
		local info = AH.GetItemSearchResultInfo(d.key, i)
		if info and info.auctionID and info.buyoutAmount and info.buyoutAmount > 0 and not info.containsOwnerItem then
			local quantity = max(info.quantity or 1, 1)
			local vendor = info.itemLink and VendorPrice(info.itemLink) or d.vendor
			local unit = info.buyoutAmount / quantity
			if vendor and vendor - unit >= db.minProfit then
				count, profit = count + quantity, profit + (vendor - unit) * quantity
				if not best or unit < best.unit then
					best = { auctionID = info.auctionID, buyout = info.buyoutAmount, quantity = quantity,
						unit = unit, vendor = vendor, link = info.itemLink }
				end
			end
		end
	end
	if not best then return nil end
	return { unit = best.unit, count = count, profit = profit, best = best }
end

local function ReadCommodity()
	local d = buy.deal
	if buy.purpose == "check" then
		FinishCheck(d, CommodityOffer(d))
		return
	end
	local offer = CommodityOffer(d, GetMoney())
	if not offer then
		RemoveDeal(d)
		ResetBuy(L["Nothing below vendor price any more (or not enough gold)."])
		return
	end
	buy.state, buy.qty, buy.cost = "commodity_ready", offer.count, offer.cost
	SetStatus(L["%d× %s below vendor price, profit about %s."]:format(offer.count, d.link or d.name, Money(offer.profit)))
	Refresh()
end

local function ReadItem()
	local d = buy.deal
	local offer = ItemOffer(d)
	if buy.purpose == "check" then
		FinishCheck(d, offer)
		return
	end
	if not offer then
		RemoveDeal(d)
		ResetBuy(L["Nothing below vendor price any more."])
		return
	end
	local best = offer.best
	d.price, d.count, d.profit = offer.unit, offer.count, offer.profit
	buy.state = "item_ready"
	buy.auctionID, buy.buyout, buy.qty, buy.vendor, buy.link = best.auctionID, best.buyout, best.quantity, best.vendor, best.link
	SetStatus(L["%s ×%d for %s, vendor pays %s."]:format(best.link or d.link or d.name, best.quantity,
		Money(best.buyout), Money(best.vendor * best.quantity)))
	Refresh()
end

-- The buy button and the key binding. Runs only on a click or key press.
local function Action()
	local state = buy.state
	if not state then
		if selected then Verify(selected) end
		return
	end
	local d = buy.deal
	if state == "item_ready" then
		if GetMoney() < buy.buyout then
			SetStatus(L["Not enough gold."])
			return
		end
		AH.PlaceBid(buy.auctionID, buy.buyout)
		pendingBuys[buy.auctionID] = { cost = buy.buyout, value = buy.vendor * buy.qty }
		Print(L["Purchase sent: %s ×%d for %s (vendor pays %s)."]:format(buy.link or d.link or d.name, buy.qty,
			Money(buy.buyout), Money(buy.vendor * buy.qty)))
		buy.state, buy.t = "bought", GetTime()
	elseif state == "commodity_ready" then
		AH.StartCommoditiesPurchase(d.id, buy.qty)
		buy.state, buy.t = "quoting", GetTime()
	elseif state == "quote_ok" then
		AH.ConfirmCommoditiesPurchase(d.id, buy.qty)
		buy.state, buy.t = "confirming", GetTime()
	end
	Refresh()
end

local BUSY = { quoting = true, confirming = true, bought = true }

local function Select(d)
	local state = buy.state
	if BUSY[state] or (state == "verifying" and buy.purpose == "buy") then return end
	if state == "quote_ok" then CancelQuote() end
	if buy.purpose == "check" and buy.deal then
		-- interrupt the round's check: that find is checked again afterwards
		table.insert(queue, 1, buy.deal)
		pendingSend, sentAt = nil, nil
	end
	selected = d
	Verify(d, "buy")
end

-- Key binding "Buy next find" and /vfloor buy: each press does the next step.
-- First press checks the selected (or best) find, the next one buys it.
-- Stackable goods need one press more: quote, then confirm.
function VendorFloor_BuyNext()
	if not ahOpen then return end
	local state = buy.state
	if state == "item_ready" or state == "commodity_ready" or state == "quote_ok" then
		Action()
		return
	end
	if BUSY[state] or (state == "verifying" and buy.purpose == "buy") then return end
	local d = (selected and deals[selected.k] and selected) or order[1]
	if d then Select(d) end
end

---------------------------------------------------------------------------
-- Clock: send queries, time-outs, the check queue, continuous mode
---------------------------------------------------------------------------

local function Tick()
	local now = GetTime()
	if pendingSend then
		if AH.IsThrottledMessageSystemReady() then
			local fn = pendingSend
			pendingSend, sentAt = nil, now
			fn()
		end
		return
	end
	if scan.active and sentAt and now - sentAt > SEND_TIMEOUT then
		if tries < 3 and lastSend then
			tries = tries + 1
			pendingSend = lastSend
		else
			StopScan(L["The auction house is not responding. Scan stopped."])
		end
		return
	end
	local state = buy.state
	if not state and not scan.active and queue[1] then
		local d = table.remove(queue, 1)
		if not d.dropped then Verify(d, "check") end
		return
	end
	if state == "verifying" and now - buy.t > SEND_TIMEOUT then
		if buy.purpose == "check" then
			FinishCheck(buy.deal, nil)
		else
			ResetBuy(L["No answer while checking."])
		end
	elseif state == "bought" and now - buy.t > 1.5 then
		Verify(buy.deal, "buy") -- more of it below the vendor price?
	elseif (state == "quoting" or state == "confirming") and now - buy.t > 12 then
		CancelQuote()
		ResetBuy(L["No answer from the auction house."])
	elseif state == "quote_ok" and now - buy.t > 10 then
		CancelQuote()
		ResetBuy(L["Quote expired."])
	end
	if scan.nextAt and not scan.active and not buy.state and not queue[1] and now >= scan.nextAt then
		scan.nextAt = nil
		StartScan()
	end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

Refresh = function()
	if not ui then return end
	local maxOffset = max(#order - ROWS, 0)
	offset = max(min(offset, maxOffset), 0)
	for i = 1, ROWS do
		local row, d = ui.rows[i], order[i + offset]
		row.deal = d
		if d then
			row.icon:SetTexture(d.icon)
			row.name:SetText(d.link or d.name or ("item:" .. d.id))
			row.info:SetText(("%s → %s  |cff40ff40+%s|r |cffaaaaaa(%d×)|r"):format(Money(d.price), Money(d.vendor),
				Money(d.profit or 0), d.count or 1))
			row.mark:SetShown(d == selected)
			row:Show()
		else
			row:Hide()
		end
	end
	local checking = buy.purpose == "check" or (queue[1] ~= nil and not buy.state)
	ui.scan:SetText((scan.active or checking) and L["Stop"] or L["Scan"])
	ui.scan:SetEnabled(scan.active or checking or not buy.state)
	ui.loop:SetChecked(db.loop)
	ui.count:SetText(#order > ROWS and L["%d–%d of %d"]:format(offset + 1, min(offset + ROWS, #order), #order) or "")

	local state, text, enabled = buy.state, L["Click a find"], false
	if not state or buy.purpose == "check" then
		if selected and deals[selected.k] then text, enabled = L["Check"], true
		elseif order[1] then text, enabled = L["Check"], true end
	elseif state == "verifying" then
		text = L["Checking …"]
	elseif state == "item_ready" then
		text, enabled = L["Buy: %d× for %s"]:format(buy.qty, Money(buy.buyout)), true
	elseif state == "commodity_ready" then
		text, enabled = L["Get quote: %d× (about %s)"]:format(buy.qty, Money(buy.cost)), true
	elseif state == "quoting" then
		text = L["Getting quote …"]
	elseif state == "quote_ok" then
		text, enabled = L["Buy: %d× for %s"]:format(buy.qty, Money(buy.total)), true
	else
		text = L["Buying …"]
	end
	ui.action:SetText(text)
	ui.action:SetEnabled(enabled)
end

local function StopAll(msg)
	if buy.purpose == "check" then wipe(buy) end
	wipe(queue)
	wipe(queued)
	StopScan(msg)
end

local function PlaceWindow()
	ui:ClearAllPoints()
	if db.point then
		ui:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4])
	elseif AuctionHouseFrame and AuctionHouseFrame:IsShown() then
		ui:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 6, 0)
	else
		ui:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
	end
end

local function BuildUI()
	if ui then return end
	local f = CreateFrame("Frame", "VendorFloorFrame", UIParent, "BackdropTemplate")
	f:SetSize(500, 124 + ROWS * ROW_HEIGHT)
	f:SetFrameStrata("HIGH")
	f:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	f:SetBackdropColor(0, 0, 0, 0.92)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint(1)
		db.point = { point, relPoint, x, y }
	end)
	f:EnableMouseWheel(true)
	f:SetScript("OnMouseWheel", function(_, delta)
		offset = offset - delta * 3
		Refresh()
	end)
	f:SetScript("OnHide", function()
		if buy.state == "quoting" or buy.state == "quote_ok" then CancelQuote() end
		StopAll(L["Scan stopped."])
		wipe(buy)
		scan.nextAt = nil
	end)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 10, -9)
	title:SetText(L["VendorFloor %s"]:format(VERSION))

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)

	f.scan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.scan:SetSize(70, 22)
	f.scan:SetPoint("TOPLEFT", 8, -28)
	f.scan:SetScript("OnClick", function()
		if scan.active or buy.purpose == "check" or (queue[1] and not buy.state) then
			StopAll(L["Scan stopped."])
		else
			StartScan()
		end
	end)

	local loop = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
	loop:SetSize(24, 24)
	loop:SetPoint("LEFT", f.scan, "RIGHT", 8, 0)
	loop:SetChecked(db.loop)
	loop:SetScript("OnClick", function(self)
		db.loop = self:GetChecked() and true or false
		if not db.loop then scan.nextAt = nil end
	end)
	f.loop = loop
	local loopText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	loopText:SetPoint("LEFT", loop, "RIGHT", 2, 0)
	loopText:SetText(L["Continuous"])

	f.count = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.count:SetPoint("TOPRIGHT", -30, -10)

	-- Minimum profit per unit: how far below the vendor price an auction must be
	local profit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	profit:SetSize(78, 20)
	profit:SetPoint("TOPRIGHT", -12, -29)
	profit:SetAutoFocus(false)
	profit:SetMaxLetters(16)
	profit:SetText(PlainMoney(db.minProfit))
	profit:SetScript("OnEnterPressed", function(self)
		local copper = ParseMoney(self:GetText())
		if copper then
			SetMinProfit(copper)
		else
			self:SetText(PlainMoney(db.minProfit))
			SetStatus(L["Amount not recognised. Examples: 50%s, 5s, 1g 20s"]:format(ns.COPPER))
		end
		self:ClearFocus()
	end)
	profit:SetScript("OnEscapePressed", function(self)
		self:SetText(PlainMoney(db.minProfit))
		self:ClearFocus()
	end)
	profit:SetScript("OnEditFocusLost", function(self)
		self:SetText(PlainMoney(db.minProfit))
	end)
	profit:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(L["Minimum profit per unit"])
		GameTooltip:AddLine(L["How far below the vendor price an auction must be."], 1, 1, 1, true)
		GameTooltip:AddLine(L["Examples: 50%s, 5s, 1g 20s. Confirm with Enter."]:format(ns.COPPER), 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	profit:SetScript("OnLeave", function(self)
		if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
	end)
	f.profit = profit
	local profitText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	profitText:SetPoint("RIGHT", profit, "LEFT", -8, 0)
	profitText:SetText(L["Min. profit/unit"])

	f.rows = {}
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, f)
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("TOPLEFT", 8, -54 - (i - 1) * ROW_HEIGHT)
		row:SetPoint("RIGHT", f, "RIGHT", -8, 0)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.mark = row:CreateTexture(nil, "BACKGROUND")
		row.mark:SetAllPoints()
		row.mark:SetColorTexture(1, 0.82, 0, 0.18)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(ROW_HEIGHT - 2, ROW_HEIGHT - 2)
		row.icon:SetPoint("LEFT", 0, 0)
		row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.info:SetPoint("RIGHT", -2, 0)
		row.info:SetJustifyH("RIGHT")
		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
		row.name:SetPoint("RIGHT", row.info, "LEFT", -6, 0)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)
		row:SetScript("OnClick", function(self, button)
			if not self.deal then return end
			if button == "RightButton" then Ignore(self.deal) else Select(self.deal) end
		end)
		row:SetScript("OnEnter", function(self)
			local d = self.deal
			if not d then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(d.link or ("item:" .. d.id))
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(L["Below vendor price: %d×, total profit %s"]:format(d.count or 1, Money(d.profit or 0)), 0.25, 1, 0.25)
			GameTooltip:AddLine(L["Listed on the AH: %d"]:format(d.listed or 0), 0.7, 0.7, 0.7)
			GameTooltip:AddLine(L["Click: check and buy. Right-click: hide this item."], 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function(self)
			if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
		end)
		f.rows[i] = row
	end

	f.ledger = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.ledger:SetPoint("BOTTOMLEFT", 10, 52)
	f.ledger:SetPoint("RIGHT", f, "RIGHT", -10, 0)
	f.ledger:SetJustifyH("LEFT")
	f.ledger:SetWordWrap(false)
	f.ledger:SetText(L["Session: %d buys, spent %s, vendor value %s, profit %s"]:format(LedgerText(session)))

	f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.status:SetPoint("BOTTOMLEFT", 10, 36)
	f.status:SetPoint("RIGHT", f, "RIGHT", -10, 0)
	f.status:SetJustifyH("LEFT")
	f.status:SetWordWrap(false)
	f.status:SetText(statusText)

	f.action = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.action:SetHeight(24)
	f.action:SetPoint("BOTTOMLEFT", 8, 8)
	f.action:SetPoint("BOTTOMRIGHT", -8, 8)
	f.action:SetScript("OnClick", VendorFloor_BuyNext)

	local elapsed = 0
	f:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < 0.1 then return end
		elapsed = 0
		Tick()
	end)

	f:Hide()
	ui = f
end

local function ShowWindow()
	BuildUI()
	PlaceWindow()
	if statusText == "" then SetStatus(L["Ready. \"Scan\" reads the auction house item list."]) end
	ui:Show()
	Refresh()
end

---------------------------------------------------------------------------
-- Settings under Options > AddOns. No predicates or proxy getters: they would run
-- addon code inside Blizzard's options search.
---------------------------------------------------------------------------

local function RegisterSettings()
	if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then return end
	local category = Settings.RegisterVerticalLayoutCategory("VendorFloor")

	local sound = Settings.RegisterAddOnSetting(category, "VENDORFLOOR_SOUND", "sound", db,
		Settings.VarType.Boolean, L["Alert sound"], defaults.sound)
	Settings.CreateCheckbox(category, sound, L["Play a sound when a new find appears."])

	local loop = Settings.RegisterAddOnSetting(category, "VENDORFLOOR_LOOP", "loop", db,
		Settings.VarType.Boolean, L["Continuous mode"], defaults.loop)
	Settings.CreateCheckbox(category, loop, L["Scan again automatically after each round."])
	loop:SetValueChangedCallback(function(_, value)
		if not value then scan.nextAt = nil end
		if ui then ui.loop:SetChecked(value and true or false) end
	end)

	local interval = Settings.RegisterAddOnSetting(category, "VENDORFLOOR_INTERVAL", "interval", db,
		Settings.VarType.Number, L["Pause between rounds (seconds)"], defaults.interval)
	local intervalOptions = Settings.CreateSliderOptions(5, 120, 5)
	if intervalOptions.SetLabelFormatter and MinimalSliderWithSteppersMixin then
		intervalOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
	end
	Settings.CreateSlider(category, interval, intervalOptions, L["How long continuous mode waits before the next round."])

	local profit = Settings.RegisterAddOnSetting(category, "VENDORFLOOR_MINPROFIT", "minProfitSilver", db,
		Settings.VarType.Number, L["Minimum profit per unit (silver)"], defaults.minProfitSilver)
	local profitOptions = Settings.CreateSliderOptions(0, 500, 1)
	if profitOptions.SetLabelFormatter and MinimalSliderWithSteppersMixin then
		profitOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
	end
	Settings.CreateSlider(category, profit, profitOptions,
		L["How far below the vendor price an auction must be. Finer amounts can be typed into the window."])
	profit:SetValueChangedCallback(function(_, value)
		SetMinProfit((tonumber(value) or 0) * 100)
	end)

	Settings.RegisterAddOnCategory(category)
	ns.category = category
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {}

function handlers.ADDON_LOADED(name)
	if name ~= ADDON then return end
	VendorFloorDB = VendorFloorDB or {}
	db = VendorFloorDB
	for key, value in pairs(defaults) do
		if db[key] == nil then db[key] = value end
	end
	db.ignore = db.ignore or {}
	db.total = db.total or { buys = 0, spent = 0, value = 0 }
	local ok, err = pcall(RegisterSettings)
	if not ok then Print(tostring(err)) end
end

function handlers.AUCTION_HOUSE_SHOW()
	ahOpen = true
	if not db.hidden then ShowWindow() end
end

function handlers.AUCTION_HOUSE_CLOSED()
	ahOpen = false
	if ui then ui:Hide() end
	-- prices change while the auction house is closed: start the next visit empty
	for i = #order, 1, -1 do RemoveDeal(order[i]) end
	wipe(queue)
	wipe(queued)
	wipe(pendingInfo)
end

function handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
	if not scan.active then return end
	Process(AH.GetBrowseResults())
	ContinueScan()
end

function handlers.AUCTION_HOUSE_BROWSE_RESULTS_ADDED(added)
	if not scan.active then return end
	Process(added)
	ContinueScan()
end

function handlers.AUCTION_HOUSE_BROWSE_FAILURE()
	if scan.active then StopScan(L["The auction house rejected the query."]) end
end

function handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()
	if lastSend and (scan.active or buy.state == "verifying") then pendingSend = lastSend end
end

function handlers.GET_ITEM_INFO_RECEIVED(id, success)
	local result = pendingInfo[id]
	if not result then return end
	pendingInfo[id] = nil
	if success and VendorPrice(id) ~= nil then
		Evaluate(result)
		Refresh()
	end
end

function handlers.COMMODITY_SEARCH_RESULTS_UPDATED(id)
	if buy.state == "verifying" and buy.deal and buy.deal.id == id then ReadCommodity() end
end

function handlers.ITEM_SEARCH_RESULTS_UPDATED(key)
	if buy.state == "verifying" and buy.deal and type(key) == "table" and key.itemID == buy.deal.id then ReadItem() end
end

function handlers.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
	local p = pendingBuys[auctionID]
	if not p then return end
	pendingBuys[auctionID] = nil
	Record(p.cost, p.value)
end

function handlers.COMMODITY_PRICE_UPDATED(_, total)
	if buy.state ~= "quoting" then return end
	local d = buy.deal
	if total and total <= buy.qty * (d.vendor - db.minProfit) then
		buy.state, buy.total, buy.t = "quote_ok", total, GetTime()
		SetStatus(L["Quote: %d× for %s, vendor pays %s."]:format(buy.qty, Money(total), Money(buy.qty * d.vendor)))
		Refresh()
	else
		CancelQuote()
		ResetBuy(L["The price has risen meanwhile. Not bought."])
	end
end

function handlers.COMMODITY_PRICE_UNAVAILABLE()
	if buy.state == "quoting" then ResetBuy(L["No quote received."]) end
end

function handlers.COMMODITY_PURCHASE_SUCCEEDED()
	if buy.state ~= "confirming" then return end
	local d = buy.deal
	Print(L["Bought: %s ×%d for %s (vendor pays %s)."]:format(d.link or d.name, buy.qty, Money(buy.total),
		Money(buy.qty * d.vendor)))
	Record(buy.total or 0, buy.qty * d.vendor)
	RemoveDeal(d)
	ResetBuy(L["Bought."])
end

function handlers.COMMODITY_PURCHASE_FAILED()
	if buy.state == "confirming" or buy.state == "quoting" then ResetBuy(L["Purchase failed."]) end
end

local events = CreateFrame("Frame")
for event in pairs(handlers) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, ...)
	local handler = handlers[event]
	if handler then handler(...) end
end)

---------------------------------------------------------------------------
-- Key binding and /vfloor
---------------------------------------------------------------------------

BINDING_HEADER_VENDORFLOOR = "VendorFloor"
BINDING_NAME_VENDORFLOOR_BUYNEXT = L["Buy next find"]

local function Help()
	Print(L["VendorFloor %s commands:"]:format(VERSION))
	for _, line in ipairs({
		L["/vfloor – show or hide the window"],
		L["/vfloor buy – check and buy the next find (also a key binding)"],
		L["/vfloor profit <amount> – minimum profit per unit, e.g. 5s"],
		L["/vfloor interval <seconds> – pause between rounds"],
		L["/vfloor sound – alert sound on or off"],
		L["/vfloor ignore list | clear – show or clear the ignore list"],
		L["/vfloor stats – totals since install"],
		L["/vfloor reset – reset the window position"],
		L["/vfloor options – open the settings"],
	}) do
		DEFAULT_CHAT_FRAME:AddMessage("  " .. line)
	end
end

SLASH_VENDORFLOOR1 = "/vfloor"
SLASH_VENDORFLOOR2 = "/vendorfloor"
SlashCmdList.VENDORFLOOR = function(msg)
	local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "profit" and ParseMoney(arg) then
		SetMinProfit(ParseMoney(arg))
		Print(L["Minimum profit per unit: %s"]:format(Money(db.minProfit)))
	elseif cmd == "interval" and tonumber(arg) then
		db.interval = max(floor(tonumber(arg)), 5)
		Print(L["Pause between rounds: %d seconds"]:format(db.interval))
	elseif cmd == "sound" then
		db.sound = not db.sound
		Print(L["Alert sound: %s"]:format(db.sound and L["on"] or L["off"]))
	elseif cmd == "buy" then
		VendorFloor_BuyNext()
	elseif cmd == "ignore" and arg == "clear" then
		wipe(db.ignore)
		Print(L["Ignore list cleared."])
	elseif cmd == "ignore" then
		local names = {}
		for id, name in pairs(db.ignore) do names[#names + 1] = type(name) == "string" and name or tostring(id) end
		table.sort(names)
		Print(#names > 0 and L["Ignore list: %s"]:format(table.concat(names, ", ")) or L["The ignore list is empty."])
	elseif cmd == "stats" then
		Print(L["Total: %d buys, spent %s, vendor value %s, profit %s"]:format(LedgerText(db.total)))
	elseif cmd == "reset" then
		db.point = nil
		if ui and ui:IsShown() then PlaceWindow() end
		Print(L["Window position reset."])
	elseif cmd == "options" then
		if ns.category and Settings and Settings.OpenToCategory then
			Settings.OpenToCategory(ns.category:GetID())
		end
	elseif cmd == "" then
		if not ahOpen then
			Print(L["The auction house must be open."])
		elseif ui and ui:IsShown() then
			db.hidden = true
			ui:Hide()
		else
			db.hidden = false
			ShowWindow()
		end
	else
		Help()
	end
end
