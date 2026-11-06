#!/usr/bin/env bash
# Préparation d'un VPS OVH neuf (Ubuntu 24.04) — à lancer une seule fois en root :
#   curl … ou scp server-setup.sh root@VPS: && ssh root@VPS 'bash server-setup.sh "ssh-ed25519 AAAA…clé publique du pipeline"'
set -euo pipefail
PIPELINE_PUBKEY="${1:?Usage: server-setup.sh \"<clé publique SSH du pipeline>\"}"

apt-get update && apt-get -y upgrade
apt-get install -y ca-certificates curl ufw fail2ban unattended-upgrades openssl

# Docker + plugin compose
curl -fsSL https://get.docker.com | sh

# Utilisateur de déploiement (utilisé par GitLab CI / GitHub Actions)
id deploy &>/dev/null || adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
echo "$PIPELINE_PUBKEY" >> /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys && chmod 600 /home/deploy/.ssh/authorized_keys

# Dossier de l'application + clés JWT de production
install -d -o deploy -g deploy /opt/techstore /opt/techstore/keys /opt/techstore/backups
if [ ! -f /opt/techstore/keys/privateKey.pem ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /opt/techstore/keys/privateKey.pem
  openssl rsa -pubout -in /opt/techstore/keys/privateKey.pem -out /opt/techstore/keys/publicKey.pem
  # le conteneur Quarkus tourne avec un autre utilisateur : lecture seule pour tous, dossier fermé aux autres comptes
  chmod 644 /opt/techstore/keys/*.pem && chown -R deploy:deploy /opt/techstore/keys && chmod 755 /opt/techstore/keys
fi

# Pare-feu : SSH + web uniquement (MongoDB n'est pas exposé)
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443
ufw --force enable

# Sauvegarde MongoDB quotidienne à 3 h (14 jours conservés)
cat > /etc/cron.d/techstore-backup <<'CRON'
0 3 * * * deploy cd /opt/techstore && docker compose -f docker-compose.prod.yml exec -T mongo sh -c 'mongodump -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --db techstore --archive=/backups/techstore-$(date +\%F).gz --gzip' && find /opt/techstore/backups -name '*.gz' -mtime +14 -delete
CRON

echo "OK. Créez maintenant /opt/techstore/.env (voir deploy/.env.prod.example), puis lancez le pipeline."
