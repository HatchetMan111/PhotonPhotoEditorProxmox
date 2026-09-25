#!/usr/bin/env bash
#
# Photon Studio — In-Container-Setup (laeuft IM LXC als root).
# Wird von install/photon.sh per `pct exec` aufgerufen.
#
# Env (optional): PORT=8080 VNC_PASSWORD=... KASMVNC_VERSION=1.5.0
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
  local frame trace line func src
  for (( frame=0; frame<25; frame++ )); do
    trace="$(caller "$frame" 2>/dev/null)" || break
    read -r line func src <<< "$trace"
    echo "    at ${func:-?} (${src:-?}:${line:-?})" >&2
  done
  echo "------------------------------------------------------------------" >&2
  echo "  Relevante Logs:" >&2
  journalctl -u kasmvnc -n 50 --no-pager 2>/dev/null || true
  # Falls Clean-DNS aktiv war, Original wiederherstellen; Proxy stoppen.
  if declare -F restore_dns >/dev/null 2>&1; then restore_dns >/dev/null 2>&1 || true; fi
  if declare -F stop_transparent_proxy >/dev/null 2>&1; then stop_transparent_proxy >/dev/null 2>&1 || true; fi
  echo "==================================================================" >&2
  exit "${rc}"
}
trap fail ERR

log()  { echo -e "\033[1;32m[photon-setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[photon-setup WARN]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[photon-setup FEHLER]\033[0m $*" >&2; exit 1; }

# ------------------------------------------- DNS-Diagnose + Bypass --
RESOLV_BAK="/tmp/resolv.conf.photon-bak"

# Pro Host: A/AAAA-Adressen + TCP-443-Connect je Familie (mit Timing).
# Deckt DNS-Filter (Pi-hole: 0.0.0.0 -> instant Error 7) und v6-Defekte auf.
netcheck() {
  log "Netz-Check (DNS + TCP/443 je Adressfamilie) ..."
  python3 - "$@" <<'PYEOF' 2>&1 | while IFS= read -r line; do echo "[netcheck] $line"; done
import socket, sys, time
for host in sys.argv[1:]:
    try:
        infos = socket.getaddrinfo(host, 443, socket.AF_UNSPEC, socket.SOCK_STREAM)
    except Exception as e:
        print(f"{host}: RESOLVE-FAIL {e}")
        continue
    seen = []
    for fam, _, _, _, sa in infos:
        ip = sa[0]
        if ip in seen:
            continue
        seen.append(ip)
        famname = "v4" if fam == socket.AF_INET else "v6"
        s = socket.socket(fam, socket.SOCK_STREAM)
        s.settimeout(5)
        t = time.time()
        try:
            s.connect(sa)
            print(f"{host} [{famname} {ip}]: CONNECT-OK {(time.time()-t)*1000:.0f}ms")
        except Exception as e:
            print(f"{host} [{famname} {ip}]: CONNECT-FAIL {e}")
        finally:
            s.close()
PYEOF
}

# Kritische Hosts per Direkt-DNS (1.1.1.1) aufloesen und in /etc/hosts
# pinnen. Umgeht filternde/wackelige LAN-Resolver (Pi-hole) fuer JEDES Tool
# (curl, flatpak, python) — unabhaengig von nsswitch/systemd-resolved.
# Pins bleiben bewusst bestehen (sonst brechen spaetere flatpak-Updates).
pin_hosts() {
  log "Pinne kritische Hosts via 1.1.1.1 nach /etc/hosts ..."
  local h ip
  for h in "$@"; do
    ip="$(dig +short A "$h" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
    if [[ -n "$ip" ]]; then
      sed -i "/[[:space:]]${h}[[:space:]]*\(#.*\)\?$/d" /etc/hosts
      echo "${ip} ${h} # photon-pinned" >> /etc/hosts
      log "  ${h} -> ${ip}"
    else
      warn "  ${h}: keine IPv4 via 1.1.1.1 (UDP/53 outbound blockiert?)"
    fi
  done
}

