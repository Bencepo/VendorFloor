-- luacheck-Konfiguration für VendorFloor (WoW Forever, Lua 5.1)
std = "lua51"
max_line_length = false
codes = true

-- WoW-API-Funktionen und -Tabellen sind zu viele zum Auflisten: Lesezugriffe auf
-- unbekannte globale Namen (113) werden nicht gemeldet. Schreibzugriffe schon,
-- damit ein Tippfehler nicht still eine neue globale Variable anlegt.
ignore = { "113", "212/self" }

globals = {
	"VendorFloorDB",
	"VendorFloor_BuyNext",
	"VendorFloor_Ledger",
	"VendorFloor_OnCompartmentClick",
	"SLASH_VENDORFLOOR1",
	"SLASH_VENDORFLOOR2",
	"SlashCmdList",
	"StaticPopupDialogs",
	"BINDING_HEADER_VENDORFLOOR",
	"BINDING_NAME_VENDORFLOOR_BUYNEXT",
}

exclude_files = { ".release/**", "Libs/**" }
