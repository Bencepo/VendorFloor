-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Texts: the English text is the key and is shown as it is. Other client
-- languages translate it below. A missing translation falls back to English.

local _, ns = ...

local L = setmetatable({}, { __index = function(_, key) return key end })
ns.L = L
ns.COPPER = "c" -- abbreviation for copper in amounts ("50c")

if GetLocale() ~= "deDE" then return end

ns.COPPER = "k"

-- Window
L["VendorFloor %s"] = "VendorFloor %s"
L["Scan"] = "Scan"
L["Stop"] = "Stopp"
L["Continuous"] = "Dauerlauf"
L["Min. profit/unit"] = "Mindestgewinn/Stück"
L["Minimum profit per unit"] = "Mindestgewinn je Stück"
L["How far below the vendor price an auction must be."] = "So viel muss eine Auktion unter dem Händlerpreis liegen."
L["Examples: 50%s, 5s, 1g 20s. Confirm with Enter."] = "Beispiele: 50%s, 5s, 1g 20s. Mit Enter bestätigen."
L["Amount not recognised. Examples: 50%s, 5s, 1g 20s"] = "Betrag nicht erkannt. Beispiele: 50%s, 5s, 1g 20s"
L["Click a find"] = "Fund anklicken"
L["Check"] = "Prüfen"
L["Checking …"] = "Prüfe …"
L["Buy: %d× for %s"] = "Kaufen: %d× für %s"
L["Get quote: %d× (about %s)"] = "Angebot holen: %d× (etwa %s)"
L["Getting quote …"] = "Hole Angebot …"
L["Buying …"] = "Kaufe …"
L["%d–%d of %d"] = "%d–%d von %d"
L["Ready. \"Scan\" reads the auction house item list."] = "Bereit. „Scan“ liest die Artikelliste des Auktionshauses."
L["Session: %d buys, spent %s, sold %s, profit %s (%s per hour), still to sell %s"] = "Sitzung: %d Käufe, ausgegeben %s, verkauft %s, Gewinn %s (%s pro Stunde), noch zu verkaufen %s"
L["%d finds · cost %s · profit %s"] = "%d Funde · Einsatz %s · Gewinn %s"

-- Rows
L["Listed on the AH: %d"] = "Im AH gelistet: %d"
L["Below vendor price: %d×, total profit %s"] = "Unter Händlerpreis: %d×, Gewinn gesamt %s"
L["Profit per unit %s, units not counted yet"] = "Gewinn je Stück %s, Stückzahl noch nicht gezählt"
L["Click: check and buy. Right-click: hide this item."] = "Klick: prüfen und kaufen. Rechtsklick: Gegenstand ausblenden."

-- Scan
L["The auction house must be open."] = "Das Auktionshaus muss offen sein."
L["Scanning …"] = "Scanne …"
L["Scanning … %d items read, %d finds"] = "Scanne … %d Artikel gelesen, %d Funde"
L["%d items read. Checking %d candidates …"] = "%d Artikel gelesen. Prüfe %d Kandidaten …"
L["Round done: %d items read, %d below vendor price."] = "Runde fertig: %d Artikel gelesen, %d unter Händlerpreis."
L["Checking: %s (%d left)"] = "Prüfe: %s (noch %d)"
L["Scan stopped."] = "Scan gestoppt."
L["The auction house is not responding. Scan stopped."] = "Das Auktionshaus antwortet nicht. Scan abgebrochen."
L["The auction house rejected the query."] = "Das Auktionshaus hat die Abfrage abgelehnt."
L["%s below vendor price: %s× for %s each, vendor pays %s"] = "%s unter Händlerpreis: %s× zu je %s, Händler zahlt %s"

