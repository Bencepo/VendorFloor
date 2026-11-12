-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Finds auction house listings priced below what a vendor pays and buys them on
-- click or key press. Standalone, no libraries. It touches neither Auctionator nor
-- the Blizzard window: it only sends its own auction house queries and shows its
-- own window. Every purchase needs a click or key press of its own.

local ADDON, ns = ...
-- Texts come from Locales.lua. Should it not have loaded (an outdated .toc), English is used.
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })
ns.COPPER = ns.COPPER or "c"
local AH = C_AuctionHouse
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local floor, min, max = math.floor, math.min, math.max

local VERSION = GetMetadata and GetMetadata(ADDON, "Version") or ""
if VERSION == "" or VERSION:find("^@") then VERSION = "dev" end
ns.VERSION = VERSION

local PREFIX = "|cff33ff99VendorFloor:|r "
local ROWS, ROW_HEIGHT = 12, 22
local SEND_TIMEOUT = 15
local BUY_SILENT = 5       -- seconds a purchase check waits before it tries the other item key or gives up
local keyStyle = {}        -- itemID -> "plain" when gear is only found with the plain item key
local CHECK_TIMEOUT = 3    -- seconds a check waits for the auction house before it tries again later
local CACHE_WAIT = 0.6     -- results the auction house already holds come without an event: read them after this
local FULL_COOLDOWN = 15 * 60  -- the auction house allows one full scan every 15 minutes
local FULL_WAIT = 10 * 60      -- seconds a full scan waits for the auction house to answer
local FULL_PER_TICK = 400      -- auctions read per tick (ten ticks a second)

local MARKET_DAYS = 14         -- days of price history kept per item (one value per day)
local AH_CUT = 0.95            -- what a sale on the auction house brings after the 5% cut
local QUICK_ITEMS = 40         -- items a quick round checks
local MAX_CHECKS = 150         -- checks per round at most
local TABS = { "vendor", "de", "craft" }

local defaults = {
	minPercent = 0,       -- minimum profit in percent of the price (0: off)
	minSlot = 0,          -- minimum profit per auction, i.e. per bag slot, in copper (0: off)
	flash = true,         -- flash the taskbar icon on new finds while the game is in the background
	tab = "vendor",       -- the tab shown: vendor, de (disenchant) or craft
	minProfit = 100,      -- minimum profit per unit in copper (distance to the vendor price): 1 silver
	minProfitSilver = 1,  -- the same in silver, for the slider in the settings
	sound = true,         -- sound on a new find
	loop = false,         -- continuous mode: scan again after each round
	interval = 20,        -- seconds between two rounds
}
local db

local deals, order = {}, {}   -- confirmed finds: by key and as a sorted list
local queue, queued = {}, {}  -- finds still to be checked (list and by key)
local pendingInfo = {}        -- itemID -> browse results whose item data is still loading
local noOffer = {}            -- deal key -> { price, at }: checked, no buyout below vendor price (e.g. bid-only)
local NO_OFFER_KEEP = 30 * 60  -- seconds such a key is skipped while its browse price stays the same
local pendingBuys = {}        -- auctionID -> item purchase waiting for confirmation
local scan = { active = false, seen = 0, round = 0 }
local full = { active = false } -- the full scan (every auction at once)
local buy = {}                -- state of the find being checked or bought
local selected
local pendingSend, lastSend, sentAt, tries = nil, nil, nil, 0
local ahOpen = false
local offset = 0
local statusText = ""
local ui

local StartScan, StopScan, Verify, ResetBuy, Refresh, ResultsReady, ReadResults, StartFull, NextRound, FullReady, StartCraftScan

-- The finds of the tab shown, in list order.
local function View()
	local tab, list = db and db.tab or "vendor", {}
	for _, d in ipairs(order) do
		if (d.mode or "vendor") == tab then list[#list + 1] = d end
	end
	return list
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end
ns.Print = Print

local function Money(copper)
	copper = floor(copper or 0)
	local sign = ""
	if copper < 0 then sign, copper = "-", -copper end
	local g, s, c = floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
	local text = sign
	if g > 0 then text = text .. ("|cffffd700%dg|r "):format(g) end
	if g > 0 or s > 0 then text = text .. ("|cffc7c7cf%ds|r "):format(s) end
	return text .. ("|cffeda55f%d%s|r"):format(c, ns.COPPER)
end
ns.Money = Money

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

local pendingAt = 0
local SEND_FORCE = 10 -- seconds a query waits for the throttle before it is sent anyway

local function Send(fn)
	pendingSend, lastSend, pendingAt = fn, fn, GetTime()
end

local SORTS = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }

