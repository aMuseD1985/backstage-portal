# Anderheyden Portal (Backstage)

Ein Backstage-Portal für alle eigenen Projekte – **ohne Docker**. Gebaut wird bei GitHub, der Server lädt nur die fertige Laufzeit.

| Teil | Wo | Was |
|---|---|---|
| Katalog | `catalog/` | alle Projekte, Server und Schnittstellen im Backstage-Format |
| App | `app/` | entsteht einmalig per Workflow „Backstage anlegen (einmalig)“ |
| Bauen | `.github/workflows/build.yml` | baut bei jeder Änderung an `app/` ein Release `backstage-runtime.tar.gz` |
| Server | `server/` | Einrichten, Aktualisieren, Entfernen – Node.js und MkDocs in eigenen Ordnern unter `/opt/backstage` |

Auf dem Server liegt alles unter `/opt/backstage`, dazu ein systemd-Dienst, eine nginx-Seite und eine Datenbank `backstage` im vorhandenen PostgreSQL (ein Schema je Plugin). Backstage lauscht nur auf `127.0.0.1:7007`.

## Einrichten

**0. Reste des Podman-Tests entfernen** (auf dem Server):

```bash
sudo systemctl disable --now podman.socket podman.service podman-auto-update.timer podman-restart.service 2>/dev/null
sudo apt purge -y podman buildah slirp4netns uidmap fuse-overlayfs crun conmon netavark aardvark-dns catatonit passt containernetworking-plugins && sudo apt autoremove -y
sudo userdel -r backstage      # der Test-Benutzer; install.sh legt ihn sauber neu an
```

**1. Repo bei GitHub:** privates Repo `aMuseD1985/backstage-portal` anlegen (leer), dann im VS-Code-Terminal:

```bash
git clone ~/Downloads/backstage-portal.bundle backstage-portal && cd backstage-portal
git remote set-url origin https://github.com/aMuseD1985/backstage-portal.git
git push -u origin main
```

**2. Backstage anlegen:** auf GitHub → **Actions** → „Backstage anlegen (einmalig)“ → **Run workflow**. Das legt `app/` an und baut das erste Release (rund 15–25 Minuten). Ergebnis unter **Releases**.

**3. Lese-Schlüssel für den Server:** Profilbild → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token:
- Repository access: **Only select repositories** → `backstage-portal` und die Projekt-Repos, deren Katalog/Doku Backstage lesen soll
- Permissions: **Contents: Read-only** (Metadata: Read-only kommt automatisch)
- Expiration: so lang, wie du magst – beim Ablauf in `/opt/backstage/config/backstage.env` ersetzen und `systemctl restart backstage`

**4. DNS:** A-Eintrag `backstage.anderheyden.de` → IP des Servers.

**5. Auf dem Server** (Ordner `server/` hinkopieren, z. B. `scp -r server root@v21886:/root/backstage-setup`):

```bash
cd /root/backstage-setup
sudo DOMAIN=backstage.anderheyden.de bash install.sh
sudo certbot --nginx -d backstage.anderheyden.de
```

`install.sh` fragt nach dem GitHub-Schlüssel und nach Benutzer/Passwort fürs Portal. Erneut ausführen schadet nicht.

**6. Öffnen:** `https://backstage.anderheyden.de` → Benutzer/Passwort → als Gast eintreten.

## Im Alltag

| Was | Wie |
|---|---|
| Katalog ändern | `catalog/*.yaml` bearbeiten, pushen – Backstage liest den Katalog von selbst neu (dauert wenige Minuten), kein Deploy nötig |
| Projekt mit eigener `catalog-info.yaml` | in `catalog/all.yaml` als Ziel eintragen, Eintrag aus `systems.yaml` entfernen |
| Backstage aktualisieren | in `app/`: `yarn backstage-cli versions:bump`, pushen → Release wird gebaut → auf dem Server `sudo bash /opt/backstage/deploy.sh` |
| Protokoll | `journalctl -u backstage -f` |
| Entfernen | `sudo bash /opt/backstage/uninstall.sh` |

`deploy.sh` springt automatisch auf die vorige Version zurück, wenn eine neue nicht startet, und behält die letzten drei Versionen.

## Gut zu wissen

- **Schutz:** nginx fragt einmal nach Benutzer/Passwort und setzt ein geheimes Cookie; die API-Pfade sind nur mit diesem Cookie erreichbar. In Backstage selbst meldet man sich als Gast an. Reines Basic-Auth genügt nicht, weil Backstage bei API-Aufrufen ein eigenes `Authorization`-Feld schickt.
- **Speicher:** Der Dienst ist auf 1,2 GB begrenzt (`MemoryMax`), damit die anderen Anwendungen auf dem Server nie leiden.
- **Node-Version:** Build (`node-version: '22'`) und Server (`NODE_MAJOR=22`) müssen dieselbe Hauptversion haben; `deploy.sh` prüft das.
- **Warum ohne Docker:** Der Server ist ein OpenVZ-Container; Podman ohne root scheitert an fehlendem `/dev/net/tun` und `fuse`, Docker würde iptables umbauen.
