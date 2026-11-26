-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Market Flips: a price history of its own per item (one value per day, the lowest daily
-- median seen that day), the market value from it (median of the days of the last two
-- weeks) and the check whether an auction lies far enough below it to buy and post again.
-- An item needs at least 3 days and 3 price readings before it can be a flip.
-- db.marketHistory[price key] = { days = { [day number] = unit price }, scans = n, lastDay = day }

local _, ns = ...

ns.Market = ns.Market or {}
local Market = ns.Market

Market.MIN_DAYS = 3
Market.MIN_SCANS = 3
Market.MAX_DAYS = 14
Market.RETENTION_DAYS = 21
Market.AH_CUT = 0.05

local floor = math.floor
local max = math.max

local function IsSecret(v)
	return issecretvalue and issecretvalue(v) or false
end

function Market:GetDayIndex(timestamp)
	local ts = (type(timestamp) == "number" and timestamp > 0) and timestamp or time()
	return floor(ts / 86400)
end

function Market:EnsureDB(db)
	if type(db) ~= "table" then return nil end
	db.marketHistory = db.marketHistory or {}
	db.marketDays = db.marketDays or {} -- day number -> true: days with any reading (for the empty-tab hint)
	db.marketSettings = db.marketSettings or {}
	local cfg = db.marketSettings
	if type(cfg.minDiscountPct) ~= "number" then cfg.minDiscountPct = 30 end
	if type(cfg.minNetProfit) ~= "number" then cfg.minNetProfit = 5000 end -- 50 silver
	if type(cfg.retentionDays) ~= "number" then cfg.retentionDays = Market.RETENTION_DAYS end
	if cfg.showTooltip == nil then cfg.showTooltip = true end
	return db
end

function Market:Reset(db)
	local okDB = self:EnsureDB(db)
	if not okDB then return end
	okDB.marketHistory = {}
	okDB.marketDays = {}
end

function Market:Prune(db, nowTs)
	local okDB = self:EnsureDB(db)
	if not okDB then return end
	local nowDay = self:GetDayIndex(nowTs)
	local retention = max(floor(okDB.marketSettings.retentionDays or Market.RETENTION_DAYS), Market.MIN_DAYS)
	local cutoffDay = nowDay - retention

	for itemKey, entry in pairs(okDB.marketHistory) do
		if type(entry) ~= "table" then
			okDB.marketHistory[itemKey] = nil
		else
			local lastDay = entry.lastDay or 0
			if lastDay < cutoffDay then
				okDB.marketHistory[itemKey] = nil
			elseif type(entry.days) == "table" then
				local remaining = 0
				for dayIdx, val in pairs(entry.days) do
					if type(dayIdx) ~= "number" or dayIdx < cutoffDay or type(val) ~= "number" or val <= 0 then
						entry.days[dayIdx] = nil
					else
						remaining = remaining + 1
					end
				end
				if remaining == 0 then okDB.marketHistory[itemKey] = nil end
			else
				okDB.marketHistory[itemKey] = nil
			end
		end
	end
	for dayIdx in pairs(okDB.marketDays) do
		if type(dayIdx) ~= "number" or dayIdx < cutoffDay then okDB.marketDays[dayIdx] = nil end
	end
end

