-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. Siehe LICENSE.
--
-- VendorFloor: Auktionen unter Händlerpreis finden und per Klick kaufen.
-- Eigenständig, ohne Bibliotheken. Fasst weder Auctionator noch das Blizzard-Fenster an:
-- es sendet nur eigene Abfragen an das Auktionshaus und zeigt ein eigenes Fenster.
-- Gekauft wird ausschließlich auf Mausklick (jeder Kauf braucht einen Klick).

local ADDON = ...
local AH = C_AuctionHouse
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local floor, min, max = math.floor, math.min, math.max

local PREFIX = "|cff33ff99VendorFloor:|r "
local ROWS, ROW_HEIGHT = 12, 20
local SEND_TIMEOUT = 15

local defaults = {
	minProfit = 100, -- Mindestgewinn je Stück in Kupfer (Abstand zum Händlerpreis); Standard 1 Silber
	sound = true,   -- Ton bei neuem Fund
	loop = false,   -- Dauerlauf: nach jeder Runde neu scannen
	interval = 20,  -- Sekunden Pause zwischen zwei Runden
}
local db

local deals, order = {}, {}   -- bestätigte Funde: nach Schlüssel und als sortierte Liste
local queue, queued = {}, {}  -- Funde, deren Sofortkauf noch zu prüfen ist (Liste und nach Schlüssel)
local pendingInfo = {}        -- itemID -> Browse-Ergebnis, dessen Itemdaten noch laden
local scan = { active = false, seen = 0, round = 0 }
local buy = {}                -- Zustand des gerade bearbeiteten Funds
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
	return text .. ("|cffeda55f%dk|r"):format(c)
end

