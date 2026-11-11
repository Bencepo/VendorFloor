# VendorFloor

Finds World of Warcraft: Forever auction house listings priced below what a vendor pays and lets you buy them with one click. Runs as a small standalone window beside the auction house and works alongside Auctionator.

## Features

- **Scan**: reads the auction house item list and shows items priced below vendor value, best profit first.
- **Buy-it-now only**: an auction is only listed if it has a buyout price. Bid-only auctions are ignored.
- **Minimum profit per unit**: set how far below the vendor price an auction must be, for example `50k`, `5s` or `1g 20s`.
- **One-click buying**: click a find to check its live auctions, then press Buy. Nothing is ever bought automatically.
- **Key binding**: "Buy next find" (Options > Keybindings > AddOns) or `/vfloor buy` checks and buys the best find, one step per press.
- **Stackable goods**: checked before listing, so each row shows the units really below vendor price and the total profit.
- **Ignore list**: right-click a find to hide that item for good.
- **Settings** under Options > AddOns > VendorFloor, and a session ledger (spent, vendor value, profit) in the window.
- **English and German**: follows the game client's language.
- **Continuous mode**: rescans automatically after each round.
- **Alerts**: new finds are announced in chat, with an optional sound.
- **Safe stackable purchases**: a quote is only accepted if the total is still below vendor value.
- **Standalone**: no libraries and no dependencies.

## Usage

1. Open the auction house. The VendorFloor window appears beside it.
2. Press **Scan**. Candidates are checked for buyout prices one by one.
3. Click a find to check its live auctions, then press **Buy**.

| Command | Effect |
| --- | --- |
| `/vfloor` | Show or hide the window |
| `/vfloor profit <amount>` | Minimum profit per unit, e.g. `50k`, `5s`, `1g 20s` |
| `/vfloor interval <seconds>` | Pause between two continuous rounds |
| `/vfloor sound` | Toggle the alert sound |
| `/vfloor buy` | Check and buy the next find (same as the key binding) |
| `/vfloor ignore list` / `clear` | Show or clear the ignore list |
| `/vfloor stats` | Totals since install |
| `/vfloor options` | Open the settings |
| `/vfloor reset` | Reset the window position |

The minimum profit can also be set in the window's input field, top right.

## Notes

- Stop the scan before running an Auctionator search. Both addons share the auction house's query channel.
- Status: beta, built for WoW Forever 1.60.1.

## Releasing

Add a new version heading at the top of `CHANGELOG.md` (for example `## 0.2.1-beta`) and push to `main`.
The release workflow checks the code with luacheck, tags the commit as `v0.2.1-beta`, builds the zip and uploads it to CurseForge.
`-beta` and `-alpha` versions are uploaded as beta and alpha files.

## License

Copyright (c) 2026 Bencepo. All rights reserved. See [LICENSE](LICENSE).
