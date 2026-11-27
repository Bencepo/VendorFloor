# Notes for Claude

VendorFloor: auction house sniper for WoW Forever (modern C_AuctionHouse API, Lua 5.1). Author and rights holder: Bencepo. All rights reserved, no open-source license.

## Layout

- `VendorFloor.lua`: scanning, full scan, finds, buying, disenchant values, settings window, events, slash commands. `ns.test` exposes internals for the tests.
- `Trade.lua` (purchases, mail collection, merchant sales), `Basket.lua` (disenchant basket), `Craft.lua` (crafting tab), `Sales.lua` (own auctions), `Export.lua` (ledger export, minimap button), `Locales.lua` (item info shims and `L`, which returns its key: no translations).
- `Libs/BencepoUI`: shared settings-window toolkit of all Bencepo addons; must be the same file in each (canonical: minor 6, Nov 2026). Change it in one repo, bump the LibStub minor, copy it to the others: two different copies with the same minor make the result depend on load order.
- `web/index.html`: the ledger page on bencepo.github.io/vendorfloor.

## Rules

- `VendorFloor.lua`'s main chunk is at Lua's limit of 200 locals (`luac5.1 -p VendorFloor.lua` fails above it). New helpers go into `ns` or an existing table such as `AHT`, not into new file-level locals (not into `handlers`: every key there is registered as an event).
- English only: UI texts, commands and descriptions. No translations (Ben's wish, Nov 2026), no `Notes-xxXX` in the .toc. Buttons in the UI instead of chat commands.
- `C_AuctionHouse.ReplicateItems` (full scan) is a throttled message: sent while a search is still under way it is dropped without an answer. Only send it when `IsThrottledMessageSystemReady()` is true, and resend on `AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED`. Since 0.9.2 continuous mode leaves the full scan to the button. Tested by Ben (Nov 2026): the full scan only comes when the player clicks; one started without a click is not answered. Keep it on the button.
- Test before release: `busted` (tests/*_spec.lua, WoW mock in tests/helpers/wow.lua). CI also runs luacheck and LuaLS with the WoW API annotations.
- Release: new version heading at the top of `CHANGELOG.md` (`## 0.9.2`), push to `main`; the workflow tags, builds and uploads to CurseForge and Wago. The release reaches players right away, so test changes in the game before pushing.
- Release rhythm (Ben, Nov 2026): at most one release per addon per week. Tested changes are collected under `## Unreleased` at the top of `CHANGELOG.md` (the workflow only releases a numbered heading, so pushes to `main` with `## Unreleased` release nothing); the weekly release renames it to the version. Exception: hotfixes for Lua errors or a broken core feature go out at once.