-- Record a single price reading (e.g. the median unit price of a listing).
-- Keeps the lowest reading per calendar day.
function Market:RecordObservation(db, itemKey, unitPrice, nowTs)
	local okDB = self:EnsureDB(db)
	if not okDB or not itemKey or IsSecret(itemKey) then return end
	if type(unitPrice) ~= "number" or IsSecret(unitPrice) or unitPrice <= 0 then return end

	local key = tostring(itemKey)
	local dayIdx = self:GetDayIndex(nowTs)
	local entry = okDB.marketHistory[key]
	if type(entry) ~= "table" then
		entry = { days = {}, scans = 0, lastDay = dayIdx }
		okDB.marketHistory[key] = entry
	end

	entry.days = entry.days or {}
	entry.scans = (entry.scans or 0) + 1
	if dayIdx > (entry.lastDay or 0) then entry.lastDay = dayIdx end

	local rounded = floor(unitPrice + 0.5)
	if rounded > 0 and (not entry.days[dayIdx] or rounded < entry.days[dayIdx]) then
		entry.days[dayIdx] = rounded
	end
	okDB.marketDays[dayIdx] = true

	-- at most MAX_DAYS + 7 days per entry until the next Prune
	local dayList = {}
	for d in pairs(entry.days) do dayList[#dayList + 1] = d end
	if #dayList > Market.MAX_DAYS + 7 then
		table.sort(dayList)
		for i = 1, #dayList - (Market.MAX_DAYS + 7) do entry.days[dayList[i]] = nil end
	end
end

-- Record from an auction listing: { { unitPrice, quantity, isOwn }, ... }.
-- The median unit price of the other players' auctions resists single outliers.
function Market:RecordListings(db, itemKey, listings, nowTs)
	if type(listings) ~= "table" or #listings == 0 then return end
	local prices = {}
	for _, row in ipairs(listings) do
		if type(row) == "table" and not row[3] then
			local u = row[1]
			if type(u) == "number" and not IsSecret(u) and u > 0 then prices[#prices + 1] = u end
		end
	end
	if #prices == 0 then return end
	table.sort(prices)
	local n = #prices
	local med = (n % 2 == 1) and prices[(n + 1) / 2] or ((prices[n / 2] + prices[n / 2 + 1]) / 2)
	self:RecordObservation(db, itemKey, med, nowTs)
end

local function Median(values)
	local n = #values
	if n == 0 then return nil end
	table.sort(values)
	local mid = floor((n + 1) / 2)
	if n % 2 == 1 then return values[mid] end
	return floor((values[mid] + values[mid + 1]) / 2)
end

function Market:GetStats(db, itemKey, nowTs)
	local okDB = self:EnsureDB(db)
	if not okDB or not itemKey or IsSecret(itemKey) then return nil end
	local entry = okDB.marketHistory[tostring(itemKey)]
	if type(entry) ~= "table" or type(entry.days) ~= "table" then
		return { ready = false, days = 0, scans = 0, neededDays = Market.MIN_DAYS, neededScans = Market.MIN_SCANS }
	end

	local nowDay = self:GetDayIndex(nowTs)
	local minDay = nowDay - Market.MAX_DAYS
	local dailyPrices = {}
	for dayIdx, val in pairs(entry.days) do
		if type(dayIdx) == "number" and dayIdx >= minDay and dayIdx <= nowDay and type(val) == "number" and val > 0 then
			dailyPrices[#dailyPrices + 1] = val
		end
	end
	local activeDays = #dailyPrices

	local scans = entry.scans or 0
	if activeDays < Market.MIN_DAYS or scans < Market.MIN_SCANS then
		return {
			ready = false,
			days = activeDays,
			scans = scans,
			neededDays = max(0, Market.MIN_DAYS - activeDays),
			neededScans = max(0, Market.MIN_SCANS - scans),
		}
	end

	local marketValue = Median(dailyPrices)
	if not marketValue or marketValue <= 0 then return nil end

	local confidence = "Low"
	if scans >= 10 and activeDays >= 7 then
		confidence = "High"
	elseif scans >= 5 and activeDays >= 4 then
		confidence = "Medium"
	end
	return { ready = true, marketValue = marketValue, days = activeDays, scans = scans, confidence = confidence }
end

-- What one unit brings when sold at the market value, after the auction house cut.
function Market:NetValue(marketValue)
	return floor((marketValue or 0) * (1 - Market.AH_CUT))
end

-- The flip check of a unit price against ready stats (GetStats). Separate from EvaluateFlip so
-- a full scan looks up the stats of an item once and checks each of its auctions with them.
function Market:JudgeFlip(db, stats, buyoutUnitPrice)
	if not (stats and stats.ready and stats.marketValue and stats.marketValue > 0) then return nil end
	if type(buyoutUnitPrice) ~= "number" or IsSecret(buyoutUnitPrice) or buyoutUnitPrice <= 0 then return nil end
	local netProfit = floor(stats.marketValue * (1 - Market.AH_CUT) - buyoutUnitPrice)
	local discountPct = (stats.marketValue - buyoutUnitPrice) / stats.marketValue * 100
	local cfg = (type(db) == "table" and db.marketSettings) or {}
	local qualifying = discountPct >= (cfg.minDiscountPct or 30) and netProfit >= (cfg.minNetProfit or 5000)
	return {
		ready = true,
		qualifying = qualifying,
		marketValue = stats.marketValue,
		netValue = self:NetValue(stats.marketValue),
		netProfit = netProfit,
		discountPct = discountPct,
		confidence = stats.confidence,
		days = stats.days,
		scans = stats.scans,
	}
end

function Market:EvaluateFlip(db, itemKey, buyoutUnitPrice, nowTs)
	local okDB = self:EnsureDB(db)
	if not okDB or type(buyoutUnitPrice) ~= "number" or IsSecret(buyoutUnitPrice) or buyoutUnitPrice <= 0 then
		return nil
	end
	local stats = self:GetStats(okDB, itemKey, nowTs)
	if not stats then return nil end
	if not stats.ready then return stats end
	return self:JudgeFlip(okDB, stats, buyoutUnitPrice)
end

-- Days with any price reading in the last MAX_DAYS: the empty Market Flips tab says how far
-- the history is.
function Market:HistoryDays(db, nowTs)
	local okDB = self:EnsureDB(db)
	if not okDB then return 0 end
	local nowDay, n = self:GetDayIndex(nowTs), 0
	for dayIdx in pairs(okDB.marketDays) do
		if type(dayIdx) == "number" and dayIdx > nowDay - Market.MAX_DAYS and dayIdx <= nowDay then n = n + 1 end
	end
	return n
end

-- Once: the daily median prices VendorFloor kept before 1.2 (db.prices, up to 14 days per
-- item) start the history, so flips show without waiting three days. Each day counts as
-- one reading.
function Market:SeedFromPrices(db)
	local okDB = self:EnsureDB(db)
	if not okDB or okDB.marketSeeded then return end
	okDB.marketSeeded = true
	for pk, h in pairs(okDB.prices or {}) do
		if type(h) == "table" and okDB.marketHistory[tostring(pk)] == nil then
			local entry = { days = {}, scans = 0, lastDay = 0 }
			for dayIdx, val in pairs(h) do
				if type(dayIdx) == "number" and type(val) == "number" and val > 0 then
					entry.days[dayIdx] = floor(val + 0.5)
					entry.scans = entry.scans + 1
					if dayIdx > entry.lastDay then entry.lastDay = dayIdx end
					okDB.marketDays[dayIdx] = true
				end
			end
			if entry.scans > 0 then okDB.marketHistory[tostring(pk)] = entry end
		end
	end
end
