-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Own auction sales: what you post (hooked from the auction house, works with Auctionator),
-- when a buyer is found and what expires. From this VendorFloor learns how fast an item
-- sells, at what price it really sold, and how often it sells at all. Disenchant materials
-- and crafted items are then valued at the price that sold, times the share that sells.
-- Sales while you are offline only show up in the mail and are not counted.

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local floor, max, min = math.floor, math.max, math.min

local KEEP = 3 * 86400   -- posted auctions are forgotten after this (longest duration is 48 h)
local FRESH = 3 * 86400  -- a sold price counts this long
local MIN_ENDED = 3      -- ended auctions needed before the sell rate counts

local function DB() return ns.db end

-- db.sales[itemID] = { posts, units, sold = buyer messages, firstN = auctions with a sale,
--   firstSum = seconds from posting to the first buyer (summed), expired, price, priceAt }
local function Entry(db, id)
	db.sales = db.sales or {}
	local e = db.sales[id]
	if not e then
		e = { posts = 0, units = 0, sold = 0, firstN = 0, firstSum = 0, expired = 0 }
		db.sales[id] = e
	end
	return e
end

local function OnPost(loc, qty, unit)
	local db = DB()
	if not (db and loc and C_Item and C_Item.GetItemID) then return end
	local id = C_Item.GetItemID(loc)
	if not id then return end
	local name = GetItemInfo(id)
	if not name then return end
	local e = Entry(db, id)
	e.posts = e.posts + 1
	e.units = e.units + (qty or 1)
	db.open = db.open or {}
	db.open[#db.open + 1] = { id = id, name = name, unit = unit and floor(unit + 0.5), at = time() }
end

if C_AuctionHouse and hooksecurefunc then
	if C_AuctionHouse.PostCommodity then
		hooksecurefunc(C_AuctionHouse, "PostCommodity", function(loc, _, qty, unit)
			pcall(OnPost, loc, qty, unit)
		end)
	end
	if C_AuctionHouse.PostItem then
		hooksecurefunc(C_AuctionHouse, "PostItem", function(loc, _, qty, _, buyout)
			qty = qty or 1
			pcall(OnPost, loc, qty, buyout and buyout / max(qty, 1))
		end)
	end
end

-- "A buyer has been found for your auction of %s." -> Lua pattern with one capture
local function Pattern(fmt)
	if type(fmt) ~= "string" then return nil end
	local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)")
	return "^" .. p .. "$"
end
local SOLD, EXPIRED = Pattern(ERR_AUCTION_SOLD_S), Pattern(ERR_AUCTION_EXPIRED_S)

local function Oldest(db, name)
	for i, o in ipairs(db.open or {}) do
		if o.name == name then return o, i end
	end
end

local function Purge(db)
	local now, keep = time(), {}
	for _, o in ipairs(db.open or {}) do
		if now - o.at < KEEP then keep[#keep + 1] = o end
	end
	db.open = keep
end

local function OnSystem(msg)
	local db = DB()
	if not (db and db.open and type(msg) == "string") then return end
	local name = SOLD and msg:match(SOLD)
	if name then
		local o = Oldest(db, name)
		if not o then return end
		local e = Entry(db, o.id)
		e.sold = e.sold + 1
		if not o.hit then
			o.hit = true
			e.firstN = e.firstN + 1
			e.firstSum = e.firstSum + (time() - o.at)
		end
		if o.unit then e.price, e.priceAt = o.unit, time() end
		return
	end
	name = EXPIRED and msg:match(EXPIRED)
	if name then
		local o, i = Oldest(db, name)
		if not o then return end
		local e = Entry(db, o.id)
		if not o.hit then e.expired = e.expired + 1 end
		table.remove(db.open, i)
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("CHAT_MSG_SYSTEM")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, msg)
	if event == "PLAYER_LOGIN" then
		if DB() then Purge(DB()) end
	else
		OnSystem(msg)
	end
end)

-- Unit price your last sale of this item went for (recent), or nil.
function ns.SoldPrice(id)
	local e = DB() and DB().sales and DB().sales[id]
	if e and e.price and time() - (e.priceAt or 0) < FRESH then return e.price end
end

-- Share of your ended auctions of this item that found a buyer, or nil if too few ended.
function ns.SellRate(id)
	local e = DB() and DB().sales and DB().sales[id]
	if not e then return nil end
	local ended = e.firstN + e.expired
	if ended < MIN_ENDED then return nil end
	return e.firstN / ended
end

local function Duration(sec)
	if sec < 3600 then return ("%d min"):format(max(floor(sec / 60 + 0.5), 1)) end
	return ("%.1f h"):format(sec / 3600)
end

function ns.PrintSales()
	local db = DB()
	local list = {}
	for id, e in pairs(db and db.sales or {}) do list[#list + 1] = { id = id, e = e } end
	table.sort(list, function(a, b) return a.e.posts > b.e.posts end)
	if #list == 0 then
		ns.Print(L["No own auctions recorded yet. They are recorded from now on when you post."])
		return
	end
	for i = 1, min(#list, 15) do
		local x, e = list[i], list[i].e
		local ended = e.firstN + e.expired
		ns.Print(L["%s: posted %d×, sold %d of %d ended, first buyer after %s, last price %s"]:format(
			select(2, GetItemInfo(x.id)) or x.id, e.posts, e.firstN, ended,
			e.firstN > 0 and Duration(e.firstSum / e.firstN) or "–",
			e.price and ns.Money(e.price) or "–"))
	end
end