-- The item list to read. The disenchant tab reads only green and blue weapons and armor.
local function BrowseQuery(mode)
	local qualities = { "PoorQuality", "CommonQuality", "UncommonQuality", "RareQuality",
		"EpicQuality", "LegendaryQuality", "ArtifactQuality" }
	local classes = {}
	if mode == "de" then
		qualities = { "UncommonQuality", "RareQuality" }
		classes = { { classID = 2 }, { classID = 4 } } -- weapons, armor
	end
	local filters = {}
	for _, name in ipairs(qualities) do
		local value = Enum.AuctionHouseFilter and Enum.AuctionHouseFilter[name]
		if value ~= nil then filters[#filters + 1] = value end
	end
	return { searchString = "", minLevel = 0, maxLevel = 0, filters = filters, itemClassFilters = classes, sorts = SORTS }
end

---------------------------------------------------------------------------
-- Finds
---------------------------------------------------------------------------

-- Finds of the disenchant tab get their own keys, so one item can be in two tabs.
local function DealKey(key, mode)
	local k = (key.itemID or 0) .. ":" .. (key.itemLevel or 0) .. ":" .. (key.itemSuffix or 0) .. ":" .. (key.battlePetSpeciesID or 0)
	if mode and mode ~= "vendor" then k = mode .. "|" .. k end
	return k
end

-- Disenchant finds are grouped by item: every level and suffix of an item disenchants
-- the same. The variants (their auction keys, cheapest first) are tried one by one.
local function GroupKey(key, mode)
	if mode == "de" then return "de|" .. (key.itemID or 0) end
	return DealKey(key, mode)
end

local function AddVariant(d, key, price)
	d.variants = d.variants or {}
	local dk = DealKey(key)
	for _, v in ipairs(d.variants) do
		if v.dk == dk then
			if price < v.price then v.price = price end
			return
		end
	end
	d.variants[#d.variants + 1] = { dk = dk, key = key, price = price }
	table.sort(d.variants, function(a, b) return a.price < b.price end)
	d.key, d.vi, d.triedPlain = d.variants[1].key, 1, nil
end

-- The next variant of a grouped find to search, after the current one had nothing.
local function NextVariant(d)
	if not (d.variants and (d.vi or 1) < #d.variants) then return false end
	d.vi = (d.vi or 1) + 1
	d.key, d.triedPlain = d.variants[d.vi].key, nil
	return true
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

-- Units per auction, capped at the item's stack size. Some auction house versions report
-- grouped or listed counts for single items (a bag "830×" for one buyout), which turned
-- one auction above the vendor price into hundreds of fake units below it.
local function Units(item, quantity)
	quantity = max(floor(quantity or 1), 1)
	local stack = select(8, GetItemInfo(item))
	if stack and stack > 0 and quantity > stack then quantity = stack end
	return quantity
end

local function IsIgnored(itemID)
	return db.ignore and db.ignore[itemID] and true or false
end

-- Is buying at unit worth it against target (what one unit brings)? The minimum per unit,
-- the minimum in percent of the price and, with count, the minimum for the whole auction
-- (one auction takes one bag slot).
local function Worth(target, unit, count)
	local gain = target - unit
	if unit < 1 or gain < db.minProfit then return false end
	if (db.minPercent or 0) > 0 and gain / unit * 100 < db.minPercent then return false end
	if count and (db.minSlot or 0) > 0 and gain * count < db.minSlot then return false end
	return true
end
ns.Worth = Worth

local function IsGear(item)
	local equipLoc = select(9, GetItemInfo(item))
	return equipLoc ~= nil and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
end

-- Watch list: items that were found below the vendor price, with how often. Quick rounds
-- check the most frequent of them one by one instead of reading the whole item list.
local function Watch(itemID)
	if not itemID or IsGear(itemID) then return end
	db.watch = db.watch or {}
	local w = db.watch[itemID] or { hits = 0 }
	w.hits, w.last = w.hits + 1, time()
	db.watch[itemID] = w
end

-- Sound and taskbar flash for new finds: once per round, at most once a minute.
local lastAlert = 0
local function Alert()
	if GetTime() - lastAlert < 60 then return end
	lastAlert = GetTime()
	if db.sound then PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959) end
	if db.flash and FlashClientIcon then FlashClientIcon() end
end

-- Stackable goods sell at a fixed price per unit; single items can be bid-only.
-- nil when the item data is not there yet.
local function IsCommodity(key)
	local info = AH.GetItemKeyInfo and AH.GetItemKeyInfo(key)
	if info == nil then return nil end
	return info.isCommodity and true or false
end

-- Messages about a disenchant find name its disenchant value instead of the vendor price.
local function DeText(d, text)
	if d and d.mode == "de" then return (text:gsub("vendor pays %%s", "disenchanting brings about %%s")) end
	return text
end

-- Take the find into the list and announce it.
local newFinds = {} -- new finds per tab since the last round summary

local function Confirm(d, quiet)
	if d.dropped or deals[d.k] then return end
	deals[d.k] = d
	order[#order + 1] = d
	if quiet then return end
	-- No chat line per find: the round ends with one line of counts (and the window lists them).
	local mode = d.mode or "vendor"
	if mode == "vendor" then Watch(d.id) end
	newFinds[mode] = (newFinds[mode] or 0) + 1
end

-- Every candidate is checked against its real auctions before it is listed: an item
-- may have bid-only auctions, and for stackable goods the check counts how many units
-- lie below the vendor price. Once per round.
local function Enqueue(d)
	if d.queuedRound == scan.round then return end
	d.queuedRound = scan.round
	queue[#queue + 1] = d
end

-- A browse result as a candidate of one tab (target: what one unit brings in that tab).
local function AddCandidate(result, mode, target, id, name, link, icon)
	local key, price = result.itemKey, result.minPrice
	local k = GroupKey(key, mode)
	local d = deals[k] or queued[k]
	if not d then
		d = { k = k }
		queued[k] = d
	end
	if d.fullAt and GetTime() - d.fullAt < FULL_COOLDOWN then
		d.stale = false -- seen and counted by the last full scan: no check needed
		return
	end
	-- Checked before without a buyout below the target (bid-only auctions show their bid
	-- as the browse price): skip it until a cheaper listing appears or the entry expires.
	local skip = noOffer[k]
	if skip and price >= skip.price and GetTime() - skip.at < NO_OFFER_KEEP and not deals[k] then
		queued[k] = nil
		return
	end
	if mode == "de" and d.queuedRound == scan.round then
		-- another level or suffix of an item already in this round's group
		AddVariant(d, key, price)
		d.listed = (d.listed or 0) + (result.totalQuantity or 0)
		if price < (d.browsePrice or price) then d.browsePrice = price end
		return
	end
	d.browsePrice, d.mode = price, mode
	d.key, d.id, d.vendor, d.listed = key, id, target, result.totalQuantity or 0
	if mode == "de" then
		d.variants = nil
		AddVariant(d, key, price)
	end
	d.name, d.link, d.icon, d.stale, d.dropped = name, link, icon, false, nil
	d.commodity = IsCommodity(key) == true
	if d.commodity then
		-- Stackable goods always sell at a fixed price: listed at once with the browse price,
		-- the check later only counts the units below the target.
		d.price = price
		if not d.count then d.profit = target - price end
		Confirm(d)
	else
		-- Single items can be bid-only auctions: listed only once the check finds a buyout.
		d.price = d.price or price
	end
	Enqueue(d)
end

-- One browse result, for both auction tabs: below the vendor price and below its
-- disenchant value.
local function Evaluate(result)
	local key = result.itemKey
	local id, price = key.itemID, result.minPrice
	if IsIgnored(id) then return end
	local vendor, name, link, icon = VendorPrice(id)
	if vendor == nil then
		pendingInfo[id] = pendingInfo[id] or {}
		table.insert(pendingInfo[id], result)
		if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
		return
	end
	-- each tab scans for itself: the vendor tab only for vendor finds, the disenchant tab only for gear
	if scan.mode ~= "de" then
		if vendor > 0 and Worth(vendor, price) then AddCandidate(result, "vendor", vendor, id, name, link, icon) end
		return
	end
	if ns.DisenchantValue then
		local de = ns.DisenchantValue(link or id)
		if de and Worth(de, price) then AddCandidate(result, "de", de, id, name, link, icon) end
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
end

-- Set the minimum distance to the vendor price (copper per unit). Finds below it leave the list.
local function SetMinProfit(copper)
	db.minProfit = max(floor(copper), 1)
	db.minProfitSilver = floor(db.minProfit / 100)
	for i = #order, 1, -1 do
		local d = order[i]
		if not Worth(d.vendor, d.price) and d ~= buy.deal then RemoveDeal(d) end
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
-- Ledger (Trade.lua keeps it): the window's line follows every change
---------------------------------------------------------------------------

ns.OnLedgerChanged = function()
	if ui and ns.LedgerLine then ui.ledger:SetText(ns.LedgerLine()) end
end

---------------------------------------------------------------------------
-- Scan: the whole auction house item list, page by page
---------------------------------------------------------------------------

StartScan = function()
	if not ahOpen then
		Print(L["The auction house must be open."])
		return
	end
	if buy.state or full.active then return end
	scan.active, scan.seen, scan.nextAt = true, 0, nil
	scan.mode = db.tab == "de" and "de" or "vendor"
	scan.round = scan.round + 1
	tries = 0
	wipe(queue)
	wipe(queued)
	for _, d in ipairs(order) do
		if not (d.fullAt and GetTime() - d.fullAt < FULL_COOLDOWN) then d.stale = true end
	end
	local mode = scan.mode
	Send(function() AH.SendBrowseQuery(BrowseQuery(mode)) end)
	SetStatus(mode == "de" and L["Scanning green and blue weapons and armor …"] or L["Scanning …"])
	Refresh()
end

StopScan = function(msg)
	scan.active, scan.nextAt = false, nil
	pendingSend, sentAt = nil, nil
	if msg then SetStatus(msg) end
	Refresh()
end

-- Quick round: the items found below vendor price most often, one search each, instead of
-- reading the whole item list. Gear is left out (its auction key depends on level and suffix).
local function StartQuick()
	if not ahOpen or buy.state or full.active then return false end
	scan.mode = "vendor"
	local list = {}
	for itemID, w in pairs(db.watch or {}) do
		if not IsIgnored(itemID) then list[#list + 1] = { id = itemID, hits = w.hits or 0 } end
	end
	if #list < 5 then return false end
	table.sort(list, function(a, b) return a.hits > b.hits end)
	scan.round = scan.round + 1
	wipe(queue)
	wipe(queued)
	local now = GetTime()
	for i = 1, min(#list, QUICK_ITEMS) do
		local id = list[i].id
		local vendor, name, link, icon = VendorPrice(id)
		local key = AH.MakeItemKey and AH.MakeItemKey(id)
		if vendor and vendor > 0 and key then
			local k = DealKey(key)
			local skip = noOffer[k]
			if not (skip and now - skip.at < NO_OFFER_KEEP / 3) then
				local d = deals[k] or { k = k }
				d.key, d.id, d.vendor, d.mode = key, id, vendor, "vendor"
				d.name, d.link, d.icon, d.dropped = name, link, icon, nil
				d.price = d.price or vendor
				d.browsePrice = d.browsePrice or vendor
				d.commodity = IsCommodity(key) == true
				queued[k] = d
				Enqueue(d)
			end
		end
	end
	if not queue[1] then return false end
	scan.checkTotal, scan.seen, scan.checked = #queue, 0, 0
	SetStatus(L["Quick round: checking %d items that were often below vendor price …"]:format(#queue))
	Refresh()
	return true
end

-- Continuous mode: a full scan whenever one is allowed, otherwise two quick rounds and
-- then one reading the whole item list.
-- Continuous mode follows the tab shown: a full scan whenever one is allowed (it fills
-- every tab), otherwise the vendor tab alternates quick rounds and the whole item list,
-- the disenchant tab reads gear only, the crafting tab checks the prices of its items.
NextRound = function()
	scan.rounds = (scan.rounds or 0) + 1
	if FullReady() then
		StartFull()
	elseif db.tab == "craft" then
		if not StartCraftScan() then scan.nextAt = GetTime() + db.interval end
	elseif db.tab == "de" then
		StartScan()
	elseif scan.rounds % 3 ~= 0 and StartQuick() then
		return
	else
		StartScan()
	end
end

local function RoundDone()
	local v, e = newFinds.vendor or 0, newFinds.de or 0
	wipe(newFinds)
	SetStatus(L["Round done: %d items read. New: vendor %d, disenchant %d."]:format(scan.seen, v, e))
	if v + e > 0 then
		Print(L["New finds: vendor %d, disenchant %d."]:format(v, e))
		Alert()
	end
	if db.loop then scan.nextAt = GetTime() + db.interval end
end

local function FinishScan()
	scan.active, sentAt = false, nil
	for i = #order, 1, -1 do
		local d = order[i]
		if d.stale and d ~= buy.deal then RemoveDeal(d) end
	end
	table.sort(queue, function(a, b)
		if a.commodity ~= b.commodity then return not a.commodity end
		return (a.vendor - a.price) > (b.vendor - b.price)
	end)
	-- never more than MAX_CHECKS per round: the most promising first, the rest next round
	for i = #queue, MAX_CHECKS + 1, -1 do
		local d = table.remove(queue, i)
		d.queuedRound = nil
		if not deals[d.k] then queued[d.k] = nil end
	end
	scan.checkTotal, scan.checked = #queue, 0
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
	-- gear from full scans: use the key that worked for this item before
	if d.plainKey and not d.triedPlain and keyStyle[d.id] == "plain" then
		d.key, d.triedPlain = d.plainKey, true
	end
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
	if offer == false then
		-- no answer: try once more at the end of the queue, keep what is already listed
		-- An item search without any auctions left sends no answer at all; after the second
		-- silent check the find counts as gone and is skipped like one without a buyout.
		d.retries = (d.retries or 0) + 1
		if d.retries <= 1 then
			queue[#queue + 1] = d
		else
			d.retries = nil
			if d.browsePrice then noOffer[d.k] = { price = d.browsePrice, at = GetTime() } end
			queued[d.k] = nil
		end
		wipe(buy)
		if not queue[1] and not scan.active then RoundDone() end
		Refresh()
		return
	end
	d.retries = nil
	if offer then
		noOffer[d.k] = nil
		d.price, d.count, d.profit = offer.unit, offer.count, offer.profit
		Confirm(d)
		SortDeals()
	else
		if d.browsePrice then noOffer[d.k] = { price = d.browsePrice, at = GetTime() } end
		if deals[d.k] then RemoveDeal(d) end
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
		if not info or not info.unitPrice or not Worth(d.vendor, info.unitPrice) then break end
		local n = (info.quantity or 0) - (info.numOwnerItems or 0)
		if limit then n = min(n, floor((limit - cost) / info.unitPrice)) end
		if n > 0 then
			first = first or info.unitPrice
			count, cost = count + n, cost + n * info.unitPrice
		end
	end
	if count <= 0 or ((db.minSlot or 0) > 0 and count * d.vendor - cost < db.minSlot) then return nil end
	return { unit = first, count = count, cost = cost, profit = count * d.vendor - cost }
end

-- Single items: all auctions with a buyout below the vendor price.
-- Bid-only auctions (buyoutAmount 0) are left out. best: the cheapest of them per unit.
local function ItemOffer(d)
	local best, count, profit = nil, 0, 0
	for i = 1, AH.GetNumItemSearchResults(d.key) do
		local info = AH.GetItemSearchResultInfo(d.key, i)
		if info and info.auctionID and info.buyoutAmount and info.buyoutAmount > 0 and not info.containsOwnerItem then
			local quantity = Units(info.itemLink or d.id, info.quantity)
			-- vendor finds compare each auction with its own vendor price, the other tabs with the find's value
			local vendor = (d.mode or "vendor") == "vendor" and info.itemLink and VendorPrice(info.itemLink) or d.vendor
			local unit = info.buyoutAmount / quantity
			if vendor and Worth(vendor, unit, quantity) then
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
		if NextVariant(d) then
			Verify(d, "buy")
			return
		end
		if d.plainKey and not d.triedPlain then
			-- the full scan built this key from the item link; the plain item key may be the one in use
			d.key, d.triedPlain = d.plainKey, true
			Verify(d, "buy")
			return
		end
		RemoveDeal(d)
		ResetBuy(L["Nothing below vendor price any more."])
		return
	end
	local best = offer.best
	if d.triedPlain and d.plainKey then keyStyle[d.id] = "plain" end
	d.price, d.count, d.profit = offer.unit, offer.count, offer.profit
	buy.state = "item_ready"
	buy.auctionID, buy.buyout, buy.qty, buy.vendor, buy.link = best.auctionID, best.buyout, best.quantity, best.vendor, best.link
	SetStatus(L[DeText(d, "%s ×%d for %s, vendor pays %s.")]:format(best.link or d.link or d.name, best.quantity,
		Money(best.buyout), Money(best.vendor * best.quantity)))
	Refresh()
end

-- Does the auction house already hold the results of the last query for this find?
-- It sends no event for results it had before, so they are read without one.
ResultsReady = function(d)
	if not d then return false end
	if d.commodity then
		return AH.HasFullCommoditySearchResults(d.id) or (AH.GetCommoditySearchResultsQuantity(d.id) or 0) > 0
	end
	return AH.HasSearchResults(d.key) and (AH.HasFullItemSearchResults(d.key) or (AH.GetItemSearchResultsQuantity(d.key) or 0) > 0)
end

ReadResults = function()
	if buy.deal and buy.deal.commodity then ReadCommodity() else ReadItem() end
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
		pendingBuys[buy.auctionID] = { id = d.id, qty = buy.qty, cost = buy.buyout, value = buy.vendor * buy.qty,
			name = d.name, at = GetTime(), mode = d.mode or "vendor" }
		Print(L[DeText(d, "Purchase sent: %s ×%d for %s (vendor pays %s).")]:format(buy.link or d.link or d.name, buy.qty,
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
	local d = (selected and deals[selected.k] and selected) or View()[1]
	if d then Select(d) end
end

---------------------------------------------------------------------------
-- Full scan: every auction of the auction house at once (allowed every 15 minutes).
-- Each auction comes with its buyout, so the finds need no check: bid-only auctions,
-- own auctions and auctions above the vendor price are simply left out.
---------------------------------------------------------------------------

FullReady = function()
	return time() - (db.lastFull or 0) >= FULL_COOLDOWN
end

local function FullWait()
	return max(FULL_COOLDOWN - (time() - (db.lastFull or 0)), 0)
end

-- The item key the auction house uses for this item: gear by item level and suffix,
-- everything else by item ID alone.
local function KeyFor(itemID, link)
	local make = AH.MakeItemKey
	local plain = make and make(itemID) or { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
	local equipLoc = select(9, GetItemInfo(link or itemID))
	if not (link and equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" and make) then
		return plain, nil
	end
	local level = GetDetailedItemLevelInfo and GetDetailedItemLevelInfo(link)
	local suffix = tonumber(link:match("item:%d+:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d+)")) or 0
	return make(itemID, level or 0, suffix), plain
end

StartFull = function()
	if not ahOpen then
		Print(L["The auction house must be open."])
		return
	end
	if full.active or scan.active or (buy.state and buy.purpose ~= "check") or not FullReady() then return end
	if buy.purpose == "check" then wipe(buy) end
	pendingSend, sentAt = nil, nil
	wipe(full)
	full.active, full.phase, full.t0 = true, "waiting", GetTime()
	full.items, full.pending, full.player = {}, {}, UnitName("player")
	db.lastFull = time()
	AH.ReplicateItems()
	SetStatus(L["Full scan: waiting for the auction house …"])
	Refresh()
end

-- One auction of the list, collected by item. Returns false when its item data has not
-- loaded yet. Every auction with a buyout is kept: the vendor tab needs the cheap ones, the
-- disenchant and crafting tabs the usual price of all of them.
local function FullRecord(index)
	local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID, hasAll = AH.GetReplicateItemInfo(index)
	if not itemID then return true end
	if not hasAll then return false end
	if not buyout or buyout <= 0 or IsIgnored(itemID) then return true end
	local link = AH.GetReplicateItemLink and AH.GetReplicateItemLink(index)
	local vendor, name, itemLink, icon = VendorPrice(link or itemID)
	if vendor == nil then return false end
	count = Units(link or itemID, count)
	local unit = buyout / count
	if unit < 1 then return true end
	local key, plain = KeyFor(itemID, link)
	local pk = DealKey(key)
	local it = full.items[pk]
	if not it then
		it = { key = key, plainKey = plain, id = itemID, vendor = vendor, name = name, link = itemLink or link,
			icon = icon, a = {} }
		if link then it.link = link end
		full.items[pk] = it
	end
	it.a[#it.a + 1] = { unit, count, owner and owner == full.player or nil }
	return true
end

---------------------------------------------------------------------------
-- Prices: the usual price of an item is the median of its daily median prices
-- (last 14 days), each daily value the median unit price of all its auctions.
---------------------------------------------------------------------------

local function MedianOf(list)
	if not list[1] then return nil end
	table.sort(list)
	local n = #list
	if n % 2 == 1 then return list[(n + 1) / 2] end
	return (list[n / 2] + list[n / 2 + 1]) / 2
end

-- Median unit price of auctions { unit, count, own }, weighted by count, own auctions left out.
local function ListingMedian(a)
	local list, total = {}, 0
	for _, x in ipairs(a) do
		if not x[3] then
			list[#list + 1] = x
			total = total + x[2]
		end
	end
	if total == 0 then return nil, 0 end
	table.sort(list, function(p, q) return p[1] < q[1] end)
	local run = 0
	for _, x in ipairs(list) do
		run = run + x[2]
		if run >= total / 2 then return x[1], #list end
	end
end

-- Day number (days since 1970) as the key of the price history: short in the saved file.
local function Today() return floor(time() / 86400) end

-- What the cheapest tenth of the listed units costs (weighted by count, own auctions left
-- out): the price to buy at, and about the price a sale has to beat.
local function ListingLow(a)
	local list, total = {}, 0
	for _, x in ipairs(a) do
		if not x[3] then
			list[#list + 1] = x
			total = total + x[2]
		end
	end
	if total == 0 then return nil end
	table.sort(list, function(p, q) return p[1] < q[1] end)
	local run = 0
	for _, x in ipairs(list) do
		run = run + x[2]
		if run >= total * 0.1 then return x[1] end
	end
	return list[#list][1]
end

-- Latest low price of a price key (from the last full scan or price check), or nil.
local function StoreLow(pk, value)
	db.lows = db.lows or {}
	db.lows[pk] = { floor(value + 0.5), time() }
end

local function LowValue(pk)
	local l = db.lows and db.lows[pk]
	if l and time() - l[2] < 3 * 86400 then return l[1] end
	return nil
end
ns.LowValue = LowValue

local function StorePrice(pk, value)
	db.prices = db.prices or {}
	local h = db.prices[pk] or {}
	h[Today()] = floor(value + 0.5)
	local keys = {}
	for d in pairs(h) do keys[#keys + 1] = d end
	if #keys > MARKET_DAYS then
		table.sort(keys)
		for i = 1, #keys - MARKET_DAYS do h[keys[i]] = nil end
	end
	db.prices[pk] = h
end

-- Usual price of a price key and on how many days it rests (nil without data).
local function MarketValue(pk)
	local h = db.prices and db.prices[pk]
	if not h then return nil, 0 end
	local list = {}
	for _, v in pairs(h) do list[#list + 1] = v end
	return MedianOf(list), #list
end
ns.MarketValue = MarketValue

local function PlainKey(itemID)
	return DealKey(AH.MakeItemKey and AH.MakeItemKey(itemID) or { itemID = itemID })
end
ns.PlainKey = PlainKey

---------------------------------------------------------------------------
-- Disenchanting: expected materials of green and blue weapons and armor by item level,
-- after the Classic tables (Forever may differ), valued at the materials' usual price.
---------------------------------------------------------------------------

local DUST = { strange = 10940, soul = 11083, vision = 11137, dream = 11176, illusion = 16204 }
local ESS = { lmagic = 10938, gmagic = 10939, lastral = 10998, gastral = 11082, lmystic = 11134, gmystic = 11135,
	lnether = 11174, gnether = 11175, leternal = 16202, geternal = 16203 }
local SHARD = { sglim = 10978, lglim = 11084, sglow = 11138, lglow = 11139, srad = 11177, lrad = 11178,
	sbril = 14343, lbril = 14344 }

-- WoW Forever disenchant table (wow-professions.com, Forever guide): rows by the level
-- required to equip the item (not its item level), the same row for green and blue.
-- up to required level, { dust, avg. count }, { essence, avg. count }, shard
local DE_ROWS = {
	{ 10, { DUST.strange, 1.5 }, { ESS.lmagic, 1.5 }, nil },
	{ 15, { DUST.strange, 2.5 }, { ESS.gmagic, 1.5 }, SHARD.sglim },
	{ 20, { DUST.strange, 5 }, { ESS.lastral, 1.5 }, SHARD.sglim },
	{ 25, { DUST.soul, 1.5 }, { ESS.gastral, 1.5 }, SHARD.lglim },
	{ 30, { DUST.soul, 3.5 }, { ESS.lmystic, 1.5 }, SHARD.sglow },
	{ 35, { DUST.vision, 1.5 }, { ESS.gmystic, 1.5 }, SHARD.lglow },
	{ 40, { DUST.vision, 3.5 }, { ESS.lnether, 1.5 }, SHARD.srad },
	{ 45, { DUST.dream, 1.5 }, { ESS.gnether, 1.5 }, SHARD.lrad },
	{ 50, { DUST.dream, 3.5 }, { ESS.leternal, 1.5 }, SHARD.sbril },
	{ 55, { DUST.illusion, 1.5 }, { ESS.geternal, 1.5 }, SHARD.lbril },
	{ 60, { DUST.illusion, 3.5 }, { ESS.geternal, 2 }, SHARD.lbril },
}
local SHARD_CHANCE = 0.04 -- green items: a shard in about 3-5% of cases

local matCache = {}

local function MatValue(itemID, live)
	if matCache[itemID] ~= nil then return matCache[itemID] or nil end
	-- materials are sold again: value them at what a sale has to beat (the low price), not the median
	local pk = PlainKey(itemID)
	local value = live and live[pk] and ListingLow(live[pk].a) or LowValue(pk)
	if not value then
		local med = MarketValue(pk)
		value = med and med * 0.9
	end
	-- your own sales: the price that really sold, and how much of what you post sells at all
	local sold = ns.SoldPrice and ns.SoldPrice(itemID)
	if sold and (not value or sold < value) then value = sold end
	local rate = ns.SellRate and ns.SellRate(itemID)
	if value and rate then value = value * max(rate, 0.3) end
	matCache[itemID] = value or false
	return value
end

---------------------------------------------------------------------------
-- Learned disenchant results: every disenchant the player does is recorded (item and
-- materials), and once there are enough of them they replace the table above.
-- db.deLearn[key] = { n = disenchants, m = { [material itemID] = units } }
-- keys: "i<itemID>" per item, "b<quality>:<classID>:<item level>" per kind of item.
---------------------------------------------------------------------------

-- Item ID of an ID or link (GetItemInfoInstant is not a global on every client)
local function ItemID(item)
	if type(item) == "number" then return item end
	if type(item) ~= "string" then return nil end
	return tonumber(item:match("item:(%d+)")) or tonumber(item)
end
local LEARN_ITEM, LEARN_KIND = 3, 5 -- disenchants needed before the results count
local deCast
-- Every disenchant material: loot made only of these after an item left the bags is a disenchant.
-- (Forever may use its own spell ID for Disenchant, so the spell is not checked.)
local DE_MATS = { [20725] = true, [22445] = true, [22446] = true, [22447] = true, [22448] = true, [22449] = true, [22450] = true }
for _, t in ipairs({ DUST, ESS, SHARD }) do
	for _, id in pairs(t) do DE_MATS[id] = true end
end

local function BagCounts()
	local counts = {}
	local CC = C_Container
	for bag = 0, 4 do
		local slots = CC and CC.GetContainerNumSlots and CC.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local info = CC.GetContainerItemInfo(bag, slot)
			if info and info.itemID then counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1) end
		end
	end
	return counts
end

local function LearnKeys(itemID)
	local _, _, quality, itemLevel, _, _, _, _, _, _, _, classID = GetItemInfo(itemID)
	if not quality then return "i" .. itemID end
	return "i" .. itemID, ("b%d:%d:%d"):format(quality, classID or 0, itemLevel or 0)
end

local function AddLearned(key, mats)
	if not key then return end
	db.deLearn = db.deLearn or {}
	local e = db.deLearn[key] or { n = 0, m = {} }
	e.n = e.n + 1
	for id, qty in pairs(mats) do e.m[id] = (e.m[id] or 0) + qty end
	db.deLearn[key] = e
end

-- The disenchanted item is the one missing from the bags when the materials show up.
local function DeDebug(fmt, ...)
	if db and db.deDebug then print("|cffe0a83aVendorFloor DE|r " .. fmt:format(...)) end
end

local function IsGear(id)
	local _, _, quality, _, _, _, _, _, _, _, _, classID = GetItemInfo(id)
	return (quality == 2 or quality == 3 or quality == 4) and (classID == 2 or classID == 4)
end

-- The disenchanted item: the gear item locked in the bags while the loot is open, or the
-- one missing from the bags compared with before the cast.
local function FindTarget(before, mats)
	local CC = C_Container
	for bag = 0, 4 do
		for slot = 1, (CC and CC.GetContainerNumSlots and CC.GetContainerNumSlots(bag) or 0) do
			local info = CC.GetContainerItemInfo(bag, slot)
			if info and info.isLocked and info.itemID and IsGear(info.itemID) then return info.itemID, "locked" end
		end
	end
	if not before then return nil end
	local now = BagCounts()
	for id, count in pairs(before) do
		if (now[id] or 0) < count and not mats[id] and IsGear(id) then return id, "gone" end
	end
end

local deLoot -- loot of a disenchant whose item is not known yet: { mats, before, at }

local function Learn(id, mats, how)
	local itemKey, kindKey = LearnKeys(id)
	AddLearned(itemKey, mats)
	AddLearned(kindKey, mats)
	deLoot = nil
	DeDebug("recorded %s (%s)", select(2, GetItemInfo(id)) or id, how)
end

local function RecordDisenchant()
	local before = deCast and deCast.bags
	deCast = nil
	local n = GetNumLootItems and GetNumLootItems() or 0
	local mats, any = {}, false
	for i = 1, n do
		local id = ItemID(GetLootSlotLink(i))
		local _, _, qty = GetLootSlotInfo(i)
		if id then
			if not DE_MATS[id] then
				DeDebug("loot is not from disenchanting (%s)", id)
				return
			end
			mats[id] = (mats[id] or 0) + (qty or 1)
			any = true
		end
	end
	if not any then
		DeDebug("loot window without items (%d slots)", n)
		return
	end
	local id, how = FindTarget(before, mats)
	if id then
		Learn(id, mats, how)
	else
		deLoot = { mats = mats, before = before, at = GetTime() }
		DeDebug("materials seen, waiting for the item to leave the bags (snapshot %s)", before and "yes" or "no")
	end
end

-- After the loot is taken the item is gone from the bags.
local function RetryPending()
	if not deLoot then return end
	if GetTime() - deLoot.at > 5 then
		DeDebug("gave up: disenchanted item not found")
		deLoot = nil
		return
	end
	local id, how = FindTarget(deLoot.before, deLoot.mats)
	if id then Learn(id, deLoot.mats, how) end
end

local deEvents = CreateFrame("Frame")
for _, event in ipairs({ "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED", "LOOT_READY",
	"LOOT_OPENED", "LOOT_CLOSED", "BAG_UPDATE_DELAYED" }) do
	pcall(deEvents.RegisterEvent, deEvents, event)
end
-- UNIT_SPELLCAST_SENT: unit, target, castGUID, spellID; FAILED/INTERRUPTED: unit, castGUID, spellID
deEvents:SetScript("OnEvent", function(_, event, unit, _, a3, a4)
	if event == "LOOT_READY" or event == "LOOT_OPENED" then
		if deLoot then return end
		local fresh = deCast and GetTime() - deCast.at < 15
		DeDebug("%s, cast before: %s", event, fresh and tostring(deCast.spell) or "none")
		if fresh or event == "LOOT_READY" then RecordDisenchant() end
	elseif event == "LOOT_CLOSED" or event == "BAG_UPDATE_DELAYED" then
		RetryPending()
	elseif unit == "player" then
		if event == "UNIT_SPELLCAST_SENT" then
			deCast = { at = GetTime(), bags = BagCounts(), spell = a4 }
		elseif deCast and a3 == deCast.spell then
			deCast = nil
		end
	end
end)

-- Average materials per disenchant from the player's own results, or nil if there are too few.
local function Learned(itemID)
	if not db.deLearn then return nil end
	local itemKey, kindKey = LearnKeys(itemID)
	local e = db.deLearn[itemKey]
	if not (e and e.n >= LEARN_ITEM) then
		e = kindKey and db.deLearn[kindKey]
		if not (e and e.n >= LEARN_KIND) then return nil end
	end
	return e
end

local function LearnedValue(e, live)
	local value, priced = 0, false
	for id, qty in pairs(e.m) do
		local price = MatValue(id, live)
		if price then
			value = value + qty / e.n * price
			priced = true
		end
	end
	return priced and value or nil
end

-- What disenchanting one of these items brings (after the auction house cut), or nil.
-- Green armor: 75% dust, 20% essence; green weapons the other way round; plus a small
-- chance of a shard. Blue items: the shard of their row.
local function DisenchantValue(item, live)
	local _, _, quality, _, minLevel, _, _, _, _, _, _, classID = GetItemInfo(item)
	if not (quality and (classID == 2 or classID == 4)) or (quality ~= 2 and quality ~= 3) then return nil end
	local id = ItemID(item)
	local learned = id and Learned(id)
	if learned then
		local v = LearnedValue(learned, live)
		if v then return v * AH_CUT end
	end
	local level = max(minLevel or 1, 1)
	local row
	for _, r in ipairs(DE_ROWS) do
		if level <= r[1] then
			row = r
			break
		end
	end
	row = row or DE_ROWS[#DE_ROWS]
	local value
	if quality == 2 then
		local dust, ess = MatValue(row[2][1], live), MatValue(row[3][1], live)
		if not (dust and ess) then return nil end
		local pDust, pEss = 0.75, 0.20
		if classID == 2 then pDust, pEss = 0.20, 0.75 end
		value = pDust * row[2][2] * dust + pEss * row[3][2] * ess
		local shard = row[4] and MatValue(row[4], live)
		if shard then value = value + SHARD_CHANCE * shard end
	else
		value = row[4] and MatValue(row[4], live)
	end
	return value and value * AH_CUT or nil
end
ns.DisenchantValue = DisenchantValue

local function FinishFull(failed)
	full.active = false
	if failed then
		SetStatus(L["Full scan: the auction house did not answer. Try again in 15 minutes."])
		Refresh()
		return
	end
	-- 1. today's usual price of every item (for disenchant materials and crafting)
	wipe(matCache)
	for pk, it in pairs(full.items) do
		local med = ListingMedian(it.a)
		if med then
			StorePrice(pk, med)
			StoreLow(pk, ListingLow(it.a))
		end
	end
	-- 2. finds per tab
	local found, counts = {}, { vendor = 0, de = 0 }
	local function add(mode, pk, it, target, unit, count)
		local k = GroupKey(it.key, mode)
		local g = found[k]
		if not g then
			g = { k = k, key = it.key, plainKey = it.plainKey, id = it.id, vendor = target, price = unit, count = 0,
				profit = 0, listed = 0, name = it.name, link = it.link, icon = it.icon, mode = mode, pk = pk }
			found[k] = g
			counts[mode] = counts[mode] + 1
		end
		g.count, g.profit, g.listed = g.count + count, g.profit + (target - unit) * count, g.listed + 1
		if unit < g.price then g.price = unit end
		if mode == "de" then
			AddVariant(g, it.key, unit)
			-- the group shows the base item, not one of its variants
			g.name, g.link = GetItemInfo(it.id), select(2, GetItemInfo(it.id)) or g.link
		end
	end
	for pk, it in pairs(full.items) do
		local de = DisenchantValue(it.link or it.id, full.items)
		for _, x in ipairs(it.a) do
			local unit, count, own = x[1], x[2], x[3]
			if not own then
				if it.vendor > 0 and Worth(it.vendor, unit, count) then add("vendor", pk, it, it.vendor, unit, count) end
				if de and Worth(de, unit, count) then add("de", pk, it, de, unit, count) end
			end
		end
	end
	-- 3. into the lists
	local now, new = GetTime(), 0
	for k, g in pairs(found) do
		g.commodity = IsCommodity(g.key) == true
		g.fullAt, g.stale = now, false
		if g.mode == "vendor" then Watch(g.id) end
		local d = deals[k]
		if d then
			d.price, d.count, d.profit, d.listed, d.fullAt, d.stale = g.price, g.count, g.profit, g.listed, now, false
			d.vendor, d.mode = g.vendor, g.mode
			if g.variants then d.variants, d.key, d.vi, d.triedPlain = g.variants, g.key, 1, nil end
			d.plainKey = d.plainKey or g.plainKey
		else
			Confirm(g, true)
			new = new + 1
		end
	end
	-- the full list is complete: what it did not show is gone
	for i = #order, 1, -1 do
		local d = order[i]
		if not found[d.k] and d ~= buy.deal then RemoveDeal(d) end
	end
	full.items = nil
	ns.craftDirty = true
	-- kept for the next visit: until the next full scan is allowed the finds come from here
	local keep = {}
	for _, g in pairs(found) do
		keep[#keep + 1] = { k = g.k, key = g.key, plainKey = g.plainKey, id = g.id, vendor = g.vendor, price = g.price,
			count = g.count, profit = g.profit, listed = g.listed, name = g.name, link = g.link, icon = g.icon,
			mode = g.mode, commodity = g.commodity, variants = g.variants, vi = 1 }
	end
	db.lastFinds = { at = time(), list = keep }
	SortDeals()
	SetStatus(L["Full scan done: %d auctions. Vendor %d, disenchant %d finds."]:format(full.count or 0,
		counts.vendor, counts.de))
	if new > 0 then
		Print(L["%d new finds (vendor %d, disenchant %d)."]:format(new, counts.vendor, counts.de))
		Alert()
	end
	if db.loop then scan.nextAt = GetTime() + 5 end
	Refresh()
end

---------------------------------------------------------------------------
-- Price check for the crafting tab: one search per reagent and product of your
-- recipes, their current median price goes into the price history.
---------------------------------------------------------------------------

local craft = {}
local CRAFT_WAIT, CRAFT_TIMEOUT = 0.6, 3

local function CraftItems()
	local char = (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "")
	local mine = db.recipes and db.recipes[char]
	local seen, list = {}, {}
	local function add(id)
		if id and not seen[id] then
			seen[id] = true
			list[#list + 1] = id
		end
	end
	for _, p in pairs(mine or {}) do
		for _, rec in ipairs(p.list or {}) do
			add(rec.out)
			for _, r in ipairs(rec.r) do
				-- reagents a merchant sells are not looked up on the auction house
				if not (db.vendorBuy and db.vendorBuy[r[1]]) then add(r[1]) end
			end
		end
	end
	return list
end

StartCraftScan = function()
	if not ahOpen or buy.state or full.active or scan.active then return false end
	local list = CraftItems()
	if not list[1] then
		SetStatus(L["Open each profession window once so VendorFloor can read your recipes."])
		return false
	end
	wipe(craft)
	craft.active, craft.list, craft.i, craft.found = true, list, 0, 0
	scan.nextAt = nil
	SetStatus(L["Price check: %d reagents and products …"]:format(#list))
	Refresh()
	return true
end

local function StopCraftScan(msg)
	wipe(craft)
	if msg then SetStatus(msg) end
end

local function ReadCraftPrice(id)
	local key = AH.MakeItemKey and AH.MakeItemKey(id)
	local a = {}
	local n = AH.GetNumCommoditySearchResults and AH.GetNumCommoditySearchResults(id) or 0
	for i = 1, n do
		local info = AH.GetCommoditySearchResultInfo(id, i)
		if info and info.unitPrice and info.quantity and not info.containsOwnerItem then
			a[#a + 1] = { info.unitPrice, info.quantity }
		end
	end
	if not a[1] and key then
		for i = 1, (AH.GetNumItemSearchResults(key) or 0) do
			local info = AH.GetItemSearchResultInfo(key, i)
			if info and info.buyoutAmount and info.buyoutAmount > 0 and not info.containsOwnerItem then
				local q = max(info.quantity or 1, 1)
				a[#a + 1] = { info.buyoutAmount / q, q }
			end
		end
	end
	local med = ListingMedian(a)
	if med then
		StorePrice(PlainKey(id), med)
		StoreLow(PlainKey(id), ListingLow(a))
		craft.found = craft.found + 1
	end
end

local function CraftTick(now)
	if craft.cur then
		local id, key = craft.cur, craft.key
		local ready = AH.HasFullCommoditySearchResults(id) or (AH.GetCommoditySearchResultsQuantity(id) or 0) > 0
			or (key and AH.HasSearchResults(key) and (AH.HasFullItemSearchResults(key) or (AH.GetItemSearchResultsQuantity(key) or 0) > 0))
		if ready and now - craft.t > CRAFT_WAIT then
			ReadCraftPrice(id)
			craft.cur = nil
		elseif now - craft.t > CRAFT_TIMEOUT then
			craft.cur = nil -- no auctions of it right now
		end
		return
	end
	craft.i = craft.i + 1
	local id = craft.list[craft.i]
	if not id then
		local found = craft.found
		local total = #craft.list
		StopCraftScan(L["Price check done: %d of %d items on the auction house."]:format(found, total))
		ns.craftDirty = true
		if db.loop then scan.nextAt = GetTime() + db.interval end
		Refresh()
		return
	end
	local key = AH.MakeItemKey and AH.MakeItemKey(id)
	craft.cur, craft.key, craft.t = id, key, now
	Send(function() AH.SendSearchQuery(key, SORTS, true) end)
	Refresh()
end

local function FullTick(now)
	if full.phase == "waiting" then
		if now - full.t0 > FULL_WAIT then FinishFull(true) end
	elseif full.phase == "arriving" then
		-- the list can arrive in parts: read it once it has stopped growing for two seconds
		local n = AH.GetNumReplicateItems()
		if n ~= full.count then
			full.count, full.stableAt = n, now
		elseif now - full.stableAt > 2 then
			full.phase, full.index = "reading", 0
		end
	elseif full.phase == "reading" then
		local last = min(full.index + FULL_PER_TICK, full.count) - 1
		for i = full.index, last do
			if not FullRecord(i) then
				full.pending[#full.pending + 1] = i
				local itemID = select(17, AH.GetReplicateItemInfo(i))
				if itemID and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
			end
		end
		full.index = last + 1
		SetStatus(L["Full scan: reading %d of %d auctions …"]:format(full.index, full.count))
		if full.index >= full.count then full.phase, full.loadT = "loading", now end
	elseif full.phase == "loading" then
		-- items the client had not loaded yet: up to 30 seconds more
		local still = {}
		for n, i in ipairs(full.pending) do
			if n > FULL_PER_TICK or not FullRecord(i) then still[#still + 1] = i end
		end
		full.pending = still
		if still[1] and now - full.loadT < 30 then
			SetStatus(L["Full scan: loading item data (%d left) …"]:format(#still))
		else
			FinishFull()
		end
	end
	Refresh()
end

---------------------------------------------------------------------------
-- Clock: send queries, time-outs, the check queue, continuous mode
---------------------------------------------------------------------------

local function Tick()
	local now = GetTime()
	if full.active then
		FullTick(now)
		return
	end
	if craft.active and not pendingSend then
		CraftTick(now)
		return
	end
	if pendingSend then
		-- The throttle can stay "not ready" after a purchase; send anyway after a while.
		-- A dropped query comes back through AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED.
		if AH.IsThrottledMessageSystemReady() or now - pendingAt > SEND_FORCE then
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
		if not d.dropped then
			scan.checked = (scan.checked or 0) + 1
			Verify(d, "check")
		end
		return
	end
	-- A check reads held results quickly. A purchase waits longer for fresh ones, so an
	-- auction bought a moment ago is not offered again from old results.
	local wait = buy.purpose == "check" and CACHE_WAIT or 2.5
	if state == "verifying" and sentAt and now - sentAt > wait and ResultsReady(buy.deal) then
		ReadResults()
		return
	end
	if state == "verifying" and buy.purpose == "check" and now - buy.t > CHECK_TIMEOUT then
		FinishCheck(buy.deal, false)
	elseif state == "verifying" and not pendingSend and now - buy.t > BUY_SILENT then
		-- No answer to a purchase check: the auction house sends none for a search without
		-- results. Gear from a full scan gets a second try with the plain item key, then it is gone.
		local d = buy.deal
		if d and NextVariant(d) then
			Verify(d, "buy")
		elseif d and d.plainKey and not d.triedPlain then
			d.key, d.triedPlain = d.plainKey, true
			Verify(d, "buy")
		else
			if d then RemoveDeal(d) end
			ResetBuy(L["Nothing below vendor price any more."])
		end
	elseif state == "verifying" and now - buy.t > SEND_TIMEOUT then
		ResetBuy(L["No answer while checking."])
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
		NextRound()
	end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local TAB_HINT = {
	vendor = "Auctions below what a merchant pays. Scan, or a full scan every 15 minutes.",
	de = "Green and blue weapons and armor below what disenchanting them brings (Classic disenchant tables, materials at their usual price). \"Scan\" on this tab reads only green and blue weapons and armor; full scans fill it too. Needs Enchanting (any skill: Forever lets you disenchant everything from skill 1).",
	craft = "Your learned recipes that make a profit: product (auction house after the cut, or merchant) minus reagents (auction house or merchant, whichever is cheaper). Open each profession window once so VendorFloor can read your recipes. \"Prices\" looks up the current price of each reagent and product; full scans and merchants you visit add to it.",
}

-- Crafting tab: rows show recipes instead of auctions.
local function RefreshCraft()
	local list, miss = {}, 0
	if ns.CraftResults then list, miss = ns.CraftResults() end
	local maxOffset = max(#list - ROWS, 0)
	offset = max(min(offset, maxOffset), 0)
	ui.empty:SetShown(#list == 0)
	ui.empty:SetText(L[TAB_HINT.craft])
	for i = 1, ROWS do
		local row, c = ui.rows[i], list[i + offset]
		row.deal, row.craft = nil, c
		if c then
			row.icon:SetTexture(c.icon)
			row.name:SetText((c.link or c.name) .. (c.qty ~= 1 and (" ×" .. c.qty) or ""))
			row.info:SetText(("%s > %s  |cff6cc58c+%s|r |cff8d97a5(%s)|r"):format(Money(c.cost), Money(c.revenue),
				Money(c.profit), c.route == "ah" and L["AH"] or L["merchant"]))
			row.mark:Hide()
			row:Show()
		else
			row:Hide()
		end
	end
	local profs = ns.CraftProfessions and ns.CraftProfessions() or {}
	ui.summary:SetText(#list > 0 and L["%d crafts with profit · %s"]:format(#list, table.concat(profs, ", ")) or "")
	ui.count:SetText(#list > ROWS and L["%d–%d of %d"]:format(offset + 1, min(offset + ROWS, #list), #list) or "")
	if miss > 0 and not craft.active then SetStatus(L["%d recipes have no prices yet (reagent or product never seen in a full scan)."]:format(miss)) end
	ui.action:SetText(L["Read recipes: open a profession window"])
	ui.action:SetEnabled(false)
	ui.loop:SetChecked(db.loop)
end

Refresh = function()
	if not ui then return end
	local view = View()
	local maxOffset = max(#view - ROWS, 0)
	offset = max(min(offset, maxOffset), 0)
	for _, mode in ipairs(TABS) do
		local n = 0
		if mode == "craft" then
			n = ns.CraftResults and #(ns.CraftResults()) or 0
		else
			for _, d in ipairs(order) do if (d.mode or "vendor") == mode then n = n + 1 end end
		end
		local tab = ui.tabs[mode]
		tab:SetText(n > 0 and ("%s (%d)"):format(tab.label, n) or tab.label)
		tab:SetOn(db.tab == mode)
	end
	ui.empty:SetShown(#view == 0)
	ui.empty:SetText(L[TAB_HINT[db.tab] or TAB_HINT.vendor])
	for i = 1, ROWS do
		local row, d = ui.rows[i], view[i + offset]
		row.deal, row.craft = d, nil
		if d then
			row.icon:SetTexture(d.icon)
			row.name:SetText(d.link or d.name or ("item:" .. d.id))
			row.info:SetText(("%s > %s%s  |cff6cc58c+%s|r |cff8d97a5(%s×)|r"):format(Money(d.price),
				d.mode == "de" and L["DE ~"] or "", Money(d.vendor), Money(d.profit or 0), d.count and tostring(d.count) or "?"))
			row.mark:SetShown(d == selected)
			row:Show()
		else
			row:Hide()
		end
	end
	local checking = buy.purpose == "check" or (queue[1] ~= nil and not buy.state)
	ns.UpdateFullButton()

	-- progress: full scan (auctions read), check phase (candidates checked), browsing (no total known)
	local fraction
	if full.active then
		fraction = full.phase == "reading" and full.count and full.count > 0 and full.index / full.count
			or full.phase == "loading" and 1 or 0
	elseif craft.active then
		fraction = craft.i / max(#craft.list, 1)
	elseif checking and ((scan.checked or 0) + #queue) > 0 then
		fraction = (scan.checked or 0) / ((scan.checked or 0) + #queue)
	elseif scan.active then
		fraction = 0
	end
	ui.bar:SetShown(fraction ~= nil)
	if fraction then
		fraction = max(0, min(1, fraction))
		ui.bar:SetValue(fraction)
		local label
		if full.active then
			label = full.phase == "reading" and L["Full scan %d%%"]:format(floor(fraction * 100)) or L["Full scan: waiting for the auction house"]
		elseif craft.active then
			label = L["Prices %d of %d (%d%%)"]:format(craft.i, #craft.list, floor(fraction * 100))
		elseif checking and ((scan.checked or 0) + #queue) > 0 then
			label = L["Checking %d of %d (%d%%)"]:format(scan.checked or 0, (scan.checked or 0) + #queue, floor(fraction * 100))
		else
			label = L["Reading auctions: %d"]:format(scan.seen or 0)
		end
		ui.bar.text:SetText(label)
	end

	if db.tab == "craft" then
		RefreshCraft()
		return
	end

	-- summary: what the whole list of this tab would cost and bring
	local cost, profit = 0, 0
	for _, d in ipairs(view) do
		local n = d.count or 1
		cost, profit = cost + (d.price or 0) * n, profit + (d.profit or 0)
	end
	ui.summary:SetText(#view > 0 and L["%d finds · cost %s · profit %s"]:format(#view, Money(cost), Money(profit)) or "")
	ui.loop:SetChecked(db.loop)
	ui.count:SetText(#view > ROWS and L["%d–%d of %d"]:format(offset + 1, min(offset + ROWS, #view), #view) or "")

	local state, text, enabled = buy.state, L["Click a find"], false
	if not state or buy.purpose == "check" then
		if selected and deals[selected.k] then text, enabled = L["Check"], true
		elseif view[1] then text, enabled = L["Check"], true end
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

-- Scan button: "Stop" while a round runs, while finds are checked and while continuous
-- mode waits for the next round (with the seconds left), otherwise "Scan".
local function UpdateScanButton()
	local checking = buy.purpose == "check" or (queue[1] ~= nil and not buy.state)
	local waiting = scan.nextAt and not scan.active and not checking and not craft.active
	local running = scan.active or checking or waiting or craft.active
	if waiting then
		ui.scan:SetText(L["Stop (%d)"]:format(max(0, math.ceil(scan.nextAt - GetTime()))))
	else
		ui.scan:SetText(running and L["Stop"] or L["Scan"])
	end
	ui.scan:SetEnabled(not full.active and (running or not buy.state))
	if not running then
		ui.scan:SetText(db.tab == "craft" and L["Prices"] or L["Scan"])
	end
	-- while something runs the button is shown switched on
	ui.scan:SetOn(running)
end

-- The full scan button: its countdown runs once a second (the scan button's as well).
function ns.UpdateFullButton()
	if not ui then return end
	UpdateScanButton()
	if full.active then
		ui.full:SetText(L["Full scan"])
		ui.full:SetEnabled(false)
	elseif FullReady() then
		ui.full:SetText(L["Full scan"])
		ui.full:SetEnabled(not scan.active and not (buy.state and buy.purpose ~= "check"))
	else
		local wait = FullWait()
		ui.full:SetText(L["Full scan (%s)"]:format(("%d:%02d"):format(floor(wait / 60), wait % 60)))
		ui.full:SetEnabled(false)
	end
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

---------------------------------------------------------------------------
-- Look: flat dark panels in the colours of bencepo.github.io
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local C = {
	bg = { 0.059, 0.075, 0.094, 0.97 },    -- #0f1318
	panel = { 0.110, 0.137, 0.173, 1 },    -- #1c232c
	line = { 0.157, 0.192, 0.235, 1 },     -- #28313c
	well = { 0.043, 0.055, 0.071, 1 },     -- #0b0e12
	gold = { 0.878, 0.659, 0.227, 1 },     -- #e0a83a
	goldDim = { 0.165, 0.141, 0.086, 1 },  -- #2a2416
	text = { 0.902, 0.914, 0.933, 1 },     -- #e6e9ee
	muted = { 0.553, 0.592, 0.647, 1 },    -- #8d97a5
	dark = { 0.102, 0.071, 0.020, 1 },     -- #1a1205
}
ns.C = C

local function Flat(frame, bg, border)
	if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
	frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
	frame:SetBackdropColor(unpack(bg or C.panel))
	frame:SetBackdropBorderColor(unpack(border or C.line))
end
ns.Flat = Flat

-- A flat button. kind "primary": gold with dark text (the main action).
-- :SetOn(true) shows it switched on (gold border and text), e.g. while a scan runs.
local function FlatButton(parent, width, height, kind)
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	b:SetSize(width or 80, height or 22)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("CENTER", 0, 0)
	b:SetFontString(fs)
	b.kind, b.on, b.hover = kind, false, false
	if kind == "primary" then
		fs:SetShadowOffset(0, 0)
		local font, size = fs:GetFont()
		if font then fs:SetFont(font, (size or 12) + 1, "") end
		-- dark text on gold: drop the colour codes of money amounts, they would vanish on gold
		local setText = b.SetText
		function b:SetText(text)
			if text then
				-- drop the money colours and force dark text: colour codes win over font colours
				text = "|cff1a1205" .. tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. "|r"
			end
			setText(self, text)
		end
	end
	function b:Restyle()
		local enabled = self:IsEnabled()
		local bg, border, text
		if self.kind == "primary" then
			bg, border, text = C.gold, C.gold, C.dark
		elseif self.on then
			bg, border, text = C.goldDim, C.gold, C.gold
		else
			bg, border, text = C.panel, self.hover and C.gold or C.line, C.text
		end
		Flat(self, bg, border)
		fs:SetTextColor(unpack(text))
		self:SetAlpha(enabled and 1 or 0.45)
		if self.kind == "primary" and self.hover and enabled then self:SetBackdropColor(0.95, 0.75, 0.32, 1) end
	end
	function b:SetOn(on) self.on = on and true or false self:Restyle() end
	b:HookScript("OnEnter", function(self) self.hover = true self:Restyle() end)
	b:HookScript("OnLeave", function(self) self.hover = false self:Restyle() end)
	b:HookScript("OnEnable", function(self) self:Restyle() end)
	b:HookScript("OnDisable", function(self) self:Restyle() end)
	b:SetScript("OnMouseDown", function(self) if self:IsEnabled() then fs:SetPoint("CENTER", 0, -1) end end)
	b:SetScript("OnMouseUp", function() fs:SetPoint("CENTER", 0, 0) end)
	b:Restyle()
	return b
end
ns.FlatButton = FlatButton

-- A switch with a label (checked = on), with SetChecked/GetChecked like a check button.
local function FlatToggle(parent, label, width)
	local b = FlatButton(parent, width or 96, 24)
	b.checked = false
	function b:SetChecked(v) self.checked = v and true or false self:SetText((self.checked and "|TInterface\\RaidFrame\\ReadyCheck-Ready:12|t " or "") .. label) self:SetOn(self.checked) end
	function b:GetChecked() return self.checked end
	b:SetScript("PreClick", function(self) self:SetChecked(not self.checked) end)
	b:SetChecked(false)
	return b
end

local function BuildUI()
	if ui then return end
	local f = CreateFrame("Frame", "VendorFloorFrame", UIParent, "BackdropTemplate")
	f:SetSize(580, 222 + ROWS * ROW_HEIGHT)
	f:SetFrameStrata("HIGH")
	Flat(f, C.bg, C.line)
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

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 12, -9)
	title:SetText("VendorFloor")
	title:SetTextColor(unpack(C.gold))
	local version = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	version:SetPoint("LEFT", title, "RIGHT", 6, -1)
	version:SetText(VERSION)
	local head = f:CreateTexture(nil, "ARTWORK")
	head:SetColorTexture(unpack(C.line))
	head:SetHeight(1)
	head:SetPoint("TOPLEFT", 1, -30)
	head:SetPoint("TOPRIGHT", -1, -30)

	local close = FlatButton(f, 22, 20)
	close:SetPoint("TOPRIGHT", -6, -5)
	close:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	f.scan = FlatButton(f, 90, 24)
	f.scan:SetPoint("TOPLEFT", 10, -38)
	f.scan:SetScript("OnClick", function()
		if craft.active then
			StopCraftScan(L["Scan stopped."])
			scan.nextAt = nil
			Refresh()
		elseif scan.active or scan.nextAt or buy.purpose == "check" or (queue[1] and not buy.state) then
			StopAll(L["Scan stopped."])
		elseif db.tab == "craft" then
			StartCraftScan()
		else
			StartScan()
		end
	end)

	-- full scan: every auction at once, allowed every 15 minutes
	f.full = FlatButton(f, 130, 24)
	f.full:SetPoint("LEFT", f.scan, "RIGHT", 6, 0)
	f.full:SetScript("OnClick", function() StartFull() end)
	f.full:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(L["Full scan"])
		GameTooltip:AddLine(L["Reads every auction at once: complete, without checking each item."], 1, 1, 1, true)
		GameTooltip:AddLine(L["The full scan is available every 15 minutes."], 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	f.full:HookScript("OnLeave", function(self)
		if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
	end)

	local loop = FlatToggle(f, L["Continuous"], 120)
	loop:SetPoint("LEFT", f.full, "RIGHT", 6, 0)
	loop:SetChecked(db.loop)
	loop:SetScript("OnClick", function(self)
		db.loop = self:GetChecked() and true or false
		if not db.loop then scan.nextAt = nil end
	end)
	f.loop = loop

	f.count = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.count:SetPoint("TOPRIGHT", -30, -10)

	-- Minimum profit per unit: how far below the vendor price an auction must be
	local profit = CreateFrame("EditBox", nil, f, "BackdropTemplate")
	Flat(profit, C.well, C.line)
	profit:SetFontObject("GameFontHighlight")
	profit:SetTextInsets(6, 6, 0, 0)
	profit:SetSize(84, 24)
	profit:SetPoint("TOPRIGHT", -10, -38)
	profit:HookScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(unpack(C.gold)) end)
	profit:HookScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(unpack(C.line)) end)
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
	local profitText = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	profitText:SetPoint("RIGHT", profit, "LEFT", -8, 0)
	profitText:SetText(L["Min. profit/unit"])

	-- tabs: one list per kind of find, never mixed
	f.tabs = {}
	local labels = { vendor = L["Vendor"], de = L["Disenchant"], craft = L["Crafting"] }
	local prev
	for _, mode in ipairs(TABS) do
		local tab = FlatButton(f, 136, 24)
		tab.label = labels[mode]
		if prev then tab:SetPoint("LEFT", prev, "RIGHT", 6, 0) else tab:SetPoint("TOPLEFT", 10, -68) end
		tab:SetScript("OnClick", function()
			db.tab, offset = mode, 0
			if selected and (selected.mode or "vendor") ~= mode then selected = nil end
			Refresh()
		end)
		f.tabs[mode], prev = tab, tab
	end

	-- progress bar under the buttons
	f.bar = CreateFrame("StatusBar", nil, f)
	f.bar:SetPoint("TOPLEFT", 10, -98)
	f.bar:SetPoint("RIGHT", f, "RIGHT", -10, 0)
	f.bar:SetHeight(14)
	f.bar:SetStatusBarTexture(WHITE)
	f.bar:SetStatusBarColor(unpack(C.gold))
	f.bar:SetMinMaxValues(0, 1)
	f.bar.bg = f.bar:CreateTexture(nil, "BACKGROUND")
	f.bar.bg:SetAllPoints()
	f.bar.bg:SetColorTexture(unpack(C.well))
	f.bar.text = f.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.bar.text:SetPoint("CENTER", 0, 0)
	local font = f.bar.text:GetFont()
	if font then f.bar.text:SetFont(font, 11, "OUTLINE") end
	f.bar:Hide()

	f.rows = {}
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, f)
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("TOPLEFT", 10, -118 - (i - 1) * ROW_HEIGHT)
		row:SetPoint("RIGHT", f, "RIGHT", -10, 0)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		if i % 2 == 0 then
			local zebra = row:CreateTexture(nil, "BACKGROUND", nil, -1)
			zebra:SetAllPoints()
			zebra:SetColorTexture(1, 1, 1, 0.025)
		end
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.06)
		row.mark = row:CreateTexture(nil, "BACKGROUND")
		row.mark:SetAllPoints()
		row.mark:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.16)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(ROW_HEIGHT - 2, ROW_HEIGHT - 2)
		row.icon:SetPoint("LEFT", 2, 0)
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.info:SetPoint("RIGHT", -2, 0)
		row.info:SetJustifyH("RIGHT")
		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
		row.name:SetPoint("RIGHT", row.info, "LEFT", -6, 0)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)
		row:SetScript("OnClick", function(self, button)
			if not self.deal then return end
			if button == "RightButton" then Ignore(self.deal) else Select(self.deal) end
		end)
		row:SetScript("OnEnter", function(self)
			local c = self.craft
			if c then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetHyperlink(c.link or ("item:" .. c.out))
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine(L["%s: %s"]:format(c.prof, c.recipe or ""), 0.88, 0.66, 0.23)
				for _, r in ipairs(c.parts) do
					local name = GetItemInfo(r.id) or ("item:" .. r.id)
					GameTooltip:AddDoubleLine(("%d× %s"):format(r.qty, name), ("%s (%s)"):format(Money(r.unit * r.qty),
						r.src == "ah" and L["AH"] or L["merchant"]), 1, 1, 1, 1, 1, 1)
				end
				GameTooltip:AddDoubleLine(L["Reagents"], Money(c.cost), 0.7, 0.7, 0.7, 1, 1, 1)
				GameTooltip:AddDoubleLine(c.route == "ah" and L["Sells on the AH for (after cut)"] or L["A merchant pays"], Money(c.revenue), 0.7, 0.7, 0.7, 1, 1, 1)
				GameTooltip:AddDoubleLine(L["Profit"], Money(c.profit), 0.25, 1, 0.25, 0.25, 1, 0.25)
				GameTooltip:Show()
				return
			end
			local d = self.deal
			if not d then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(d.link or ("item:" .. d.id))
			GameTooltip:AddLine(" ")
			if d.mode == "de" then
				GameTooltip:AddLine(L["Disenchanting brings about %s (estimate)"]:format(Money(d.vendor or 0)), 0.88, 0.66, 0.23)
			end
			if d.count and (d.mode or "vendor") ~= "vendor" then
				GameTooltip:AddLine(L["Below that: %d×, total profit %s"]:format(d.count, Money(d.profit or 0)), 0.25, 1, 0.25)
			elseif d.count then
				GameTooltip:AddLine(L["Below vendor price: %d×, total profit %s"]:format(d.count, Money(d.profit or 0)), 0.25, 1, 0.25)
			else
				GameTooltip:AddLine(L["Profit per unit %s, units not counted yet"]:format(Money(d.profit or 0)), 0.25, 1, 0.25)
			end
			GameTooltip:AddLine(L["Listed on the AH: %d"]:format(d.listed or 0), 0.7, 0.7, 0.7)
			GameTooltip:AddLine(L["Click: check and buy. Right-click: hide this item."], 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function(self)
			if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
		end)
		f.rows[i] = row
	end

	f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	f.empty:SetPoint("TOPLEFT", 20, -130)
	f.empty:SetPoint("RIGHT", f, "RIGHT", -20, 0)
	f.empty:SetJustifyH("LEFT")
	f.empty:SetSpacing(3)

	f.ledger = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	f.ledger:SetPoint("BOTTOMLEFT", 10, 60)
	f.ledger:SetPoint("RIGHT", f, "RIGHT", -10, 0)
	f.ledger:SetJustifyH("LEFT")
	f.ledger:SetWordWrap(false)
	f.ledger:SetText(ns.LedgerLine and ns.LedgerLine() or "")

	f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.summary:SetPoint("BOTTOMLEFT", 10, 79)
	f.summary:SetPoint("RIGHT", f, "RIGHT", -10, 0)
	f.summary:SetJustifyH("LEFT")
	f.summary:SetWordWrap(false)

	f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.status:SetPoint("BOTTOMLEFT", 10, 43)
	f.status:SetPoint("RIGHT", f, "RIGHT", -10, 0)
	f.status:SetJustifyH("LEFT")
	f.status:SetWordWrap(false)
	f.status:SetText(statusText)

	local foot = f:CreateTexture(nil, "ARTWORK")
	foot:SetColorTexture(unpack(C.line))
	foot:SetHeight(1)
	foot:SetPoint("BOTTOMLEFT", 1, 98)
	foot:SetPoint("BOTTOMRIGHT", -1, 98)

	f.action = FlatButton(f, 100, 30, "primary")
	f.action:SetPoint("BOTTOMLEFT", 10, 8)
	f.action:SetPoint("BOTTOMRIGHT", -10, 8)
	f.action:SetScript("OnClick", VendorFloor_BuyNext)


	local elapsed, second = 0, 0
	f:SetScript("OnUpdate", function(_, dt)
		elapsed, second = elapsed + dt, second + dt
		if second >= 1 then
			second = 0
			ns.UpdateFullButton()
		end
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

function ns.RefreshWindow()
	if ui and ui:IsShown() then Refresh() end
end

-- Open the window on a tab (the crafting button in the profession window uses it).
function ns.OpenTab(mode)
	db.tab, offset = mode, 0
	ShowWindow()
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

	local percent = Settings.RegisterAddOnSetting(category, "VENDORFLOOR_MINPERCENT", "minPercent", db,
		Settings.VarType.Number, L["Minimum profit in percent"], defaults.minPercent)
	local percentOptions = Settings.CreateSliderOptions(0, 100, 5)
	if percentOptions.SetLabelFormatter and MinimalSliderWithSteppersMixin then
		percentOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
	end
	Settings.CreateSlider(category, percent, percentOptions,
		L["Profit in percent of the price, for every tab. 0 turns it off."])

	local slotSetting = Settings.RegisterAddOnSetting(category, "VENDORFLOOR_MINSLOT", "minSlotSilver", db,
		Settings.VarType.Number, L["Minimum profit per bag slot (silver)"], 0)
	local slotOptions = Settings.CreateSliderOptions(0, 500, 5)
	if slotOptions.SetLabelFormatter and MinimalSliderWithSteppersMixin then
		slotOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
	end
	Settings.CreateSlider(category, slotSetting, slotOptions,
		L["Profit an auction must bring as a whole (one auction takes one bag slot). 0 turns it off."])
	slotSetting:SetValueChangedCallback(function(_, value) db.minSlot = (tonumber(value) or 0) * 100 end)

	local flash = Settings.RegisterAddOnSetting(category, "VENDORFLOOR_FLASH", "flash", db,
		Settings.VarType.Boolean, L["Flash the taskbar"], defaults.flash)
	Settings.CreateCheckbox(category, flash, L["Flash the game's taskbar icon on new finds while the game is in the background."])

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
	db.total.sold, db.total.soldCost = db.total.sold or 0, db.total.soldCost or 0
	db.bought = db.bought or {}  -- itemID -> { units, cost }: bought and not sold yet
	db.minSlotSilver = floor((db.minSlot or 0) / 100)
	if db.tab ~= "vendor" and db.tab ~= "de" and db.tab ~= "craft" then db.tab = "vendor" end
	ns.db = db
	local ok, err = pcall(RegisterSettings)
	if not ok then Print(tostring(err)) end
end

-- The finds of the last full scan (up to an hour old), so the tabs are not empty until the
-- next full scan is allowed. Each is checked against the live auctions when clicked.
local function RestoreFinds()
	local last = db.lastFinds
	if not (last and last.list and time() - (last.at or 0) < 3600) then return end
	local age = time() - last.at
	local n = 0
	for _, g in ipairs(last.list) do
		if not deals[g.k] and not IsIgnored(g.id) and (g.mode == "vendor" or (g.mode == "de" and g.variants)) then
			local d = {}
			for field, value in pairs(g) do d[field] = value end
			d.fullAt, d.stale = GetTime() - age, false
			Confirm(d, true)
			n = n + 1
		end
	end
	if n > 0 then
		SortDeals()
		SetStatus(L["%d finds from the full scan %d min ago. They are checked when you click them."]:format(n, floor(age / 60)))
	end
end

function handlers.AUCTION_HOUSE_SHOW()
	ahOpen = true
	pcall(RestoreFinds)
	if not db.hidden then ShowWindow() end
end

function handlers.AUCTION_HOUSE_CLOSED()
	ahOpen = false
	StopCraftScan()
	full.active = false
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

function handlers.REPLICATE_ITEM_LIST_UPDATE()
	if full.active and full.phase == "waiting" then
		full.phase, full.count, full.stableAt = "arriving", AH.GetNumReplicateItems(), GetTime()
	end
end

function handlers.AUCTION_HOUSE_BROWSE_FAILURE()
	if scan.active then StopScan(L["The auction house rejected the query."]) end
end

function handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()
	if lastSend and (scan.active or buy.state == "verifying") then pendingSend = lastSend end
end

function handlers.GET_ITEM_INFO_RECEIVED(id, success)
	local results = pendingInfo[id]
	if not results then return end
	pendingInfo[id] = nil
	if success and VendorPrice(id) ~= nil then
		for _, result in ipairs(results) do Evaluate(result) end
		Refresh()
	end
end

function handlers.COMMODITY_SEARCH_RESULTS_UPDATED(id)
	if buy.state == "verifying" and buy.deal and buy.deal.id == id then
		buy.deal.commodity = true
		ReadCommodity()
	end
end
handlers.COMMODITY_SEARCH_RESULTS_ADDED = handlers.COMMODITY_SEARCH_RESULTS_UPDATED

function handlers.ITEM_SEARCH_RESULTS_UPDATED(key)
	if buy.state == "verifying" and buy.deal and type(key) == "table" and key.itemID == buy.deal.id then
		buy.deal.commodity = false
		ReadItem()
	end
end
handlers.ITEM_SEARCH_RESULTS_ADDED = handlers.ITEM_SEARCH_RESULTS_UPDATED

function handlers.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
	local p = pendingBuys[auctionID]
	if not p then return end
	pendingBuys[auctionID] = nil
	ns.RecordBuy(p.id, p.qty, p.cost, p.value, p.mode)
end

-- In case the client has no purchase event: the "You won an auction for ..." line.
local WON_PATTERN = ERR_AUCTION_WON_S and ("^" .. ERR_AUCTION_WON_S:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)") .. "$")
function handlers.CHAT_MSG_SYSTEM(msg)
	if not (WON_PATTERN and msg) then return end
	local name = msg:match(WON_PATTERN)
	if not name then return end
	for auctionID, p in pairs(pendingBuys) do
		if p.name == name and GetTime() - p.at < 60 then
			pendingBuys[auctionID] = nil
			ns.RecordBuy(p.id, p.qty, p.cost, p.value, p.mode)
			return
		end
	end
end

function handlers.COMMODITY_PRICE_UPDATED(_, total)
	if buy.state ~= "quoting" then return end
	local d = buy.deal
	if total and total <= buy.qty * (d.vendor - db.minProfit) then
		buy.state, buy.total, buy.t = "quote_ok", total, GetTime()
		SetStatus(L[DeText(d, "Quote: %d× for %s, vendor pays %s.")]:format(buy.qty, Money(total), Money(buy.qty * d.vendor)))
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
	Print(L[DeText(d, "Bought: %s ×%d for %s (vendor pays %s).")]:format(d.link or d.name, buy.qty, Money(buy.total),
		Money(buy.qty * d.vendor)))
	ns.RecordBuy(d.id, buy.qty, buy.total or 0, buy.qty * d.vendor, d.mode or "vendor")
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
		L["/vfloor full – start a full scan (every 15 minutes)"],
		L["/vfloor stats – totals since install"],
		L["/vfloor de – your recorded disenchant results"],
		L["/vfloor sales – how fast your own auctions sell"],
		L["/vfloor percent <n> – minimum profit in percent (0 = off)"],
		L["/vfloor slot <amount> – minimum profit per bag slot, e.g. 10s (0 = off)"],
		L["/vfloor quick – quick round over the watch list"],
		L["/vfloor craft – crafts with profit in chat"],
		L["/vfloor flash – taskbar flash on or off"],
		L["/vfloor export – ledger to copy into bencepo.github.io/vendorfloor"],
		L["/vfloor minimap – minimap button on or off"],
		L["/vfloor forget – forget the purchases still to sell"],
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
		Print(ns.TotalLine())
	elseif cmd == "export" then
		ns.ShowExport()
	elseif cmd == "percent" and tonumber(arg) then
		db.minPercent = max(floor(tonumber(arg)), 0)
		Print(L["Minimum profit in percent: %d%%"]:format(db.minPercent))
	elseif cmd == "slot" and ParseMoney(arg) then
		db.minSlot = ParseMoney(arg)
		db.minSlotSilver = floor(db.minSlot / 100)
		Print(L["Minimum profit per bag slot: %s"]:format(Money(db.minSlot)))
	elseif cmd == "flash" then
		db.flash = not db.flash
		Print(L["Taskbar flash: %s"]:format(db.flash and L["on"] or L["off"]))
	elseif cmd == "craft" then
		ns.PrintCraft()
	elseif cmd == "sales" then
		ns.PrintSales()
	elseif cmd == "de" and arg == "debug" then
		db.deDebug = not db.deDebug
		Print("disenchant debug: " .. (db.deDebug and "on" or "off"))
	elseif cmd == "de" then
		local list = {}
		for key, e in pairs(db.deLearn or {}) do
			local id = tonumber(key:match("^i(%d+)$"))
			if id then list[#list + 1] = { id = id, e = e } end
		end
		table.sort(list, function(a, b) return a.e.n > b.e.n end)
		if #list == 0 then Print(L["No disenchants recorded yet."]) end
		for i = 1, min(#list, 15) do
			local x = list[i]
			local v = LearnedValue(x.e)
			Print(L["%s: %d× disenchanted, about %s each"]:format(select(2, GetItemInfo(x.id)) or x.id, x.e.n,
				v and Money(v * AH_CUT) or "?"))
		end
	elseif cmd == "quick" then
		if not StartQuick() then Print(L["The watch list needs at least 5 items. They come from finds below vendor price."]) end
	elseif cmd == "debug" then
		Print(("scan.active=%s round=%d seen=%d queue=%d checkTotal=%s buy.state=%s purpose=%s pending=%s throttleReady=%s full.active=%s phase=%s nextAt=%s ah=%s"):format(
			tostring(scan.active), scan.round or 0, scan.seen or 0, #queue, tostring(scan.checkTotal), tostring(buy.state),
			tostring(buy.purpose), tostring(pendingSend ~= nil), tostring(AH.IsThrottledMessageSystemReady()),
			tostring(full.active), tostring(full.phase), tostring(scan.nextAt and floor(scan.nextAt - GetTime())), tostring(ahOpen)))
	elseif cmd == "minimap" then
		Print(ns.ToggleMinimap() and L["Minimap button shown."] or L["Minimap button hidden."])
	elseif cmd == "full" then
		StartFull()
	elseif cmd == "forget" then
		ns.ForgetPurchases()
		Print(L["Tracked purchases cleared."])
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
