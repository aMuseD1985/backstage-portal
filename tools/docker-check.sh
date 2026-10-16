#!/usr/bin/env bash
# docker-check.sh – prüft, ob Docker auf diesem Server laufen würde.
# Installiert NICHTS und verändert NICHTS (Test-Mounts landen in einem temporären Ordner und werden sofort wieder entfernt).
# Aufruf:  sudo bash docker-check.sh            (als root: alle Tests)
#          bash docker-check.sh                 (ohne root: einige Tests werden übersprungen)
#          sudo bash docker-check.sh --run-test (zusätzlich: falls Docker schon installiert ist, "hello-world" starten – lädt ein kleines Image)

set -u
OK=0; WARN=0; FAIL=0
gruen() { printf '  \033[32m✔\033[0m %s\n' "$1"; OK=$((OK+1)); }
gelb()  { printf '  \033[33m!\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
rot()   { printf '  \033[31m✘\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
info()  { printf '    %s\n' "$1"; }
titel() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ROOT=0; [ "$(id -u)" -eq 0 ] && ROOT=1
ISVZ=0; NS_OK=0; OVL_OK=0; NET_OK=0   # für das Urteil bei OpenVZ/LXC: entscheiden die Funktionstests
RUNTEST=0; [ "${1:-}" = "--run-test" ] && RUNTEST=1

echo "Docker-Prüfung auf $(hostname) – $(date '+%d.%m.%Y %H:%M')"
[ $ROOT -eq 0 ] && echo "Hinweis: ohne root – Namespace- und Overlay-Test werden übersprungen. Besser: sudo bash $0"

# ── 1. Virtualisierung ─────────────────────────────────────────────────────
titel "1. Virtualisierung"
VIRT="${DOCKERCHECK_VIRT:-unbekannt}"   # DOCKERCHECK_VIRT nur zum Testen des Scripts
[ -z "${DOCKERCHECK_VIRT:-}" ] && command -v systemd-detect-virt >/dev/null 2>&1 && VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
if [ -z "${DOCKERCHECK_VIRT:-}" ] && { [ -e /proc/user_beancounters ] || [ -d /proc/vz ]; }; then VIRT="openvz"; fi
info "erkannt: $VIRT"
case "$VIRT" in
  kvm|qemu|vmware|microsoft|xen|amazon|oracle|bochs|none) gruen "Vollvirtualisierung oder echte Hardware – Docker läuft hier normalerweise problemlos" ;;
  openvz) ISVZ=1; gelb "OpenVZ/Virtuozzo – Docker läuft hier nur, wenn der Anbieter es freigeschaltet hat (die Tests unten zeigen, ob ja)" ;;
  lxc|lxc-libvirt|systemd-nspawn|docker|podman) ISVZ=1; gelb "Container-Virtualisierung ($VIRT) – Docker geht nur, wenn der Anbieter verschachtelte Container erlaubt (nesting)" ;;
  *) gelb "Virtualisierung nicht eindeutig erkannt – die folgenden Tests entscheiden" ;;
esac

# ── 2. Kernel und Architektur ──────────────────────────────────────────────
titel "2. Kernel und Architektur"
KERN="$(uname -r)"; ARCH="$(uname -m)"
info "Kernel $KERN · Architektur $ARCH"
KMAJ="${KERN%%.*}"; KREST="${KERN#*.}"; KMIN="${KREST%%.*}"
if [ "$KMAJ" -gt 4 ] 2>/dev/null || { [ "$KMAJ" -eq 4 ] && [ "$KMIN" -ge 15 ]; } 2>/dev/null; then gruen "Kernel ist aktuell genug (≥ 4.15)"
else gelb "Kernel ist alt – Docker läuft evtl., aktuelle Versionen setzen neuere Kernel voraus"; fi
case "$ARCH" in x86_64|aarch64|arm64) gruen "Architektur $ARCH wird von Docker und Backstage-Images unterstützt" ;;
  armv7l) gelb "32-Bit-ARM – Docker läuft, viele Images (u. a. Backstage) gibt es dafür aber nicht" ;;
  *) gelb "ungewöhnliche Architektur $ARCH" ;; esac

