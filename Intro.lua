-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- First steps: a short panel over the result list the first time the VendorFloor tab
-- opens. Three steps from scan to sale, one button to close it. Menu > How it works
-- shows it again.

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })

local STEPS = {
	{ "Scan", "Pick a list on the left (vendor, disenchant or crafting) and press Scan. Finds appear in this list." },
	{ "Check", "Click a find, or the gold button at the bottom right: it checks the find against the live auctions." },
	{ "Buy", "Click the button again to buy. Purchases come by mail: Collect purchases at the mailbox, Sell purchases at a merchant." },
}

local panel

local function Build(ui)
	local C = ns.C
	local body = ui.body or ui
	panel = CreateFrame("Frame", nil, body, "BackdropTemplate")
	ns.Flat(panel, C.bg, C.gold)
	panel:SetPoint("TOPLEFT", body, "TOPLEFT", 170, -48)
	panel:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -10, 40)
	panel:SetFrameLevel(body:GetFrameLevel() + 20)
	panel:EnableMouse(true) -- clicks stay on the panel, not on the rows under it

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 18, -16)
	title:SetText(L["Welcome to VendorFloor"])
	title:SetTextColor(unpack(C.gold))

	local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	sub:SetText(L["From scan to gold in three clicks:"])

	for i, s in ipairs(STEPS) do
		local num = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		num:SetPoint("TOPLEFT", 18, -76 - (i - 1) * 56)
		num:SetWidth(16)
		num:SetText(tostring(i))
		num:SetTextColor(unpack(C.gold))
		local head = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		head:SetPoint("TOPLEFT", num, "TOPRIGHT", 12, 0)
		head:SetText(L[s[1]])
		local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		text:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
		text:SetPoint("RIGHT", panel, "RIGHT", -18, 0)
		text:SetJustifyH("LEFT")
		text:SetSpacing(2)
		text:SetText(L[s[2]])
	end

	local tip = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	tip:SetPoint("BOTTOMLEFT", 18, 16)
	tip:SetPoint("RIGHT", panel, "RIGHT", -130, 0)
	tip:SetJustifyH("LEFT")
	tip:SetText(L["Tip: Continuous mode scans again on its own. Every purchase is still your own click."])

	local ok = ns.FlatButton(panel, 100, 24, "primary")
	ok:SetPoint("BOTTOMRIGHT", -14, 12)
	ok:SetText(L["Got it"])
	ok:SetScript("OnClick", function()
		if ns.db then ns.db.introSeen = true end
		panel:Hide()
	end)
	panel:Hide()
end

-- force: show it again (menu). Without: only until the player has closed it once.
function ns.ShowIntro(force)
	local ui = ns.ui
	if not ui or not ns.db then return end
	if not force and ns.db.introSeen then return end
	if not panel then Build(ui) end
	panel:Show()
end

function ns.IntroShown() return panel ~= nil and panel:IsShown() end
