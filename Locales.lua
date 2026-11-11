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
L["Session: %d buys, spent %s, vendor value %s, profit %s"] = "Sitzung: %d Käufe, ausgegeben %s, Händlerwert %s, Gewinn %s"

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
L["Total: %d buys, spent %s, vendor value %s, profit %s"] = "Gesamt: %d Käufe, ausgegeben %s, Händlerwert %s, Gewinn %s"
L["VendorFloor %s commands:"] = "VendorFloor %s – Befehle:"
L["/vfloor – show or hide the window"] = "/vfloor – Fenster ein- oder ausblenden"
L["/vfloor buy – check and buy the next find (also a key binding)"] = "/vfloor buy – nächsten Fund prüfen und kaufen (auch als Taste belegbar)"
L["/vfloor profit <amount> – minimum profit per unit, e.g. 5s"] = "/vfloor profit <Betrag> – Mindestgewinn je Stück, z. B. 5s"
L["/vfloor interval <seconds> – pause between rounds"] = "/vfloor interval <Sekunden> – Pause zwischen zwei Runden"
L["/vfloor sound – alert sound on or off"] = "/vfloor sound – Ton bei neuem Fund an oder aus"
L["/vfloor ignore list | clear – show or clear the ignore list"] = "/vfloor ignore list | clear – Sperrliste zeigen oder leeren"
L["/vfloor stats – totals since install"] = "/vfloor stats – Bilanz seit der Installation"
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
