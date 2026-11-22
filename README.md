# FreeNotes

Eine kostenlose, quelloffene Handschrift-Notiz-App für Windows, Linux (Ubuntu), Android und iPhone.
Schreiben mit Stift, Maus oder Finger, PDFs beschriften und alles automatisch auf
der eigenen NAS sichern. Kein Abo, kein Konto, keine Cloud eines Anbieters.

![App-Icon](assets/icon/icon.png)

## Funktionen

- **7 Stifte:** Kugelschreiber, Füller, Fineliner, Pinsel, Kalligrafie (breite Feder), Bleistift und Textmarker (auf Wunsch mit geraden Linien); drucksensitiv mit Stylus (z. B. Surface Pen), je 3 Stärken
- **Lieblingsstifte:** Stift, Farbe und Stärke mit dem Stern speichern und mit einem Tipp wieder wählen
- **Farben:** Schnellfarben pro Stift plus eine Palette mit 18 Farben
- **Formen:** Kreis, Ellipse, Linie, Rechteck, Dreieck oder Vieleck grob zeichnen, FreeNotes macht eine saubere Form daraus
- **Lasso:** Geschriebenes einkreisen oder antippen, dann verschieben, größer/kleiner machen, umfärben, kopieren, ausschneiden, einfügen, duplizieren oder löschen
- **Radierer:** ganze Striche oder **genau** nur das, was er berührt; auf Wunsch nur Textmarker; 3 Größen; die Radierer-Seite eines Stylus funktioniert auch
- **Laserpointer** zum Zeigen, die Spur verblasst von selbst
- **Text und Bilder** auf der Seite einfügen, mit dem Lasso verschieben und vergrößern
- **PDF importieren** und direkt darauf schreiben
- **Scharfe PDFs bei jedem Zoom:** Text-PDFs werden beim Hineinzoomen neu und gestochen scharf berechnet. Bei **eingescannten** PDFs schärft FreeNotes die Kanten der Buchstaben nach, damit sie auch stark vergrößert gut lesbar bleiben
- **PDF-Export:** das ganze Notizbuch als PDF speichern, die Handschrift als scharfe Vektoren
- **Seitenübersicht:** alle Seiten als Miniaturen, per Ziehen umsortieren, duplizieren, löschen
- **Unendliches Blatt:** ein einziges Blatt ohne Ränder, auf das der Inhalt von über 1000 Seiten passt; bleibt dank Bild-Kacheln (wie bei einer Online-Karte) auch dann flüssig
- **Zoomen und Verschieben:** zwei Finger (mit Schwung), Touchpad, Strg + Mausrad, Strg + Plus/Minus, rechte Maustaste ziehen; A4-Seiten bis 3000 %, das unendliche Blatt von 0,2 % bis 20 000 %
- **Strichstärke passt sich dem Zoom an:** hineingezoomt schreibt der Stift automatisch feiner, die Linie sieht am Bildschirm immer gleich dick aus
- **Notizbücher** mit farbigen Covern, in **Ordnern** sortiert
- **Papier:** blanko, liniert, kariert oder punktiert, pro Seite wählbar
- **Suche** nach Notizbuch-Namen und getipptem Text
- **Rückgängig / Wiederholen** pro Seite
- **Handballen-Erkennung:** Sobald ein Stylus benutzt wurde, zeichnen Finger nicht mehr, sondern zoomen und verschieben
- **Automatisches Speichern** lokal und auf der **NAS (WebDAV)**, auch zwischen mehreren Geräten; ein **NAS-Assistent** findet die NAS im Heimnetz von selbst
- **Schneller Kern in Rust:** Speichern, Laden, Strich-Berechnung, Radierer- und Lasso-Suche, das Zeichnen des unendlichen Blatts und das Schärfen von Scans laufen in Rust, verteilt auf alle Prozessorkerne

### Geschwindigkeit: 1.3 (Rust-Kern) gegenüber 1.2

