-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Crafting: which of your learned recipes make a profit right now?
-- Recipes are read when a profession window is open (the game only offers them then) and
-- kept per character. Prices come from VendorFloor's full scans (usual price) and from
-- merchants (what a merchant sells a reagent for, read when a merchant window is open).
-- Profit = what the product brings (auction house after the 5% cut, or a merchant,
-- whichever is more) minus the reagents (auction house or merchant, whichever is cheaper).

local _, ns = ...
local ipairs, pairs, pcall, select, setmetatable, type, wipe =
	ipairs, pairs, pcall, select, setmetatable, type, wipe
local max, min = math.max, math.min
local format = string.format
local tsort = table.sort

local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })
local GetItemInfo = ns.GetItemInfo
local TITLE = "VendorFloor"
local CHAT_PREFIX = "|cff33ff99VendorFloor:|r "
local AH_CUT = 0.95

local charKey
local function CharKey()
	if charKey then return charKey end
	local name = UnitName and UnitName("player")
	local realm = GetRealmName and GetRealmName() or ""
	if type(name) == "string" and name ~= "" and name ~= "Unknown" and type(realm) == "string" and realm ~= "" then
		charKey = name .. "-" .. realm
		return charKey
	end
	return (type(name) == "string" and name or "?") .. "-" .. (type(realm) == "string" and realm or "")
end

---------------------------------------------------------------------------
-- Recipes (profession window open)
---------------------------------------------------------------------------

