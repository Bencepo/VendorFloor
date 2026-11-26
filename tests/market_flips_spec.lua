local wow = require("tests.helpers.wow")

local DAY = 86400
local NOW = 20000 * DAY + 3600 -- a fixed day, an hour after midnight UTC

-- Market Flips: price history, market value and the flip check (MarketHistory.lua).
describe("Market Flips history", function()
	local ns, M, db

	before_each(function()
		ns = wow.Load("VendorFloor", { "MarketHistory.lua" })
		M = ns.Market
		db = {}
		M:EnsureDB(db)
	end)

	-- one reading per day, `days` days ending today
	local function record(key, prices)
		for i, p in ipairs(prices) do M:RecordObservation(db, key, p, NOW - (#prices - i) * DAY) end
	end

	it("is not ready with fewer than 3 days", function()
		record("1:0:0:0", { 10000, 10000 })
		local st = M:GetStats(db, "1:0:0:0", NOW)
		assert.is_false(st.ready)
		assert.equal(2, st.days)
		assert.is_true(st.neededDays > 0)
		local r = M:EvaluateFlip(db, "1:0:0:0", 1000, NOW)
		assert.is_false(r.ready)
		assert.is_nil(r.qualifying)
	end)

	it("needs 3 readings too, not just 3 days", function()
		db.marketHistory.x = { days = { [20000] = 100, [19999] = 100, [19998] = 100 }, scans = 2, lastDay = 20000 }
		local st = M:GetStats(db, "x", NOW)
		assert.is_false(st.ready)
		assert.equal(1, st.neededScans)
	end)

	it("knows nothing of an unknown item", function()
		local st = M:GetStats(db, "nothing", NOW)
		assert.is_false(st.ready)
		assert.equal(3, st.neededDays)
	end)

	it("with 3 days is ready, with market value and net profit after the 5% cut", function()
		record("1:0:0:0", { 10000, 12000, 11000 })
		local st = M:GetStats(db, "1:0:0:0", NOW)
		assert.is_true(st.ready)
		assert.equal(11000, st.marketValue)
		assert.equal("Low", st.confidence)
		local r = M:EvaluateFlip(db, "1:0:0:0", 4000, NOW)
		assert.is_true(r.ready)
		assert.equal(6450, r.netProfit)
		assert.equal(10450, r.netValue)
		assert.is_true(r.qualifying) -- 63.6% below, 64s 50c net
	end)

	it("applies minimum discount and minimum net profit", function()
		record("1:0:0:0", { 10000, 10000, 10000 })
		-- 20% below: under the default 30%
		assert.is_false(M:EvaluateFlip(db, "1:0:0:0", 8000, NOW).qualifying)
		db.marketSettings.minDiscountPct, db.marketSettings.minNetProfit = 15, 1000
		assert.is_true(M:EvaluateFlip(db, "1:0:0:0", 8000, NOW).qualifying) -- 15s net
		db.marketSettings.minNetProfit = 2000
		assert.is_false(M:EvaluateFlip(db, "1:0:0:0", 8000, NOW).qualifying) -- 15s < 20s
	end)

	it("keeps the lowest reading of a day and counts every reading", function()
		M:RecordObservation(db, "k", 500, NOW)
		M:RecordObservation(db, "k", 300, NOW + 60)
		M:RecordObservation(db, "k", 900, NOW + 120)
		local e = db.marketHistory.k
		assert.equal(300, e.days[20000])
		assert.equal(3, e.scans)
	end)

	it("outlier prices do not corrupt the median market value", function()
		record("1:0:0:0", { 10000, 10200, 9900, 9800, 10100, 999999999, 1 })
		local st = M:GetStats(db, "1:0:0:0", NOW)
		assert.is_true(st.ready)
		assert.equal(10000, st.marketValue)
		-- and within a listing, a single absurd auction does not move the day's value
		M:RecordListings(db, "2:0:0:0", { { 100, 5 }, { 110, 1 }, { 120, 1 }, { 5000000, 1 } }, NOW)
		assert.equal(115, db.marketHistory["2:0:0:0"].days[20000])
	end)

	it("leaves own auctions out of a listing", function()
		M:RecordListings(db, "3:0:0:0", { { 50, 1, true }, { 200, 1 }, { 220, 1 }, { 240, 1 } }, NOW)
		assert.equal(220, db.marketHistory["3:0:0:0"].days[20000])
		M:RecordListings(db, "4:0:0:0", { { 50, 1, true } }, NOW)
		assert.is_nil(db.marketHistory["4:0:0:0"])
	end)

	it("uses only the last 14 days for the market value", function()
		local prices = {}
		for i = 1, 20 do prices[i] = i <= 6 and 99999 or 1000 end -- the old days were expensive
		record("1:0:0:0", prices)
		assert.equal(1000, M:GetStats(db, "1:0:0:0", NOW).marketValue)
	end)

	it("Prune removes entries and days older than the retention", function()
		record("old", { 100, 100, 100 })
		M:RecordObservation(db, "mixed", 100, NOW - 30 * DAY)
		M:RecordObservation(db, "mixed", 200, NOW)
		db.marketHistory.old.lastDay = 20000 - 22
		db.marketHistory.junk = "not a table"
		M:Prune(db, NOW)
		assert.is_nil(db.marketHistory.old)
		assert.is_nil(db.marketHistory.junk)
		assert.is_nil(db.marketHistory.mixed.days[20000 - 30])
		assert.equal(200, db.marketHistory.mixed.days[20000])
		assert.is_nil(db.marketDays[20000 - 30])
		assert.is_true(db.marketDays[20000])
	end)

	it("Prune keeps entries within a shorter retention, never below 3 days", function()
		db.marketSettings.retentionDays = 1
		record("k", { 100, 100, 100 })
		M:Prune(db, NOW)
		assert.is_not_nil(db.marketHistory.k.days[20000 - 2])
	end)

	it("ignores secret and invalid values", function()
		ns = wow.Load("VendorFloor", { "MarketHistory.lua" }, function(e)
			e.issecretvalue = function(v) return v == "secret" or v == 777 end
		end)
		M = ns.Market
		M:RecordObservation(db, "secret", 100, NOW)
		M:RecordObservation(db, "k", 777, NOW)
		M:RecordObservation(db, "k", -5, NOW)
		M:RecordObservation(db, "k", "100", NOW)
		M:RecordObservation(db, nil, 100, NOW)
		assert.is_nil(next(db.marketHistory))
		assert.is_nil(M:EvaluateFlip(db, "k", 777, NOW))
	end)

	it("counts the days of history for the empty tab", function()
		assert.equal(0, M:HistoryDays(db, NOW))
		record("a", { 1, 1 })
		M:RecordObservation(db, "b", 1, NOW)
		assert.equal(2, M:HistoryDays(db, NOW))
	end)

	it("Reset clears the history", function()
		record("a", { 1, 1, 1 })
		M:Reset(db)
		assert.is_nil(next(db.marketHistory))
		assert.equal(0, M:HistoryDays(db, NOW))
	end)

	it("starts once from the daily prices kept before 1.2", function()
		db.prices = { ["9:0:0:0"] = { [19998] = 100, [19999] = 120, [20000] = 110 } }
		M:SeedFromPrices(db)
		local st = M:GetStats(db, "9:0:0:0", NOW)
		assert.is_true(st.ready)
		assert.equal(110, st.marketValue)
		db.prices["9:0:0:0"][20000] = 1
		db.marketHistory = {}
		M:SeedFromPrices(db) -- only once
		assert.is_nil(next(db.marketHistory))
	end)

	it("repairs broken settings", function()
		local d = { marketSettings = { minDiscountPct = "x", showTooltip = false } }
		M:EnsureDB(d)
		assert.equal(30, d.marketSettings.minDiscountPct)
		assert.equal(5000, d.marketSettings.minNetProfit)
		assert.equal(21, d.marketSettings.retentionDays)
		assert.is_false(d.marketSettings.showTooltip)
		assert.is_nil(M:EnsureDB(nil))
	end)
end)

describe("Market Flips in VendorFloor", function()
	local ns, env, T, db

	before_each(function()
		ns, env = wow.Load("VendorFloor", { "Locales.lua", "MarketHistory.lua", "VendorFloor.lua", "Trade.lua" }, function(e)
			e.VendorFloorDB = {}
			e.time = function() return NOW end
			e.Enum = e.Enum or {}
			rawset(e.Enum, "BagIndex", { ReagentBag = 5 })
		end)
		T = ns.test
		T.Init()
		db = ns.db
		env.items[7000] = { name = "Silk Cloth", quality = 1, ilvl = 30, minLevel = 0, classID = 7, sell = 150, stack = 20 }
	end)

	it("sets up the history on load", function()
		assert.is_table(db.marketHistory)
		assert.equal(30, db.marketSettings.minDiscountPct)
	end)

	it("keeps the Market Flips tab after a reload", function()
		db.tab = "flips"
		T.Init()
		assert.equal("flips", db.tab)
		db.tab = "nonsense"
		T.Init()
		assert.equal("vendor", db.tab)
	end)

	it("a check adds a reading to the history", function()
		ns.RecordListing(7000, { { 1000, 20 }, { 1100, 5 } })
		local pk = ns.PlainKey(7000)
		assert.equal(1050, db.marketHistory[pk].days[20000])
	end)

	it("a full scan lists auctions far below the market value as flips", function()
		local pk = ns.PlainKey(7000)
		db.marketHistory[pk] = { days = { [19997] = 10000, [19998] = 10000, [19999] = 10000 }, scans = 3, lastDay = 19999 }
		local full = T.Full()
		full.items = { [pk] = { key = { itemID = 7000, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 },
			plainKey = pk, id = 7000, vendor = 150, name = "Silk Cloth",
			a = { { 3000, 2 }, { 3500, 1 }, { 9000, 4 }, { 10000, 10 }, { 2000, 5, true } } } }
		T.FinishFull(false)
		local flip
		for _, d in ipairs(T.Deals()) do if d.mode == "flips" then flip = d end end
		assert.is_not_nil(flip)
		assert.equal(3, flip.count) -- 3000 ×2 and 3500 ×1; 9000 is only 10% below, the own auction is left out
		assert.equal(3000, flip.price)
		assert.equal(9500, flip.vendor) -- market value 10000 after the 5% cut
		assert.equal((9500 - 3000) * 2 + (9500 - 3500), flip.profit)
		assert.is_true(T.Shown(flip))
		-- the full scan's listing became today's reading
		assert.is_not_nil(db.marketHistory[pk].days[20000])
		-- a stricter setting hides it at once
		db.marketSettings.minDiscountPct = 80
		assert.is_false(T.Shown(flip))
	end)

	it("checks flip auctions against the market value, not the vendor price", function()
		local pk = ns.PlainKey(7000)
		db.marketHistory[pk] = { days = { [19997] = 10000, [19998] = 10000, [19999] = 10000 }, scans = 3, lastDay = 19999 }
		local d = { mode = "flips", key = { itemID = 7000, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }, vendor = 9500 }
		assert.is_true(T.Fits(d, d.vendor, 4000))
		assert.is_false(T.Fits(d, d.vendor, 9000))
	end)

	it("says how many days of history are missing on the empty tab", function()
		db.tab = "flips"
		local hint = ns.FlipHint()
		assert.truthy(hint:find("at least 3 days", 1, true))
		assert.truthy(hint:find("has 0 so far", 1, true))
		for i = 0, 2 do ns.Market:RecordObservation(db, "x", 100, NOW - i * DAY) end
		assert.is_nil(ns.FlipHint())
		db.tab = "vendor"
		assert.is_nil(ns.FlipHint())
	end)

	it("flip purchases are collected from the mail but never sold to a merchant", function()
		ns.RecordBuy(7000, 3, 9000, 28500, "flips")
		assert.is_nil(db.bought[7000])
		assert.equal(3, db.debought[7000])
		assert.equal(9000, db.fliptotal.spent)
		assert.is_nil(db.deBasket[7000])
	end)
end)
