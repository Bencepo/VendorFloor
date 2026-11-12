-- Minimal World of Warcraft environment for running addon files outside the game.
-- Every unknown global is a "stub": any field of it and any call on it returns the stub
-- again, so frames, events and settings calls at load time do nothing. Tests set what they
-- need (items, chat strings, saved variables) before loading.

local M = {}

local stub
stub = setmetatable({}, {
	__index = function() return stub end,
	__call = function() return stub end,
	__newindex = function() end,
})
M.stub = stub

-- items[id] = { name, quality, ilvl, minLevel, classID, sell, stack }
local function ItemInfo(items, item)
	local id = type(item) == "number" and item or tonumber(tostring(item or ""):match("item:(%d+)"))
	local it = id and items[id]
	if not it then return nil end
	local link = "|cff1eff00|Hitem:" .. id .. "::::::::|h[" .. it.name .. "]|h|r"
	return it.name, link, it.quality or 1, it.ilvl or 1, it.minLevel or 1, "", "", it.stack or 1, "", 0,
		it.sell or 0, it.classID or 15
end

-- Loads the addon files (in order) into a fresh environment. Returns ns and the environment.
function M.Load(addon, files, setup)
	local env, items = {}, {}
	env._G = env
	env.items = items
	local function info(item) return ItemInfo(items, item) end
	env.GetItemInfo = info
	env.C_Item = { GetItemInfo = info, GetItemID = function(loc) return loc and loc.id end }
	env.C_AuctionHouse = setmetatable({
		MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
	}, { __index = function() return stub end })
	env.GetLocale = function() return "enUS" end
	env.time = os.time
	env.GetTime = os.clock
	env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	env.tinsert, env.tremove = table.insert, table.remove
	env.unpack = unpack or table.unpack
	env.print = function() end
	env.DEFAULT_CHAT_FRAME = { AddMessage = function() end }
	env.SlashCmdList = {}
	env.UISpecialFrames = {}
	env.ERR_AUCTION_SOLD_S = "A buyer has been found for your auction of %s."
	env.ERR_AUCTION_EXPIRED_S = "Your auction of %s has expired."
	env.ERR_CANT_BE_DISENCHANTED = "Item cannot be disenchanted"
	env.ERR_AUCTION_WON_S = "You won an auction for %s"
	env.INVTYPE_NON_EQUIP_IGNORE = "Non-equippable"
	if setup then setup(env) end
	setmetatable(env, { __index = function(_, k)
		local v = _G[k]
		if v ~= nil then return v end
		return stub
	end })
	local ns = {}
	for _, file in ipairs(files) do
		local chunk
		if setfenv then -- Lua 5.1, like the game
			chunk = assert(loadfile(file))
			setfenv(chunk, env)
		else
			chunk = assert(loadfile(file, "t", env))
		end
		chunk(addon, ns)
	end
	return ns, env
end

return M
