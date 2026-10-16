#!/usr/bin/env bash
# Richtet Backstage auf diesem Server ein – ohne Docker. Einmal als root ausführen; erneut ausführen schadet nicht.
#   sudo DOMAIN=backstage.anderheyden.de bash install.sh
# Danach: HTTPS mit certbot (siehe Ende). Updates spielt GitHub Actions per SSH ein (Benutzer backstage);
# von Hand geht es weiter mit: sudo bash /opt/backstage/deploy.sh
set -euo pipefail

DOMAIN="${DOMAIN:-backstage.anderheyden.de}"
REPO="${REPO:-aMuseD1985/backstage-portal}"
NODE_MAJOR="${NODE_MAJOR:-22}"          # muss zur Node-Version im Build-Workflow passen
WITH_TECHDOCS="${WITH_TECHDOCS:-1}"     # 0 = ohne MkDocs/Python
BASE=/opt/backstage
HERE="$(cd "$(dirname "$0")" && pwd)"
schritt() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "Bitte als root: sudo bash $0"; exit 1; }
for c in nginx psql systemctl curl tar xz openssl python3 sha256sum ssh-keygen visudo sshd; do
  command -v "$c" >/dev/null 2>&1 || { echo "Es fehlt: $c"; exit 1; }
done
id postgres >/dev/null 2>&1 || { echo "Kein Systembenutzer 'postgres' – läuft PostgreSQL lokal?"; exit 1; }
echo "Domain: $DOMAIN · Repo: $REPO · Node $NODE_MAJOR · TechDocs: $WITH_TECHDOCS"

schritt "1. Benutzer und Ordner"
# Eigener Benutzer backstage: kein Passwort (Anmeldung nur per Schlüssel), Shell nur für den erzwungenen Deploy-Befehl.
if id backstage >/dev/null 2>&1; then usermod --home "$BASE" --shell /bin/bash backstage
else useradd --system --home-dir "$BASE" --shell /bin/bash backstage; fi
usermod -p '*' backstage
mkdir -p "$BASE/node" "$BASE/releases" "$BASE/config" "$BASE/data/techdocs" "$BASE/.ssh"

schritt "2. Node.js $NODE_MAJOR – eigener Ordner, nicht systemweit"
if [ -x "$BASE/node/bin/node" ] && "$BASE/node/bin/node" --version | grep -q "^v$NODE_MAJOR\."; then
  echo "vorhanden: $("$BASE/node/bin/node" --version)"
else
  URL="https://nodejs.org/dist/latest-v$NODE_MAJOR.x"
  SUMS="$(curl -fsSL "$URL/SHASUMS256.txt")"
  FILE="$(printf '%s\n' "$SUMS" | awk '/linux-x64\.tar\.xz$/{print $2}')"
  SUM="$(printf '%s\n' "$SUMS" | awk '/linux-x64\.tar\.xz$/{print $1}')"
  [ -n "$FILE" ] || { echo "Node-Download nicht gefunden"; exit 1; }
  curl -fsSLo "/tmp/$FILE" "$URL/$FILE"
  echo "$SUM  /tmp/$FILE" | sha256sum -c -
  rm -rf "$BASE/node"; mkdir -p "$BASE/node"
  tar xJf "/tmp/$FILE" -C "$BASE/node" --strip-components=1; rm -f "/tmp/$FILE"
  echo "installiert: $("$BASE/node/bin/node" --version)"
fi

if [ "$WITH_TECHDOCS" = "1" ]; then
  schritt "3. MkDocs für TechDocs – eigene Python-Umgebung"
  python3 -c 'import ensurepip' >/dev/null 2>&1 || apt-get install -y python3-venv
  if [ ! -x "$BASE/venv/bin/mkdocs" ]; then
    python3 -m venv "$BASE/venv"
    "$BASE/venv/bin/pip" install --quiet --upgrade pip
    "$BASE/venv/bin/pip" install --quiet mkdocs-techdocs-core
  fi
  echo "$("$BASE/venv/bin/mkdocs" --version)"
fi

