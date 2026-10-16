#!/usr/bin/env bash
# Holt das neueste Release (backstage-runtime.tar.gz) von GitHub und startet Backstage damit neu.
# Startet die neue Version nicht, geht es automatisch auf die vorige zurück.   sudo bash /opt/backstage/deploy.sh [--force]
set -euo pipefail
BASE=/opt/backstage
HEALTH=http://127.0.0.1:7007/.backstage/health/v1/readiness
[ "$(id -u)" -eq 0 ] || { echo "Bitte als root: sudo bash $0"; exit 1; }
# shellcheck disable=SC1091
. "$BASE/config/deploy.conf"
TOKEN="$(grep '^GITHUB_TOKEN=' "$BASE/config/backstage.env" | cut -d= -f2-)"
AUTH=(-H "Authorization: Bearer $TOKEN" -H "X-GitHub-Api-Version: 2022-11-28")

REL="$(curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest")"
TAG="$(printf '%s' "$REL" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
ASSET="$(printf '%s' "$REL" | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin)["assets"] if x["name"]=="backstage-runtime.tar.gz"]; print(a[0]["url"] if a else "")')"
[ -n "$ASSET" ] || { echo "Release $TAG hat keine backstage-runtime.tar.gz"; exit 1; }

PREV="$(readlink -f "$BASE/current" 2>/dev/null || true)"
if [ "$PREV" = "$BASE/releases/$TAG" ] && [ "${1:-}" != "--force" ]; then echo "Schon aktuell: $TAG"; exit 0; fi

echo "Lade $TAG …"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL "${AUTH[@]}" -H "Accept: application/octet-stream" -o "$TMP/runtime.tgz" "$ASSET"
rm -rf "$BASE/releases/$TAG"; mkdir -p "$BASE/releases/$TAG"
tar xzf "$TMP/runtime.tgz" -C "$BASE/releases/$TAG"

WANT="$(cut -d. -f1 "$BASE/releases/$TAG/NODE_VERSION")"; HAVE="$("$BASE/node/bin/node" --version | cut -d. -f1)"
if [ "$WANT" != "$HAVE" ]; then
  echo "Gebaut mit Node $WANT, auf dem Server ist $HAVE – in install.sh NODE_MAJOR anpassen und erneut ausführen."; exit 1
fi
chown -R backstage:backstage "$BASE/releases/$TAG"
ln -sfn "$BASE/releases/$TAG" "$BASE/current"
systemctl restart backstage

echo -n "Warte auf Backstage "
for _ in $(seq 1 90); do curl -fs "$HEALTH" >/dev/null 2>&1 && break; echo -n "."; sleep 2; done; echo
if curl -fs "$HEALTH" >/dev/null 2>&1; then
  echo "Backstage läuft: $TAG ($(cat "$BASE/current/COMMIT" 2>/dev/null))"
  ls -1dt "$BASE"/releases/*/ | tail -n +4 | xargs -r rm -rf     # nur die letzten 3 Versionen behalten
else
  echo "Neue Version startet nicht. Protokoll: journalctl -u backstage -n 80"
  if [ -n "$PREV" ] && [ -d "$PREV" ] && [ "$PREV" != "$BASE/releases/$TAG" ]; then
    ln -sfn "$PREV" "$BASE/current"; systemctl restart backstage; echo "Zurück auf $(basename "$PREV")."
  fi
  exit 1
fi
