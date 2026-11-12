#!/usr/bin/env python3
# Noi OS – robuster Ersatz für das Calamares-Modul "automirror"
# (Original: calamares-settings-ubuntu-common, © 2018-2023 Simon Quigley, GPL-3+).
#
# Das Original brach die GESAMTE Installation mit
#     "Main Skriptdatei …/automirror/main.py … hat eine Ausnahme ausgelöst"
# ab, sobald irgendetwas Nebensächliches schiefging, z. B.:
#   * die Standortabfrage (GeoIP) liefert etwas Unerwartetes – Anmeldeseite
#     eines Hotel-/Gäste-WLANs, leere Antwort, abgebrochene Verbindung, Proxy
#   * /etc/apt/sources.list fehlt im Zielsystem
#   * das Python-Modul "distro" fehlt oder kennt den Codenamen nicht
#
# Diese Fassung schreibt dieselben Paketquellen, lässt die Installation aber
# nie an der Spiegelserver-Auswahl scheitern: Im Zweifel wird einfach der
# Hauptserver archive.ubuntu.com eingetragen.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

import json
import os
import re
import urllib.request
import xml.etree.ElementTree as ET
from time import strftime

import libcalamares

DEFAULT_BASE_URL = "archive.ubuntu.com"
DEFAULT_CODENAME = "noble"
GEOIP_TIMEOUT = 10  # Sekunden – das Original wartete bis zu 75

SUBDOMAINS_BY_COUNTRY_CODE = {
    "US": "us.", "AU": "au.", "SE": "no.", "NO": "no.",
    "NZ": "nz.", "NL": "nl.", "KR": "kr.", "DE": "de.",
    "GE": "ge.", "PF": "pf.", "CZ": "cz.", "HR": "hr.",
    # zusätzliche Länderspiegel (alle von Canonical unter XX.archive.ubuntu.com)
    "AT": "at.", "CH": "ch.", "FR": "fr.", "GB": "gb.", "IT": "it.",
    "ES": "es.", "PL": "pl.", "BE": "be.", "DK": "dk.", "FI": "fi.",
}

SOURCES_TEMPLATE = """# Automatisch vom Installer erzeugt am {date}.
# Basis: {distro} – Paketquellen von Ubuntu {codename}.
#
# Types:      "deb-src" ergänzen, um auch Quellpakete zu beziehen
# URIs:       Adresse des Spiegelservers
# Suites:     -updates = Fehlerkorrekturen, -backports = neuere Programmversionen
# Components: main/restricted/universe/multiverse
# Siehe sources.list(5).
Types: deb
URIs: {url}
Suites: {codename} {codename}-updates {codename}-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

## Sicherheitsupdates
Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: {codename}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
"""


def _warn(msg):
    try:
        libcalamares.utils.warning("automirror: {}".format(msg))
    except Exception:  # noqa: BLE001 – Protokollieren darf nie scheitern
        pass


def _config(key, default):
    try:
        value = libcalamares.job.configuration.get(key)
    except Exception:  # noqa: BLE001
        value = None
    return default if value in (None, "") else value


def get_country_code():
    """Ländercode (z. B. "DE") oder "" – wirft niemals eine Ausnahme."""
    try:
        if not libcalamares.globalstorage.value("hasInternet"):
            return ""
        geoip = _config("geoip", {}) or {}
        url = geoip.get("url")
        style = geoip.get("style", "xml")
        if not url:
            return ""
        with urllib.request.urlopen(url, timeout=GEOIP_TIMEOUT) as resp:
            data = resp.read(65536).decode("utf-8", "replace")
        if style == "json":
            code = json.loads(data).get("country_code")
        else:
            node = ET.fromstring(data).find("CountryCode")
            code = node.text if node is not None else None
        code = (code or "").strip().upper()
        return code if re.fullmatch(r"[A-Z]{2}", code) else ""
    except Exception as e:  # noqa: BLE001 – Standort ist nur Komfort
        _warn("Standort nicht ermittelbar ({}: {}) – nehme den Hauptserver"
              .format(type(e).__name__, e))
        return ""


def _os_release_value(path, key):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip().strip("\"'")
    except OSError:
        pass
    return ""


def get_codename(root_mount_point):
    """Ubuntu-Codename des Zielsystems (noble …), mit mehreren Rückfallebenen."""
    candidates = []
    for root in (root_mount_point, ""):
        for rel in ("/etc/os-release", "/usr/lib/os-release"):
            for key in ("UBUNTU_CODENAME", "VERSION_CODENAME"):
                candidates.append(_os_release_value(root + rel, key))
    try:
        import distro
        candidates.append(distro.codename())
    except Exception:  # noqa: BLE001 – python3-distro ist optional
        pass
    for c in candidates:
        c = (c or "").strip().lower()
        if re.fullmatch(r"[a-z]+", c):
            return c
    _warn("Codename nicht ermittelbar – nehme '{}'".format(DEFAULT_CODENAME))
    return DEFAULT_CODENAME


def run():
    root_mount_point = libcalamares.globalstorage.value("rootMountPoint") or ""
    base = str(_config("baseUrl", DEFAULT_BASE_URL)).strip().strip("/")
    base = re.sub(r"^https?://", "", base) or DEFAULT_BASE_URL

    subdomain = SUBDOMAINS_BY_COUNTRY_CODE.get(get_country_code(), "")
    base_url = "http://{}{}/ubuntu".format(subdomain, base)
    codename = get_codename(root_mount_point)

    try:
        apt_dir = os.path.join(root_mount_point, "etc/apt")
        os.makedirs(os.path.join(apt_dir, "sources.list.d"), exist_ok=True)
        sources = SOURCES_TEMPLATE.format(
            date=strftime("%Y-%m-%d"),
            distro=_config("distribution", "Ubuntu"),
            url=base_url, codename=codename)
        with open(os.path.join(apt_dir, "sources.list.d/ubuntu.sources"), "w",
                  encoding="utf-8") as f:
            f.write(sources)
        # Alte einzeilige Liste entfernen (falls vorhanden) – sonst doppelte Quellen
        try:
            os.remove(os.path.join(apt_dir, "sources.list"))
        except FileNotFoundError:
            pass
    except OSError as e:
        # Die Quellen aus dem Live-Abbild sind bereits gültig – weiter installieren
        _warn("Paketquellen nicht neu geschrieben ({}) – behalte die vorhandenen"
              .format(e))

    libcalamares.globalstorage.insert("mirrorURL", base_url)
    libcalamares.globalstorage.insert("ubuntuCodename", codename)
    return None
