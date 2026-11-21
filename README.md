# Spirit Tech Revolution — Infrastructure partagée

Infra commune à tous les projets Spirit Tech, déployée sur un VPS unique.
Un seul `docker compose up` démarre l'ensemble des services.

## Services

| Service | URL | Description |
|---|---|---|
| Keycloak 26 | `https://auth.spirittechrevolution.com` (seulement `/realms/…` hors master et `/resources/…`) | IAM — un realm par projet |
| Console d'administration Keycloak | tunnel SSH : `ssh -L 8081:127.0.0.1:8081 dinthialma` puis `http://localhost:8081/admin/` | Plus d'adresse publique (SE06) |
| Traefik v3 | `https://traefik.spirittechrevolution.com` (mot de passe `admin-auth`) | Reverse proxy + SSL Let's Encrypt |
| pgAdmin 4 | tunnel SSH : `ssh -L 5050:127.0.0.1:5050 dinthialma` puis `http://localhost:5050` | Gestion des bases PostgreSQL ; plus d'adresse publique (IN14) |
| MinIO console | tunnel SSH : `ssh -L 9001:127.0.0.1:9001 dinthialma` puis `http://localhost:9001` | Object storage S3 — interface web ; plus d'adresse publique |
| MinIO API S3 | `https://storage.spirittechrevolution.com` | Endpoint S3 pour les backends |
| Dozzle | `https://logs.spirittechrevolution.com` (mot de passe `admin-auth`) | Logs temps réel des containers |

Les consoles d'administration (Keycloak, pgAdmin, MinIO) ne sont plus servies sur
Internet depuis le 21/11/2026 : leurs ports sont publiés sur `127.0.0.1` du VPS
uniquement, et on y accède par tunnel SSH avec la clé d'administration
(un seul tunnel pour les trois : `ssh -L 8081:127.0.0.1:8081 -L 5050:127.0.0.1:5050 -L 9001:127.0.0.1:9001 dinthialma`).

## Prérequis

- VPS : `155.117.40.193` (spirit-tech-revolution-vps)
- Docker + Docker Compose installés
- DNS wildcard `*.spirittechrevolution.com` → `155.117.40.193` (configuré sur OVH)
- Ports 80 et 443 ouverts sur le VPS

## Première installation

```bash
git clone <repo> /opt/infra
cd /opt/infra

# 1. Créer le .env
cp .env.example .env
nano .env   # remplir toutes les valeurs

# 2. Initialiser (réseau Docker + acme.json)
chmod +x deploy.sh
./deploy.sh --init

# 3. Démarrer
./deploy.sh
```

## Mise à jour

```bash
cd /opt/infra
./deploy.sh
```

Ou manuellement :

```bash
git pull
docker compose --env-file .env up -d
```

## Architecture réseau

```
Internet
   │  HTTPS 443
   ▼
Traefik (réseau: proxy)
   ├── auth.spirittechrevolution.com  → keycloak:8080 (/realms/ hors master, /resources/)
   ├── storage.spirittechrevolution.com → minio:9000
   └── logs.spirittechrevolution.com → dozzle:8080

Réseau infra-internal (isolé, pas d'accès externe)
   ├── postgres-shared:5432
   ├── keycloak → postgres-shared
   └── pgadmin  → postgres-shared
```

Deux réseaux Docker :
- `proxy` — externe, partagé avec tous les projets. Traefik écoute dessus.
- `infra-internal` — interne, postgres et les services qui s'y connectent.

## Bases de données

Instance PostgreSQL 17 unique, une base par projet :

| Base | Projet | Schéma |
|---|---|---|
| `db-keycloak` | Keycloak | — |
| `db-dinthialma` | Dinthialma | `dinthialma` |
| `db-pharmagest` | PharmaGest | `pharmagest` |

Les bases sont créées automatiquement au premier démarrage via `postgres/init-db.sh`.

Pour ajouter un nouveau projet : éditer `postgres/init-db.sh` et ajouter un bloc `SELECT 'CREATE DATABASE...'`.

## Connecter un projet à l'infra

Dans le `docker-compose.yml` du projet, rejoindre les réseaux existants :

```yaml
networks:
  proxy:
    external: true
  infra-internal:
    external: true
    name: infra-internal
```

Variables d'environnement backend :
```env
DB_HOST=postgres-shared
DB_PORT=5432
KEYCLOAK_URL=https://auth.spirittechrevolution.com
MINIO_ENDPOINT=http://minio:9000
```

