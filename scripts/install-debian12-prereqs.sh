#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/install-debian12-prereqs.sh" >&2
  exit 1
fi

apt-get update
apt-get install -y ca-certificates curl gnupg git unzip rsync jq nginx ffmpeg postgresql postgresql-contrib build-essential

if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi

id newdomofon >/dev/null 2>&1 || useradd --system --home /opt/newdomofon-video-node --shell /usr/sbin/nologin newdomofon
install -d -o newdomofon -g newdomofon /var/lib/newdomofon-video/dvr /var/log/newdomofon-video /var/www/newdomofon-video
install -d -m 0750 /etc/newdomofon-video

echo "Prerequisites installed. Node: $(node -v), npm: $(npm -v)"
