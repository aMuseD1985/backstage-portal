# Backstage Portal

Ein Backstage-Portal für alle eigenen Projekte – **ohne Docker**. Gebaut wird bei GitHub, und GitHub spielt jedes neue Release **per SSH** auf den Server (eigener Benutzer `backstage`, der nur diesen einen Befehl ausführen darf).

| Teil | Wo | Was |
|---|---|---|
| Katalog | `catalog/` | alle Projekte, Server und Schnittstellen im Backstage-Format |
| App | `app/` | entsteht einmalig per Workflow „Backstage anlegen (einmalig)“ |
| Bauen und Ausrollen | `.github/workflows/build.yml` | baut bei jeder Änderung an `app/` ein Release `backstage-runtime.tar.gz` und spielt es per SSH ein |
| Server | `server/` | Einrichten, Aktualisieren, Entfernen – Node.js und MkDocs in eigenen Ordnern unter `/opt/backstage` |
| Werkzeuge | `tools/` | `docker-check.sh`: prüft, ob und wie Container auf einem Server laufen würden (verändert nichts) |

Auf dem Server liegt alles unter `/opt/backstage`, dazu ein systemd-Dienst, eine nginx-Seite und eine Datenbank `backstage` im vorhandenen PostgreSQL (ein Schema je Plugin). Backstage lauscht nur auf `127.0.0.1:7007`.

## Einrichten

**1. Repo bei GitHub:** privates Repo `aMuseD1985/backstage-portal` anlegen (leer), dann im VS-Code-Terminal:

```bash
git clone ~/Downloads/backstage-portal.bundle backstage-portal && cd backstage-portal
git remote set-url origin https://github.com/aMuseD1985/backstage-portal.git
git push -u origin main
```

**2. Backstage anlegen:** auf GitHub → **Actions** → „Backstage anlegen (einmalig)“ → **Run workflow**. Das legt `app/` an und baut das erste Release (rund 15–25 Minuten). Ergebnis unter **Releases**.

**3. Lese-Schlüssel für den Server** (eigener Schlüssel nur für den Server, getrennt von allen anderen): Profilbild → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token:
- Repository access: **Only select repositories** → `backstage-portal` und die Projekt-Repos, deren Katalog/Doku Backstage lesen soll
- Permissions: **Contents: Read-only** (Metadata: Read-only kommt automatisch)
- Expiration: so lang, wie du magst – beim Ablauf in `/opt/backstage/config/backstage.env` ersetzen und `systemctl restart backstage`

**4. DNS:** A-Eintrag `backstage.anderheyden.de` → IP des Servers.

**5. Auf dem Server:**

```bash
git clone https://github.com/aMuseD1985/backstage-portal.git /root/backstage-portal
cd /root/backstage-portal/server
sudo DOMAIN=backstage.anderheyden.de bash install.sh
sudo certbot --nginx -d backstage.anderheyden.de
```

Ist das Repo privat, beim `git clone` den Lese-Schlüssel aus Schritt 3 als Passwort angeben (Benutzername beliebig) – oder den Ordner `server/` per `scp` auf den Server kopieren.

`install.sh` fragt nach dem GitHub-Schlüssel und nach Benutzer/Passwort fürs Portal. Erneut ausführen schadet nicht.
Am Ende zeigt es **einmalig** die Werte für den SSH-Deploy-Zugang – der private Schlüssel wird danach vom Server gelöscht.

**6. Deploy-Zugang bei GitHub eintragen:** Repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**, viermal:

| Name | Wert (aus der Ausgabe von `install.sh`) |
|---|---|
| `DEPLOY_SSH_HOST` | Servername, z. B. `v21886.1blu.de` |
| `DEPLOY_SSH_PORT` | SSH-Port, meist `22` |
| `DEPLOY_SSH_KNOWN_HOSTS` | die Zeile mit dem Host-Schlüssel des Servers (schützt vor untergeschobenen Servern) |
| `DEPLOY_SSH_KEY` | der private Schlüssel, komplett mit `-----BEGIN …` und `-----END …` |

Danach **Actions** → „Backstage bauen“ → **Run workflow** – ab jetzt spielt GitHub jedes neue Release selbst ein. Steht in der SSH-Konfiguration des Servers `AllowUsers`, weist `install.sh` darauf hin: dann `backstage` dort ergänzen.

**7. Öffnen:** `https://backstage.anderheyden.de` → Benutzer/Passwort → als Gast eintreten.

## Im Alltag

| Was | Wie |
|---|---|
| Katalog ändern | `catalog/*.yaml` bearbeiten, pushen – Backstage liest den Katalog von selbst neu (dauert wenige Minuten), kein Deploy nötig |
| Projekt mit eigener `catalog-info.yaml` | in `catalog/all.yaml` als Ziel eintragen, Eintrag aus `systems.yaml` entfernen |
| Backstage aktualisieren | in `app/`: `yarn backstage-cli versions:bump`, pushen → GitHub baut und spielt es per SSH ein |
| Von Hand einspielen | auf dem Server `sudo bash /opt/backstage/deploy.sh` (holt das neueste Release) |
| Deploy-Schlüssel erneuern | `sudo NEW_DEPLOY_KEY=1 bash install.sh`, dann `DEPLOY_SSH_KEY` bei GitHub ersetzen |
| Protokoll | `journalctl -u backstage -f` |
| Entfernen | `sudo bash /opt/backstage/uninstall.sh` |

Beim Einspielen (per SSH oder von Hand) geht es automatisch auf die vorige Version zurück, wenn eine neue nicht startet – der Lauf in Actions wird dann rot. Die letzten drei Versionen bleiben auf dem Server.

## Gut zu wissen

- **Schutz:** nginx fragt einmal nach Benutzer/Passwort und setzt ein geheimes Cookie; die API-Pfade sind nur mit diesem Cookie erreichbar. In Backstage selbst meldet man sich als Gast an. Reines Basic-Auth genügt nicht, weil Backstage bei API-Aufrufen ein eigenes `Authorization`-Feld schickt.
- **Deploy-Zugang:** Der Schlüssel in `/opt/backstage/.ssh/authorized_keys` ist auf `restrict` und den erzwungenen Befehl `receive.sh` festgelegt – keine Shell, keine Tunnel. Der Benutzer `backstage` hat kein Passwort und darf per `sudo` ausschließlich `systemctl restart backstage`.
- **Speicher:** Der Dienst ist auf 1,2 GB begrenzt (`MemoryMax`), damit die anderen Anwendungen auf dem Server nie leiden.
- **Node-Version:** Build (`node-version: '22'`) und Server (`NODE_MAJOR=22`) müssen dieselbe Hauptversion haben; `deploy.sh` prüft das.
- **Warum ohne Docker:** Der Server ist ein OpenVZ-Container. Container mit root würden laufen, bauen aber iptables um (freigegebene Ports umgehen die Firewall); ohne root sperrt OpenVZ `/dev/net/tun` für normale Benutzer, und `fuse` fehlt. Nachprüfen mit `sudo bash tools/docker-check.sh` – das Script verändert nichts.