# ── 3. cgroups ─────────────────────────────────────────────────────────────
titel "3. cgroups (Ressourcen-Begrenzung für Container)"
CGFS="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo fehlt)"
if [ "$CGFS" = "cgroup2fs" ]; then
  CTRL="$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null)"
  info "cgroup v2 · Controller: ${CTRL:-keine}"
  FEHLT=""; for c in cpu memory pids; do echo " $CTRL " | grep -q " $c " || FEHLT="$FEHLT $c"; done
  if [ -z "$FEHLT" ]; then gruen "cgroup v2 mit cpu, memory und pids"; else gelb "cgroup v2, aber es fehlen Controller:$FEHLT (Container laufen, Speicher-/CPU-Grenzen evtl. nicht)"; fi
elif [ "$CGFS" = "tmpfs" ]; then
  info "cgroup v1 · $(ls /sys/fs/cgroup 2>/dev/null | tr '\n' ' ')"
  if [ -d /sys/fs/cgroup/memory ] && [ -d /sys/fs/cgroup/cpu ] || [ -d /sys/fs/cgroup/cpu,cpuacct ]; then gruen "cgroup v1 mit cpu und memory (funktioniert, v2 wäre moderner)"
  else gelb "cgroup v1 ohne memory/cpu-Hierarchie"; fi
else rot "keine cgroups gefunden (/sys/fs/cgroup: $CGFS) – ohne cgroups kein Docker"; fi

# ── 4. Namespaces ──────────────────────────────────────────────────────────
titel "4. Namespaces (Isolation der Container)"
if [ $ROOT -eq 1 ] && command -v unshare >/dev/null 2>&1; then
  NS_OK=1
  for ns in "--mount:Dateisystem" "--uts:Hostname" "--ipc:IPC" "--net:Netzwerk" "--pid --fork:Prozesse"; do
    flag="${ns%%:*}"; name="${ns##*:}"
    if unshare $flag true 2>/dev/null; then gruen "Namespace $name"; else rot "Namespace $name lässt sich nicht anlegen"; NS_OK=0; fi
  done
  if unshare --user --map-root-user true 2>/dev/null; then gruen "User-Namespaces (für rootless Docker/Podman)"; else gelb "keine User-Namespaces – normales Docker geht trotzdem, rootless nicht"; fi
else gelb "übersprungen (braucht root und 'unshare')"; fi

# ── 5. Speichertreiber overlay2 ────────────────────────────────────────────
titel "5. Dateisystem für Container-Images (overlay2)"
if grep -qw overlay /proc/filesystems 2>/dev/null; then gruen "Kernel kennt overlayfs"
elif [ $ROOT -eq 1 ] && modprobe -n overlay 2>/dev/null; then gelb "overlay-Modul vorhanden, aber nicht geladen (Docker lädt es beim Start)"
else rot "overlayfs nicht verfügbar – Docker müsste auf den langsamen vfs-Treiber ausweichen"; fi
if [ $ROOT -eq 1 ]; then
  T="$(mktemp -d)"; mkdir -p "$T"/{l,u,w,m}
  if mount -t overlay overlay -o "lowerdir=$T/l,upperdir=$T/u,workdir=$T/w" "$T/m" 2>/dev/null; then umount "$T/m"; OVL_OK=1; gruen "overlay-Mount funktioniert wirklich"
  else rot "overlay-Mount schlägt fehl (oft bei OpenVZ/LXC)"; fi
  rm -rf "$T"
fi
info "Dateisystem von /var/lib: $(df -T /var/lib 2>/dev/null | awk 'NR==2{print $2}')"