# Transparenter TCP-Forwarder (127.0.0.1:8888) + iptables-REDIRECT fuer ALLES
# auf tcp/443. Heilt flatpak, dessen eigener Socket-Aufbau im LAN klemmt ([7]),
# waehrend curl/python problemlos verbinden (9x reproduziert, libcurl-gnutls
# vs. libcurl-openssl belegt). Kein MITM: TLS laeuft Ende-zu-Ende (SNI, IP,
# Bytes identisch) — nur der TCP-Aufbau kommt aus bewiesen-funktionierendem
# Python. Laeuft als 'nobody' + Owner-Ausnahme (kein Loop).
TPROXY_PORT="8888"
TPROXY_PID="/tmp/photon-tproxy.pid"
TPROXY_SCRIPT="/tmp/photon-tproxy.py"
TPROXY_LOG="/tmp/tproxy.log"
start_transparent_proxy() {
  cat > "$TPROXY_SCRIPT" <<'PYEOF'
import socket, struct, threading
def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
def orig_dst(c):
    buf = c.getsockopt(socket.SOL_IP, 80, 16)
    fam, port, raw, _ = struct.unpack("!HH4s8s", buf)
    return (socket.inet_ntoa(raw), port)
def handle(c):
    try:
        dst = orig_dst(c)
    except OSError:
        c.close()
        return
    try:
        s = socket.create_connection(dst, timeout=15)
    except OSError:
        c.close()
        return
    t1 = threading.Thread(target=pipe, args=(c, s), daemon=True)
    t2 = threading.Thread(target=pipe, args=(s, c), daemon=True)
    t1.start(); t2.start(); t1.join(); t2.join()
    try:
        c.close()
    except OSError:
        pass
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 8888))
srv.listen(100)
print("tproxy ready", flush=True)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PYEOF
  chmod 644 "$TPROXY_SCRIPT"
  sudo -u nobody nohup python3 "$TPROXY_SCRIPT" >"$TPROXY_LOG" 2>&1 &
  echo $! > "$TPROXY_PID"
  local i
  for i in $(seq 1 30); do
    if (echo > "/dev/tcp/127.0.0.1/${TPROXY_PORT}") 2>/dev/null; then
      log "Transparent-Proxy laeuft (127.0.0.1:${TPROXY_PORT}, als nobody)."
      return 0
    fi
    sleep 1
  done
  warn "Transparent-Proxy startet nicht (s. ${TPROXY_LOG})."
  return 1
}
stop_transparent_proxy() {
  if [[ -f "$TPROXY_PID" ]]; then
    kill "$(cat "$TPROXY_PID")" 2>/dev/null || true
    rm -f "$TPROXY_PID"
  fi
  # Redirect-Regeln entfernen (still, falls nicht vorhanden).
  iptables -t nat -D OUTPUT -p tcp --dport 443 -j REDIRECT --to-port "$TPROXY_PORT" 2>/dev/null || true
  local nouid=""
  nouid="$(id -u nobody 2>/dev/null || true)"
  if [[ -n "$nouid" ]]; then
    iptables -t nat -D OUTPUT -m owner --uid-owner "$nouid" -j ACCEPT 2>/dev/null || true
  fi
}
setup_transparent_proxy() {
  # Rueckgabe 0 = aktiv + per Gate-Fetch BEWIESEN.
  local nouid=""
  nouid="$(id -u nobody 2>/dev/null || true)"
  if [[ -z "$nouid" ]]; then warn "User 'nobody' fehlt - kein Transparent-Proxy."; return 1; fi
  if ! command -v iptables >/dev/null 2>&1; then warn "iptables fehlt - kein Transparent-Proxy."; return 1; fi
  start_transparent_proxy || return 1
  iptables -t nat -I OUTPUT 1 -m owner --uid-owner "$nouid" -j ACCEPT 2>/dev/null \
    || { warn "Owner-Match nicht moeglich - kein Transparent-Proxy."; stop_transparent_proxy; return 1; }
  iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-port "$TPROXY_PORT" 2>/dev/null \
    || { warn "REDIRECT-Regel nicht setzbar - kein Transparent-Proxy."; stop_transparent_proxy; return 1; }
  log "Transparent-Redirect aktiv (tcp/443 -> 127.0.0.1:${TPROXY_PORT}), Gate-Fetch als Beweis ..."
  local code=""
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 25 https://dl.flathub.org/repo/summary.idx 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    log "Gate-Fetch OK (200) - Transparent-Pfad bewiesen."
    return 0
  fi
  warn "Gate-Fetch scheiterte (code=${code:-?}) - baue Redirect zurueck, weiter direkt."
  stop_transparent_proxy
  return 1
}