local function ScanRecipes()
	local db = ns.db
	local T = C_TradeSkillUI
	if not (db and T and T.GetAllRecipeIDs and T.GetRecipeInfo and T.GetRecipeSchematic) then return end
	local ids = T.GetAllRecipeIDs()
	if type(ids) ~= "table" or #ids == 0 then return end
	local prof = "?"
	if T.GetBaseProfessionInfo then
		local info = T.GetBaseProfessionInfo()
		if type(info) == "table" then
			prof = (info.professionName ~= "" and info.professionName) or (info.parentProfessionName ~= "" and info.parentProfessionName) or prof
		end
	end
	if not prof or prof == "" or prof == "?" then return end
	local basicType = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
	local list = {}
	for _, id in ipairs(ids) do
		local info = T.GetRecipeInfo(id)
		if type(info) == "table" and info.learned then
			local ok, sch = pcall(T.GetRecipeSchematic, id, false)
			if ok and type(sch) == "table" and sch.outputItemID then
				local slots = sch.reagentSlotSchematics
				if slots and slots[1] then
					local reagents = {}
					for _, slot in ipairs(slots) do
						local r = slot.reagents and slot.reagents[1]
						local basic = slot.reagentType == nil or (basicType ~= nil and slot.reagentType == basicType)
						if r and r.itemID and basic and (slot.required ~= false) then
							reagents[#reagents + 1] = { r.itemID, slot.quantityRequired or 1 }
						end
					end
					if reagents[1] then
						local qty = ((sch.quantityMin or 1) + (sch.quantityMax or sch.quantityMin or 1)) / 2
						list[#list + 1] = { id = id, name = info.name, out = sch.outputItemID, qty = qty, r = reagents }
					end
				end
			end
		end
	end
	if not list[1] then return end
	db.recipes = db.recipes or {}
	local char = CharKey()
	db.recipes[char] = db.recipes[char] or {}
	db.recipes[char][prof] = { at = time(), list = list }
	ns.craftDirty = true
	if ns.RefreshWindow then ns.RefreshWindow() end
end

---------------------------------------------------------------------------
-- Merchant prices of reagents (merchant window open)
---------------------------------------------------------------------------

local function ScanMerchant()
	local db = ns.db
	-- GetMerchantItemInfo is the merchant API of this client (C_MerchantFrame is retail only).
	---@diagnostic disable-next-line: deprecated
	if not (db and GetMerchantNumItems and GetMerchantItemInfo and GetMerchantItemID) then return end
	local vendorBuy = db.vendorBuy
	if not vendorBuy then
		vendorBuy = {}
		db.vendorBuy = vendorBuy
	end
	local changed = false
	for i = 1, GetMerchantNumItems() do
		---@diagnostic disable-next-line: deprecated
		local _, _, price, quantity, numAvailable, _, _, extendedCost = GetMerchantItemInfo(i)
		-- only unlimited items for gold
		if price and price > 0 and not extendedCost and (numAvailable or -1) < 0 then
			local itemID = GetMerchantItemID(i)
			if itemID then
				local unit = price / max(quantity or 1, 1)
				if vendorBuy[itemID] ~= unit then
					vendorBuy[itemID] = unit
					changed = true
				end
			end
		end
	end
	if changed then ns.craftDirty = true end
end

---------------------------------------------------------------------------
-- Profit
---------------------------------------------------------------------------

-- Cheapest way to get one unit: auction house (usual price) or merchant.
local function ReagentCost(db, itemID)
	-- buying: the cheapest listings (low price), else the usual price
	local pk = ns.PlainKey and ns.PlainKey(itemID)
	local market = pk and ((ns.LowValue and ns.LowValue(pk)) or (ns.MarketValue and ns.MarketValue(pk)))
	local vendor = db.vendorBuy and db.vendorBuy[itemID]
	if market and vendor then
		if vendor <= market then return vendor, "vendor" end
		return market, "ah"
	end
	if vendor then return vendor, "vendor" end
	if market then return market, "ah" end
	return nil
end

-- What one unit of the product brings: auction house after the cut, or a merchant.
local function ProductValue(itemID)
	-- selling: what a sale has to beat (low price), else 90% of the usual price
	local pk = ns.PlainKey and ns.PlainKey(itemID)
	local market = pk and ns.LowValue and ns.LowValue(pk)
	if not market and pk and ns.MarketValue then
		local med = ns.MarketValue(pk)
		market = med and med * 0.9
	end
	local sold = ns.SoldPrice and ns.SoldPrice(itemID)
	if sold and (not market or sold < market) then market = sold end
	local rate = ns.SellRate and ns.SellRate(itemID)
	if market and rate then market = market * max(rate, 0.3) end
	local sell = select(11, GetItemInfo(itemID)) or 0
	local ah = market and market * AH_CUT or nil
	if ah and ah >= sell then return ah, "ah" end
	if sell > 0 then return sell, "vendor" end
	return nil
end

-- Craft results, best first; results.char marks the character they belong to.
local results, missing = {}, 0
local costCache, srcCache, valCache, routeCache = {}, {}, {}, {}

---@param a table
---@param b table
local function byProfit(a, b) return a.profit > b.profit end

-- All recipes of this character with a positive profit, best first.
function ns.CraftResults()
	local char = CharKey()
	if not ns.craftDirty and results.char == char then return results, missing end
	ns.craftDirty = false
	results, missing = { char = char }, 0
	local db = ns.db
	local mine = db and db.recipes and db.recipes[char]
	if not mine then return results, missing end
	local minProfit = db.minProfit or 1
	wipe(costCache)
	wipe(srcCache)
	wipe(valCache)
	wipe(routeCache)
	for prof, p in pairs(mine) do
		local recList = p.list
		if recList then
			for _, rec in ipairs(recList) do
				local cost, ok = 0, true
				local recReagents = rec.r
				for _, r in ipairs(recReagents) do
					local id = r[1]
					local unit = costCache[id]
					if unit == nil then
						local u, src = ReagentCost(db, id)
						unit = u or false
						costCache[id] = unit
						srcCache[id] = src
					end
					if not unit then ok = false break end
					cost = cost + unit * r[2]
				end
				if ok then
					local outID = rec.out
					local value = valCache[outID]
					if value == nil then
						local v, rt = ProductValue(outID)
						value = v or false
						valCache[outID] = value
						routeCache[outID] = rt
					end
					if value then
						local revenue = value * rec.qty
						local profit = revenue - cost
						if profit >= minProfit then
							local parts = {}
							for j = 1, #recReagents do
								local r = recReagents[j]
								local id = r[1]
								parts[j] = { id = id, qty = r[2], unit = costCache[id], src = srcCache[id] }
							end
							local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(outID)
							results[#results + 1] = { prof = prof, recipe = rec.name, out = outID, qty = rec.qty, cost = cost,
								revenue = revenue, profit = profit, route = routeCache[outID], parts = parts, name = name or rec.name,
								link = link, icon = icon }
						end
					else
						missing = missing + 1
					end
				else
					missing = missing + 1
				end
			end
		end
	end
	wipe(costCache)
	wipe(srcCache)
	wipe(valCache)
	wipe(routeCache)
	tsort(results, byProfit)
	return results, missing
end

local function HasProfession(mine)
	if not mine then return false end
	for prof in pairs(mine) do
		if prof ~= "" and prof ~= "?" then return true end
	end
	return false
end

function ns.CraftProfessions()
	local db = ns.db
	local mine = db and db.recipes and db.recipes[CharKey()]
	local names = {}
	if mine then
		for prof in pairs(mine) do
			if prof ~= "" and prof ~= "?" then names[#names + 1] = prof end
		end
		tsort(names)
	end
	return names
end

-- Chat output for /vfloor craft.
function ns.PrintCraft()
	local list, miss = ns.CraftResults()
	local out = DEFAULT_CHAT_FRAME
	local db = ns.db
	if not HasProfession(db and db.recipes and db.recipes[CharKey()]) then
		out:AddMessage(CHAT_PREFIX .. L["Open each profession window once so VendorFloor can read your recipes."])
		return
	end
	out:AddMessage(CHAT_PREFIX .. L["%d crafts with profit (%d recipes without prices yet):"]:format(#list, miss))
	for i = 1, min(#list, 10) do
		local c = list[i]
		out:AddMessage(format("  %s: %s %s > %s, +%s", c.prof, c.link or c.name, ns.Money(c.cost), ns.Money(c.revenue),
			ns.Money(c.profit)))
	end
end

---------------------------------------------------------------------------
-- Events and the button in the profession window
---------------------------------------------------------------------------

local button

local function AddButton()
	local parent = ProfessionsFrame or TradeSkillFrame
	if button or not parent or not ns.FlatButton then return end
	button = ns.FlatButton(parent, 150, 24, "primary")
	-- above the window, never near "Create" / "Create All": below it the button lay over them,
	-- because the window's frame reaches further down than its art
	button:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", parent == TradeSkillFrame and -34 or 0, 4)
	button:SetText(L["Craft profits"])
	button:SetScript("OnClick", function()
		ScanRecipes()
		if ns.OpenTab then ns.OpenTab("craft") else ns.PrintCraft() end
	end)
	button:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(TITLE)
		GameTooltip:AddLine(L["Shows which of your learned recipes make a profit, with prices from VendorFloor's full scans and from merchants."], 1, 1, 1, true)
		GameTooltip:Show()
	end)
	button:HookScript("OnLeave", function(self)
		if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
	end)
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "MERCHANT_SHOW", "MERCHANT_UPDATE" }) do
	pcall(events.RegisterEvent, events, event)
end
local pending = false
local function RunPendingScan()
	pending = false
	pcall(ScanRecipes)
end
events:SetScript("OnEvent", function(_, event)
	if not ns.db then return end
	if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
		pcall(ScanMerchant)
		return
	end
	if event == "TRADE_SKILL_SHOW" then pcall(AddButton) end
	-- the list arrives in parts: read it once it has settled
	if not pending then
		pending = true
		C_Timer.After(1, RunPendingScan)
	end
end)
