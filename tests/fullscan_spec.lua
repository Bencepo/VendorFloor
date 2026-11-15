local wow = require("tests.helpers.wow")

-- The full scan (every auction at once): continuous mode, a list from another addon,
-- an unanswered request.
describe("full scan", function()
	local ns, env, T, db, replicated, requests, ready

	before_each(function()
		replicated, requests, ready = 0, 0, true
		ns, env = wow.Load("VendorFloor", { "Locales.lua", "VendorFloor.lua" }, function(e)
			e.VendorFloorDB = {}
			e.C_AuctionHouse = {
				MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
				ReplicateItems = function() requests = requests + 1 end,
				GetNumReplicateItems = function() return replicated end,
				IsThrottledMessageSystemReady = function() return ready end,
			}
		end)
		T = ns.test
		T.Init()
		db = ns.db
		T.handlers.AUCTION_HOUSE_SHOW()
	end)

	it("starts from the button and asks the auction house once", function()
		T.StartFull()
		assert.is_true(T.Full().active)
		assert.equal("waiting", T.Full().phase)
		assert.equal(1, requests)
	end)

	it("the click wins over a running scan", function()
		T.Scan().active = true
		T.StartFull()
		assert.equal(1, requests)
		assert.is_false(T.Scan().active)
		assert.is_true(T.Full().active)
	end)

	it("waits until a running search is answered", function()
		ready = false
		T.StartFull()
		assert.equal(0, requests)
		assert.equal("sending", T.Full().phase)
		env.now = 1
		T.FullTick(env.now)
		assert.equal(0, requests)
		ready = true
		env.now = 2
		T.FullTick(env.now)
		assert.equal(1, requests)
		assert.equal("waiting", T.Full().phase)
	end)

	it("sends a dropped request again", function()
		T.StartFull()
		T.handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()
		env.now = 1
		T.FullTick(env.now)
		assert.equal(2, requests)
	end)

	it("is never started by continuous mode", function()
		db.loop, db.tab, db.lastFull = true, "vendor", nil
		pcall(T.NextRound)
		assert.equal(0, requests)
		assert.is_false(T.Full().active)
	end)

	it("reads the list of a full scan another addon started", function()
		replicated = 500
		T.handlers.REPLICATE_ITEM_LIST_UPDATE()
		assert.is_true(T.Full().active)
		assert.equal("arriving", T.Full().phase)
		assert.equal(0, requests)
	end)

	it("ignores a late list of its own scan", function()
		db.lastFull = env.time() - 60
		replicated = 500
		T.handlers.REPLICATE_ITEM_LIST_UPDATE()
		assert.is_false(T.Full().active)
	end)

	it("reads a list already there when the auction house stays silent", function()
		T.StartFull()
		replicated = 500
		env.now = 20
		T.FullTick(env.now)
		assert.equal("arriving", T.Full().phase)
	end)

	it("frees the 15 minutes again when the auction house never answers", function()
		db.lastFull = 1000
		T.StartFull()
		assert.is_true(db.lastFull > 1000)
		env.now = 91
		T.FullTick(env.now)
		assert.is_false(T.Full().active)
		assert.equal(1000, db.lastFull)
	end)
end)

describe("disenchant casts", function()
	it("without spell names only Disenchant itself counts", function()
		local ns = wow.Load("VendorFloor", { "Locales.lua", "VendorFloor.lua" }, function(e)
			e.VendorFloorDB = {}
			e.C_Spell = false
			e.InCombatLockdown = function() return false end
		end)
		local T = ns.test
		assert.is_true(T.IsDisenchantCast(13262))
		assert.is_false(T.IsDisenchantCast(133))
		assert.is_false(T.IsDisenchantCast(nil))
	end)
end)

describe("chat lines with positional specifiers", function()
	it("match like plain %s", function()
		local ns = wow.Load("VendorFloor", { "Locales.lua", "VendorFloor.lua", "Sales.lua" }, function(e)
			e.VendorFloorDB = {}
		end)
		local P = ns.salesTest.Pattern
		assert.equal("Linen Cloth", ("Auction of Linen Cloth (1) sold."):match(P("Auction of %1$s (1) sold.")))
		assert.equal("Linen Cloth", ("Auction of Linen Cloth sold."):match(P("Auction of %s sold.")))
	end)
end)
