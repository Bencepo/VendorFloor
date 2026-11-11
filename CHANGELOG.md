# Changelog

## 0.2.0

- English interface; German when the game client is German.
- Key binding "Buy next find" (Options > Keybindings > AddOns) and `/vfloor buy`: each press checks or buys the best find.
- Stackable goods are checked before they are listed, so the list shows how many units are really below vendor price.
- Each row shows the total profit and the number of units.
- Right-click a find to hide that item for good. `/vfloor ignore list` and `/vfloor ignore clear`.
- Settings under Options > AddOns > VendorFloor: alert sound, continuous mode, pause between rounds, minimum profit.
- Session ledger in the window (buys, spent, vendor value, profit) and `/vfloor stats` for totals since install.
- The version is shown in the window title and in `/vfloor help`.
- The list is cleared when the auction house closes, since prices change in the meantime.

## 0.1.0

- First release. Finds auction house listings priced below vendor value and buys them on click.
- Only auctions with a buyout price are listed; bid-only auctions are ignored.
- Adjustable minimum profit per unit (`/vfloor profit`).
- Interface currently in German.
