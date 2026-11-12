# VendorFloor

Auction house sniper for WoW Forever. Finds auctions that are worth more than they cost: below vendor price, below disenchant value, or the reagents for a profitable craft. It runs in its own small window next to Auctionator, and every purchase is your own click.

## Features

- **Vendor finds**: auctions listed below what a merchant pays. Buy, collect from the mail and sell at a merchant, each with one button.
- **Disenchant finds**: green and blue gear below what disenchanting it brings, from the Forever disenchant tables and, after 3 disenchants of an item, from your own results.
- **Disenchant basket**: enchanters get a small basket window when disenchant purchases arrive in the bags. Each click, or one key, disenchants the next item.
- **Crafting profits**: which of your learned recipes make a profit right now, with reagents from the cheapest source.
- **Realistic values**: materials count at the cheapest listings and at what your own auctions really sold for, not at an optimistic average.
- **Minimum profit** in copper, in percent and per bag slot, right in the window or in the settings.
- **Ledger**: spent, sold and real profit per session, day and item, including sales made by junk-seller addons.
- **Continuous mode, alerts and key bindings**: rescans on its own, announces new finds with an optional sound and taskbar flash; "Buy next find" and the disenchant basket work on a key.
- **Minimap button and addon menu**, settings under Options > AddOns > VendorFloor.
- **English and German**: follows the game client's language.

## Usage

1. Open the auction house: the VendorFloor window opens next to it.
2. Pick a tab (Vendor, Disenchant, Crafting) and press **Scan**, or switch on **Continuous**.
3. Click a find to check it against the live auctions, then press **Buy**.
4. At the mailbox press **Collect purchases**, at a merchant **Sell purchases**.
5. Menu (top right): statistics, your disenchants, your auctions, export and settings.

A full scan reads every auction at once (the auction house allows this every 15 minutes) and fills the tabs. In between, quick rounds and per-tab scans check the items that were cheap before.

## Web page

Menu > Export, then paste it at https://bencepo.github.io/vendorfloor for profit per day, your best items and time to sale. The page runs in the browser and uploads nothing. Its source is `web/index.html`, published from the public repo `Bencepo/bencepo.github.io` (folder `vendorfloor/`).

## Works with LevelTrail

With LevelTrail installed, the auction house profit shows up next to the leveling run, per day and per play session. LevelTrail reads it through `VendorFloor_Ledger()`.

## Chat commands

Everything is also available in the window and the settings. For those who prefer commands:

| Command | Effect |
| --- | --- |
| `/vfloor` | Show or hide the window |
| `/vfloor profit <amount>` | Minimum profit per unit, e.g. `50k`, `5s`, `1g 20s` |
| `/vfloor percent <n>` | Minimum profit in percent |
| `/vfloor slot <amount>` | Minimum profit per bag slot |
| `/vfloor interval <seconds>` | Pause between two continuous rounds |
| `/vfloor sound` / `flash` | Toggle the alert sound / taskbar flash |
| `/vfloor buy` | Check and buy the next find (same as the key binding) |
| `/vfloor full` / `quick` | Start a full scan / a quick round |
| `/vfloor craft` / `de` / `sales` | Best crafts / disenchant results / sales in chat |
| `/vfloor ignore list` / `clear` | Show or clear the ignore list |
| `/vfloor stats` / `export` | Totals since install / ledger export |
| `/vfloor forget` | Forget the purchases still to sell |
| `/vfloor minimap` | Hide or show the minimap button |
| `/vfloor options` / `reset` | Open the settings / reset the window position |

## Notes

- Stop the scan before running an Auctionator search. Both addons share the auction house's query channel.
- Built for WoW Forever 1.60.1. Libraries: LibStub, CallbackHandler, LibDataBroker, LibDBIcon (bundled).

## Releasing

Add a new version heading at the top of `CHANGELOG.md` (for example `## 0.9.0`) and push to `main`.
The release workflow checks the code with luacheck, tags the commit, builds the zip and uploads it to CurseForge and Wago.
`-beta` and `-alpha` versions are uploaded as beta and alpha files.

## AI disclosure

The code was written with the help of an AI assistant (Claude). Bencepo designed the features, tests everything in game and maintains the addon.

## License

Copyright (c) 2026 Bencepo. All rights reserved. See [LICENSE](LICENSE).
