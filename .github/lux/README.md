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

### MACOS_NOTARY_APPLE_ID, MACOS_NOTARY_TEAM_ID, MACOS_NOTARY_PASSWORD

Für die Notarisierung. `MACOS_NOTARY_APPLE_ID` ist die Apple-ID (E-Mail),
`MACOS_NOTARY_TEAM_ID` die Team-ID aus der Klammer der Signatur-Identität
(z. B. `24B9N35YSF`).

`MACOS_NOTARY_PASSWORD` ist ein **app-spezifisches Passwort**, kein
Apple-ID-Passwort: appleid.apple.com → *Anmelden und Sicherheit* →
*App-spezifische Passwörter* → erzeugen. Das Ding lässt sich einzeln
widerrufen und kann nichts außer Notarisierung.

Der Upstream-Workflow benutzt an dieser Stelle `rcodesign` mit einem
App-Store-Connect-API-Key. Hier steht stattdessen `xcrun notarytool`: es liegt
auf dem Runner ohnehin bei, und ein app-spezifisches Passwort ist schneller
erzeugt und weniger mächtig als ein API-Key mit Developer-Rolle.

Fehlen diese drei, wird signiert aber nicht notarisiert. Gatekeeper zeigt dann
beim ersten Start eine Warnung — für Kunden am Telefon keine gute Idee.

## Secrets per Kommandozeile setzen

Statt über die Weboberfläche geht es auch so, dann steht der Wert nirgends im
Browser:

```bash
gh secret set MACOS_P12_BASE64        --repo luxio/rustdesk < <(base64 -i DeveloperID.p12)
gh secret set MACOS_P12_PASSWORD      --repo luxio/rustdesk    # fragt interaktiv
gh secret set MACOS_NOTARY_PASSWORD   --repo luxio/rustdesk    # fragt interaktiv
gh secret set MACOS_NOTARY_APPLE_ID   --repo luxio/rustdesk
gh secret set MACOS_NOTARY_TEAM_ID    --repo luxio/rustdesk
```

## Sind Secrets in einem öffentlichen Repo sicher?

Ja, mit einer Einschränkung. Workflows aus fremden Forks bekommen die Secrets
grundsätzlich nicht, und `workflow_dispatch` kann nur auslösen, wer
Schreibrechte hat. Wer Schreibrechte hat, kann die Werte allerdings über einen
eigenen Workflow-Schritt auslesen — das bist nur du. Deshalb sind auch alle
geerbten Upstream-Workflows deaktiviert: würdest du Upstream-Änderungen an
Workflow-Dateien übernehmen, liefe fremder Code mit Zugriff auf diese Secrets.

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

## Lokal bauen statt auf CI

`./.github/lux/build-local.sh` führt dieselben Schritte auf diesem Rechner aus.
Der Punkt dabei: Zertifikat und Notarisierungsschlüssel bleiben im Schlüsselbund
und müssen nicht als Secret zu GitHub. Findet das Skript eine
`Developer ID Application`-Identität, signiert es von selbst.

```bash
./.github/lux/build-local.sh              # signiert, wenn eine Developer-ID da ist
./.github/lux/build-local.sh --no-sign    # unsigniert, zum Ausprobieren
./.github/lux/build-local.sh --notarize <profil>
```

Für `--notarize` einmalig ein notarytool-Profil im Schlüsselbund anlegen:

```bash
xcrun notarytool store-credentials <profil> \
  --apple-id <mail> --team-id <team> --password <app-spezifisches-passwort>
```

Voraussetzungen: Xcode Command Line Tools, Homebrew, rustup. Das Flutter-SDK
lädt das Skript sich selbst nach `.lux-build/` (rund 1,5 GB, einmalig) — deine
Systeminstallation von Flutter bleibt unangetastet, denn der Build patcht das
SDK an zwei Stellen, und das soll dir nicht im Alltag hängenbleiben. Ebenso
vcpkg. `.lux-build/` kann danach gelöscht werden.

Das Skript verlangt ein sauberes Arbeitsverzeichnis und nimmt alle Baupatches
(Serverkonfiguration, Deployment-Target, pubspec) am Ende wieder zurück — auch
wenn es unterwegs abbricht. Zum Schluss prüft es, ob die Serveradresse
tatsächlich im Binary steht.

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
