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
local min = math.min
local huge = math.huge

local scratchPrices = {}
local scratchDays = {}

local function ClearArray(t)
	for i = #t, 1, -1 do t[i] = nil end
end

local function IsSecret(v)
	return issecretvalue and issecretvalue(v) or false
end

local function IsFiniteNumber(v)
	return type(v) == "number" and not IsSecret(v) and v == v and v ~= huge and v ~= -huge
end

local function IsValidPrice(v)
	return IsFiniteNumber(v) and v >= 0.5
end

local function ClampRetention(v)
	if not IsFiniteNumber(v) then return Market.RETENTION_DAYS end
	return min(max(floor(v), Market.MIN_DAYS), 90)
end

function Market:GetDayIndex(timestamp)
	local ts = (IsFiniteNumber(timestamp) and timestamp > 0) and timestamp or time()
	return floor(ts / 86400)
end

function Market:EnsureDB(db)
	if type(db) ~= "table" then return nil end
	if type(db.marketHistory) ~= "table" then db.marketHistory = {} end
	if type(db.marketDays) ~= "table" then db.marketDays = {} end -- day number -> true: days with any reading (for the empty-tab hint)
	if type(db.marketSettings) ~= "table" then db.marketSettings = {} end
	local cfg = db.marketSettings
	if not IsFiniteNumber(cfg.minDiscountPct) then cfg.minDiscountPct = 30 end
	if not IsFiniteNumber(cfg.minNetProfit) then cfg.minNetProfit = 5000 end -- 50 silver
	cfg.retentionDays = ClampRetention(cfg.retentionDays)
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
	local retention = ClampRetention(okDB.marketSettings.retentionDays)
	okDB.marketSettings.retentionDays = retention
	local cutoffDay = nowDay - retention
	local maxDay = nowDay + 1

	for itemKey, entry in pairs(okDB.marketHistory) do
		if type(entry) ~= "table" or type(entry.days) ~= "table" then
			okDB.marketHistory[itemKey] = nil
		else
			local lastDay = IsFiniteNumber(entry.lastDay) and entry.lastDay or 0
			if lastDay < cutoffDay then
				okDB.marketHistory[itemKey] = nil
			else
				local remaining, newest = 0, 0
				for dayIdx, val in pairs(entry.days) do
					if not IsFiniteNumber(dayIdx) or dayIdx < cutoffDay or dayIdx > maxDay or not IsValidPrice(val) then
						entry.days[dayIdx] = nil
					else
						remaining = remaining + 1
						if dayIdx > newest then newest = dayIdx end
					end
				end
				if remaining == 0 then
					okDB.marketHistory[itemKey] = nil
				else
					entry.lastDay = newest
					if not IsFiniteNumber(entry.scans) or entry.scans < 0 then entry.scans = remaining end
				end
			end
		end
	end
	for dayIdx in pairs(okDB.marketDays) do
		if not IsFiniteNumber(dayIdx) or dayIdx < cutoffDay or dayIdx > maxDay then okDB.marketDays[dayIdx] = nil end
	end
end

