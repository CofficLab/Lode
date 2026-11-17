#!/usr/bin/env bash
# Generate disposable TLS fixtures for the integration engines into .fixtures/.
# Idempotent: skips generation when a CA already exists. Nothing here is
# committed (.fixtures/ is gitignored); these are throwaway test credentials.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CERT="$HERE/.fixtures/certs"
mkdir -p "$CERT"
cd "$CERT"

if [ -f ca.pem ]; then
  echo "Fixtures already present at $CERT"
  exit 0
fi

# Self-signed CA + server cert (SAN covers loopback, localhost and the Docker
# host gateway used by the SSH jump host).
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem \
  -days 3650 -subj "/CN=Lode Test CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/CN=localhost" 2>/dev/null
printf 'subjectAltName=IP:127.0.0.1,DNS:localhost,DNS:host.docker.internal\nextendedKeyUsage=serverAuth\n' > san.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -out server.pem -days 365 -extfile san.cnf 2>/dev/null

# An unrelated CA used by negative TLS tests (verification must fail).
openssl req -x509 -newkey rsa:2048 -nodes -keyout wrong-ca.key -out wrong-ca.pem \
  -days 3650 -subj "/CN=Lode Wrong CA" 2>/dev/null

# Redis ACL: default and testuser, both password testpass, full access.
printf 'user default on >testpass ~* &* +@all\nuser testuser on >testpass ~* &* +@all\n' > users.acl

chmod 644 ./*.pem ./*.key users.acl
echo "Generated TLS fixtures at $CERT"