# ── 6. Netzwerk ────────────────────────────────────────────────────────────
titel "6. Netzwerk (Brücke, NAT, Firewall)"
for m in bridge veth br_netfilter nf_nat; do
  if lsmod 2>/dev/null | grep -qw "^$m" || [ -d "/sys/module/$m" ]; then gruen "Modul $m geladen"
  elif grep -qs "/$m.ko" "/lib/modules/$(uname -r)/modules.builtin"; then gruen "Modul $m fest im Kernel eingebaut"
  elif [ $ROOT -eq 1 ] && modprobe -n "$m" 2>/dev/null; then gruen "Modul $m verfügbar (wird bei Bedarf geladen)"
  else gelb "Modul $m nicht gefunden (bei Container-Virtualisierung normal – dann entscheidet der Anbieter)"; fi
done
if command -v iptables >/dev/null 2>&1; then
  if [ $ROOT -eq 1 ]; then iptables -L -n >/dev/null 2>&1 && NET_OK=1 && gruen "iptables nutzbar ($(iptables --version 2>/dev/null))" || rot "iptables vorhanden, aber nicht nutzbar"; else info "iptables vorhanden ($(iptables --version 2>/dev/null))"; fi
elif command -v nft >/dev/null 2>&1; then gelb "nur nftables – Docker braucht iptables (iptables-nft genügt)"
else gelb "weder iptables noch nft gefunden – kommt mit dem Docker-Paket meist mit"; fi
[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] && info "IP-Forwarding ist an" || info "IP-Forwarding ist aus (Docker schaltet es selbst an)"

# ── 6b. Ohne root (rootless Docker/Podman) ─────────────────────────────────
titel "6b. Container ohne root (rootless Docker/Podman)"
RL_OK=1
if [ -c /dev/net/tun ]; then
  # Entscheidend ist, ob ein NORMALER Benutzer das Gerät öffnen darf – root darf es fast immer.
  if [ $ROOT -eq 1 ] && id nobody >/dev/null 2>&1; then
    if su -s /bin/sh nobody -c 'exec 3<>/dev/net/tun' 2>/dev/null; then gruen "/dev/net/tun für normale Benutzer nutzbar (Benutzer-Netzwerk mit slirp4netns/pasta)"
    else
      MODE="$(stat -c %A /dev/net/tun)"
      case "$MODE" in
        *rw-) gelb "/dev/net/tun für normale Benutzer gesperrt, obwohl die Rechte offen sind ($MODE) – Sperre der Virtualisierung/des Anbieters; rootless-Netzwerk geht nicht" ;;
        *)    gelb "/dev/net/tun nur für root ($MODE) – rootless-Netzwerk geht nicht" ;;
      esac
      RL_OK=0
    fi
  elif (exec 3<>/dev/net/tun) 2>/dev/null; then gruen "/dev/net/tun nutzbar"
  else gelb "/dev/net/tun gesperrt – rootless-Netzwerk geht nicht"; RL_OK=0; fi
else gelb "/dev/net/tun fehlt – rootless-Netzwerk geht nicht"; RL_OK=0; fi
if [ -c /dev/fuse ] && grep -qw fuse /proc/filesystems 2>/dev/null; then gruen "fuse verfügbar (fuse-overlayfs für rootless)"
else gelb "kein fuse – rootless geht höchstens mit langsamem vfs-Speicher oder nativem overlay (Kernel ≥ 5.13)"; RL_OK=0; fi
[ $RL_OK -eq 0 ] && info "→ Container nur MIT root möglich (Docker/Podman verändert dann iptables)."

# ── 7. Sicherheit ──────────────────────────────────────────────────────────
titel "7. Sicherheit"
if grep -q '^Seccomp:' /proc/self/status 2>/dev/null; then gruen "seccomp verfügbar"; else gelb "kein seccomp – Container laufen, aber weniger abgeschottet"; fi
[ -d /sys/kernel/security/apparmor ] && info "AppArmor aktiv" ; command -v getenforce >/dev/null 2>&1 && info "SELinux: $(getenforce)"

