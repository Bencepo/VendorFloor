# Notes for Claude

VendorFloor: auction house sniper for WoW Forever (modern C_AuctionHouse API, Lua 5.1). Author and rights holder: Bencepo. All rights reserved, no open-source license.

## Layout

- `VendorFloor.lua`: scanning, full scan, finds, buying, disenchant values, settings window, events, slash commands. `ns.test` exposes internals for the tests.
- `Trade.lua` (purchases, mail collection, merchant sales), `Basket.lua` (disenchant basket), `Craft.lua` (crafting tab), `Sales.lua` (own auctions), `Export.lua` (ledger export, minimap button), `Locales.lua` (deDE strings; enUS is the key itself).
- `Libs/BencepoUI`: shared settings-window toolkit, also shipped in ProcFlare. Bump the LibStub minor version on every change so the newest copy wins.
- `web/index.html`: the ledger page on bencepo.github.io/vendorfloor.

## Rules

- UI texts in English, German translations in `Locales.lua`. Buttons in the UI instead of chat commands.
- `C_AuctionHouse.ReplicateItems` (full scan) is a throttled message: sent while a search is still under way it is dropped without an answer. Only send it when `IsThrottledMessageSystemReady()` is true, and resend on `AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED`. Since 0.9.2 continuous mode leaves the full scan to the button; it is unproven whether a full scan started without a click is answered.
- Test before release: `busted` (tests/*_spec.lua, WoW mock in tests/helpers/wow.lua). CI also runs luacheck and LuaLS with the WoW API annotations.
- Release: new version heading at the top of `CHANGELOG.md` (`## 0.9.2`), push to `main`; the workflow tags, builds and uploads to CurseForge and Wago. The release reaches players right away, so test changes in the game before pushing.