-- Buying
L["Checking %s …"] = "Prüfe %s …"
L["Nothing below vendor price any more (or not enough gold)."] = "Nichts mehr unter Händlerpreis (oder zu wenig Gold)."
L["Nothing below vendor price any more."] = "Nichts mehr unter Händlerpreis."
L["%d× %s below vendor price, profit about %s."] = "%d× %s unter Händlerpreis, Gewinn etwa %s."
L["%s ×%d for %s, vendor pays %s."] = "%s ×%d für %s, Händler zahlt %s."
L["Not enough gold."] = "Nicht genug Gold."
L["Purchase sent: %s ×%d for %s (vendor pays %s)."] = "Kauf gesendet: %s ×%d für %s (Händler zahlt %s)."
L["No answer while checking."] = "Keine Antwort beim Prüfen."
L["No answer from the auction house."] = "Keine Antwort vom Auktionshaus."
L["Quote expired."] = "Angebot abgelaufen."
L["The price has risen meanwhile. Not bought."] = "Der Preis ist inzwischen gestiegen. Nicht gekauft."
L["Quote: %d× for %s, vendor pays %s."] = "Angebot: %d× für %s, Händler zahlt %s."
L["No quote received."] = "Kein Angebot erhalten."
L["Bought: %s ×%d for %s (vendor pays %s)."] = "Gekauft: %s ×%d für %s (Händler zahlt %s)."
L["Bought."] = "Gekauft."
L["Purchase failed."] = "Kauf fehlgeschlagen."

-- Ignore list
L["Hidden: %s. /vfloor ignore clear shows it again."] = "Ausgeblendet: %s. /vfloor ignore clear blendet es wieder ein."
L["Ignore list cleared."] = "Sperrliste geleert."
L["Ignore list: %s"] = "Sperrliste: %s"
L["The ignore list is empty."] = "Die Sperrliste ist leer."

-- Commands
L["Minimum profit per unit: %s"] = "Mindestgewinn je Stück: %s"
L["Pause between rounds: %d seconds"] = "Pause zwischen zwei Runden: %d Sekunden"
L["Alert sound: %s"] = "Ton bei neuem Fund: %s"
L["on"] = "an"
L["off"] = "aus"
L["Window position reset."] = "Fensterposition zurückgesetzt."
L["Total: %d buys, spent %s, sold %s, profit %s, still to sell %s"] = "Gesamt: %d Käufe, ausgegeben %s, verkauft %s, Gewinn %s, noch zu verkaufen %s"
L["VendorFloor %s commands:"] = "VendorFloor %s – Befehle:"
L["/vfloor – show or hide the window"] = "/vfloor – Fenster ein- oder ausblenden"
L["/vfloor buy – check and buy the next find (also a key binding)"] = "/vfloor buy – nächsten Fund prüfen und kaufen (auch als Taste belegbar)"
L["/vfloor profit <amount> – minimum profit per unit, e.g. 5s"] = "/vfloor profit <Betrag> – Mindestgewinn je Stück, z. B. 5s"
L["/vfloor interval <seconds> – pause between rounds"] = "/vfloor interval <Sekunden> – Pause zwischen zwei Runden"
L["/vfloor sound – alert sound on or off"] = "/vfloor sound – Ton bei neuem Fund an oder aus"
L["/vfloor ignore list | clear – show or clear the ignore list"] = "/vfloor ignore list | clear – Sperrliste zeigen oder leeren"
L["/vfloor full – start a full scan (every 15 minutes)"] = "/vfloor full – Vollscan starten (alle 15 Minuten)"
L["/vfloor stats – totals since install"] = "/vfloor stats – Bilanz seit der Installation"
L["/vfloor forget – forget the purchases still to sell"] = "/vfloor forget – gemerkte, noch nicht verkaufte Käufe vergessen"
L["Tracked purchases cleared."] = "Gemerkte Käufe gelöscht."
L["/vfloor export – ledger to copy into bencepo.github.io/vendorfloor"] = "/vfloor export – Bilanz zum Kopieren nach bencepo.github.io/vendorfloor"
L["Press Ctrl+C, then paste it at %s. Esc closes."] = "Strg+C drücken, dann auf %s einfügen. Esc schließt."
L["Export failed: %s"] = "Export fehlgeschlagen: %s"
L["/vfloor minimap – minimap button on or off"] = "/vfloor minimap – Minimap-Knopf an oder aus"
L["Minimap button shown."] = "Minimap-Knopf eingeblendet."
L["Full scan %d%%"] = "Komplett-Scan %d%%"
L["Stop (%d)"] = "Stopp (%d)"
L["Full scan: waiting for the auction house"] = "Komplett-Scan: wartet auf das Auktionshaus"
L["Checking %d of %d (%d%%)"] = "Prüfe %d von %d (%d%%)"
L["Reading auctions: %d"] = "Lese Auktionen: %d"
L["Minimap button hidden."] = "Minimap-Knopf ausgeblendet."
L["Profit today"] = "Gewinn heute"
L["Profit total"] = "Gewinn gesamt"
L["Still to sell"] = "Noch zu verkaufen"
L["Left-click: ledger for bencepo.github.io/vendorfloor (at the auction house: window)"] = "Linksklick: Bilanz für bencepo.github.io/vendorfloor (am Auktionshaus: Fenster)"
L["Right-click: totals in chat"] = "Rechtsklick: Summen im Chat"
L["Drag: move. /vfloor minimap: hide or show"] = "Ziehen: verschieben. /vfloor minimap: aus- oder einblenden"
L["%d buys, profit %s, still to sell %s"] = "%d Käufe, Gewinn %s, noch zu verkaufen %s"
L["/vfloor reset – reset the window position"] = "/vfloor reset – Fensterposition zurücksetzen"
L["/vfloor options – open the settings"] = "/vfloor options – Einstellungen öffnen"

