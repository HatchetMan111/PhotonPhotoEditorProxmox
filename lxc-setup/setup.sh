#!/usr/bin/env bash
#
# Photon Studio — In-Container-Setup (laeuft IM LXC als root).
# Wird von install/photon.sh per `pct exec` aufgerufen.
#
# Env (optional): PORT=8080 VNC_PASSWORD=... KASMVNC_VERSION=1.3.2
#
set -euo pipefail

PORT="${PORT:-8080}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
KASMVNC_VERSION="${KASMVNC_VERSION:-}"   # leer => neueste GitHub-Release
KASMVNC_FALLBACK="1.5.0"
PHOTON_API_URL="https://tenzen.studio/api/v1/photon/download?platform=linux&arch=x64"
APP_USER="photon"

if [[ "${DEBUG:-0}" == "1" ]]; then
  set -x
fi

fail() {
  local rc=$?
  echo "" >&2
  echo "==================================================================" >&2
  echo "  SETUP FEHLGESCHLAGEN (Photon LXC)" >&2
  echo "  Exit-Code : ${rc}" >&2
  echo "  Befehl    : ${BASH_COMMAND}" >&2
  echo "------------------------------------------------------------------" >&2
  echo "  Stacktrace (neueste zuerst):" >&2
  local i
  for (( i=${#FUNCNAME[@]}-1; i>=0; i-- )); do
    echo "    at ${FUNCNAME[$i]:-main} (${BASH_SOURCE[$i]:-?}:${BASH_LINENO[$i]:-?})" >&2
  done
  echo "------------------------------------------------------------------" >&2
  echo "  Relevante Logs:" >&2
  journalctl -u kasmvnc -n 50 --no-pager 2>/dev/null || true
  echo "==================================================================" >&2
  exit "${rc}"
}
trap fail ERR

log() { echo -e "\033[1;32m[photon-setup]\033[0m $*"; }
die() { echo -e "\033[1;31m[photon-setup FEHLER]\033[0m $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Bitte als root im Container ausfuehren."

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------ 1) Basis --
log "1/7 System aktualisieren + Abhaengigkeiten installieren ..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg sudo \
  flatpak \
  openbox xterm dbus-x11 \
  openssl iproute2 \
  python3 xz-utils
apt-get clean
rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------ 2) User ---
log "2/7 Benutzer '${APP_USER}' anlegen ..."
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$APP_USER"
fi
loginctl enable-linger "$APP_USER" 2>/dev/null || true

# ------------------------------------------------------- 3) KasmVNC ----
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
if [[ -z "$KASMVNC_VERSION" ]]; then
  log "Ermittle neueste KasmVNC-Version ..."
  KASMVNC_VERSION="$(curl -fsSL --max-time 15 https://api.github.com/repos/kasmtech/KasmVNC/releases/latest \
    | grep -m1 '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1' || true)"
  [[ -n "$KASMVNC_VERSION" ]] || { warn "GitHub-API nicht erreichbar, nutze Fallback ${KASMVNC_FALLBACK}"; KASMVNC_VERSION="$KASMVNC_FALLBACK"; }
fi
log "3/7 KasmVNC ${KASMVNC_VERSION} installieren ..."
KASM_DEB="kasmvncserver_${CODENAME}_${KASMVNC_VERSION}_amd64.deb"
KASM_URL="https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/${KASM_DEB}"
cd /tmp
for attempt in 1 2 3; do
  if wget -q -O "$KASM_DEB" "$KASM_URL"; then break; fi
  [[ "$attempt" == "3" ]] && die "KasmVNC-Download fehlgeschlagen: ${KASM_URL}"
  sleep 5
done
dpkg -i "/tmp/${KASM_DEB}" || apt-get install -yf --no-install-recommends
dpkg -i "/tmp/${KASM_DEB}" || die "KasmVNC-Installation fehlgeschlagen."
rm -f "/tmp/${KASM_DEB}"
command -v kasmvncserver >/dev/null 2>&1 || die "kasmvncserver nach Installation nicht gefunden."
VNCPASSWD_BIN="$(command -v kasmvncpasswd || command -v vncpasswd || true)"
[[ -n "$VNCPASSWD_BIN" ]] || die "Weder kasmvncpasswd noch vncpasswd gefunden."

# -------------------------------------------------------- 4) Photon ----
log "4/7 Photon Studio (Flatpak, ~270 MB) herunterladen + installieren ..."
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
PHOTON_FLATPAK="/tmp/photon-studio.flatpak"
for attempt in 1 2 3; do
  # -L folgt dem 302-Redirect der Tenzen-API auf die aktuellste Version.
  if curl -fsSL --retry 3 -o "$PHOTON_FLATPAK" "$PHOTON_API_URL"; then break; fi
  [[ "$attempt" == "3" ]] && die "Photon-Download fehlgeschlagen: ${PHOTON_API_URL}"
  sleep 5
done
[[ -s "$PHOTON_FLATPAK" ]] || die "Photon-Flatpak ist leer - Download unvollstaendig."
flatpak install -y --noninteractive "$PHOTON_FLATPAK"
rm -f "$PHOTON_FLATPAK"
PHOTON_APP_ID="$(flatpak list --app --columns=application 2>/dev/null | grep -i -m1 photon || true)"
[[ -n "$PHOTON_APP_ID" ]] || die "Photon Flatpak-App-ID nach Installation nicht gefunden. 'flatpak list --app' Ausgabe pruefen."
log "Photon App-ID: ${PHOTON_APP_ID}"

# ------------------------------------------------- 5) Desktop/Login ---
log "5/7 Web-Desktop (Openbox + Photon-Autostart) einrichten ..."
if [[ -z "$VNC_PASSWORD" ]]; then
  VNC_PASSWORD="$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 16)"
  log "VNC-Passwort generiert (wird am Ende des Host-Scripts angezeigt)."
fi
echo -n "$VNC_PASSWORD" > /root/.photon_vnc_password
chmod 600 /root/.photon_vnc_password

sudo -u "$APP_USER" mkdir -p "/home/${APP_USER}/.vnc" "/home/${APP_USER}/.config/openbox"
# vncpasswd liest via getpass() von /dev/tty — eine Pipe reicht nicht (KasmVNC #141).
# `script` stellt ein Pseudo-TTY bereit, stdin liefert die Antworten (Passwort + Verify).
printf '%s\n%s\n' "$VNC_PASSWORD" "$VNC_PASSWORD" \
  | script -qec "sudo -u ${APP_USER} ${VNCPASSWD_BIN} -u ${APP_USER} -w" /dev/null >/dev/null \
  || die "VNC-Passwort konnte nicht gesetzt werden."
[[ -f "/home/${APP_USER}/.kasmpasswd" ]] || die "Passwortdatei ~/.kasmpasswd wurde nicht angelegt."

# Eigenes xstartup: deterministisch Openbox starten (statt -select-de zu raten).
cat > "/home/${APP_USER}/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec openbox-session
EOF
chmod +x "/home/${APP_USER}/.vnc/xstartup"
chown -R "${APP_USER}:${APP_USER}" "/home/${APP_USER}/.vnc" "/home/${APP_USER}/.config"
adduser "$APP_USER" ssl-cert 2>/dev/null || true

cat > "/home/${APP_USER}/.config/openbox/autostart" <<EOF
# Photon Studio Autostart (generiert von photon-setup.sh)
flatpak run ${PHOTON_APP_ID} &
EOF
chown "${APP_USER}:${APP_USER}" "/home/${APP_USER}/.config/openbox/autostart"
chmod +x "/home/${APP_USER}/.config/openbox/autostart"

# -------------------------------------------------------- 6) Service ---
log "6/7 systemd-Service 'kasmvnc' einrichten ..."
[[ -f /root/kasmvnc.service ]] || die "/root/kasmvnc.service fehlt (wird vom Host-Script per pct push uebertragen)."
sed -e "s|{{PORT}}|${PORT}|g" -e "s|{{USER}}|${APP_USER}|g" \
  /root/kasmvnc.service > /etc/systemd/system/kasmvnc.service
systemctl daemon-reload
systemctl enable --now kasmvnc

# UFW-Port oeffnen, falls UFW aktiv ist.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp"
fi

# -------------------------------------------------------- 7) Check ----
log "7/7 Verifikation ..."
systemctl is-active --quiet kasmvnc || die "kasmvnc-Service laeuft nicht."
sleep 3
curl -sf -o /dev/null --max-time 10 "http://localhost:${PORT}/" \
  || die "Web UI antwortet nicht auf localhost:${PORT}."
log "OK: kasmvnc aktiv, Web UI antwortet auf Port ${PORT}. Photon-App-ID: ${PHOTON_APP_ID}"