Gemessen mit `benchmark/endless_bench_test.dart`: ein unendliches Blatt mit dem Inhalt von
1000 A4-Seiten (120 000 Striche, 4,8 Millionen Punkte) auf einem Laptop.

| Vorgang | 1.2 | 1.3 |
|---|---|---|
| Speichern | 2,3 s | 0,2 s |
| Öffnen | 0,95 s | 0,19 s |
| Dateigröße | 92,7 MB | 7,7 MB |
| Ganzes Blatt zeichnen (herausgezoomt) | 1061 ms | 86 ms |
| Kacheln beim Zoomen | 256 ms | 165 ms |
| Radierer: berührte Striche finden | 6,9 ms | 1,0 ms |

## Installieren

Alle Dateien gibt es auf der Seite **[Neueste Version](../../releases/latest)**.

> **Update auf 1.3:** FreeNotes 1.3 speichert Notizbücher in einem neuen, rund 10× kleineren Format.
> Ältere Versionen können diese Dateien nicht öffnen. Bitte **alle Geräte**, die mit derselben NAS
> synchronisieren, auf 1.3 aktualisieren. Notizbücher aus älteren Versionen öffnet 1.3 ohne Weiteres.

### Windows

1. `FreeNotes-Setup-x.y.z.exe` laden und ausführen. Es sind keine Administratorrechte nötig. Windows zeigt eventuell „Der Computer wurde durch Windows geschützt“, weil der Installer nicht signiert ist: **Weitere Informationen → Trotzdem ausführen**.
2. **An die Taskleiste heften:** Startmenü öffnen, **FreeNotes** suchen, Rechtsklick → **An Taskleiste anheften**.

Deinstallieren über *Einstellungen → Apps*. Deine Notizen bleiben dabei erhalten.

### Linux (Ubuntu 22.04 und neuer)

1. `freenotes_x.y.z_amd64.deb` laden.
2. Installieren: Doppelklick auf die Datei, oder im Terminal im Download-Ordner:
   ```bash
   sudo apt install ./freenotes_*_amd64.deb
   ```
3. FreeNotes im App-Menü starten. **Ans Dock heften:** Rechtsklick auf das Symbol → **Zu Favoriten hinzufügen**.

Deinstallieren: `sudo apt remove freenotes`. Die Notizen in `~/Dokumente/FreeNotes` bleiben erhalten.

### Android

1. Am Handy im Browser die Seite **[Neueste Version](../../releases/latest)** öffnen und `FreeNotes-x.y.z.apk` antippen.
2. Die heruntergeladene Datei öffnen. Android fragt, ob der Browser Apps installieren darf: **Einstellungen → Aus dieser Quelle zulassen**, zurück, **Installieren**.
3. Falls Google Play Protect warnt („Unbekannte App“): **Weitere Details → Trotzdem installieren**. Die Warnung kommt, weil FreeNotes nicht aus dem Play Store stammt.

**Update:** neue `.apk` genauso installieren. Die Notizen bleiben erhalten.

### iPhone / iPad

Apple erlaubt Apps außerhalb des App Stores nur mit Umweg. Der kostenlose Weg ist **AltStore** mit deiner
normalen Apple-ID. Du brauchst dafür einmalig einen Windows-PC oder Mac.