# Original-resolv.conf sichern, sauberes DNS (1.1.1.1) TEMPORAER aktivieren.
# Wird nach den Downloads wiederhergestellt (LAN-DNS bleibt Standard).
use_clean_dns() {
  [[ -f "$RESOLV_BAK" ]] || cp /etc/resolv.conf "$RESOLV_BAK"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
  log "Temporaer sauberes DNS (1.1.1.1/8.8.8.8) aktiv - wird wiederhergestellt."
}
restore_dns() {
  if [[ -f "$RESOLV_BAK" ]]; then
    cp "$RESOLV_BAK" /etc/resolv.conf && rm -f "$RESOLV_BAK"
    log "Original-DNS wiederhergestellt."
  fi
}

# Datei laden: erst Standard-DNS (-4, dann dual), dann Clean-DNS-Bypass.
# -L folgt Redirects (Tenzen-API -> 302 auf Version). $1=URL $2=Ziel. RC 0 ok.
fetch_url() {
  local url="$1" out="$2"
  if curl -4 -fsSL --retry 2 --max-time 120 -o "$out" "$url" 2>/dev/null; then return 0; fi
  if curl -fsSL --retry 2 --max-time 120 -o "$out" "$url" 2>/dev/null; then return 0; fi
  warn "Standard-DNS scheitert fuer ${url} -> versuche Clean-DNS-Bypass."
  use_clean_dns
  if curl -4 -fsSL --retry 2 --max-time 120 -o "$out" "$url" 2>/dev/null \
    || curl -fsSL --retry 2 --max-time 120 -o "$out" "$url" 2>/dev/null; then
    return 0
  fi
  return 1
}

[[ "$(id -u)" -eq 0 ]] || die "Bitte als root im Container ausfuehren."

export DEBIAN_FRONTEND=noninteractive
# C.UTF-8 ist in glibc eingebaut (kein locales-Paket, kein locale-gen noetig)
# und verhindert die perl/locale-Warnflut im minimalen LXC-Template.
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# ------------------------------------------------------------ 1) Basis --
log "1/7 System aktualisieren + Abhaengigkeiten installieren ..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg sudo dnsutils \
  flatpak \
  openbox xterm dbus-x11 \
  openssl iproute2 iputils-ping iptables \
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
  # JSON per python3 parsen (robust, kein grep/sed-Pipe-Kaskadenrisiko).
  KASMVNC_VERSION="$(curl -fsSL --max-time 15 https://api.github.com/repos/kasmtech/KasmVNC/releases/latest 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name","").lstrip("v"))' 2>/dev/null || true)"
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
# Abhaengigkeiten (libgbm1, libgl1, libxfont2, perl-Module, ...) aus den
# Repos aufloesen. dpkg allein kann das nicht; `apt-get install -yf` ohne
# Paketargument wuerde kasmvncserver eher ENTFERNEN statt Deps zu holen.
# Achtung: Schritt 1 hat /var/lib/apt/lists/* geloescht -> update Pflicht.
apt-get update
apt-get install -y --no-install-recommends "/tmp/${KASM_DEB}" \
  || die "KasmVNC-Installation fehlgeschlagen (Abhaengigkeiten nicht aufloesbar?)."
rm -f "/tmp/${KASM_DEB}"
command -v kasmvncserver >/dev/null 2>&1 || die "kasmvncserver nach Installation nicht gefunden."
VNCPASSWD_BIN="$(command -v kasmvncpasswd || command -v vncpasswd || true)"
[[ -n "$VNCPASSWD_BIN" ]] || die "Weder kasmvncpasswd noch vncpasswd gefunden."

# -------------------------------------------------------- 4) Photon ----
log "4/7 Photon Studio (Flatpak, ~270 MB + Runtime) herunterladen + installieren ..."
FLATHUB_REPO_URL="https://flathub.org/repo/flathub.flatpakrepo"
FLATHUB_REPO_FILE="/tmp/flathub.flatpakrepo"
FLATHUB_RUNTIME="org.freedesktop.Platform/x86_64/25.08"
netcheck flathub.org dl.flathub.org tenzen.studio downloads.tenzen.studio
log "HTTP-Stack-Fingerabdruck (welche TLS-Lib nutzt flatpak?):"
ldd /usr/bin/flatpak 2>/dev/null | grep -Eo "lib(curl|soup|ssl|crypto)[^ ]*" | sort -u \
  | while IFS= read -r line; do echo "[stack] $line"; done