## Variables d'environnement (.env)

Voir `.env.example` pour la liste complète. Fichier `.env` jamais commité (`.gitignore`).

| Variable | Description |
|---|---|
| `INFRA_DOMAIN` | Domaine racine (`spirittechrevolution.com`) |
| `ACME_EMAIL` | Email pour les certificats Let's Encrypt |
| `TRAEFIK_BASIC_AUTH` | Basic auth du dashboard Traefik (généré avec `htpasswd`) |
| `POSTGRES_USER/PASSWORD` | Credentials PostgreSQL partagé |
| `KEYCLOAK_ADMIN_USER/PASSWORD` | Admin Keycloak |
| `PGADMIN_EMAIL/PASSWORD` | Admin pgAdmin |
| `MINIO_ROOT_USER/PASSWORD` | Admin MinIO |

## Commandes utiles

```bash
# Statut des containers
docker compose ps

# Logs d'un service
docker logs -f keycloak
docker logs -f traefik

# Vérifier les routeurs Traefik
curl -s http://localhost:8080/api/http/routers | python3 -m json.tool | grep -E '"name"|"rule"'

# Renouveler les certificats (vider acme.json et redémarrer Traefik)
rm acme.json && touch acme.json && chmod 600 acme.json
docker compose restart traefik
```

## Notes

- **Keycloak** : le healthcheck utilise bash `/dev/tcp` (pas de `curl` dans l'image UBI9).
  Un container `unhealthy` est retiré du routing Traefik — surveiller avec `docker ps`.
- **acme.json** : doit exister avec `chmod 600` avant le premier démarrage de Traefik.
  Si vide ou corrompu, supprimer et recréer pour forcer la ré-émission des certificats.
- **Scaling** : un seul container Keycloak (mode standalone). Pour le clustering,
  ajouter `KC_CACHE=ispn` et plusieurs replicas.

## Sauvegardes hors du VPS

Les sauvegardes quotidiennes (`scripts/backup-postgres.sh`, 02:00) restent 14 jours sur
le VPS. Un poste Windows vient chercher une copie chaque jour : **le poste se connecte au
VPS, jamais l'inverse**.

### Côté VPS (une seule fois)
```bash
sudo /opt/infra/scripts/installer-lecteur-sauvegardes.sh "ssh-ed25519 AAAA... sauvegarde-poste"
```
Crée l'utilisateur `backup-reader` : clé dédiée uniquement, SFTP en lecture seule,
enfermé dans `/opt/backups` (il ne voit que `/postgres`), sans shell ni tunnel.
Les sauvegardes deviennent lisibles par le groupe `backup-readers` ; chaque dossier
complet contient le marqueur `SAUVEGARDE_TERMINEE`.

### Côté poste Windows
```powershell
# 1. Clé dédiée (sans phrase de passe : utilisée par une tâche planifiée)
ssh-keygen -t ed25519 -N '""' -C sauvegarde-poste -f $HOME\.ssh\dinthialma_backup
# 2. Première connexion manuelle pour accepter l'empreinte du VPS (vérifier l'empreinte)
sftp -i $HOME\.ssh\dinthialma_backup backup-reader@<hôte>
# 3. Récupération manuelle (premier essai)
.\scripts\windows\recuperer-sauvegardes.ps1 -Hote <hôte>
# 4. Récupération automatique : tâche planifiée (sans droits administrateur)
.\scripts\windows\planifier-recuperation.ps1 -Hote <hôte>
```
Destination par défaut : `D:\Sauvegardes\dinthialma\postgres` (30 jours conservés),
journal dans `D:\Sauvegardes\dinthialma\journaux`. Code de sortie 2 si la copie la plus
récente a plus de 2 jours. Les sauvegardes contiennent des données personnelles :
disque chiffré (BitLocker), jamais dans un dossier synchronisé avec un cloud.

La tâche planifiée tourne chaque jour à 08:00, à l'ouverture de session (après
5 minutes) et dès que possible après un démarrage manqué. **Le PC doit être allumé,
la session ouverte et le réseau disponible** ; les jours manqués sont rattrapés tant
qu'ils sont encore sur le VPS (14 jours). Résultat dans la colonne « Résultat de la
dernière exécution » du Planificateur de tâches : `0` OK, `0x1` erreur, `0x2` copie
trop ancienne.
