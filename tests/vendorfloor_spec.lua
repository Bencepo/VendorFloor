local wow = require("tests.helpers.wow")

local DUST, GMAGIC, SGLIM = 10940, 10939, 10978

describe("VendorFloor", function()
	local ns, env, T, db

	before_each(function()
		ns, env = wow.Load("VendorFloor", { "Locales.lua", "VendorFloor.lua", "Sales.lua" }, function(e)
			e.VendorFloorDB = {}
		end)
		T = ns.test
		T.Init()
		db = ns.db
		env.items[5000] = { name = "Test Bracers", quality = 2, ilvl = 18, minLevel = 13, classID = 4 }
		env.items[5001] = { name = "Test Blade", quality = 3, ilvl = 30, minLevel = 25, classID = 2 }
		env.items[5002] = { name = "Gray Gloves", quality = 0, ilvl = 18, minLevel = 13, classID = 4 }
		env.items[11288] = { name = "Greater Magic Wand", quality = 2, ilvl = 23, minLevel = 18, classID = 2 }
	end)

	describe("ParseMoney", function()
		it("reads gold, silver and copper", function()
			assert.equal(12000, T.ParseMoney("1g 20s"))
			assert.equal(500, T.ParseMoney("5s"))
			assert.equal(50, T.ParseMoney("50c"))
			assert.equal(123, T.ParseMoney("123"))
		end)
		it("rejects text without an amount", function()
			assert.is_nil(T.ParseMoney("abc"))
			assert.is_nil(T.ParseMoney(""))
		end)
	end)

	describe("prices of a listing", function()
		it("median is weighted by count", function()
			assert.equal(200, (T.ListingMedian({ { 100, 1 }, { 200, 1 }, { 300, 1 } })))
			assert.equal(100, (T.ListingMedian({ { 100, 9 }, { 900, 1 } })))
		end)
		it("leaves own auctions out", function()
			assert.equal(300, (T.ListingMedian({ { 100, 5, true }, { 300, 1 } })))
			assert.is_nil((T.ListingMedian({ { 100, 5, true } })))
		end)
		it("low price is the cheapest tenth of the units", function()
			assert.equal(100, T.ListingLow({ { 200, 9 }, { 100, 1 } }))
			assert.equal(200, T.ListingLow({ { 100, 1, true }, { 200, 9 } }))
		end)
		it("a checked listing updates the stored prices", function()
			ns.RecordListing(DUST, { { 80, 10 }, { 90, 10 }, { 300, 1 } })
			local pk = ns.PlainKey(DUST)
			assert.equal(80, ns.LowValue(pk))
			assert.equal(80, (ns.MarketValue(pk)))
		end)
	end)

	describe("minimum profit", function()
		it("needs the minimum profit per unit", function()
			db.minProfit, db.minPercent = 5, 0
			assert.is_true(T.Worth(300, 250))
			assert.is_false(T.Worth(300, 296))
		end)
		it("needs the minimum percent", function()
			db.minProfit, db.minPercent = 1, 15
			assert.is_false(T.Worth(253, 250))
			assert.is_true(T.Worth(300, 250))
		end)
		it("hides listed finds below the percent", function()
			local find = { price = 250, vendor = 280, mode = "vendor" }
			db.minPercent = 15
			assert.is_false(T.Shown(find))
			db.minPercent = 10
			assert.is_true(T.Shown(find))
			db.minPercent = 0
			assert.is_true(T.Shown(find))
		end)
	end)

	describe("disenchanting", function()
		before_each(function()
			ns.RecordListing(DUST, { { 100, 10 } })
			ns.RecordListing(GMAGIC, { { 300, 10 } })
			ns.RecordListing(SGLIM, { { 600, 10 } })
			T.ClearCache()
		end)

		it("values green armor by the table row of its required level", function()
			-- row up to level 15: 75% x 2.5 dust, 20% x 1.5 essence, 4% shard, after the 5% cut
			local expected = (0.75 * 2.5 * 100 + 0.20 * 1.5 * 300 + 0.04 * 600) * 0.95
			assert.near(expected, ns.DisenchantValue(5000), 0.01)
		end)

		it("does not value items that cannot be disenchanted", function()
			assert.is_nil(ns.DisenchantValue(11288)) -- enchanter's wand
			assert.is_nil(ns.DisenchantValue(5002))  -- gray
			assert.is_false(ns.CanDisenchant(11288))
			assert.is_false(T.Shown({ id = 11288, mode = "de", price = 1, vendor = 100 }))
		end)

		it("uses your own results after 3 disenchants", function()
			for _ = 1, 2 do T.AddLearned("i5000", { [DUST] = 2 }) end
			assert.is_nil(ns.DeLearnedCount(5000))
			T.AddLearned("i5000", { [DUST] = 2 })
			assert.equal(3, ns.DeLearnedCount(5000))
			assert.near(2 * 100 * 0.95, ns.DisenchantValue(5000), 0.01)
		end)

		it("reads the item ID from links", function()
			assert.equal(5000, T.ItemID("|cff1eff00|Hitem:5000::::::::|h[Test Bracers]|h|r"))
			assert.equal(42, T.ItemID(42))
			assert.is_nil(T.ItemID(nil))
		end)
	end)

	describe("own auctions", function()
		local S
		before_each(function()
			S = ns.salesTest
			env.items[2589] = { name = "Linen Cloth" }
		end)

		it("recognises the sold and expired chat lines", function()
			local sold = "A buyer has been found for your auction of Linen Cloth."
			assert.equal("Linen Cloth", sold:match(S.Pattern(env.ERR_AUCTION_SOLD_S)))
			assert.is_nil(("Something else"):match(S.Pattern(env.ERR_AUCTION_SOLD_S)))
		end)

		it("learns the sold price and the share that sells", function()
			S.OnPost({ id = 2589 }, 20, 100)
			S.OnPost({ id = 2589 }, 20, 110)
			S.OnPost({ id = 2589 }, 20, 120)
			S.OnSystem("A buyer has been found for your auction of Linen Cloth.")
			assert.equal(100, ns.SoldPrice(2589))
			assert.is_nil(ns.SellRate(2589)) -- only one ended so far
			S.OnSystem("Your auction of Linen Cloth has expired.")
			S.OnSystem("Your auction of Linen Cloth has expired.")
			assert.near(1 / 3, ns.SellRate(2589), 0.001)
		end)
	end)
end)
