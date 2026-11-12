-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- The disenchant basket: items bought on the disenchant tab wait in the bags until they are
-- disenchanted. One button (on the mail window, or its key binding) disenchants the next one:
-- one click per item, no cursor, no searching the bags. Every disenchant is still your own
-- click or key press, as the game requires.

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })

local DISENCHANT = 13262
local BUTTON_NAME = "VendorFloorBasketButton"

local function DB() return ns.db end

local function SpellName()
	if C_Spell and C_Spell.GetSpellName then
		local name = C_Spell.GetSpellName(DISENCHANT)
		if name then return name end
	end
	if GetSpellInfo then
		local name = GetSpellInfo(DISENCHANT)
		if name then return name end
	end
	return L["Disenchant"]
end

local function Slots(bag)
	if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) end
	return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end

local function SlotInfo(bag, slot)
	if C_Container and C_Container.GetContainerItemInfo then
		local info = C_Container.GetContainerItemInfo(bag, slot)
		if info then return info.itemID, info.stackCount or 1, info.isLocked, info.hyperlink end
		return nil
	end
	local _, count, locked, _, _, _, link, _, _, itemID = GetContainerItemInfo(bag, slot)
	return itemID, count, locked, link
end

local function Bags() return ns.BAGS or { 0, 1, 2, 3, 4 } end

-- Basket items in the bags: list of { bag, slot, id, link }, at most as many as were bought.
local function Contents()
	local db = DB()
	local list = {}
	if not (db and db.deBasket) then return list end
	local left = {}
	for itemID, n in pairs(db.deBasket) do left[itemID] = n end
	for _, bag in ipairs(Bags()) do
		for slot = 1, Slots(bag) do
			local itemID, _, locked, link = SlotInfo(bag, slot)
			if itemID and (left[itemID] or 0) > 0 and not locked
				and (not ns.CanDisenchant or ns.CanDisenchant(itemID)) then
				left[itemID] = left[itemID] - 1
				list[#list + 1] = { bag = bag, slot = slot, id = itemID, link = link }
			end
		end
	end
	return list
end
ns.BasketContents = Contents

-- A unit leaves the basket when it is no longer in the bags or the mail: disenchanted
-- (with the button, by hand or by another addon), sold or traded.
local function Prune()
	local db = DB()
	if not (db and db.deBasket) then return end
	local inBags = {}
	for _, bag in ipairs(Bags()) do
		for slot = 1, Slots(bag) do
			local itemID, count = SlotInfo(bag, slot)
			if itemID then inBags[itemID] = (inBags[itemID] or 0) + (count or 1) end
		end
	end
	for itemID, n in pairs(db.deBasket) do
		local keep = (inBags[itemID] or 0) + ((db.debought and db.debought[itemID]) or 0)
		if keep <= 0 then
			db.deBasket[itemID] = nil
		elseif keep < n then
			db.deBasket[itemID] = keep
		end
	end
end

---------------------------------------------------------------------------
-- The button (secure: casting needs a click or key press)
---------------------------------------------------------------------------

local button

local function Clear()
	if not button or InCombatLockdown() then return end
	button:SetAttribute("type", nil)
	button:SetAttribute("macrotext", nil)
	button.target = nil
end

-- Out of combat right before the click: aim the button at the next basket item.
-- The button listens to both press and release; only the one the game uses for action
-- buttons casts, so a click or key press disenchants exactly one item.
local function Aim(self, _, down)
	if InCombatLockdown() then return end
	local onDown = GetCVarBool and GetCVarBool("ActionButtonUseKeyDown")
	if (down and true or false) ~= (onDown and true or false) then
		Clear()
		return
	end
	local target = Contents()[1]
	if not target then
		Clear()
		return
	end
	self.target = target
	self:SetAttribute("type", "macro")
	self:SetAttribute("macrotext", ("/cast %s\n/use %d %d"):format(SpellName(), target.bag, target.slot))
end

local function Create()
	if button then return button end
	local make = ns.FlatButton
	if make then
		button = make(UIParent, 170, 24, nil, BUTTON_NAME, "SecureActionButtonTemplate")
	else
		button = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate, UIPanelButtonTemplate")
		button:SetSize(170, 24)
	end
	button:RegisterForClicks("AnyUp", "AnyDown")
	button:SetText(L["Disenchant basket (%d)"]:format(0))
	button:SetScript("PreClick", Aim)
	button:SetScript("PostClick", function() C_Timer.After(0, Clear) end)
	button:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("VendorFloor")
		GameTooltip:AddLine(L["Disenchants the next item you bought on the disenchant tab: one click per item."], 1, 1, 1, true)
		local list = Contents()
		if list[1] then
			GameTooltip:AddLine(" ")
			local shown = {}
			for _, e in ipairs(list) do shown[e.id] = shown[e.id] or { link = e.link, n = 0 } shown[e.id].n = shown[e.id].n + 1 end
			local lines = 0
			for _, e in pairs(shown) do
				lines = lines + 1
				if lines > 12 then break end
				GameTooltip:AddLine(("%s ×%d"):format(e.link or "?", e.n))
			end
		end
		local key = GetBindingKey and GetBindingKey("CLICK " .. BUTTON_NAME .. ":LeftButton")
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(key and L["Key: %s"]:format(key) or L["Tip: set a key for it under Key Bindings > AddOns > VendorFloor."],
			0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	button:HookScript("OnLeave", function(self) if GameTooltip:GetOwner() == self then GameTooltip:Hide() end end)
	button:Hide()
	return button
end

function ns.UpdateBasket()
	if not button or InCombatLockdown() then return end
	local n = #Contents()
	button:SetText(L["Disenchant basket (%d)"]:format(n))
	button:SetEnabled(n > 0)
	if MailFrame and MailFrame:IsShown() and (n > 0 or (ns.db and ns.db.deBasket and next(ns.db.deBasket))) then
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 4, -58)
		button:Show()
	else
		button:Hide()
	end
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "BAG_UPDATE_DELAYED",
	"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "LOOT_CLOSED" }) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event)
	if not DB() then return end
	if event == "PLAYER_LOGIN" then
		Create()
		if not InCombatLockdown() then Prune() end
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- the bags may change in combat: no click may hit an item it was not aimed at
		Clear()
		return
	elseif (event == "BAG_UPDATE_DELAYED" or event == "MAIL_CLOSED") and not (event == "BAG_UPDATE_DELAYED" and MailFrame and MailFrame:IsShown()) then
		-- while the mail is open, items arrive one by one: pruning waits until it is closed
		Prune()
	end
	Create()
	ns.UpdateBasket()
end)

_G["BINDING_NAME_CLICK " .. BUTTON_NAME .. ":LeftButton"] = L["Disenchant next basket item"]
