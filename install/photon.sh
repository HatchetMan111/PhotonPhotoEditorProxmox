#!/usr/bin/env bash
#
# Photon Studio on Proxmox LXC — Community-Scripts-style installer.
#
# Usage (on the Proxmox host, as root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PhotonPhotoEditorProxmox/main/install/photon.sh)"
#
# Optional env overrides:
#   CTID=150 CT_HOSTNAME=photon CPU=2 RAM=2048 DISK=10 STORAGE=local-lvm \
#   TEMPLATE_STORAGE=local PASSWORD=secret VNC_PASSWORD=secret \
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PhotonPhotoEditorProxmox/main/install/photon.sh)"
#
# Debug:
#   DEBUG=1 bash -c "$(wget -qLO - .../install/photon.sh)"   # enables `set -x`
#
set -euo pipefail

# ---------------------------------------------------------------- variables --
APP="photon"
APP_NAME="Photon Studio"
REPO="HatchetMan111/PhotonPhotoEditorProxmox"
BRANCH="main"
SETUP_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/lxc-setup/setup.sh"
UNIT_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/systemd/kasmvnc.service"

DEFAULT_CPU=2
DEFAULT_RAM=2048        # MB
DEFAULT_DISK=10         # GB
DEFAULT_OS="ubuntu-24.04"
DEFAULT_STORAGE="local-lvm"
DEFAULT_TEMPLATE_STORAGE="local"
PORT=8080

CTID="${CTID:-}"                          # empty => next free ID from cluster
# Achtung: NICHT $HOSTNAME verwenden — auf dem PVE-Host ist das der
# Node-Hostname (z. B. "Prox") und wuerde den Container falsch benennen.
CT_HOSTNAME="${CT_HOSTNAME:-${APP}}"
CPU="${CPU:-${DEFAULT_CPU}}"
RAM="${RAM:-${DEFAULT_RAM}}"
DISK="${DISK:-${DEFAULT_DISK}}"
STORAGE="${STORAGE:-${DEFAULT_STORAGE}}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-${DEFAULT_TEMPLATE_STORAGE}}"
PASSWORD="${PASSWORD:-}"                  # empty => passwordless (key/PAM login)
VNC_PASSWORD="${VNC_PASSWORD:-}"          # empty => setup.sh generates one

if [[ "${DEBUG:-0}" == "1" ]]; then
  set -x
fi

# ---------------------------------------------------------- error handling --
fail() {
  local rc=$?
  echo "" >&2
  echo "==================================================================" >&2
  echo "  INSTALLATION FEHLGESCHLAGEN (${APP_NAME})" >&2
  echo "  Exit-Code : ${rc}" >&2
  echo "  Befehl    : ${BASH_COMMAND}" >&2
  echo "------------------------------------------------------------------" >&2
  echo "  Stacktrace (neueste zuerst):" >&2
  local frame trace line func src printed=0
  for (( frame=0; frame<25; frame++ )); do
    trace="$(caller "$frame" 2>/dev/null)" || break
    read -r line func src <<< "$trace"
    echo "    at ${func:-?} (${src:-?}:${line:-?})" >&2
    printed=$((printed + 1))
  done
  [[ "$printed" -gt 0 ]] || echo "    (Top-Level-Fehler, siehe 'Befehl' oben)" >&2
  echo "------------------------------------------------------------------" >&2
  echo "  Tipp: Erneut mit DEBUG=1 starten fuer ein vollstaendiges bash -x Log:" >&2
  echo "    DEBUG=1 bash -c \"\$(wget -qLO - https://raw.githubusercontent.com/${REPO}/${BRANCH}/install/photon.sh)\"" >&2
  echo "==================================================================" >&2
  exit "${rc}"
}
trap fail ERR

log()  { echo -e "\033[1;32m[photon]\033[0m $*"; }
warn() { echo -e "\033[1;33m[photon WARN]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[photon FEHLER]\033[0m $*" >&2; exit 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausfuehren."
}

require_pve() {
  command -v pct >/dev/null 2>&1 || die "'pct' nicht gefunden - kein Proxmox-Host?"
  command -v pvesh >/dev/null 2>&1 || die "'pvesh' nicht gefunden - kein Proxmox-Host?"
  command -v pveam >/dev/null 2>&1 || die "'pveam' nicht gefunden - kein Proxmox-Host?"
}

next_free_ctid() {
  # Naechste freie VM/CT-ID vom Cluster (fasst auch Luecken).
  pvesh get /cluster/nextid
}

resolve_template() {
  # WICHTIG: Alles ausser dem finalen echo MUSS auf stderr,
  # da der Aufrufer stdout per $(...) als Template-Pfad einfaengt.
  local tmpl_store="$1" os="$2" tpl
  log "Aktualisiere Template-DB (${tmpl_store}) ..." >&2
  pveam update >/dev/null 2>&1
  tpl="$(pveam available --section system 2>/dev/null \
    | awk -v os="$os" '$2 ~ os {print $2}' | sort -V | tail -n 1 || true)"
  [[ -n "${tpl:-}" ]] || die "Kein LXC-Template fuer '${os}' auf Storage '${tmpl_store}' gefunden."
  if ! pveam list "${tmpl_store}" 2>/dev/null | grep -q "${tpl}"; then
    log "Lade Template ${tpl} herunter (kann dauern) ..." >&2
    pveam download "${tmpl_store}" "${tpl}" >&2
  else
    log "Template ${tpl} bereits vorhanden." >&2
  fi
  echo "${tmpl_store}:vztmpl/${tpl}"
}