-- Betrag ohne Farben, für das Eingabefeld: "1g 20s 5k"
local function PlainMoney(copper)
	copper = floor(copper or 0)
	local g, s, c = floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
	local parts = {}
	if g > 0 then parts[#parts + 1] = g .. "g" end
	if s > 0 then parts[#parts + 1] = s .. "s" end
	if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "k" end
	return table.concat(parts, " ")
end

-- Liest "5s", "1g 20s", "50k" oder eine reine Zahl (Kupfer). nil, wenn nichts Lesbares dabei ist.
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
-- Abfragen: immer nur eine, und erst wenn das Auktionshaus bereit ist
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
-- Funde
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

local function SortDeals()
	table.sort(order, function(a, b)
		local pa, pb = a.vendor - a.price, b.vendor - b.price
		if pa ~= pb then return pa > pb end
		return a.k < b.k
	end)
end

-- Händlerpreis je Stück; nil, solange die Itemdaten noch laden.
local function VendorPrice(item)
	local name, link, _, _, _, _, _, _, _, icon, sell = GetItemInfo(item)
	if not name then return nil end
	return sell or 0, name, link, icon
end

-- Handelsware wird immer zum Festpreis verkauft, Einzelgegenstände können reine
-- Gebotsauktionen ohne Sofortkauf sein. nil, wenn es sich nicht feststellen lässt.
local function IsCommodity(key)
	local info = AH.GetItemKeyInfo and AH.GetItemKeyInfo(key)
	if info == nil then return nil end
	return info.isCommodity and true or false
end

-- Den Fund in die Liste aufnehmen und melden.
local function Confirm(d)
	if d.dropped or deals[d.k] then return end
	deals[d.k] = d
	order[#order + 1] = d
	Print(("%s unter Händlerpreis: AH %s, Händler %s"):format(d.link or d.name, Money(d.price), Money(d.vendor)))
	if db.sound and GetTime() - lastSound > 2 then
		lastSound = GetTime()
		PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
	end
end

-- Zum Prüfen vormerken: erst wenn eine Auktion mit Sofortkauf gefunden ist,
-- kommt der Fund in die Liste. Einmal je Runde.
local function Enqueue(d)
	if d.queuedRound == scan.round then return end
	d.queuedRound = scan.round
	queue[#queue + 1] = d
end

local function Evaluate(result)
	local key = result.itemKey
	local id, price = key.itemID, result.minPrice
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
	d.key, d.id, d.vendor, d.qty = key, id, vendor, result.totalQuantity or 0
	d.name, d.link, d.icon, d.stale, d.dropped = name, link, icon, false, nil
	if IsCommodity(key) == true then
		-- Festpreis: der Preis aus der Artikelliste ist der Sofortkaufpreis.
		d.price = price
		Confirm(d)
	else
		-- Der Preis kann ein Gebot ohne Sofortkauf sein: erst prüfen.
		d.price = price
		Enqueue(d)
	end
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
	SortDeals()
end

-- Mindestabstand zum Händlerpreis setzen (Kupfer je Stück). Funde darunter fallen aus der Liste.
local function SetMinProfit(copper)
	db.minProfit = max(floor(copper), 1)
	for i = #order, 1, -1 do
		local d = order[i]
		if d.vendor - d.price < db.minProfit and d ~= buy.deal then RemoveDeal(d) end
	end
	if ui then ui.profit:SetText(PlainMoney(db.minProfit)) end
	SetStatus("Mindestgewinn je Stück: " .. Money(db.minProfit))
	Refresh()
end

---------------------------------------------------------------------------
-- Scan: die ganze Artikelliste des Auktionshauses, Seite für Seite
---------------------------------------------------------------------------

StartScan = function()
	if not ahOpen then
		Print("Das Auktionshaus muss offen sein.")
		return
	end
	if buy.state then return end
	scan.active, scan.seen, scan.nextAt = true, 0, nil
	scan.round, scan.checked = scan.round + 1, 0
	tries = 0
	wipe(queue)
	wipe(queued)
	for _, d in ipairs(order) do d.stale = true end
	Send(function() AH.SendBrowseQuery(BrowseQuery()) end)
	SetStatus("Scanne …")
	Refresh()
end

StopScan = function(msg)
	scan.active, scan.nextAt = false, nil
	pendingSend, sentAt = nil, nil
	if msg then SetStatus(msg) end
	Refresh()
end

local function FinishScan()
	scan.active, sentAt = false, nil
	for i = #order, 1, -1 do
		local d = order[i]
		if d.stale and d ~= buy.deal then RemoveDeal(d) end
	end
	if queue[1] then
		SetStatus(("%d Artikel gelesen. Prüfe %d Kandidaten auf Sofortkauf …"):format(scan.seen, #queue))
		scan.checkingSince = GetTime()
	else
		SetStatus(("Runde fertig: %d Artikel gelesen, %d unter Händlerpreis."):format(scan.seen, #order))
		if db.loop then scan.nextAt = GetTime() + db.interval end
	end
	Refresh()
end

local function ContinueScan()
	sentAt, tries = nil, 0
	if AH.HasFullBrowseResults() then
		FinishScan()
	else
		Send(function() AH.RequestMoreBrowseResults() end)
		SetStatus(("Scanne … %d Artikel gelesen, %d Funde"):format(scan.seen, #order + #queue))
		Refresh()
	end
end

---------------------------------------------------------------------------
-- Kaufen: erst die echten Auktionen des Artikels lesen, dann per Klick kaufen
---------------------------------------------------------------------------

local function CancelQuote()
	if AH.CancelCommoditiesPurchase then pcall(AH.CancelCommoditiesPurchase) end
end

ResetBuy = function(msg)
	wipe(buy)
	if msg then SetStatus(msg) end
	if db.loop and ahOpen and ui and ui:IsShown() then scan.nextAt = GetTime() + 5 end
	Refresh()
end

-- purpose "buy": der Fund wurde angeklickt und soll gekauft werden.
-- purpose "check": die Runde prüft, ob es überhaupt einen Sofortkauf gibt.
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
		SetStatus(("Prüfe Sofortkauf: %s (noch %d)"):format(d.link or d.name or "Artikel", #queue))
	else
		SetStatus("Prüfe " .. (d.link or d.name or "Artikel") .. " …")
	end
	Refresh()
end

-- Ergebnis einer Prüfung: mit Sofortkauf in die Liste, ohne wieder heraus.
local function FinishCheck(d, best)
	if best then
		d.price, d.vendor = best.unit, best.vendor or d.vendor
		Confirm(d)
		SortDeals()
	elseif deals[d.k] then
		RemoveDeal(d)
	end
	queued[d.k] = nil
	scan.checked = (scan.checked or 0) + 1
	wipe(buy)
	if not queue[1] then
		SetStatus(("Runde fertig: %d Artikel gelesen, %d mit Sofortkauf unter Händlerpreis."):format(scan.seen, #order))
		if db.loop and not scan.active then scan.nextAt = GetTime() + db.interval end
	end
	Refresh()
end

-- Handelsware (stapelbar, ein Preis je Stück): wie viele Stück liegen unter Händlerpreis?
local function ReadCommodity()
	local d = buy.deal
	if buy.purpose == "check" then
		local info = AH.GetCommoditySearchResultInfo(d.id, 1)
		local unit = info and info.unitPrice
		local ok = unit and unit > 0 and d.vendor - unit >= db.minProfit
		FinishCheck(d, ok and { unit = unit } or nil)
		return
	end
	local qty, cost, money = 0, 0, GetMoney()
	for i = 1, AH.GetNumCommoditySearchResults(d.id) do
		local info = AH.GetCommoditySearchResultInfo(d.id, i)
		if not info or not info.unitPrice or d.vendor - info.unitPrice < db.minProfit then break end
		local n = (info.quantity or 0) - (info.numOwnerItems or 0)
		n = min(n, floor((money - cost) / info.unitPrice))
		if n > 0 then qty, cost = qty + n, cost + n * info.unitPrice end
	end
	if qty <= 0 then
		RemoveDeal(d)
		ResetBuy("Nichts mehr unter Händlerpreis (oder zu wenig Gold).")
		return
	end
	buy.state, buy.qty, buy.cost = "commodity_ready", qty, cost
	SetStatus(("%d× %s unter Händlerpreis, Gewinn etwa %s."):format(qty, d.link or d.name, Money(qty * d.vendor - cost)))
	Refresh()
end

-- Einzelgegenstand: die günstigste Auktion mit Sofortkauf unter Händlerpreis.
-- Reine Gebotsauktionen (ohne Sofortkauf) bleiben außen vor: buyoutAmount ist dort 0.
local function BestItemOffer(d)
	local best
	for i = 1, AH.GetNumItemSearchResults(d.key) do
		local info = AH.GetItemSearchResultInfo(d.key, i)
		if info and info.auctionID and info.buyoutAmount and info.buyoutAmount > 0 and not info.containsOwnerItem then
			local quantity = max(info.quantity or 1, 1)
			local vendor = info.itemLink and VendorPrice(info.itemLink) or d.vendor
			local unit = info.buyoutAmount / quantity
			if vendor and vendor - unit >= db.minProfit and (not best or unit < best.unit) then
				best = { auctionID = info.auctionID, buyout = info.buyoutAmount, quantity = quantity,
					unit = unit, vendor = vendor, link = info.itemLink }
			end
		end
	end
	return best
end

local function ReadItem()
	local d = buy.deal
	local best = BestItemOffer(d)
	if buy.purpose == "check" then
		FinishCheck(d, best)
		return
	end
	if not best then
		RemoveDeal(d)
		ResetBuy("Nichts mehr unter Händlerpreis.")
		return
	end
	buy.state = "item_ready"
	buy.auctionID, buy.buyout, buy.qty, buy.vendor, buy.link = best.auctionID, best.buyout, best.quantity, best.vendor, best.link
	SetStatus(("%s ×%d für %s, Händler zahlt %s."):format(best.link or d.link or d.name, best.quantity,
		Money(best.buyout), Money(best.vendor * best.quantity)))
	Refresh()
end

-- Der Kauf-Knopf. Läuft nur auf Mausklick.
local function Action()
	local state = buy.state
	if not state then
		if selected then Verify(selected) end
		return
	end
	local d = buy.deal
	if state == "item_ready" then
		if GetMoney() < buy.buyout then
			SetStatus("Nicht genug Gold.")
			return
		end
		AH.PlaceBid(buy.auctionID, buy.buyout)
		Print(("Kauf gesendet: %s ×%d für %s (Händler zahlt %s)."):format(buy.link or d.link or d.name, buy.qty,
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

local function Select(d)
	local state = buy.state
	if state == "verifying" or state == "quoting" or state == "confirming" or state == "bought" then return end
	if state == "quote_ok" then CancelQuote() end
	selected = d
	Verify(d)
end

---------------------------------------------------------------------------
-- Takt: Abfragen senden, Zeitüberschreitungen, Dauerlauf
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
			StopScan("Das Auktionshaus antwortet nicht. Scan abgebrochen.")
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
			ResetBuy("Keine Antwort beim Prüfen.")
		end
	elseif state == "bought" and now - buy.t > 1.5 then
		Verify(buy.deal) -- gibt es noch mehr davon unter Händlerpreis?
	elseif (state == "quoting" or state == "confirming") and now - buy.t > 12 then
		CancelQuote()
		ResetBuy("Keine Antwort vom Auktionshaus.")
	elseif state == "quote_ok" and now - buy.t > 10 then
		CancelQuote()
		ResetBuy("Angebot abgelaufen.")
	end
	if scan.nextAt and not scan.active and not buy.state and not queue[1] and now >= scan.nextAt then
		scan.nextAt = nil
		StartScan()
	end
end

---------------------------------------------------------------------------
-- Fenster
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
			row.name:SetText(d.link or d.name or ("Item " .. d.id))
			row.info:SetText(("%s  →  %s   |cff40ff40+%s|r"):format(Money(d.price), Money(d.vendor), Money(d.vendor - d.price)))
			row.mark:SetShown(d == selected)
			row:Show()
		else
			row:Hide()
		end
	end
	ui.scan:SetText(scan.active and "Stopp" or "Scan")
	ui.scan:SetEnabled(not buy.state)
	ui.count:SetText(#order > ROWS and ("%d–%d von %d"):format(offset + 1, min(offset + ROWS, #order), #order) or "")

	local state, text, enabled = buy.state, "Fund anklicken", false
	if not state then
		if selected then text, enabled = "Prüfen", true end
	elseif state == "verifying" then
		text = "Prüfe …"
	elseif state == "item_ready" then
		text, enabled = ("Kaufen: %d× für %s"):format(buy.qty, Money(buy.buyout)), true
	elseif state == "commodity_ready" then
		text, enabled = ("Angebot holen: %d× (etwa %s)"):format(buy.qty, Money(buy.cost)), true
	elseif state == "quoting" then
		text = "Hole Angebot …"
	elseif state == "quote_ok" then
		text, enabled = ("Kaufen: %d× für %s"):format(buy.qty, Money(buy.total)), true
	else
		text = "Kaufe …"
	end
	ui.action:SetText(text)
	ui.action:SetEnabled(enabled)
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
	f:SetSize(440, 96 + ROWS * ROW_HEIGHT)
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
		if scan.active then StopScan("Scan gestoppt.") end
		if buy.state == "quoting" or buy.state == "quote_ok" then CancelQuote() end
		wipe(buy)
		pendingSend, scan.nextAt = nil, nil
	end)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 10, -9)
	title:SetText("VendorFloor: unter Händlerpreis")

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)

	f.scan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.scan:SetSize(70, 22)
	f.scan:SetPoint("TOPLEFT", 8, -28)
	f.scan:SetScript("OnClick", function()
		if scan.active then StopScan("Scan gestoppt.") else StartScan() end
	end)

	local loop = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
	loop:SetSize(24, 24)
	loop:SetPoint("LEFT", f.scan, "RIGHT", 8, 0)
	loop:SetChecked(db.loop)
	loop:SetScript("OnClick", function(self)
		db.loop = self:GetChecked() and true or false
		if not db.loop then scan.nextAt = nil end
	end)
	local loopText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	loopText:SetPoint("LEFT", loop, "RIGHT", 2, 0)
	loopText:SetText("Dauerlauf")

	f.count = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.count:SetPoint("TOPRIGHT", -30, -10)

	-- Mindestgewinn je Stück: Abstand, den eine Auktion unter dem Händlerpreis liegen muss
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
			SetStatus("Betrag nicht erkannt. Beispiele: 50k, 5s, 1g 20s")
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
		GameTooltip:AddLine("Mindestgewinn je Stück")
		GameTooltip:AddLine("So viel muss eine Auktion unter dem Händlerpreis liegen.", 1, 1, 1, true)
		GameTooltip:AddLine("Beispiele: 50k, 5s, 1g 20s. Mit Enter bestätigen.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	profit:SetScript("OnLeave", function(self)
		if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
	end)
	f.profit = profit
	local profitText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	profitText:SetPoint("RIGHT", profit, "LEFT", -8, 0)
	profitText:SetText("Mindestgewinn/Stück")

	f.rows = {}
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, f)
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("TOPLEFT", 8, -54 - (i - 1) * ROW_HEIGHT)
		row:SetPoint("RIGHT", f, "RIGHT", -8, 0)
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
		row:SetScript("OnClick", function(self)
			if self.deal then Select(self.deal) end
		end)
		row:SetScript("OnEnter", function(self)
			local d = self.deal
			if not d then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(d.link or ("item:" .. d.id))
			GameTooltip:AddLine(("Im AH gelistet: %d"):format(d.qty), 0.7, 0.7, 0.7)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function(self)
			if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
		end)
		f.rows[i] = row
	end

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
	f.action:SetScript("OnClick", Action)

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
	if statusText == "" then SetStatus("Bereit. „Scan“ liest die Artikelliste des Auktionshauses.") end
	ui:Show()
	Refresh()
end

---------------------------------------------------------------------------
-- Ereignisse
---------------------------------------------------------------------------

local handlers = {}

function handlers.ADDON_LOADED(name)
	if name ~= ADDON then return end
	VendorFloorDB = VendorFloorDB or {}
	db = VendorFloorDB
	for key, value in pairs(defaults) do
		if db[key] == nil then db[key] = value end
	end
end

function handlers.AUCTION_HOUSE_SHOW()
	ahOpen = true
	if not db.hidden then ShowWindow() end
end

function handlers.AUCTION_HOUSE_CLOSED()
	ahOpen = false
	if ui then ui:Hide() end
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
	if scan.active then StopScan("Das Auktionshaus hat die Abfrage abgelehnt.") end
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
		SortDeals()
		Refresh()
	end
end

function handlers.COMMODITY_SEARCH_RESULTS_UPDATED(id)
	if buy.state == "verifying" and buy.deal and buy.deal.id == id then ReadCommodity() end
end

function handlers.ITEM_SEARCH_RESULTS_UPDATED(key)
	if buy.state == "verifying" and buy.deal and type(key) == "table" and key.itemID == buy.deal.id then ReadItem() end
end

function handlers.COMMODITY_PRICE_UPDATED(_, total)
	if buy.state ~= "quoting" then return end
	local d = buy.deal
	if total and total <= buy.qty * (d.vendor - db.minProfit) then
		buy.state, buy.total, buy.t = "quote_ok", total, GetTime()
		SetStatus(("Angebot: %d× für %s, Händler zahlt %s."):format(buy.qty, Money(total), Money(buy.qty * d.vendor)))
		Refresh()
	else
		CancelQuote()
		ResetBuy("Der Preis ist inzwischen gestiegen. Nicht gekauft.")
	end
end

function handlers.COMMODITY_PRICE_UNAVAILABLE()
	if buy.state == "quoting" then ResetBuy("Kein Angebot erhalten.") end
end

function handlers.COMMODITY_PURCHASE_SUCCEEDED()
	if buy.state ~= "confirming" then return end
	local d = buy.deal
	Print(("Gekauft: %s ×%d für %s (Händler zahlt %s)."):format(d.link or d.name, buy.qty, Money(buy.total),
		Money(buy.qty * d.vendor)))
	RemoveDeal(d)
	ResetBuy("Gekauft.")
end

function handlers.COMMODITY_PURCHASE_FAILED()
	if buy.state == "confirming" or buy.state == "quoting" then ResetBuy("Kauf fehlgeschlagen.") end
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
-- /vfloor
---------------------------------------------------------------------------

SLASH_VENDORFLOOR1 = "/vfloor"
SLASH_VENDORFLOOR2 = "/vendorfloor"
SlashCmdList.VENDORFLOOR = function(msg)
	local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "profit" and ParseMoney(arg) then
		SetMinProfit(ParseMoney(arg))
		Print("Mindestgewinn je Stück: " .. Money(db.minProfit))
	elseif cmd == "interval" and tonumber(arg) then
		db.interval = max(floor(tonumber(arg)), 5)
		Print(("Pause zwischen zwei Runden: %d Sekunden"):format(db.interval))
	elseif cmd == "sound" then
		db.sound = not db.sound
		Print("Ton bei neuem Fund: " .. (db.sound and "an" or "aus"))
	elseif cmd == "reset" then
		db.point = nil
		if ui and ui:IsShown() then PlaceWindow() end
		Print("Fensterposition zurückgesetzt.")
	elseif cmd == "" then
		if not ahOpen then
			Print("Das Auktionshaus muss offen sein.")
		elseif ui and ui:IsShown() then
			db.hidden = true
			ui:Hide()
		else
			db.hidden = false
			ShowWindow()
		end
	else
		Print("/vfloor (Fenster an/aus), /vfloor profit <Betrag, z. B. 5s>, /vfloor interval <Sekunden>, /vfloor sound, /vfloor reset")
	end
end