log "Python-HTTPS-Probe (teilt sich NICHT curls Stack):"
python3 -c "import urllib.request; r=urllib.request.urlopen('https://dl.flathub.org/repo/summary.idx',timeout=20); d=r.read(); print(f'PY-HTTPS: status={r.status} bytes={len(d)}')" 2>&1 \
  | while IFS= read -r line; do echo "[pyhttps] $line"; done || true
# Diagnose: flathub.org hat IPv4+IPv6; falls der Container nur defektes IPv6
# hat (FritzBox/Pi-hole-LANs), IPv4 bevorzugen. Harmlos, falls v6 ok ist.
if ! curl -fsSL --max-time 8 -6 -o /dev/null "$FLATHUB_REPO_URL" 2>/dev/null; then
  warn "IPv6 zu Flathub defekt/langsam -> bevorzuge IPv4 (gai.conf)."
  printf 'precedence ::ffff:0:0/96  100\n' >> /etc/gai.conf
  # Harter Schnitt (best effort): v6 ist hier nachweislich zu 100 % tot
  # (alle v6-Connects Errno 101) — abschalten killt v6-first-Roulette
  # in JEDEM Tool (auch solchen, die gai.conf ignorieren).
  if sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1; then
    echo "net.ipv6.conf.all.disable_ipv6=1" > /etc/sysctl.d/99-photon-ipv6.conf
    log "IPv6 deaktiviert (war ohnehin unreachable)."
  else
    warn "IPv6 konnte nicht deaktiviert werden (weiter mit gai.conf)."
  fi
fi
# Hosts pinnen (wirkt fuer curl, flatpak, python — unabhaengig vom Resolver)
# + Clean-DNS EINMAL fuer den ganzen Schritt (statt pro Fetch zu jonglieren).
pin_hosts flathub.org dl.flathub.org tenzen.studio downloads.tenzen.studio
log "Resolver-Check (muss die Pins zeigen, sonst wirkt /etc/hosts nicht):"
getent hosts flathub.org dl.flathub.org tenzen.studio downloads.tenzen.studio 2>&1 \
  | while IFS= read -r line; do echo "[resolve] $line"; done
# MTU-Blackhole-Heilung (PPPoE 1492 vs. 1500): SYN (klein) + TLS-Handshake
# passieren, grosse Datensegmente sterben unterwegs (PMTUD-ICMP gefiltert).
# MSS-Clamp zwingt BEIDE Seiten zu kleineren Segmenten. Harmlos sonst.
log "MTU-Probe (gross mit DF-Bit; Fehlschlag = Blackhole-Indiz):"
ping -M do -s 1472 -c 2 -W 3 dl.flathub.org >/dev/null 2>&1 \
  && log "  1472B ok (kein Blackhole)" \
  || warn "  1472B scheitert -> aktiviere TCP-MSS-Clamping."
if command -v iptables >/dev/null 2>&1; then
  iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || warn "  MSS-Clamp nicht setzbar (weiter ohne)."
  iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    && log "  TCP-MSS-Clamping aktiv." || true
else
  warn "  iptables fehlt (weiter ohne Clamp)."
fi
log "Interface-MTUs:"
ip -o link show 2>&1 | while IFS= read -r line; do echo "[mtu] $line"; done
use_clean_dns
# Transparent-Redirect fuer ALLES auf tcp/443 (Kernel-Ebene, keine App-
# Kooperation noetig). Gate-Fetch beweist den Pfad VOR flatpak.
TRANS_OK=""
if setup_transparent_proxy; then TRANS_OK=1; else warn "Weiter ohne Transparent-Proxy (direkt)."; fi
# Repo-Datei laden, dann LOKAL einhaengen (kein DNS zur Add-Zeit noetig).
FLATHUB_ADDED=""
for attempt in 1 2 3; do
  if fetch_url "$FLATHUB_REPO_URL" "$FLATHUB_REPO_FILE" \
    && flatpak remote-add --if-not-exists flathub "$FLATHUB_REPO_FILE"; then
    FLATHUB_ADDED=1; break
  fi
  # Letzter Ausweg: direkt (flatpak loest selbst auf).
  if flatpak remote-add --if-not-exists flathub "$FLATHUB_REPO_URL"; then FLATHUB_ADDED=1; break; fi
  [[ "$attempt" == "3" ]] || sleep 10