schritt "4. Datenbank im vorhandenen PostgreSQL"
ENV="$BASE/config/backstage.env"
if [ -f "$ENV" ]; then PGPASS="$(grep '^POSTGRES_PASSWORD=' "$ENV" | cut -d= -f2-)"; else PGPASS="$(openssl rand -hex 24)"; fi
sudo -u postgres psql -v ON_ERROR_STOP=1 -q -v pw="$PGPASS" << 'SQL'
SELECT format('CREATE ROLE backstage LOGIN PASSWORD %L', :'pw') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'backstage') \gexec
SELECT format('ALTER ROLE backstage WITH LOGIN PASSWORD %L', :'pw') \gexec
SQL
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = 'backstage'" | grep -q 1; then
  sudo -u postgres createdb -O backstage backstage
fi
echo "Datenbank 'backstage' mit Benutzer 'backstage' bereit (Schemas legt Backstage selbst an)"

schritt "5. Zugangsdaten"
if [ ! -f "$ENV" ]; then
  echo "GitHub-Token: Fine-grained, nur Lesen (Contents + Metadata) für $REPO und die Projekt-Repos."
  read -rsp "GitHub-Token: " GHTOK; echo
  [ -n "$GHTOK" ] || { echo "Ohne Token geht es nicht"; exit 1; }
  ( umask 077; printf 'POSTGRES_HOST=127.0.0.1\nPOSTGRES_PORT=5432\nPOSTGRES_USER=backstage\nPOSTGRES_PASSWORD=%s\nGITHUB_TOKEN=%s\n' "$PGPASS" "$GHTOK" > "$ENV" )
else
  echo "vorhanden: $ENV (Token ändern: Datei bearbeiten, dann systemctl restart backstage)"
fi

schritt "6. Konfiguration und Werkzeuge"
sed -e "s#__DOMAIN__#$DOMAIN#g" -e "s#__REPO__#$REPO#g" "$HERE/app-config.server.yaml" > "$BASE/config/app-config.server.yaml"
printf 'REPO=%s\n' "$REPO" > "$BASE/config/deploy.conf"
install -m 755 "$HERE/deploy.sh" "$BASE/deploy.sh"
install -m 755 "$HERE/receive.sh" "$BASE/receive.sh"
install -m 755 "$HERE/uninstall.sh" "$BASE/uninstall.sh"
chown -R backstage:backstage "$BASE"
chmod 755 "$BASE"; chmod 600 "$ENV"

schritt "7. systemd-Dienst"
install -m 644 "$HERE/backstage.service" /etc/systemd/system/backstage.service
systemctl daemon-reload
systemctl enable backstage >/dev/null 2>&1
echo "Dienst 'backstage' eingerichtet (startet nach dem ersten Deploy)"

schritt "8. nginx mit Passwortschutz"
HT=/etc/nginx/backstage.htpasswd
if [ ! -f "$HT" ]; then
  read -rp "Benutzername fürs Portal: " PU
  read -rsp "Passwort fürs Portal: " PP; echo
  printf '%s:%s\n' "$PU" "$(openssl passwd -apr1 "$PP")" > "$HT"
  chown root:www-data "$HT"; chmod 640 "$HT"
fi
if [ -d /etc/nginx/sites-available ]; then SITE=/etc/nginx/sites-available/backstage.conf; else SITE=/etc/nginx/conf.d/backstage.conf; fi
if [ -f "$SITE" ] && grep -q 'portal_gate' "$SITE"; then
  GATE="$(grep -o '"[0-9a-f]\{48\}"' "$SITE" | head -1 | tr -d '"')"   # vorhandenes Cookie behalten
fi
GATE="${GATE:-$(openssl rand -hex 24)}"
if [ -f "$SITE" ] && grep -q 'listen 443' "$SITE"; then
  echo "nginx-Seite hat schon HTTPS (certbot) – lasse sie unverändert: $SITE"
else
  sed -e "s#__DOMAIN__#$DOMAIN#g" -e "s#__GATE__#$GATE#g" "$HERE/nginx-backstage.conf" > "$SITE"
  [ -d /etc/nginx/sites-enabled ] && ln -sf "$SITE" /etc/nginx/sites-enabled/backstage.conf
fi
nginx -t
systemctl reload nginx

