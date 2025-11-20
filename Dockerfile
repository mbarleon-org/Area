FROM node:25-alpine AS backend-builder
WORKDIR /app

COPY external/Backend/package.json external/Backend/package-lock.json ./
RUN npm install --no-audit --prefer-offline || npm install

COPY external/Backend/ .
RUN npm run build

FROM node:25-alpine AS frontend-builder
WORKDIR /app

COPY external/Frontend/package.json external/Frontend/package-lock.json ./
RUN npm install --no-audit --prefer-offline || npm install

COPY external/Frontend/ .
RUN npm run build

FROM alpine:3.22 AS final
ARG BUILD_DATE=unknown
ARG VCS_REF=unknown
RUN apk add --no-cache nginx bash curl ca-certificates

LABEL org.opencontainers.image.title="area" \
   org.opencontainers.image.description="Area project" \
   org.opencontainers.image.source="https://github.com/mbarleon-org/Area" \
   org.opencontainers.image.url="https://github.com/mbarleon-org/Area" \
   org.opencontainers.image.created="${BUILD_DATE}" \
   org.opencontainers.image.revision="${VCS_REF}"

COPY --from=frontend-builder /app/dist /var/www/html
COPY --from=backend-builder /app/dist /area-backend/dist
COPY --from=backend-builder /app/package.json /area-backend/package.json
COPY --from=backend-builder /app/node_modules /area-backend/node_modules

RUN cat > /etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
   worker_connections 1024;
}

http {
   include /etc/nginx/mime.types;
   default_type application/octet-stream;
   sendfile on;
   keepalive_timeout 65;

   server {
      listen 5173;
      server_name localhost;

      root /var/www/html;
      index index.html;

      location /api/ {
         proxy_pass http://127.0.0.1:3000/;
         proxy_set_header Host $host;
         proxy_set_header X-Real-IP $remote_addr;
         proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
         proxy_set_header X-Forwarded-Proto $scheme;
      }

      location / {
         try_files $uri $uri/ /index.html;
      }
   }
}
EOF

RUN cat > /entrypoint.sh <<'EOF'
#!/bin/sh
set -e

start_backend() {
   node dist/index.js &
   echo "started backend pid $!"
   backend_pid=$!
}

stop() {
   echo "stopping..."
   [ -n "$backend_pid" ] && kill -TERM "$backend_pid" 2>/dev/null || true
   exit 0
}

trap stop TERM INT

start_backend

nginx -g 'daemon off;'

EOF

RUN chmod +x /entrypoint.sh

EXPOSE 5173
ENTRYPOINT ["/entrypoint.sh"]
