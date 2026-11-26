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

	describe("share text", function()
		before_each(function()
			ns, env = wow.Load("VendorFloor", { "Locales.lua", "VendorFloor.lua", "Trade.lua", "Sales.lua" }, function(e)
				e.VendorFloorDB = {}
				e.Enum = e.Enum or {}
				rawset(e.Enum, "BagIndex", { ReagentBag = 5 })
			end)
			ns.test.Init()
			db = ns.db
		end)
		it("shows today's and all-time profit without colour codes, with the addon link", function()
			ns.Unsold = function() return 0, 152500 end
			db.days = { [os.date("%Y-%m-%d")] = { buys = 12, spent = 50000, sold = 4123456, soldCost = 1000000 } }
			db.total = { buys = 345, sold = 98765432, soldCost = 12345678 }
			local text = ns.ShareText()
			assert.truthy(text:find("12 buys, profit 312g from sales, 15g 25s still to sell", 1, true))
			assert.truthy(text:find("345 buys, profit 8641g", 1, true))
			assert.truthy(text:find("curseforge.com/wow/addons/vendorfloor", 1, true))
			assert.falsy(text:find("|c", 1, true))
		end)
		it("says so when nothing was bought today", function()
			db.days, db.total = {}, nil
			ns.Unsold = function() return 0, 0 end
			assert.truthy(ns.ShareText():find("no purchases today", 1, true))
		end)
	end)

	describe("ready sound", function()
		it("plays when the action button becomes clickable, not right after a click", function()
			local played = 0
			env.PlaySound = function() played = played + 1 end
			local shown = true
			T.SetUI({ IsVisible = function() return shown end })
			env.now = 100
			ns.ReadyCue(false)
			ns.ReadyCue(true)
			assert.equal(1, played)
			ns.ReadyCue(true) -- still clickable: no repeat
			assert.equal(1, played)
			ns.ReadyCue(false)
			ns.cueClick = env.now -- the player just clicked
			env.now = env.now + 1
			ns.ReadyCue(true)
			assert.equal(1, played)
			ns.ReadyCue(false)
			env.now = env.now + 5
			db.readySound = false
			ns.ReadyCue(true)
			assert.equal(1, played)
			db.readySound = true
			ns.ReadyCue(false)
			shown = false
			ns.ReadyCue(false)
			shown = true -- window just opened: quiet
			ns.ReadyCue(true)
			assert.equal(1, played)
		end)
	end)

	describe("watchlist and limits", function()
		it("a watchlist find only needs to stay within the limit", function()
			db.minProfit, db.minPercent = 100, 50
			assert.is_true(ns.Fits({ mode = "wish" }, 1000, 1000))
			assert.is_false(ns.Fits({ mode = "wish" }, 1000, 1001))
			assert.is_false(ns.Fits({ mode = "vendor" }, 1000, 1000))
		end)
		it("the spending limit caps what may be spent", function()
			ns.session = { allSpent = 15000 }
			db.spendLimit = 2
			assert.equal(5000, ns.Budget(100000))
			assert.is_not_nil(ns.Guard(6000, 1))
			assert.is_nil(ns.Guard(4000, 1))
			db.spendLimit = 0
			assert.equal(100000, ns.Budget(100000))
		end)
	end)

	describe("buying without enough gold", function()
		it("frees the purchase so scanning goes on, and keeps the find", function()
			env.items[6000] = { name = "Cheap Ore", quality = 1, ilvl = 10, minLevel = 0, classID = 7, sell = 500 }
			local key = { itemID = 6000, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
			db.lastFinds = { at = os.time(), list = { { k = "6000:0:0:0", key = key, id = 6000, vendor = 500, price = 100,
				count = 1, profit = 400, name = "Cheap Ore", mode = "vendor" } } }
			db.minProfit, db.minPercent = 1, 0
			local AH = env.C_AuctionHouse
			AH.GetNumItemSearchResults = function() return 1 end
			AH.GetItemSearchResultInfo = function()
				return { auctionID = 77, buyoutAmount = 100, quantity = 1 }
			end
			env.GetMoney = function() return 50 end -- less than the 100 copper buyout
			T.handlers.AUCTION_HOUSE_SHOW()
			env.VendorFloor_BuyNext()                 -- click: the find is searched
			assert.matches("state=verifying", ns.Diagnose())
			T.handlers.ITEM_SEARCH_RESULTS_UPDATED(key) -- the auction arrives: too expensive for the bags of gold
			assert.matches("state=nil", ns.Diagnose())
			assert.is_true(T.Shown({ price = 100, vendor = 500, mode = "vendor" }))
			assert.matches("Cheap Ore", ns.Diagnose(db.lastFinds.list[1]))
		end)
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
			assert.equal(90, (ns.MarketValue(pk))) -- 21 units: the 11th is at 90
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
			db.minProfit, db.minPercent = 1, 15
			assert.is_false(T.Shown(find))
			db.minPercent = 10
			assert.is_true(T.Shown(find))
			db.minPercent = 0
			assert.is_true(T.Shown(find))
		end)
		it("the minimum per unit filters listed finds both ways", function()
			local find = { price = 250, vendor = 300, mode = "vendor" }
			db.minProfit, db.minPercent = 100, 0
			assert.is_false(T.Shown(find)) -- 50 below the minimum: hidden
			db.minProfit = 50
			assert.is_true(T.Shown(find))  -- lowered: back in the list
			assert.is_true(T.Shown({ price = 900, vendor = 300, mode = "wish" })) -- watchlist: own limit only
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

		it("values green weapons and blue gear too", function()
			env.items[5003] = { name = "Test Sword", quality = 2, ilvl = 18, minLevel = 13, classID = 2 }
			env.items[5004] = { name = "Test Cloak", quality = 3, ilvl = 18, minLevel = 13, classID = 4 }
			local weapon, blue = ns.DisenchantValue(5003), ns.DisenchantValue(5004)
			assert.is_true(type(weapon) == "number" and weapon > 0)
			assert.is_true(type(blue) == "number" and blue > 0)
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

		it("follows new material prices without a full scan", function()
			local before = ns.DisenchantValue(5000)
			ns.RecordListing(DUST, { { 200, 10 } }) -- a check finds dust at twice the price
			local after = ns.DisenchantValue(5000)
			assert.near(before + 0.75 * 2.5 * 100 * 0.95, after, 0.01)
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

		it("counts sales and expiries from the mailbox once", function()
			S.OnPost({ id = 2589 }, 20, 100)
			S.OnPost({ id = 2589 }, 20, 110)
			S.OnPost({ id = 2589 }, 20, 120)
			env.mails = {
				{ subject = "Auction successful: Linen Cloth", money = 1900, days = 29.9, invoice = { "seller", "Linen Cloth", "Buyer", 2000, 0, 0, 0, 0, 0, 0, 20 } },
			}
			S.ScanMail()
			S.ScanMail() -- the same mail again: not counted twice
			assert.equal(100, ns.SoldPrice(2589))
			assert.is_nil(ns.SellRate(2589)) -- only one ended so far
			env.mails[2] = { subject = "Auction expired: Linen Cloth", money = 0, days = 29.5 }
			env.mails[3] = { subject = "Auction expired: Linen Cloth", money = 0, days = 29.4 }
			S.ScanMail()
			assert.near(1 / 3, ns.SellRate(2589), 0.001)
		end)
		it("counts multiple identical sales/expiries within 600s and handles buyout fallback and older mails", function()
			S.OnPost({ id = 2589 }, 10, 0) -- unit <= 0 rejected as nil
			assert.is_nil(db.open[#db.open].unit)
			S.OnPost({ id = 2589 }, 10, 100)
			S.OnPost({ id = 2589 }, 10, 100)
			env.mails = {
				{ subject = "Auction successful: Linen Cloth", money = 1900, days = 29.9,
					invoice = { "seller", "Linen Cloth", "Buyer1", 0, 2000, 0, 0, 0, 0, 0, 10 } },
				{ subject = "Auction successful: Linen Cloth", money = 1900, days = 29.9,
					invoice = { "seller", "Linen Cloth", "Buyer2", 0, 2000, 0, 0, 0, 0, 0, 10 } },
				{ subject = "Auction successful: Linen Cloth", money = 950, days = 29.0,
					invoice = { "seller", "Linen Cloth", "OlderBuyer", 1000, 0, 0, 0, 0, 0, 0, 10 } },
			}
			S.ScanMail()
			S.ScanMail() -- rescan must not double-count
			assert.equal(3, db.sales[2589].sold)
			-- newer sale (200c/unit at days=29.9) must not be overwritten by older mail (100c/unit at days=29.0)
			assert.equal(200, ns.SoldPrice(2589))
		end)
	end)

	describe("RecordListing and DB scrubbing", function()
		it("coerces ItemKey tables to string keys and scrubs corrupted/stale entries on load", function()
			local key = { itemID = 5000, itemLevel = 18, itemSuffix = 0, battlePetSpeciesID = 0 }
			ns.RecordListing(key, { { 250, 5 } })
			assert.equal(250, ns.LowValue("5000:18:0:0"))
			assert.is_nil(db.lows[key])

			local now = os.time()
			local oldDay = math.floor(now / 86400) - 20
			db.prices[key] = { [oldDay] = 100 }
			db.prices["table: 0xdeadbeef"] = { [math.floor(now / 86400)] = 100 }
			db.prices["stale:0:0:0"] = { [oldDay] = 100 }
			db.lows[key] = { 100, now }
			db.lows["old:0:0:0"] = { 100, now - 4 * 86400 }
			db.hot = { [1] = { last = now - 31 * 86400, profit = 100 }, [2] = { last = now - 5 * 86400, profit = 100 } }
			db.marketHistory = { ["table: 0x1234"] = { days = {}, scans = 1, lastDay = 20000 } }
			T.Init()
			assert.is_nil(db.prices[key])
			assert.is_nil(db.prices["table: 0xdeadbeef"])
			assert.is_nil(db.prices["stale:0:0:0"])
			assert.is_nil(db.lows[key])
			assert.is_nil(db.lows["old:0:0:0"])
			assert.is_nil(db.hot[1])
			assert.is_not_nil(db.hot[2])
			assert.is_nil(db.marketHistory["table: 0x1234"])
		end)
	end)

	describe("commodity quote validation and scan scoping", function()
		it("enforces minPercent and minSlot in COMMODITY_PRICE_UPDATED and guards nil deal", function()
			local buy = T.Buy()
			buy.state, buy.deal, buy.qty = "quoting", nil, 1
			T.handlers.COMMODITY_PRICE_UPDATED(0, 100)
			assert.is_nil(buy.state)

			db.minProfit, db.minPercent, db.minSlot = 10, 50, 0
			local deal = { k = "5000:0:0:0", id = 5000, vendor = 100, mode = "vendor", name = "Test" }
			buy.state, buy.deal, buy.qty = "quoting", deal, 2
			-- unit = 80, gain = 20 (25% < 50% minPercent): rejected
			T.handlers.COMMODITY_PRICE_UPDATED(0, 160)
			assert.is_nil(buy.state)

			db.minPercent, db.minSlot = 0, 500
			buy.state, buy.deal, buy.qty = "quoting", deal, 2
			-- total gain = 2 * 100 - 100 = 100 < 500 minSlot: rejected
			T.handlers.COMMODITY_PRICE_UPDATED(0, 100)
			assert.is_nil(buy.state)
		end)

		it("StartScan/FinishScan only clears stale deals of the scanned tab family", function()
			T.handlers.AUCTION_HOUSE_SHOW()
			T.AddDeal({ k = "vendor1", id = 5000, mode = "vendor", price = 10, vendor = 100, profit = 90 })
			T.AddDeal({ k = "de1", id = 5001, mode = "de", price = 10, vendor = 100, profit = 90 })
			db.tab = "de"
			T.StartScan()
			T.FinishScan()
			local foundVendor, foundDe = false, false
			for _, d in ipairs(T.Deals()) do
				if d.k == "vendor1" then foundVendor = true end
				if d.k == "de1" then foundDe = true end
			end
			assert.is_true(foundVendor)
			assert.is_false(foundDe)
		end)
	end)

	describe("Export JSON and Trade mail safety", function()
		it("formats integers above 2^31 without overflow", function()
			local ens = wow.Load("VendorFloor", { "Locales.lua", "Export.lua" })
			assert.equal("3000000000", ens.JsonEncode(3000000000))
			assert.equal("1234567890123", ens.JsonEncode(1234567890123))
		end)

		it("rejects C.O.D., empty, and non-buyer mails and counts only general bag slots", function()
			local tns, tenv = wow.Load("VendorFloor", { "Locales.lua", "VendorFloor.lua", "Trade.lua" }, function(e)
				e.VendorFloorDB = {}
				e.Enum = e.Enum or {}
				rawset(e.Enum, "BagIndex", { ReagentBag = 5 })
				e.C_Container = {
					GetContainerNumFreeSlots = function(bag)
						if bag == 5 then return 20, 2048 end -- reagent bag: non-zero family
						return bag == 0 and 3 or 0, 0
					end,
				}
				e.GetInboxHeaderInfo = function(i)
					local m = e.mails[i]
					return nil, nil, "Sender", m.subject, m.money or 0, m.cod or 0, 29, m.hasItem
				end
			end)
			tns.test.Init()
			tenv.mails = {
				{ subject = "Buyer", cod = 0, hasItem = 1, invoice = { "buyer" } },
				{ subject = "COD", cod = 500, hasItem = 1, invoice = { "buyer" } },
				{ subject = "Expired", cod = 0, hasItem = 1, invoice = nil },
				{ subject = "Empty", cod = 0, hasItem = 0, invoice = { "buyer" } },
				{ subject = "Seller", cod = 0, hasItem = 1, invoice = { "seller" } },
			}
			assert.is_true(tns.tradeTest.IsPurchase(1))
			assert.is_false(tns.tradeTest.IsPurchase(2))
			assert.is_false(tns.tradeTest.IsPurchase(3))
			assert.is_false(tns.tradeTest.IsPurchase(4))
			assert.is_false(tns.tradeTest.IsPurchase(5))
			assert.equal(3, tns.tradeTest.FreeSlots())
			-- ForgetPurchases nil guard
			tns.db = nil
			assert.has_no.errors(function() tns.ForgetPurchases() end)
		end)

		it("collects confirmed mails at 0.05s event-driven pace instead of waiting 0.4s", function()
			local inbox = {
				{ cod = 0, hasItem = 1, invoice = "buyer", items = { [1] = { id = 5000, count = 2 } } },
				{ cod = 0, hasItem = 1, invoice = "buyer", items = { [1] = { id = 5001, count = 3 } } },
				{ cod = 0, hasItem = nil, invoice = "seller", items = {} },
			}
			local takenCalls = {}
			local tns, tenv = wow.Load("VendorFloor", { "Locales.lua", "VendorFloor.lua", "Trade.lua" }, function(e)
				e.VendorFloorDB = {}
				e.Enum = e.Enum or {}
				rawset(e.Enum, "BagIndex", { ReagentBag = 5 })
				e.C_Container = {
					GetContainerNumFreeSlots = function(bag) return bag == 0 and 10 or 0, 0 end,
				}
				e.GetInboxNumItems = function() return #inbox end
				e.GetInboxHeaderInfo = function(i)
					local m = inbox[i]
					return nil, nil, "AH", "Won", 0, m.cod, 29, m.hasItem
				end
				e.GetInboxInvoiceInfo = function(i) return inbox[i].invoice end
				e.GetInboxItem = function(i, a)
					local it = inbox[i] and inbox[i].items[a]
					if it then return "Item", it.id, nil, it.count end
				end
				e.TakeInboxItem = function(i, a)
					takenCalls[#takenCalls + 1] = { i = i, a = a, t = e.now }
					table.remove(inbox, i)
				end
			end)
			tns.test.Init()
			tns.db.bought[5000] = { units = 2, cost = 100 }
			tns.db.debought = { [5001] = 3 }
			tenv.now = 10

			-- First take fires immediately on click
			tns.tradeTest.StartCollecting()
			assert.equal(1, #takenCalls)
			assert.equal(2, takenCalls[1].i)

			-- Confirmation shortens wait to 0.05s from sentAt (well below old 0.4s interval)
			assert.is_true(tns.tradeTest.ConfirmPendingTake())
			assert.is_nil(tns.db.debought[5001])
			tenv.now = 10.06
			tns.tradeTest.StepCollect()
			assert.equal(2, #takenCalls)
			assert.equal(1, takenCalls[2].i)

			assert.is_true(tns.tradeTest.ConfirmPendingTake())
			tenv.now = 10.12
			tns.tradeTest.StepCollect()
			assert.is_false(tns.tradeTest.IsCollecting())
			assert.equal(5, tns.tradeTest.Taken())
		end)
	end)

	describe("event-driven scan, check, and craft query pacing", function()
		it("flushes browse and check queries immediately when ready and on THROTTLED_MESSAGE_SYSTEM_READY", function()
			local AH = env.C_AuctionHouse
			local ready = false
			local sentBrowse, sentMore, sentSearch = 0, 0, {}
			AH.IsThrottledMessageSystemReady = function() return ready end
			AH.SendBrowseQuery = function() sentBrowse = sentBrowse + 1 end
			AH.RequestMoreBrowseResults = function() sentMore = sentMore + 1 end
			AH.HasFullBrowseResults = function() return false end
			AH.GetBrowseResults = function() return {} end
			AH.SendSearchQuery = function(key) sentSearch[#sentSearch + 1] = key.itemID end
			AH.GetNumItemSearchResults = function() return 0 end

			T.handlers.AUCTION_HOUSE_SHOW()
			-- Browse query defers while throttle is busy, then fires immediately when system becomes ready
			T.StartScan()
			assert.equal(0, sentBrowse)
			ready = true
			T.handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_SYSTEM_READY()
			assert.equal(1, sentBrowse)

			-- Browse page requests next page immediately without waiting for Tick()
			T.handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
			assert.equal(1, sentMore)

			-- Dropped message defers retry rather than synchronously looping
			T.handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()
			assert.equal(1, sentMore)
			T.handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_SYSTEM_READY()
			assert.equal(2, sentMore)

			-- Watchlist checks pipeline directly from FinishCheck -> PumpCheck without Tick()
			T.FinishScan()
			db.wishlist = { [5000] = { max = 500 }, [5001] = { max = 500 } }
			assert.is_true(ns.StartWish())
			assert.equal(1, #sentSearch)
			local firstID = sentSearch[1]
			T.handlers.ITEM_SEARCH_RESULTS_UPDATED({ itemID = firstID })
			assert.equal(2, #sentSearch)
			assert.not_equal(firstID, sentSearch[2])
		end)

		it("advances craft price checks immediately on search result events", function()
			local AH = env.C_AuctionHouse
			local sent = {}
			AH.IsThrottledMessageSystemReady = function() return true end
			AH.SendSearchQuery = function(key) sent[#sent + 1] = key.itemID end
			AH.GetNumCommoditySearchResults = function(id) return id == DUST and 1 or 0 end
			AH.GetCommoditySearchResultInfo = function() return { unitPrice = 120, quantity = 5, numOwnerItems = 0 } end
			AH.GetNumItemSearchResults = function() return 0 end

			env.UnitName = function() return "Tester" end
			env.GetRealmName = function() return "Forever" end
			db.recipes = { ["Tester-Forever"] = { Enchanting = { list = { { out = GMAGIC, r = { { DUST, 2 } } } } } } }

			T.handlers.AUCTION_HOUSE_SHOW()
			assert.is_true(T.StartCraftScan())
			assert.equal(1, #sent)
			local firstID = sent[1]
			T.handlers.COMMODITY_SEARCH_RESULTS_UPDATED(firstID)
			assert.equal(2, #sent)
			T.handlers.COMMODITY_SEARCH_RESULTS_UPDATED(sent[2])
			assert.falsy(T.Craft().active)
			assert.equal(120, ns.LowValue(ns.PlainKey(DUST)))
		end)

		it("only triggers Alert sound/flash for vendor and disenchant finds, not flips or watchlist", function()
			local alerts = 0
			env.PlaySound = function() alerts = alerts + 1 end
			env.FlashClientIcon = function() alerts = alerts + 1 end
			env.now = 100
			db.sound, db.flash = true, true
			env.items[6100] = { name = "Watched Gem", quality = 2, ilvl = 20, minLevel = 1, classID = 7, sell = 10 }
			local AH = env.C_AuctionHouse
			AH.IsThrottledMessageSystemReady = function() return true end
			AH.GetNumItemSearchResults = function() return 1 end
			AH.GetItemSearchResultInfo = function() return { auctionID = 1, buyoutAmount = 50, quantity = 1 } end

			-- Watchlist-only find should NOT trigger Alert
			T.handlers.AUCTION_HOUSE_SHOW()
			db.wishlist = { [6100] = { max = 100 } }
			assert.is_true(ns.StartWish())
			T.handlers.ITEM_SEARCH_RESULTS_UPDATED({ itemID = 6100 })
			assert.equal(0, alerts)

			-- Vendor find SHOULD trigger Alert
			env.items[6101] = { name = "Cheap Relic", quality = 1, ilvl = 20, minLevel = 1, classID = 0, sell = 500 }
			AH.HasFullBrowseResults = function() return true end
			AH.GetBrowseResults = function()
				return { { itemKey = { itemID = 6101, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }, minPrice = 50, totalQuantity = 1 } }
			end
			db.tab, db.minProfit, db.minPercent = "vendor", 10, 0
			T.StartScan()
			T.handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
			T.handlers.ITEM_SEARCH_RESULTS_UPDATED({ itemID = 6101 })
			assert.equal(2, alerts) -- sound + flash
		end)
	end)
end)
