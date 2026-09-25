# Photon Studio auf Proxmox (LXC, Community-Scripts-Stil)

[Photon Studio](https://tenzen.studio/photon/) (Tenzen Studio) ist ein **Desktop**-Bildeditor
(Layers, Retusche, PSD-Support, alles lokal) — kein Web-Server. Dieses Repo installiert ihn als
**LXC-Container auf Proxmox** und macht ihn im lokalen Netzwerk per **Web-Desktop (KasmVNC)**
im Browser bedienbar: `http://[LXC-IP]:8080`.

Linux-Build: offizielles Flatpak direkt von Tenzen
(`https://tenzen.studio/api/v1/photon/download?platform=linux&arch=x64`, folgt Redirect auf die
aktuelle Version, z. B. `0.1.21`, ~270 MB).

## Installation (Einzeiler, auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PhotonPhotoEditorProxmox/main/install/photon.sh)"
```

Das Script:
- nimmt automatisch die **nächste freie CT-ID** (`pvesh get /cluster/nextid`), Name `photon`
- erstellt einen Ubuntu-24.04-LXC (Standard: **2 vCPU / 2 GB RAM / 10 GB Disk**, `onboot: 1`,
  `nesting=1,keyctl=1,fuse=1` für Flatpak)
- installiert Flatpak + Photon + Openbox + KasmVNC im Container
- richtet den systemd-Service `kasmvnc` ein (`enable`, `Restart=always`)
- prüft selbst: Service aktiv + Web UI antwortet — und gibt die finale URL + VNC-Passwort aus

### Optionen (Env-Variablen)

```bash
CTID=150 CT_HOSTNAME=photon CPU=4 RAM=4096 DISK=15 VNC_PASSWORD=mein-passwort \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PhotonPhotoEditorProxmox/main/install/photon.sh)"
```

| Variable | Standard | Beschreibung |
|---|---|---|
| `CTID` | nächste freie ID | Container-ID (muss frei sein) |
| `CT_HOSTNAME` | `photon` | Container-Name (bewusst nicht `HOSTNAME`, das ist auf dem Host der Node-Name) |
| `CPU` / `RAM` / `DISK` | `2` / `2048` / `10` | vCPU / MB RAM / GB Disk |
| `STORAGE` | `local-lvm` | Storage für RootFS |
| `TEMPLATE_STORAGE` | `local` | Storage für LXC-Template |
| `PASSWORD` | (leer) | Root-Passwort des Containers |
| `VNC_PASSWORD` | (generiert) | Passwort für den Web-Desktop |
| `DEBUG` | `0` | `DEBUG=1` → volles `bash -x` Log |

## Nutzung

Nach der Installation: `http://[LXC-IP]:8080` im Browser öffnen, mit dem angezeigten
VNC-Passwort anmelden — Photon Studio startet automatisch. Dateien bleiben im Container
(`VNC_PASSWORD` steht auch in `/root/.photon_vnc_password` im Container).

## Update / Deinstall

```bash
# Photon im Container aktualisieren (CTID anpassen)
pct exec <CTID> -- flatpak update -y

# Container neu starten (Photon muss danach wieder erreichbar sein)
pct reboot <CTID>

# Deinstallieren
pct stop <CTID> && pct destroy <CTID>
```

## Struktur

```
install/photon.sh      # Host-Installer (Community-Scripts-konform, Variablen oben)
lxc-setup/setup.sh     # In-Container-Setup (Flatpak + KasmVNC + Autostart)
systemd/kasmvnc.service # systemd-Unit (Template mit {{USER}}/{{PORT}})
```

## Testdurchlauf (Nachweis)

```
1. Einzeiler auf PVE-Host ausführen  → „Photon Studio erfolgreich installiert! http://…:8080"
2. pct exec <CTID> -- systemctl is-active kasmvnc   → active
3. curl -sf http://<LXC-IP>:8080/                    → 200
4. pct reboot <CTID> → 2 Min warten → Browser-Check → wieder erreichbar
```

Bei Fehlern: **komplette Ausgabe** posten (das Script druckt Exit-Code, Befehl und Stacktrace),
oder mit `DEBUG=1` erneut laufen lassen.