# ── 8. Ressourcen ──────────────────────────────────────────────────────────
titel "8. Ressourcen (Richtwert Backstage-Betrieb: ≥ 1 GB RAM frei, ≥ 5 GB Platte)"
MEM=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo); AVAIL=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
info "RAM gesamt ${MEM} MB · frei ${AVAIL} MB · Swap $(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo) MB"
[ "$AVAIL" -ge 1024 ] && gruen "genug freier Arbeitsspeicher" || gelb "weniger als 1 GB frei – Backstage würde knapp"
DISK=$(df -BG /var/lib 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}')
info "Platte frei unter /var/lib: ${DISK} GB"
[ "${DISK:-0}" -ge 5 ] && gruen "genug Plattenplatz" || gelb "weniger als 5 GB frei"
info "CPU-Kerne: $(nproc)"

# ── 9. Was schon da ist ────────────────────────────────────────────────────
titel "9. Bereits vorhanden"
if command -v docker >/dev/null 2>&1; then
  info "Docker installiert: $(docker --version 2>/dev/null)"
  if docker info >/dev/null 2>&1; then gruen "Docker-Dienst läuft (Speichertreiber: $(docker info --format '{{.Driver}}' 2>/dev/null), cgroup: $(docker info --format '{{.CgroupVersion}}' 2>/dev/null))"
    if [ $RUNTEST -eq 1 ]; then docker run --rm hello-world >/dev/null 2>&1 && gruen "Test-Container 'hello-world' läuft" || rot "Test-Container startet nicht"; fi
  else gelb "Docker installiert, Dienst läuft aber nicht oder keine Rechte"; fi
else info "Docker ist (noch) nicht installiert"; fi
command -v podman >/dev/null 2>&1 && info "Podman vorhanden: $(podman --version)"
if command -v psql >/dev/null 2>&1 || (command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':5432 '); then info "PostgreSQL vorhanden/läuft (Port 5432) – Backstage könnte ein eigenes Schema darin nutzen"; else info "kein PostgreSQL gefunden – ginge auch als Container"; fi
if command -v ss >/dev/null 2>&1; then
  for p in 80 443 7007 3000; do L=$(ss -ltnp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {print $NF; exit}'); [ -n "$L" ] && info "Port $p belegt: $L"; done
fi

# ── Ergebnis ───────────────────────────────────────────────────────────────
titel "Ergebnis"
if [ $ISVZ -eq 1 ]; then
  if [ $NS_OK -eq 1 ] && [ $OVL_OK -eq 1 ] && [ $NET_OK -eq 1 ]; then
    echo "  Container-Virtualisierung ($VIRT), aber alle Funktionstests bestanden: Der Anbieter hat die nötigen Funktionen offenbar freigeschaltet."
    echo "  Restrisiko: Kernel und Freischaltung steuert der Anbieter. Letzter Beweis: Docker/Podman installieren und 'hello-world' starten."
  elif [ $ROOT -eq 1 ]; then
    rot "Container-Virtualisierung ($VIRT) ohne die nötigen Funktionen – vom Anbieter offenbar nicht freigeschaltet"
  fi
fi
echo "  ✔ $OK in Ordnung · ! $WARN Hinweise · ✘ $FAIL Probleme"
[ "${RL_OK:-1}" -eq 0 ] && echo "  Hinweis: ohne root (rootless) laufen hier keine Container – nur mit root."
if [ $FAIL -eq 0 ] && [ $WARN -le 3 ]; then echo "  → Docker sollte hier laufen."
elif [ $FAIL -eq 0 ]; then echo "  → Docker läuft hier wahrscheinlich – die Hinweise oben kurz ansehen."
else echo "  → Docker läuft hier vermutlich NICHT ohne Weiteres. Die ✘-Punkte entscheiden; bei OpenVZ/LXC den Anbieter fragen oder einen KVM-Server bzw. den Raspberry Pi nehmen."; fi
