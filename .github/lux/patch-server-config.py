#!/usr/bin/env python3
"""Backt Serveradresse und Public Key fest in den Client.

Der Client liest beides zur Laufzeit aus der Konfiguration; fehlt sie, fällt er
auf zwei Konstanten in `libs/hbb_common/src/config.rs` zurück. Genau die werden
hier ersetzt — dann ist der frisch installierte Client ohne jedes Zutun des
Kunden auf unseren Server eingestellt.

Absichtlich ein exakter Textvergleich statt einer Regex: ändert Upstream die
Zeilen, bricht der Build hier ab, statt still einen Client zu bauen, der gegen
rs-ny.rustdesk.com läuft.
"""
import os
import pathlib
import sys

HOST = os.environ["LUX_RENDEZVOUS_SERVER"]
KEY = os.environ["LUX_RS_PUB_KEY"]

path = pathlib.Path("libs/hbb_common/src/config.rs")
if not path.exists():
    sys.exit(f"{path} fehlt — wurden die Submodule ausgecheckt?")

src = path.read_text()
ersetzungen = [
    (
        'pub const RENDEZVOUS_SERVERS: &[&str] = &["rs-ny.rustdesk.com"];',
        f'pub const RENDEZVOUS_SERVERS: &[&str] = &["{HOST}"];',
    ),
    (
        'pub const RS_PUB_KEY: &str = "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=";',
        f'pub const RS_PUB_KEY: &str = "{KEY}";',
    ),
]

for alt, neu in ersetzungen:
    if alt not in src:
        sys.exit(
            "Ankerzeile nicht gefunden, Upstream hat sie geändert:\n"
            f"  erwartet: {alt}\n"
            "Bitte patch-server-config.py an die neue Zeile anpassen."
        )
    src = src.replace(alt, neu, 1)

path.write_text(src)

print("Serverkonfiguration eingebacken:")
for zeile in path.read_text().splitlines():
    if "RENDEZVOUS_SERVERS" in zeile or "RS_PUB_KEY" in zeile:
        print("  " + zeile.strip())
