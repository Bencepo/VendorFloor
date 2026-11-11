# VendorFloor

Findet im Auktionshaus von **WoW Forever** Angebote, die unter dem Händlerpreis liegen, und kauft sie per Klick. Läuft eigenständig neben Auctionator.

*Finds auctions listed below vendor price in WoW Forever and buys them on click. Standalone, works alongside Auctionator.*

## Bedienung

- Auktionshaus öffnen: rechts daneben erscheint das VendorFloor-Fenster.
- **Scan** liest die Artikelliste und zeigt alles unter Händlerpreis, bester Gewinn zuerst.
- Fund anklicken (prüft die echten Auktionen), dann unten **Kaufen**.
- **Dauerlauf** scannt nach jeder Runde automatisch neu.
- **Mindestgewinn/Stück** (Feld oben rechts): so viel muss eine Auktion unter dem Händlerpreis liegen. Standard 1 Silber, Eingabe z. B. `50k`, `5s`, `1g 20s`, mit Enter bestätigen.

| Befehl | Wirkung |
| --- | --- |
| `/vfloor` | Fenster ein-/ausblenden |
| `/vfloor profit <Betrag>` | Mindestgewinn je Stück, z. B. `50k`, `5s`, `1g 20s` |
| `/vfloor interval <Sekunden>` | Pause zwischen zwei Runden |
| `/vfloor sound` | Ton bei neuem Fund an/aus |
| `/vfloor reset` | Fensterposition zurücksetzen |

## Hinweise

- Gekauft wird nur auf Mausklick, nie automatisch.
- Während einer Auctionator-Suche den Scan stoppen: beide Addons teilen sich die Abfragen des Auktionshauses.
- Status: frühe Version (0.1.0).

## Lizenz

Copyright (c) 2026 Bencepo. Alle Rechte vorbehalten, siehe [LICENSE](LICENSE).
