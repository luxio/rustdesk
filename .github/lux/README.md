# Eigener macOS-Client für rd.lux.io

Dieser Fork weicht vom Upstream in genau drei Dateien ab:

```
.github/workflows/lux-macos.yml     Build-Job, abgeleitet aus flutter-build.yml (Tag 1.4.9)
.github/lux/patch-server-config.py  backt Serveradresse und Key in den Client
.github/lux/README.md               diese Datei
```

Der Rest ist unveränderter RustDesk 1.4.9. Das ist Absicht: je kleiner die
Abweichung, desto einfacher ist das Nachziehen auf ein neues Upstream-Release.

## Was der Patch macht

`libs/hbb_common/src/config.rs` enthält die Fallback-Werte, die der Client
benutzt, solange keine eigene Konfiguration hinterlegt ist:

```rust
pub const RENDEZVOUS_SERVERS: &[&str] = &["rs-ny.rustdesk.com"];
pub const RS_PUB_KEY: &str = "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=";
```

Der Patch ersetzt beide durch `rd.lux.io` und unseren Public Key. Ein frisch
installierter Client ist damit ohne Zutun des Kunden richtig eingestellt — kein
Entsperren der Netzwerkeinstellungen, kein Konfigstring. Die beiden
TCC-Freigaben (Bedienungshilfen, Bildschirmaufnahme) bleiben unvermeidlich.

Der Vergleich ist ein exakter Textvergleich. Ändert Upstream diese Zeilen,
bricht der Build ab, statt still einen Client zu bauen, der gegen
`rs-ny.rustdesk.com` läuft.

## Secrets einrichten

Unter *Settings → Secrets and variables → Actions* im Fork anlegen. Ohne
`MACOS_P12_BASE64` läuft der Build durch und liefert ein **unsigniertes** DMG —
zum Testen brauchbar, beim Kunden blockt Gatekeeper es.

### MACOS_CODESIGN_IDENTITY

```bash
security find-identity -v -p codesigning
```

Der Wert ist der Name in Anführungszeichen, z. B.
`Developer ID Application: Stephane Lux (24B9N35YSF)`. Nicht die Development-,
sondern die **Developer ID Application**-Identität — nur die taugt zur
Verteilung außerhalb des App Store.

### MACOS_P12_BASE64 und MACOS_P12_PASSWORD

Schlüsselbundverwaltung öffnen, unter *Meine Zertifikate* die Developer-ID
aufklappen (das Dreieck — der private Schlüssel muss mit exportiert werden),
Rechtsklick → *Exportieren* → Format „Persönlicher Informationsaustausch
(.p12)", Passwort vergeben. Dann:

```bash
base64 -i DeveloperID.p12 | pbcopy
```

Der Inhalt der Zwischenablage ist `MACOS_P12_BASE64`, das vergebene Passwort
ist `MACOS_P12_PASSWORD`.

### MACOS_NOTARIZE_JSON

Braucht einen App-Store-Connect-API-Key: appstoreconnect.apple.com →
*Users and Access* → *Integrations* → *App Store Connect API* → Key erzeugen
(Rolle *Developer* genügt). Die `.p8`-Datei lässt sich nur einmal laden. Issuer
ID und Key ID stehen auf derselben Seite.

```bash
brew install rcodesign
rcodesign encode-app-store-connect-api-key -o notarize.json <issuer-id> <key-id> AuthKey_<key-id>.p8
base64 -i notarize.json | pbcopy
```

Die drei Dateien (`.p12`, `.p8`, `notarize.json`) danach sicher ablegen oder
löschen — sie sind Zugang zu deinem Entwicklerkonto.

## Bauen

*Actions → lux macOS-Client → Run workflow*.

`lux-1.4.9` ist der Default-Branch dieses Forks. Das muss so bleiben:
GitHub blendet `workflow_dispatch` nur ein, wenn die Workflow-Datei im
Default-Branch liegt. Alle geerbten Upstream-Workflows sind deaktiviert —
sonst würde der geerbte Nightly-Cron einen kompletten Multi-Plattform-Build
auslösen. Aktiv sind nur *lux macOS-Client* und *Build flutter-rust-bridge*,
letzterer wird vom Build aufgerufen.

Läuft rund eine Stunde (vcpkg baut ffmpeg, aom, libvpx; ab dem zweiten Lauf
greift der Cache). Ergebnis sind zwei Artefakte:

```
rustdesk-lux-macos-aarch64   Apple Silicon
rustdesk-lux-macos-x86_64    Intel
```

Beide auf den Server legen und in `web/site/index.html` verlinken:

```bash
scp rustdesk-lux-1.4.9-*.dmg deploy@docker1.lux.io:/opt/docker/support/site/downloads/
```

## Auf ein neues Upstream-Release nachziehen

```bash
git fetch upstream --tags
git checkout -b lux-<neue-version> <neue-version>
git checkout lux-1.4.9 -- .github/workflows/lux-macos.yml .github/lux/
# VERSION im Workflow anpassen, ebenso die Toolchain-Pins aus dem neuen
# flutter-build.yml (MAC_RUST_VERSION, FLUTTER_VERSION, VCPKG_COMMIT_ID)
git push fork lux-<neue-version>
gh api -X PATCH repos/luxio/rustdesk -f default_branch=lux-<neue-version>
```

Der Patch-Schritt sagt beim Build von selbst Bescheid, falls Upstream die
Konstanten verschoben hat.

## AGPL

RustDesk steht unter AGPL-3.0. Wird ein geändertes Binary weitergegeben, muss
der zugehörige Quellcode angeboten werden. Dieser Fork ist öffentlich; auf
support.lux.io gehört ein Link darauf. Der Hinweis dort, es werde die
„unveränderte Originalversion" ausgeliefert, stimmt für das macOS-DMG dann
nicht mehr und muss umformuliert werden.
