ARG BUILD_DATE=unknown
ARG VCS_REF=unknown

FROM golang:1.25.3 AS backend-builder
WORKDIR /src

COPY external/Backend/go.mod ./
RUN go env -w GOPROXY=https://proxy.golang.org,direct

COPY external/Backend .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /area-backend ./src

FROM node:25-alpine AS frontend-builder
WORKDIR /app

COPY external/Frontend/package.json ./
RUN npm install --no-audit --prefer-offline || npm install

COPY external/Frontend/ .
RUN npm run build

FROM alpine:3.22 AS final
RUN apk add --no-cache nginx bash curl ca-certificates

LABEL org.opencontainers.image.title="area" \
   org.opencontainers.image.description="Area project" \
   org.opencontainers.image.source="https://github.com/mbarleon-org/Area" \
   org.opencontainers.image.url="https://github.com/mbarleon-org/Area" \
   org.opencontainers.image.created="${BUILD_DATE}" \
   org.opencontainers.image.revision="${VCS_REF}"

COPY --from=frontend-builder /app/dist /var/www/html
COPY --from=backend-builder /area-backend /area-backend
RUN chmod +x /area-backend

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
         proxy_pass http://127.0.0.1:8080/;
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
   /area-backend &
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
