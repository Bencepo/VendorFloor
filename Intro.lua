-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- First steps: three small callouts, one after the other, each with an arrow to the part
-- of the window it explains (Scan button, result list, action button). Shown the first
-- time the VendorFloor tab opens; Menu > How it works shows them again.

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })

local W = 250

-- target: which part of the window; side: where the callout sits relative to it.
local STEPS = {
	{ target = "scan", side = "below", title = "Scan",
		text = "Pick a list on the left (vendor, disenchant or crafting), then press Scan." },
	{ target = "list", side = "below", title = "Check",
		text = "Finds appear in this list. Click one: VendorFloor checks it against the live auctions." },
	{ target = "action", side = "above", title = "Buy",
		text = "Click this button to buy. Purchases come by mail: Collect purchases at the mailbox, Sell purchases at a merchant." },
}

local box, step

local function Target(ui, name)
	if name == "scan" then return ui.scan end
	if name == "action" then return ui.action end
	return ui.rows and ui.rows[1] or ui.body
end

-- Arrow: the game's tutorial arrow where it exists, else a plain arrow texture.
local function SetArrow(tex, down)
	local atlas = down and "NPE_ArrowDown" or "NPE_ArrowUp"
	if tex.SetAtlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
		tex:SetAtlas(atlas)
		tex:SetTexCoord(0, 1, 0, 1)
	else
		tex:SetTexture("Interface\\Buttons\\UI-MicroStream-Yellow")
		if down then tex:SetTexCoord(0, 1, 0, 1) else tex:SetTexCoord(0, 1, 1, 0) end
	end
end

local function Build(ui)
	local C = ns.C
	box = CreateFrame("Frame", nil, ui, "BackdropTemplate")
	ns.Flat(box, C.bg, C.gold)
	box:SetWidth(W)
	box:SetFrameStrata("DIALOG")
	box:SetFrameLevel(60)
	box:EnableMouse(true)

	box.count = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	box.count:SetPoint("TOPRIGHT", -32, -10)

	box.title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	box.title:SetPoint("TOPLEFT", 12, -10)
	box.title:SetTextColor(unpack(C.gold))

	box.text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	box.text:SetPoint("TOPLEFT", box.title, "BOTTOMLEFT", 0, -6)
	box.text:SetWidth(W - 24)
	box.text:SetJustifyH("LEFT")
	box.text:SetSpacing(2)

	box.next = ns.FlatButton(box, 80, 22, "primary")
	box.next:SetPoint("BOTTOMRIGHT", -10, 10)
	box.next:SetScript("OnClick", function() ns.IntroNext() end)

	box.skip = ns.FlatButton(box, 20, 18)
	box.skip:SetPoint("TOPRIGHT", -6, -6)
	box.skip:SetText("x")
	box.skip:SetScript("OnClick", function() ns.IntroDone() end)

	box.arrow = box:CreateTexture(nil, "OVERLAY")
	box.arrow:SetSize(32, 32)
	box:Hide()
end

local function ShowStep(i)
	local ui = ns.ui
	local s = STEPS[i]
	if not (ui and s) then return end
	step = i
	box.title:SetText(L[s.title])
	box.text:SetText(L[s.text])
	box.count:SetText(("%d/%d"):format(i, #STEPS))
	box.next:SetText(i < #STEPS and L["Next"] or L["Got it"])
	box:SetHeight(10 + 14 + 6 + math.max(box.text:GetStringHeight() or 0, 42) + 12 + 22 + 10)

	local target = Target(ui, s.target)
	box:ClearAllPoints()
	box.arrow:ClearAllPoints()
	if s.side == "above" then
		box:SetPoint("BOTTOMRIGHT", target, "TOPRIGHT", 0, 30)
		box.arrow:SetPoint("TOP", box, "BOTTOMRIGHT", -40, 2)
		SetArrow(box.arrow, true)
	else
		box:SetPoint("TOPLEFT", target, "BOTTOMLEFT", 0, -22)
		box.arrow:SetPoint("BOTTOM", box, "TOPLEFT", 40, -6)
		SetArrow(box.arrow, false)
	end
	box:Show()
end

function ns.IntroNext()
	if step and step < #STEPS then ShowStep(step + 1) else ns.IntroDone() end
end

function ns.IntroDone()
	if ns.db then ns.db.introSeen = true end
	step = nil
	if box then box:Hide() end
end

-- force: show it again (menu). Without: only until the player has finished or closed it.
function ns.ShowIntro(force)
	local ui = ns.ui
	if not ui or not ns.db then return end
	if not force and ns.db.introSeen then return end
	if not box then Build(ui) end
	ShowStep(1)
end

function ns.IntroShown() return box ~= nil and box:IsShown() end