schritt "9. Deploy-Zugang für GitHub Actions (SSH)"
# Neustart darf backstage – und sonst nichts
SUDO=/etc/sudoers.d/backstage
printf 'backstage ALL=(root) NOPASSWD: /usr/bin/systemctl restart backstage\n' > "$SUDO.tmp"
visudo -cf "$SUDO.tmp" >/dev/null && install -m 440 "$SUDO.tmp" "$SUDO"; rm -f "$SUDO.tmp"
AK="$BASE/.ssh/authorized_keys"
SSHPORT="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"; SSHPORT="${SSHPORT:-22}"
SSHHOST="${SSH_HOST:-$(hostname -f)}"
if [ -s "$AK" ] && [ "${NEW_DEPLOY_KEY:-0}" != "1" ]; then
  echo "Deploy-Schlüssel ist schon eingerichtet (neu erzeugen: NEW_DEPLOY_KEY=1 bash install.sh)."
else
  K="$(mktemp -d)"
  ssh-keygen -q -t ed25519 -N '' -C "github-actions@backstage-portal" -f "$K/deploy"
  # restrict = keine Shell, keine Weiterleitungen; command = nur der Empfang eines Releases
  printf 'restrict,command="%s/receive.sh" %s\n' "$BASE" "$(cat "$K/deploy.pub")" > "$AK"
  chown -R backstage:backstage "$BASE/.ssh"; chmod 700 "$BASE/.ssh"; chmod 600 "$AK"
  if [ "$SSHPORT" = "22" ]; then KH="$SSHHOST $(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"
  else KH="[$SSHHOST]:$SSHPORT $(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"; fi
  cat << TXT

  ┌─ Jetzt in GitHub eintragen: Repo $REPO → Settings → Secrets and variables → Actions → New repository secret
  │  DEPLOY_SSH_HOST         $SSHHOST
  │  DEPLOY_SSH_PORT         $SSHPORT
  │  DEPLOY_SSH_KNOWN_HOSTS  $KH
  │  DEPLOY_SSH_KEY          (der private Schlüssel unten – komplett, mit BEGIN- und END-Zeile)
  └─ Er wird nur JETZT angezeigt und danach vom Server gelöscht.

TXT
  cat "$K/deploy"; echo
  rm -rf "$K"
fi
chown -R backstage:backstage "$BASE/.ssh"; chmod 700 "$BASE/.ssh"
AU="$(sshd -T 2>/dev/null | awk '$1=="allowusers"{$1=""; print}')"
if [ -n "$AU" ] && ! printf ' %s ' "$AU" | grep -q ' backstage '; then
  echo "ACHTUNG: In der SSH-Konfiguration steht 'AllowUsers$AU' – backstage fehlt dort."
  echo "         Bitte 'backstage' in /etc/ssh/sshd_config ergänzen und 'systemctl reload ssh' (nicht automatisch geändert)."
fi
AG="$(sshd -T 2>/dev/null | awk '$1=="allowgroups"{$1=""; print}')"
[ -n "$AG" ] && echo "Hinweis: In der SSH-Konfiguration steht 'AllowGroups$AG' – backstage muss in einer dieser Gruppen sein."

schritt "10. Erstes Deploy"
bash "$BASE/deploy.sh" || echo "Erstes Deploy noch nicht möglich – gibt es schon ein Release? (Actions → „Backstage anlegen (einmalig)“). Danach: sudo bash $BASE/deploy.sh"

schritt "Fertig – noch zu tun"
cat << TXT
  1. DNS: $DOMAIN → IP dieses Servers (A-Eintrag), falls noch nicht geschehen.
  2. HTTPS:   sudo certbot --nginx -d $DOMAIN
     (Das Schutz-Cookie ist 'Secure' – ohne HTTPS lädt die Oberfläche, die Daten aber nicht.)
  3. Öffnen:  https://$DOMAIN  → Benutzer/Passwort → „Enter“ als Gast.
  4. Die vier DEPLOY_SSH_*-Werte von oben als Secrets eintragen, dann Actions → „Backstage bauen“ → Run workflow:
     ab jetzt spielt GitHub jedes neue Release selbst ein.
  Von Hand:   sudo bash $BASE/deploy.sh      Protokoll: journalctl -u backstage -f
  Entfernen:  sudo bash $BASE/uninstall.sh
TXT
