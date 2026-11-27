-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Optional (settings, off by default): VendorFloor's values in item tooltips. The
-- disenchant value of green and blue gear, the latest low auction price VendorFloor saw,
-- the Market Flips market value and your watchlist limit. The vendor price is left out:
-- the game and many addons show it.

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })

local GOLD = { 0.88, 0.66, 0.23 }

local function AddLines(tip, link)
	local db = ns.db
	if not (db and db.tooltip and ns.Money) then return end
	if type(link) ~= "string" then return end
	if issecretvalue and issecretvalue(link) then return end -- hidden from addons
	local id = tonumber(link:match("item:(%d+)"))
	if not id then return end
	local de, low, st
	if ns.DisenchantValue then -- green and blue weapons and armor, when you can disenchant
		local ok, v = pcall(ns.DisenchantValue, link)
		if ok then de = v end
	end
	local pk = ns.PlainKey and ns.PlainKey(id)
	if pk and ns.LowValue then
		local ok, v = pcall(ns.LowValue, pk)
		if ok then low = v end
	end
	-- Market Flips: the market value once its history is ready (3 days, 3 readings)
	local market = ns.Market
	if market and pk and db.marketSettings and db.marketSettings.showTooltip and ns.FlipsOn() then
		local ok, v = pcall(market.GetStats, market, db, pk)
		if ok and v and v.ready then st = v end
	end
	local want = db.wishlist and db.wishlist[id]
	if not (de or low or st or want) then return end
	tip:AddLine("VendorFloor", GOLD[1], GOLD[2], GOLD[3])
	if de then tip:AddDoubleLine(L["Disenchant value"], "~" .. ns.Money(de), 0.8, 0.8, 0.8, 1, 1, 1) end
	if low then tip:AddDoubleLine(L["Auction house (low)"], ns.Money(low), 0.8, 0.8, 0.8, 1, 1, 1) end
	if st then
		tip:AddDoubleLine(L["Market value"], ns.Money(st.marketValue), 0.8, 0.8, 0.8, 1, 1, 1)
		tip:AddDoubleLine(L["Price history"], L["%d days, %d readings"]:format(st.days, st.scans), 0.8, 0.8, 0.8, 1, 1, 1)
	end
	if want then tip:AddDoubleLine(L["Watchlist limit"], ns.Money(want.max), 0.8, 0.8, 0.8, 1, 1, 1) end
end

local function OnTooltipItem(tip)
	if not (ns.db and ns.db.tooltip) then return end
	if not tip or (tip.IsForbidden and tip:IsForbidden()) or not tip.GetItem then return end
	local _, link = tip:GetItem()
	AddLines(tip, link)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipItem)
else
	for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
		if tip then tip:HookScript("OnTooltipSetItem", OnTooltipItem) end
	end
end
