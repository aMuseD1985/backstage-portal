#!/usr/bin/env bash
# Empfängt ein Release von GitHub Actions über SSH und spielt es ein.
# Wird NUR als erzwungener Befehl aus /opt/backstage/.ssh/authorized_keys aufgerufen (Benutzer backstage).
# Aufruf durch Actions:  ssh backstage@server "deploy build-JJJJMMTT-N" < backstage-runtime.tar.gz
# Startet die neue Version nicht, geht es automatisch auf die vorige zurück – und der Lauf in Actions wird rot.
set -euo pipefail
BASE=/opt/backstage
HEALTH=http://127.0.0.1:7007/.backstage/health/v1/readiness
MAXBYTES=1500000000

CMD="${SSH_ORIGINAL_COMMAND:-}"
if [[ ! "$CMD" =~ ^deploy\ (build-[0-9]{8}-[0-9]+)$ ]]; then
  echo "Erlaubt ist nur: deploy build-JJJJMMTT-N" >&2; exit 2
fi
TAG="${BASH_REMATCH[1]}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
head -c "$MAXBYTES" > "$TMP/runtime.tgz"
[ -s "$TMP/runtime.tgz" ] || { echo "Kein Paket empfangen." >&2; exit 1; }
gzip -t "$TMP/runtime.tgz" || { echo "Paket beschädigt." >&2; exit 1; }
echo "Empfangen: $TAG ($(du -h "$TMP/runtime.tgz" | cut -f1))"

PREV="$(readlink -f "$BASE/current" 2>/dev/null || true)"
NEW="$BASE/releases/$TAG"
rm -rf "$NEW"; mkdir -p "$NEW"
tar xzf "$TMP/runtime.tgz" -C "$NEW" --no-same-owner

WANT="$(cut -d. -f1 "$NEW/NODE_VERSION")"; HAVE="$("$BASE/node/bin/node" --version | cut -d. -f1)"
if [ "$WANT" != "$HAVE" ]; then
  echo "Gebaut mit Node $WANT, auf dem Server ist $HAVE – NODE_MAJOR in install.sh anpassen." >&2; rm -rf "$NEW"; exit 1
fi

ln -sfn "$NEW" "$BASE/current"
sudo -n /usr/bin/systemctl restart backstage

printf 'Warte auf Backstage '
for _ in $(seq 1 90); do curl -fs "$HEALTH" >/dev/null 2>&1 && break; printf '.'; sleep 2; done; echo
if curl -fs "$HEALTH" >/dev/null 2>&1; then
  echo "Backstage läuft: $TAG ($(cat "$NEW/COMMIT" 2>/dev/null))"
  ls -1dt "$BASE"/releases/*/ | tail -n +4 | xargs -r rm -rf     # die letzten 3 Versionen behalten
  exit 0
fi
echo "Neue Version startet nicht – Protokoll auf dem Server: journalctl -u backstage -n 80" >&2
if [ -n "$PREV" ] && [ -d "$PREV" ] && [ "$PREV" != "$NEW" ]; then
  ln -sfn "$PREV" "$BASE/current"; sudo -n /usr/bin/systemctl restart backstage
  echo "Zurück auf $(basename "$PREV")." >&2
fi
exit 1