done
rm -f "$FLATHUB_REPO_FILE"
if [[ -z "$FLATHUB_ADDED" ]]; then
  warn "Flathub-Remote 3x fehlgeschlagen."
  echo "--- HINWEIS: Pi-hole/AdGuard whitelisten:" >&2
  echo "    flathub.org, dl.flathub.org, tenzen.studio, downloads.tenzen.studio" >&2
  die "Flathub-Remote nicht erreichbar (s. [netcheck]-Zeilen oben)."
fi
# Laufzeitumgebung EXPLIZIT vorab installieren (gross, dauert Minuten):
# Das Bundle verlangt sie, und so schlaegt ein Metadata-Problem sofort
# sichtbar hier auf statt verzoegert im Bundle-Install.
log "Installiere Runtime ${FLATHUB_RUNTIME} von Flathub ..."
RUNTIME_OK=""
for attempt in 1 2; do
  if flatpak install -y --noninteractive flathub "$FLATHUB_RUNTIME"; then RUNTIME_OK=1; break; fi
  [[ "$attempt" == "2" ]] || { warn "Runtime-Install Versuch 1 scheiterte -> Retry in 15s."; sleep 15; }
done
if [[ -z "$RUNTIME_OK" ]]; then
  warn "DIAGNOSE: volle Fetch-Protokolle (RC = Exit-Code, entscheidend!):"
  echo "--- getent ahosts dl.flathub.org (was sieht NSS JETZT?) ---" >&2
  getent ahosts dl.flathub.org >&2 || true
  echo "--- curl -v VOLLSTAENDIG (inkl. Transfer + RC) ---" >&2
  curl -v --max-time 25 -o /tmp/diag.bin https://dl.flathub.org/repo/summary.idx 2>&1 | head -60 >&2 || true
  echo "--- curl -v --http1.1 (h2-Bypass-Variante) ---" >&2
  curl -v --http1.1 --max-time 25 -o /tmp/diag11.bin https://dl.flathub.org/repo/summary.idx 2>&1 | head -40 >&2 || true
  echo "--- curl -v -4 erzwungen ---" >&2
  curl -v -4 --max-time 25 -o /dev/null https://dl.flathub.org/repo/summary.idx 2>&1 | head -40 >&2 || true
  echo "--- grosse Datei-Test (zeigt Stall vs. Abbruch + Bytes) ---" >&2
  RC_BIG=0
  curl -s --max-time 30 -o /tmp/diag10.bin https://dl.flathub.org/repo/summary.idx 2>/dev/null || RC_BIG=$?
  echo "RC-GROSS=${RC_BIG} SIZE=$(stat -c%s /tmp/diag10.bin 2>/dev/null || echo none)" >&2
  rm -f /tmp/diag.bin /tmp/diag11.bin /tmp/diag10.bin
  echo "--- Routen + MTU ---" >&2
  ip route >&2 || true
  ip -o link show >&2 || true
  die "Runtime-Installation fehlgeschlagen (s. Ausgabe + Diagnose oben)."
fi
PHOTON_FLATPAK="/tmp/photon-studio.flatpak"
if [[ "${PHOTON_PRESEEDED:-}" == "1" ]]; then
  # Host hat die Datei per pct push nach /root/photon-studio.flatpak gelegt.
  PHOTON_FLATPAK="/root/photon-studio.flatpak"
  log "Nutze Host-Preseed: ${PHOTON_FLATPAK}"
else
  for attempt in 1 2 3; do
    # -L (in fetch_url) folgt dem 302-Redirect der Tenzen-API auf die Version.
    if fetch_url "$PHOTON_API_URL" "$PHOTON_FLATPAK"; then break; fi
    [[ "$attempt" == "3" ]] && die "Photon-Download fehlgeschlagen: ${PHOTON_API_URL} (s. [netcheck]-Zeilen oben)"
    sleep 5
  done
fi
[[ -s "$PHOTON_FLATPAK" ]] || die "Photon-Flatpak fehlt/leer: ${PHOTON_FLATPAK}"
# (Volle Ausgabe, keine Kuerzung: komplette Fehlerkette ist Pflicht.)
log "Installiere Photon-Bundle (Runtime bereits vorhanden) ..."
flatpak install -y --noninteractive "$PHOTON_FLATPAK" \
  || die "Flatpak-Installation fehlgeschlagen (s. Ausgabe oben)."
rm -f "$PHOTON_FLATPAK" /root/photon-studio.flatpak
stop_transparent_proxy
restore_dns
log "Hinweis: /etc/hosts-Pins bleiben bestehen (sonst brechen spaetere flatpak-Updates am LAN-Filter)."
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