container_ip() {
  local ctid="$1" ip=""
  local tries=0
  while (( tries < 30 )); do
    ip="$(pct exec "$ctid" -- ip -4 -o addr show dev eth0 scope global 2>/dev/null \
      | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    sleep 5
    tries=$((tries + 1))
  done
  echo ""
}

# ------------------------------------------------------------------- main --
require_root
require_pve

if [[ -z "$CTID" ]]; then
  CTID="$(next_free_ctid)"
  log "Keine CTID angegeben -> nutze naechste freie ID: ${CTID}"
else
  log "Nutze angegebene CTID: ${CTID}"
fi

if pct status "$CTID" >/dev/null 2>&1; then
  die "Container ${CTID} existiert bereits. Andere CTID waehlen (z. B. CTID=$(next_free_ctid) ...) oder 'pct destroy ${CTID}'."
fi

OSTPL="$(resolve_template "$TEMPLATE_STORAGE" "$DEFAULT_OS")"
[[ "$OSTPL" == *":vztmpl/"* ]] || die "Unerwarteter Template-Pfad: '${OSTPL}'"
log "Erstelle Container ${CTID} (${CT_HOSTNAME}, ${CPU} vCPU, ${RAM} MB RAM, ${DISK} GB Disk) ..."

CREATE_ARGS=(
  "$CTID" "$OSTPL"
  --hostname "$CT_HOSTNAME"
  --cores "$CPU"
  --memory "$RAM"
  --rootfs "${STORAGE}:${DISK}"
  --net0 "name=eth0,bridge=vmbr0,ip=dhcp"
  --onboot 1
  --features "nesting=1,keyctl=1,fuse=1"
  --unprivileged 1
  --ostype ubuntu
)
if [[ -n "$PASSWORD" ]]; then
  CREATE_ARGS+=(--password "$PASSWORD")
fi

pct create "${CREATE_ARGS[@]}"
pct start "$CTID"
log "Container gestartet. Warte auf Netzwerk ..."

IP="$(container_ip "$CTID")"
[[ -n "$IP" ]] || die "Keine IP fuer CT ${CTID} erhalten (DHCP?). Pruefe Bridge vmbr0."
log "Container-IP: ${IP}"

log "Uebertrage Setup-Script in den Container ..."
TMP_SETUP="$(mktemp /tmp/photon-setup.XXXXXX.sh)"
TMP_UNIT="$(mktemp /tmp/kasmvnc.XXXXXX.service)"
wget -qO "$TMP_SETUP" "$SETUP_URL"
wget -qO "$TMP_UNIT" "$UNIT_URL"
pct push "$CTID" "$TMP_SETUP" /root/photon-setup.sh
pct push "$CTID" "$TMP_UNIT" /root/kasmvnc.service
rm -f "$TMP_SETUP" "$TMP_UNIT"

log "Installiere ${APP_NAME} im Container (dauert mehrere Minuten: ~270 MB Download + Flatpak) ..."
if [[ -n "$VNC_PASSWORD" ]]; then
  pct exec "$CTID" -- env VNC_PASSWORD="$VNC_PASSWORD" PORT="$PORT" bash /root/photon-setup.sh
else
  pct exec "$CTID" -- env PORT="$PORT" bash /root/photon-setup.sh
fi

log "Verifiziere Installation ..."
pct exec "$CTID" -- systemctl is-active --quiet kasmvnc \
  || die "Service 'kasmvnc' laeuft nicht. Logs: pct exec ${CTID} -- journalctl -u kasmvnc -n 100 --no-pager"
pct exec "$CTID" -- bash -c "curl -sf -o /dev/null --max-time 10 http://localhost:${PORT}/" \
  || die "Web UI antwortet nicht auf localhost:${PORT}. Logs: pct exec ${CTID} -- journalctl -u kasmvnc -n 100 --no-pager"

SAVED_PW="$(pct exec "$CTID" -- cat /root/.photon_vnc_password 2>/dev/null || true)"

echo ""
echo "=================================================================="
echo "  ${APP_NAME} erfolgreich installiert!"
echo "  ----------------------------------------------------------------"
echo "  Container : CT ${CTID} (${CT_HOSTNAME})"
echo "  Web-Desktop: http://${IP}:${PORT}"
if [[ -n "${SAVED_PW:-}" ]]; then
echo "  VNC-Passwort (in CT /root/.photon_vnc_password gespeichert): ${SAVED_PW}"
fi
echo "  Photon Studio im Web-Desktop oeffnen und lokal arbeiten."
echo "  Reboot-sicher: onboot=1 + systemd kasmvnc (Restart=always)."
echo "  Update im Container: pct exec ${CTID} -- flatpak update -y"
echo "  Deinstallieren : pct stop ${CTID} && pct destroy ${CTID}"
echo "=================================================================="