**Einmalig einrichten (am PC):**
1. **iTunes** und **iCloud** direkt von apple.com installieren (nicht aus dem Microsoft Store).
2. **AltServer** von [altstore.io](https://altstore.io) installieren und starten (Symbol unten rechts in der Taskleiste).
3. iPhone per Kabel anschließen und „Diesem Computer vertrauen“ bestätigen. In iTunes beim iPhone **„Mit diesem iPhone über WLAN synchronisieren“** einschalten.
4. AltServer-Symbol anklicken → **Install AltStore** → dein iPhone → mit deiner Apple-ID anmelden.
5. Am iPhone: *Einstellungen → Allgemein → VPN & Geräteverwaltung* → deine Apple-ID → **Vertrauen**. Unter *Einstellungen → Datenschutz & Sicherheit* den **Entwicklermodus** einschalten (iPhone startet neu).

**FreeNotes installieren:**
1. Am iPhone in Safari die Seite **[Neueste Version](../../releases/latest)** öffnen und `FreeNotes-vx.y.z.ipa` laden.
2. **AltStore** öffnen → *Meine Apps* → **+** → die `.ipa`-Datei wählen.

**Wichtig:** Mit einer kostenlosen Apple-ID läuft die App 7 Tage. AltStore verlängert sie automatisch, wenn
iPhone und PC (mit laufendem AltServer) im selben WLAN sind. Alternativ in AltStore auf **Aktualisieren** tippen.
Mit einem Apple-Entwicklerkonto (99 €/Jahr) ginge es ohne Ablauf über TestFlight.

Beim ersten Suchen nach der NAS fragt das iPhone, ob FreeNotes Geräte im lokalen Netzwerk finden darf: **Erlauben**.

## Bedienung

| Aktion | So geht's |
|---|---|
| Zoomen | zwei Finger, Touchpad-Pinch oder **Strg + Mausrad** |
| Verschieben | Mausrad (mit **Umschalt** waagrecht), rechte Maustaste ziehen, zwei Finger |
| Ganze Seite / alles zeigen | **Strg + 0** oder Knopf *Ganze Seite zeigen* |
| Stufenweise zoomen | **Strg + Plus** / **Strg + Minus** |
| Rückgängig / Wiederholen | **Strg + Z** / **Strg + Y** |
| Seite blättern | **←** / **→** |
| Auswählen | Lasso-Werkzeug: Geschriebenes einkreisen, oder einen Strich, Text oder ein Bild antippen |
| Auswahl verschieben / Größe ändern | in die Auswahl tippen und ziehen / am blauen Punkt unten rechts ziehen |
| Kopieren, Ausschneiden, Einfügen, Duplizieren | **Strg + C**, **Strg + X**, **Strg + V**, **Strg + D** oder die Knöpfe in der Werkzeugleiste |
| Auswahl löschen / aufheben | **Entf** / **Esc** |
| Saubere Form | Formen-Werkzeug, Form grob zeichnen und loslassen |
| Text einfügen | Text-Werkzeug wählen, auf die Seite tippen |
| Seiten ordnen | Seitenübersicht (Kachel-Symbol, am Handy im Menü ⋮), Seite an die neue Stelle ziehen |
| Als PDF speichern | Menü ⋮ → *Als PDF exportieren* |

## Wo liegen meine Notizen?

Lokal in **Dokumente\FreeNotes**:

```
library.json          Ordner und Liste der Notizbücher
notebooks\<id>.json   Seiten eines Notizbuchs (ab 1.3 in einem kompakten Binärformat, trotz der Endung)
assets\               importierte PDFs und Bilder
```

**Anderen Speicherort wählen** (z. B. ein zweites Laufwerk): Zahnrad → *Speicherort ändern…*. FreeNotes
verschiebt alle Notizen in einen Ordner `FreeNotes` am neuen Ort, löscht die alte Kopie erst, wenn alles
geprüft kopiert ist, und startet neu. Ist das Laufwerk später nicht angeschlossen, meldet FreeNotes das,
statt mit einem leeren Ordner zu starten.

Jede Änderung wird nach weniger als einer Sekunde gespeichert. Es wird zuerst in eine
Zwischendatei geschrieben und dann ausgetauscht, sodass ein Absturz nie eine halbe Datei hinterlässt.

## NAS-Synchronisierung (WebDAV)

FreeNotes speichert deine Notizbücher zusätzlich auf deiner NAS und gleicht sie zwischen
Geräten ab: beim Start, alle 2 Minuten, beim Schließen eines Notizbuchs und beim Beenden.

**Einrichten mit dem Assistenten (empfohlen):**
1. Auf der NAS **WebDAV** einschalten, am besten mit **HTTPS** (bei UGREEN: *Systemsteuerung → Dateidienste → WebDAV*, HTTPS-Port 5006).
   Findet der Assistent eine NAS, auf der WebDAV noch aus ist, zeigt er diese Schritte ebenfalls an.
2. In FreeNotes: Zahnrad → **NAS automatisch finden und verbinden**.
3. Die gefundene NAS antippen, mit deinem NAS-Konto anmelden, einen Ordner wählen → **Hier speichern**. Fertig.

Der Assistent sucht im eigenen Heimnetz (alle Adressen x.y.z.1 bis 254) nach WebDAV (Port 5005/5006) und den
Weboberflächen von UGREEN (9999) und Synology (5000/5001). Liegt die NAS in einem anderen Netz, geht es von Hand:

**Von Hand:** Zahnrad → *Einstellungen*
- **WebDAV-Adresse:** `https://NAS-IP:HTTPS-PORT/Freigabe/FreeNotes`
- **Benutzername / Passwort:** dein NAS-Konto (am besten ein eigenes Konto nur mit Zugriff auf diesen Ordner)
- **Eigenes Zertifikat der NAS akzeptieren:** einschalten, wenn die NAS ihr Standard-Zertifikat benutzt
- **Speichern und testen**

**Sicherheit:** Beim Einrichten mit dem Assistenten merkt sich FreeNotes das Zertifikat deiner NAS und akzeptiert
danach nur noch genau dieses. Ein anderes Gerät, das sich als deine NAS ausgibt, bekommt so dein Passwort nicht.
Wird das Zertifikat der NAS erneuert, den Assistenten einfach noch einmal ausführen.

Adresse und Benutzername liegen nur auf deinem Gerät (im App-Datenordner). Das Passwort liegt im sicheren
Speicher des Systems (Windows-Anmeldeinformationsverwaltung, Android-Keystore, iOS-Schlüsselbund,
Linux-Schlüsselbund). Nichts davon ist im Code oder in diesem Repository.

**Wenn auf zwei Geräten dasselbe Notizbuch geändert wurde**, bevor sie synchronisiert haben,
bleiben beide Versionen erhalten: Die NAS-Version erscheint als Kopie „Name (Konflikt)“.

## Selbst bauen

Voraussetzungen: [Flutter](https://docs.flutter.dev/get-started/install/windows), [Rust](https://rustup.rs),
Visual Studio Build Tools 2022 mit *Desktopentwicklung mit C++* und der Komponente *C++ ATL*, Windows-Entwicklermodus,
[Inno Setup 6](https://jrsoftware.org/isinfo.php) (nur für den Installer).

> Den Projektordner an einem Ort mit **kurzem Pfad** ablegen (z. B. `C:\dev\freenotes`).
> Bei sehr langen Pfaden scheitert der Build des PDF-Moduls an der Windows-Pfadgrenze.

```bash
flutter pub get
cargo build --release --manifest-path rust/Cargo.toml   # Rust-Kern für die Tests
flutter test
flutter run -d windows
```

`flutter run` und `flutter build` bauen den Rust-Kern automatisch mit. Rust-Tests:
`cargo test --manifest-path rust/Cargo.toml`. Nach Änderungen an der Rust-Schnittstelle (`rust/src/api/`)
die Dart-Anbindung in `lib/src/rust/` neu erzeugen:

```bash
cargo install flutter_rust_bridge_codegen --version 2.13.0
flutter_rust_bridge_codegen generate
```

Installer bauen (Ergebnis in `dist\`):

```bash
powershell -ExecutionPolicy Bypass -File tool/build_installer.ps1
```

**Android-APK** (braucht zusätzlich das Android-SDK mit NDK, z. B. über Android Studio):

```bash
flutter build apk --release
```

Ohne eigene `android/key.properties` wird mit dem Debug-Schlüssel signiert. Für Updates über eine
installierte Version muss immer derselbe Schlüssel verwendet werden.

**iPhone und Linux:** werden automatisch von GitHub Actions gebaut (`.github/workflows/ios.yml` auf einem Mac,
`.github/workflows/linux.yml` auf Ubuntu), sobald ein Versions-Tag (`v…`) gepusht wird. `.ipa` und `.deb` landen am Release.

App-Icon ändern: `tool/make_icon.py` anpassen, dann `python tool/make_icon.py` und `dart run flutter_launcher_icons`.

## Projektaufbau

| Datei | Inhalt |
|---|---|
| `lib/main.dart` | App-Start, Speichern beim Beenden |
| `lib/model.dart` | Datenmodell: Notizbuch, Seite, Strich, Text, Bild, Ordner; Dateiformat |
| `lib/ink.dart` | Stifttypen, Strich-Darstellung, Papier |
| `lib/scene.dart` | Striche einer Seite im Rust-Kern: Suche für Radierer und Lasso, Kacheln zeichnen |
| `lib/tiles.dart` | Bild-Kacheln für das unendliche Blatt (flüssig auch bei 1000 Seiten Inhalt) |
| `lib/pdf_detail.dart` | PDF scharf beim Hineinzoomen: Text-PDFs neu berechnen, Scans nachschärfen |
| `lib/pdf_export.dart` | Notizbuch als PDF exportieren |
| `lib/page_overview.dart` | Seitenübersicht: Miniaturen, umsortieren, duplizieren, löschen |
| `lib/prefs.dart` | Lieblingsstifte |
| `lib/store.dart` | Lokales Speichern (automatisch, absturzsicher) |
| `lib/sync.dart` | WebDAV-Synchronisierung mit der NAS, Zertifikat-Prüfung |
| `lib/nas_wizard.dart` | NAS-Assistent: NAS im Heimnetz finden, anmelden, Ordner wählen |
| `lib/library_screen.dart` | Startseite: Ordner, Notizbücher, Suche, PDF-Import |
| `lib/editor_screen.dart` | Editor: Stifte, Formen, Lasso, Radierer, Laser, Zoomen, Text, Bilder, Seiten |
| `lib/settings_screen.dart` | NAS-Einstellungen, Speicherort |
| `lib/src/rust/` | Automatisch erzeugte Dart-Anbindung an den Rust-Kern (nicht von Hand ändern) |
| `rust/src/freehand.rs` | Strich-Umrisse (perfect-freehand-Algorithmus) und Kalligrafie-Feder |
| `rust/src/api/ink.rs` | Stifte, Formerkennung, genaues Radieren |
| `rust/src/api/codec.rs` | Kompaktes Speicherformat der Striche, JPEG für den PDF-Export |
| `rust/src/api/scene.rs` | Räumlicher Index (R-Baum) für Radierer/Lasso, Kacheln zeichnen auf allen Kernen |
| `rust/src/api/scan.rs` | Schärfen eingescannter PDF-Seiten beim Zoomen |
| `rust_builder/` | Baut den Rust-Kern automatisch in jede App mit (cargokit) |
| `test/` | Tests für Sync, Radierer, Lasso, Formen, Speicherformat, Zertifikat, Speicherort-Wechsel, Kacheln |
| `benchmark/` | Messungen: 1000 A4-Seiten auf einem unendlichen Blatt, Scan-Schärfung, PDF-Export |
| `installer/`, `tool/` | Windows-Installer, Build-Skript, Icon-Generator |
| `.github/workflows/` | Baut die iPhone-App und die Linux-App (.deb) auf GitHub |

## Grenzen

- **Eingescannte PDFs:** Die Schärfung macht die Kanten der Buchstaben scharf, kann aber keine Details erfinden,
  die im Scan nicht vorhanden sind. Sehr kleine Schrift in groben Scans bleibt grob.
- **PDF-Export:** Importierte PDF-Seiten werden als Bild (216 dpi) eingebettet, nicht als Original-Vektoren.
- Noch nicht enthalten: Handschrifterkennung (Handschrift durchsuchen oder in Text umwandeln),
  Installation über Play Store / App Store.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Die Strich-Berechnung ist eine Portierung von
[perfect-freehand](https://github.com/steveruizok/perfect-freehand) (MIT, Stephen Ruiz; Dart-Version Adil Hanney);
der Lizenzhinweis steht in `rust/src/freehand.rs`.