-- Record a single price reading (e.g. the median unit price of a listing).
-- Keeps the lowest reading per calendar day.
function Market:RecordObservation(db, itemKey, unitPrice, nowTs)
	local okDB = self:EnsureDB(db)
	if not okDB or not itemKey or IsSecret(itemKey) or type(itemKey) == "table" then return end
	if not IsValidPrice(unitPrice) then return end

	local key = tostring(itemKey)
	local rounded = floor(unitPrice + 0.5)
	if rounded <= 0 then return end

	local dayIdx = self:GetDayIndex(nowTs)
	local entry = okDB.marketHistory[key]
	if type(entry) ~= "table" then
		entry = { days = {}, scans = 0, lastDay = dayIdx }
		okDB.marketHistory[key] = entry
	end

	if type(entry.days) ~= "table" then entry.days = {} end
	entry.scans = (IsFiniteNumber(entry.scans) and entry.scans or 0) + 1
	if not IsFiniteNumber(entry.lastDay) or dayIdx > entry.lastDay then entry.lastDay = dayIdx end

	local prev = entry.days[dayIdx]
	local isNewDay = prev == nil
	if isNewDay or not IsFiniteNumber(prev) or rounded < prev then
		entry.days[dayIdx] = rounded
	end
	okDB.marketDays[dayIdx] = true

	-- at most MAX_DAYS + 7 days per entry until the next Prune (only check when a new day is added)
	if isNewDay then
		ClearArray(scratchDays)
		for d in pairs(entry.days) do
			if IsFiniteNumber(d) then scratchDays[#scratchDays + 1] = d else entry.days[d] = nil end
		end
		local limit = Market.MAX_DAYS + 7
		if #scratchDays > limit then
			table.sort(scratchDays)
			for i = 1, #scratchDays - limit do entry.days[scratchDays[i]] = nil end
		end
	end
end

-- Record from an auction listing: { { unitPrice, quantity, isOwn }, ... }.
-- The median unit price of the other players' auctions resists single outliers.
function Market:RecordListings(db, itemKey, listings, nowTs)
	if type(listings) ~= "table" or #listings == 0 then return end
	ClearArray(scratchPrices)
	for _, row in ipairs(listings) do
		if type(row) == "table" and not row[3] then
			local u = row[1]
			if IsValidPrice(u) then scratchPrices[#scratchPrices + 1] = u end
		end
	end
	local n = #scratchPrices
	if n == 0 then return end
	table.sort(scratchPrices)
	local med = (n % 2 == 1) and scratchPrices[(n + 1) / 2] or ((scratchPrices[n / 2] + scratchPrices[n / 2 + 1]) / 2)
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
	ClearArray(scratchPrices)
	for dayIdx, val in pairs(entry.days) do
		if IsFiniteNumber(dayIdx) and dayIdx > minDay and dayIdx <= nowDay and IsValidPrice(val) then
			scratchPrices[#scratchPrices + 1] = val
		end
	end
	local activeDays = #scratchPrices

	local scans = IsFiniteNumber(entry.scans) and entry.scans or 0
	if activeDays < Market.MIN_DAYS or scans < Market.MIN_SCANS then
		return {
			ready = false,
			days = activeDays,
			scans = scans,
			neededDays = max(0, Market.MIN_DAYS - activeDays),
			neededScans = max(0, Market.MIN_SCANS - scans),
		}
	end

	local marketValue = Median(scratchPrices)
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

-- Zero-allocation flip check against ready stats: returns qualifying, netValue, netProfit, discountPct.
function Market:JudgeFlipFast(db, stats, buyoutUnitPrice)
	if not (stats and stats.ready and IsFiniteNumber(stats.marketValue) and stats.marketValue > 0) then return false end
	if not IsFiniteNumber(buyoutUnitPrice) or buyoutUnitPrice <= 0 then return false end
	local netValue = self:NetValue(stats.marketValue)
	local netProfit = floor(netValue - buyoutUnitPrice)
	local discountPct = (stats.marketValue - buyoutUnitPrice) / stats.marketValue * 100
	local cfg = type(db) == "table" and db.marketSettings
	local minDisc = (cfg and IsFiniteNumber(cfg.minDiscountPct)) and cfg.minDiscountPct or 30
	local minNet = (cfg and IsFiniteNumber(cfg.minNetProfit)) and cfg.minNetProfit or 5000
	local qualifying = discountPct >= minDisc and netProfit >= minNet
	return qualifying, netValue, netProfit, discountPct
end

-- The flip check of a unit price against ready stats (GetStats). Separate from EvaluateFlip so
-- a full scan looks up the stats of an item once and checks each of its auctions with them.
function Market:JudgeFlip(db, stats, buyoutUnitPrice)
	if not (stats and stats.ready and IsFiniteNumber(stats.marketValue) and stats.marketValue > 0) then return nil end
	if not IsFiniteNumber(buyoutUnitPrice) or buyoutUnitPrice <= 0 then return nil end
	local qualifying, netValue, netProfit, discountPct = self:JudgeFlipFast(db, stats, buyoutUnitPrice)
	return {
		ready = true,
		qualifying = qualifying,
		marketValue = stats.marketValue,
		netValue = netValue,
		netProfit = netProfit,
		discountPct = discountPct,
		confidence = stats.confidence,
		days = stats.days,
		scans = stats.scans,
	}
end

function Market:EvaluateFlip(db, itemKey, buyoutUnitPrice, nowTs)
	local okDB = self:EnsureDB(db)
	if not okDB or not IsFiniteNumber(buyoutUnitPrice) or buyoutUnitPrice <= 0 then
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
		if IsFiniteNumber(dayIdx) and dayIdx > nowDay - Market.MAX_DAYS and dayIdx <= nowDay then n = n + 1 end
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
		local key = type(pk) == "string" and not pk:find("^table:") and pk or nil
		if key and type(h) == "table" and okDB.marketHistory[key] == nil then
			local entry = { days = {}, scans = 0, lastDay = 0 }
			for dayIdx, val in pairs(h) do
				if IsFiniteNumber(dayIdx) and IsValidPrice(val) then
					local rounded = floor(val + 0.5)
					if rounded > 0 then
						entry.days[dayIdx] = rounded
						entry.scans = entry.scans + 1
						if dayIdx > entry.lastDay then entry.lastDay = dayIdx end
						okDB.marketDays[dayIdx] = true
					end
				end
			end
			if entry.scans > 0 then okDB.marketHistory[key] = entry end
		end
	end
end
