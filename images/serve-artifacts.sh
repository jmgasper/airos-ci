#!/usr/bin/env bash
# serve-artifacts.sh: serve $AIROS_ARTIFACTS (images, manifests) over HTTP on
# port 80 of the build server with an nginx container (host networking).
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
conf=$AIROS_DATA/www/default.conf
mkdir -p "$AIROS_DATA/www" "$AIROS_ARTIFACTS/images"
cp "$AIROS_CI/images/nginx-artifacts.conf" "$conf"
docker rm -f airos-artifacts >/dev/null 2>&1 || true
docker run -d --name airos-artifacts --restart unless-stopped --network host \
	-v "$AIROS_ARTIFACTS:/usr/share/nginx/html:ro" -v "$conf:/etc/nginx/conf.d/default.conf:ro" \
	nginx:alpine >/dev/null
echo "serving $AIROS_ARTIFACTS at http://$(hostname).local/"
