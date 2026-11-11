# Changelog

## 0.4.1-beta

- New look: flat dark window in the colours of the web page, gold accents, flat buttons (also at the mailbox and merchant), a "Continuous" switch, zebra rows and a clearer progress bar.
- Fix: single items (e.g. bags) could show hundreds of units for one auction, with a unit price below 1 copper and a huge fake profit. Units per auction are now capped at the stack size, and prices below 1 copper per unit are ignored.
- Fixed: the "Sell purchases" button at a merchant (and "Collect purchases" at the mailbox) could appear as an empty red bar without its text until the bags changed.
- Minimap button (LibDBIcon, so minimap button collectors can take it): left-click opens the ledger export (at the auction house: the window), right-click prints the totals, the tooltip shows today's and the total profit. Drag to move, `/vfloor minimap` hides or shows it. VendorFloor also appears in the game's addon menu next to the minimap.
- Continuous mode: between two rounds the scan button shows "Stop (12)" with the seconds to the next round, so it is clear the loop is running. While a round, the checks or the loop run, the button stays pressed in. A click stops it.
- Fixed: the arrow between auction and vendor price showed as an empty box.
- Progress bar shows its text: percent of the full scan, "checking 12 of 40 (30 %)", or the auctions read so far.
- Fixed: after a purchase the round could stop with "Bought." and a half-full bar, because the auction house kept reporting that it was not ready for the next query. Such a query is now sent anyway after 10 seconds. `/vfloor debug` prints the internal state if it still happens.
- Sales by other addons count: bought items sold at a merchant in any way (for example by an addon that sells grey items automatically) now go into the ledger. VendorFloor counts them from the bags.
- Faster checks: a check waits 3 instead of 6 seconds for an answer, and a find that stays silent twice (sold out meanwhile) is skipped for 30 minutes instead of being checked every round.
- Fewer useless checks: an item checked without a buyout below the vendor price (for example one with bid-only auctions) is skipped for 30 minutes, unless a cheaper listing appears.

## 0.4.0-beta

- Ledger per day and per item: spending, sales and real profit per calendar day (last 120 days), and per item how many were bought and sold and how long they waited until the sale.
- `/vfloor export`: the ledger as text to copy into the new web page https://bencepo.github.io/vendorfloor/ (profit per day, best items, holding time). Nothing is uploaded; the page runs in your browser.
- LevelTrail, if installed, shows your VendorFloor profit next to your gold curve and per play session.

## 0.3.0-beta

- Full scan: reads every auction of the auction house at once (allowed every 15 minutes). Each auction comes with its buyout, so finds appear complete and without checking each item. Between full scans the normal rounds keep running.
- Collect purchases: a button at the mailbox takes the items VendorFloor bought out of the auction house mail.
- Sell purchases: a button at a merchant sells them, at most as many as VendorFloor bought, so items of your own stay.
- Ledger counts sales and the profit they really made, profit per hour and what is still to sell. `/vfloor stats` shows the totals, `/vfloor forget` clears the purchases still to sell.
- Progress bar for full scans and checks, and a summary line with the cost and profit of the whole list.

## 0.2.2-beta

- Faster checking: results the auction house already holds are read at once instead of after a 15 second wait.
- Fewer lost finds: a check without an answer is tried again later instead of dropping the find, and several variants of one item (e.g. "of the Bear", "of the Monkey") whose data is still loading are all kept.
- Stackable goods appear in the list right after the scan; the check then counts the units below vendor price ("?×" until then).
- Single items are checked first, best potential profit first.

## 0.2.1-beta

- Fixed: the window failed to open with "attempt to index upvalue 'L'" when the texts file had not been loaded. VendorFloor now falls back to English texts.

## 0.2.0-beta.2

- English interface; German when the game client is German.
- Key binding "Buy next find" (Options > Keybindings > AddOns) and `/vfloor buy`: each press checks or buys the best find.
- Stackable goods are checked before they are listed, so the list shows how many units are really below vendor price.
- Each row shows the total profit and the number of units.
- Right-click a find to hide that item for good. `/vfloor ignore list` and `/vfloor ignore clear`.
- Settings under Options > AddOns > VendorFloor: alert sound, continuous mode, pause between rounds, minimum profit.
- Session ledger in the window (buys, spent, vendor value, profit) and `/vfloor stats` for totals since install.
- The version is shown in the window title and in `/vfloor help`.
- The list is cleared when the auction house closes, since prices change in the meantime.

## 0.1.0-beta

- First release. Finds auction house listings priced below vendor value and buys them on click.
- Only auctions with a buyout price are listed; bid-only auctions are ignored.
- Adjustable minimum profit per unit (`/vfloor profit`).
- Interface currently in German.