-- Settings and key binding
L["Alert sound"] = "Ton bei neuem Fund"
L["Play a sound when a new find appears."] = "Spielt einen Ton, wenn ein neuer Fund erscheint."
L["Continuous mode"] = "Dauerlauf"
L["Scan again automatically after each round."] = "Nach jeder Runde automatisch neu scannen."
L["Pause between rounds (seconds)"] = "Pause zwischen zwei Runden (Sekunden)"
L["How long continuous mode waits before the next round."] = "So lange wartet der Dauerlauf bis zur nächsten Runde."
L["Minimum profit per unit (silver)"] = "Mindestgewinn je Stück (Silber)"
L["How far below the vendor price an auction must be. Finer amounts can be typed into the window."] = "So viel muss eine Auktion unter dem Händlerpreis liegen. Feinere Beträge lassen sich im Fenster eintippen."
L["Buy next find"] = "Nächsten Fund kaufen"

-- Full scan
L["Full scan"] = "Vollscan"
L["Full scan (%s)"] = "Vollscan (%s)"
L["Reads every auction at once: complete, without checking each item."] = "Liest alle Auktionen auf einmal: vollständig, ohne Einzelprüfung."
L["The full scan is available every 15 minutes."] = "Den Vollscan erlaubt das Auktionshaus alle 15 Minuten."
L["Full scan: waiting for the auction house …"] = "Vollscan: warte auf das Auktionshaus …"
L["Full scan: reading %d of %d auctions …"] = "Vollscan: lese %d von %d Auktionen …"
L["Full scan: loading item data (%d left) …"] = "Vollscan: lade Gegenstandsdaten (noch %d) …"
L["Full scan done: %d auctions read, %d finds below vendor price."] = "Vollscan fertig: %d Auktionen gelesen, %d Funde unter Händlerpreis."
L["Full scan: the auction house did not answer. Try again in 15 minutes."] = "Vollscan: Das Auktionshaus hat nicht geantwortet. In 15 Minuten erneut versuchen."
L["%d new finds below vendor price."] = "%d neue Funde unter Händlerpreis."

-- Mail and merchant
L["Collect purchases (%d)"] = "Käufe abholen (%d)"
L["VendorFloor takes the items it bought out of the auction house mail."] = "VendorFloor holt die Gegenstände, die es gekauft hat, aus der Auktionshaus-Post."
L["Bags full. Collected %d items."] = "Taschen voll. %d Gegenstände abgeholt."
L["Collected %d items."] = "%d Gegenstände abgeholt."
L["Sell purchases (%d)"] = "Käufe verkaufen (%d)"
L["Sells the items VendorFloor bought, at most as many as it bought."] = "Verkauft die Gegenstände, die VendorFloor gekauft hat, höchstens so viele wie gekauft."
L["Sold %d items for %s (profit %s)."] = "%d Gegenstände für %s verkauft (Gewinn %s)."
L["Nothing to sell."] = "Nichts zu verkaufen."
