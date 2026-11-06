# Mise en ligne sur OVHcloud + pipeline CI/CD

Architecture en production (un seul VPS) :

```
Internet ──443──▶ Caddy (HTTPS auto) ──▶ frontend (Nginx + Angular) ──/api, /uploads──▶ backend (Quarkus) ──▶ MongoDB
```

| Fichier | Rôle |
|---|---|
| `.gitlab-ci.yml` + `backend/.gitlab-ci.yml` + `frontend/.gitlab-ci.yml` | Pipeline GitLab |
| `.github/workflows/ci-cd.yml` | Même pipeline pour GitHub Actions |
| `deploy/docker-compose.prod.yml`, `deploy/Caddyfile` | Production (copiés sur le serveur à chaque déploiement) |
| `deploy/.env.prod.example` | Modèle du fichier de secrets du serveur |
| `deploy/server-setup.sh` | Préparation du VPS (Docker, pare-feu, utilisateur deploy, clés JWT, sauvegardes) |

Pipeline : **build** (chaque push / merge request) → **images Docker** (branche principale) → **déploiement SSH** sur le VPS.

---

## Étape 1 — Commander chez OVHcloud
1. **VPS** : gamme VPS, Ubuntu 24.04, **4 Go de RAM minimum** (MongoDB + Quarkus + Nginx), datacenter Europe (Gravelines/Strasbourg, proche de la Tunisie).
2. **Nom de domaine** : un `.com`/`.shop`… chez OVH, ou un `.tn` chez un registrar tunisien agréé ATI (on pointe ensuite ses DNS de la même façon).
3. **(Optionnel) E-mail** : une offre e-mail OVH sur le domaine pour `no-reply@votredomaine` (SMTP `ssl0.ovh.net`, port 465, SSL).

## Étape 2 — DNS
Dans l'espace client OVH → *Noms de domaine* → *Zone DNS* :
- `A`  `@`   → adresse IPv4 du VPS
- `A`  `www` → adresse IPv4 du VPS
(ajoutez aussi les `AAAA` si le VPS a une IPv6). Propagation : quelques minutes à quelques heures.

## Étape 3 — Clé SSH du pipeline (sur votre PC)
```bash
ssh-keygen -t ed25519 -f techstore-deploy -C "techstore-ci" -N ""
# techstore-deploy      -> secret SSH_PRIVATE_KEY du pipeline
# techstore-deploy.pub  -> installée sur le serveur à l'étape 4
```

## Étape 4 — Préparer le serveur (une seule fois)
```bash
scp deploy/server-setup.sh ubuntu@IP_DU_VPS:
ssh ubuntu@IP_DU_VPS "sudo bash server-setup.sh '$(cat techstore-deploy.pub)'"
```
Le script installe Docker, active le pare-feu (22/80/443 seulement), crée l'utilisateur `deploy`,
génère les **clés JWT de production** dans `/opt/techstore/keys` et programme une sauvegarde MongoDB quotidienne.

Puis créez le fichier de secrets :
```bash
ssh ubuntu@IP_DU_VPS
sudo -u deploy nano /opt/techstore/.env     # contenu : deploy/.env.prod.example, avec VOS valeurs
sudo chmod 600 /opt/techstore/.env
```
Mots de passe forts : `openssl rand -base64 24`.

## Étape 5 — Pousser le code et configurer le pipeline

### GitLab
1. Créez le projet et poussez : `git init && git add . && git commit -m "TechStore" && git remote add origin … && git push -u origin main`
2. *Settings → CI/CD → Variables* :
   - `SSH_PRIVATE_KEY` — **type File**, protégée, contenu de `techstore-deploy`
   - `SSH_KNOWN_HOSTS` — résultat de `ssh-keyscan IP_DU_VPS`
   - `DEPLOY_HOST` — IP du VPS ; `DEPLOY_USER` — `deploy`
3. Le registre d'images GitLab est utilisé automatiquement (`$CI_REGISTRY_IMAGE`).

### GitHub
1. Poussez le dépôt sur GitHub (branche `main`).
2. *Settings → Secrets and variables → Actions* : `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `DEPLOY_HOST`, `DEPLOY_USER` (mêmes valeurs).
3. *Settings → Environments* : créez `production` (vous pouvez y exiger une validation manuelle avant chaque déploiement).
4. Les images vont sur `ghcr.io/<compte>/<dépôt>/backend|frontend`.

> Utilisez **l'un ou l'autre** pour déployer (pas les deux en même temps sur le même serveur).

## Étape 6 — Premier déploiement
Un push sur `main` lance tout. Au premier démarrage, le backend crée les collections, les index et le compte admin (`ADMIN_EMAIL` / `ADMIN_PASSWORD` du `.env`).
Caddy obtient le certificat HTTPS tout seul (il faut que le DNS pointe déjà vers le VPS).

Vérification :
```bash
ssh deploy@IP_DU_VPS
cd /opt/techstore && docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs -f backend
```
Puis ouvrez `https://votredomaine/admin/connexion`.

## Étape 7 — Importer les catalogues (Gembird, Cecotec)
```bash
scp -r import deploy@IP_DU_VPS:/opt/techstore/
ssh deploy@IP_DU_VPS
cd /opt/techstore
C="docker compose -f docker-compose.prod.yml"
$C cp import/gembird/images/. backend:/data/uploads/
$C cp import/cecotec/images/. backend:/data/uploads/
$C cp import/gembird/import-gembird.js mongo:/tmp/
$C cp import/cecotec/import-cecotec.js mongo:/tmp/
M='mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin techstore'
$C exec -e MARGE=0.25 mongo sh -c "$M /tmp/import-gembird.js"
$C exec -e STOCK=0     mongo sh -c "$M /tmp/import-cecotec.js"
```

## Exploitation
- **Revenir à une version précédente** : dans `/opt/techstore/.env`, `TAG=<sha du commit>` puis `docker compose -f docker-compose.prod.yml up -d`.
- **Sauvegardes** : `/opt/techstore/backups/techstore-AAAA-MM-JJ.gz` (14 jours). Copiez-les régulièrement ailleurs (PC, OVH Object Storage).
  Restauration : `$C exec -T mongo sh -c 'mongorestore -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --gzip --archive=/backups/<fichier>.gz --drop'`
- **Accès à MongoDB** : le port n'est pas publié. Sur le serveur : `$C exec mongo sh -c "$M"`.
  Pour Compass, ajoutez temporairement `ports: ["127.0.0.1:27017:27017"]` au service mongo, puis `ssh -L 27017:localhost:27017 deploy@IP_DU_VPS`.
- **Snapshots OVH** : activez l'option *Backup automatisé* ou faites un snapshot du VPS avant les grosses mises à jour.
