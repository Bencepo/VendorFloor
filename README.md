# VendorFloor

Auction house sniper for WoW Forever. Finds auctions that are worth more than they cost: below vendor price, below disenchant value, or the reagents for a profitable craft. It lives as its own tab in the auction house window, works alongside other auction addons, and every purchase is your own click.

**Website and live demo:** https://bencepo.github.io/vendorfloor/

## Features

- **Vendor finds**: auctions listed below what a merchant pays. Buy, collect from the mail and sell at a merchant, each with one button.
- **Disenchant finds**: green and blue gear below what disenchanting it brings, from the Forever disenchant tables and, after 3 disenchants of an item, from your own results.
- **Disenchant basket**: enchanters get a small basket window when disenchant purchases arrive in the bags. Each click, or one key, disenchants the next item.
- **Crafting profits**: which of your learned recipes make a profit right now, with reagents from the cheapest source.
- **Realistic values**: materials count at the cheapest listings and at what your own auctions really sold for, not at an optimistic average.
- **Minimum profit** in copper, in percent and per bag slot, right in the window or in the settings.
- **Ledger**: spent, sold and real profit per session, day and item, including sales made by junk-seller addons.
- **Continuous mode, alerts and key bindings**: rescans on its own, announces new finds with an optional sound and taskbar flash; "Buy next find" and the disenchant basket work on a key.
- **Minimap button and addon menu.** Settings in a window of their own (menu > Settings): drag it anywhere, it stays open while you play and changes apply at once.
- **English and German**: follows the game client's language.

## Usage

1. Open the auction house and click the **VendorFloor** tab (it opens there again next time).
2. Pick a list on the left (Vendor, Disenchant, Crafting, Watchlist) and press **Scan**, or switch on **Continuous**.
3. Click a find to check it against the live auctions, then press **Buy**.
4. At the mailbox press **Collect purchases**, at a merchant **Sell purchases**.
5. Right-click a find to hide it or add it to the watchlist. Menu (top right): statistics, your disenchants, your auctions, export, watchlist, ignore list and settings.

A full scan reads every auction at once (the auction house allows this every 15 minutes) and fills the tabs. In between, quick rounds and per-tab scans check the items that were cheap before.

## Web page

Menu > Export, then paste it at https://bencepo.github.io/vendorfloor for profit per day, your best items and time to sale. The page runs in the browser and uploads nothing. Its source is `web/index.html`, published from the public repo `Bencepo/bencepo.github.io` (folder `vendorfloor/`).

## Works with LevelTrail

With LevelTrail installed, the auction house profit shows up next to the leveling run, per day and per play session. LevelTrail reads it through `VendorFloor_Ledger()`.

## Chat commands

Everything is in the auction house tab, its menu and the settings. Three commands remain:

| Command | Effect |
| --- | --- |
| `/vfloor` | Show or hide VendorFloor at the auction house |
| `/vfloor buy` | Check and buy the next find (same as the key binding) |
| `/vfloor options` | Open the settings |

## Notes

- Stop the scan before searching on another tab or with another auction addon. All searches share the auction house's query channel.
- Built for WoW Forever 1.60.1. Libraries: LibStub, CallbackHandler, LibDataBroker, LibDBIcon (bundled).

## Releasing

Add a new version heading at the top of `CHANGELOG.md` (for example `## 0.9.0`) and push to `main`.
The release workflow checks the code with luacheck and LuaLS (with the WoW API annotations), tags the commit, builds the zip and uploads it to CurseForge and Wago.
`-beta` and `-alpha` versions are uploaded as beta and alpha files.

## Feedback and bug reports

Found a bug or have an idea? [Open an issue](https://github.com/Bencepo/VendorFloor/issues/new/choose), it takes a minute. For bugs the Lua error text (from BugSack, or `/console scriptErrors 1`) and your VendorFloor version help the most. No GitHub account? Comment on [CurseForge](https://www.curseforge.com/wow/addons/vendorfloor#comments). Every report gets read.

## More addons by Bencepo

All addons, live demos and the web pages: **https://bencepo.github.io**

Like the addons? Support them on Ko-fi: **https://ko-fi.com/bencepo**

- [LevelTrail](https://bencepo.github.io/leveltrail/): records your leveling run; the page shows splits, XP sources, deaths, records and a share image.
- [ProcFlare](https://bencepo.github.io/procflare/): big Clearcasting alert and small icons for weapon, trinket and talent procs, with melee and caster sound packs.
- [SwingCast](https://bencepo.github.io/swingcast/): spell icon, cast time, latency zone and a swing timer on the standard cast bar.
- [StatTrim](https://bencepo.github.io/stattrim/): hide, merge and reorder stats right inside the character window.

## AI disclosure

The code was written with the help of an AI assistant (Claude). Bencepo designed the features, tests everything in game and maintains the addon.

## License

Copyright (c) 2026 Bencepo. All rights reserved. See [LICENSE](LICENSE).
