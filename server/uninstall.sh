#!/usr/bin/env bash
# Entfernt Backstage vollständig: Dienst, nginx-Seite, Datenbank, Ordner, Benutzer.   sudo bash /opt/backstage/uninstall.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Bitte als root: sudo bash $0"; exit 1; }
read -rp "Backstage wirklich komplett entfernen (Dienst, Datenbank, /opt/backstage)? [ja/nein] " A
[ "$A" = "ja" ] || { echo "Abgebrochen."; exit 0; }
systemctl disable --now backstage 2>/dev/null || true
rm -f /etc/systemd/system/backstage.service; systemctl daemon-reload
rm -f /etc/nginx/sites-enabled/backstage.conf /etc/nginx/sites-available/backstage.conf /etc/nginx/conf.d/backstage.conf /etc/nginx/backstage.htpasswd
nginx -t && systemctl reload nginx
sudo -u postgres dropdb --if-exists backstage
sudo -u postgres psql -q -c 'DROP ROLE IF EXISTS backstage'
rm -rf /opt/backstage
id backstage >/dev/null 2>&1 && userdel backstage || true
echo "Backstage ist entfernt. (Das HTTPS-Zertifikat ggf. mit: certbot delete --cert-name <domain>)"
