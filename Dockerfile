FROM node:25-alpine AS backend-builder
WORKDIR /app

ARG NODE_ENV=production
ENV NODE_ENV=$NODE_ENV

COPY external/Backend/package.json external/Backend/package-lock.json ./
RUN npm install --no-audit --prefer-offline || npm install

COPY external/Backend/ .
RUN npm run build

FROM node:25-alpine AS frontend-builder
WORKDIR /app

ARG NODE_ENV=production
ENV NODE_ENV=$NODE_ENV

COPY external/Frontend/package.json external/Frontend/package-lock.json ./
RUN npm install --no-audit --prefer-offline || npm install

COPY external/Frontend/ .
RUN EXPO_NO_TELEMETRY=1 npx expo export --platform web --output-dir dist && \
    node -e 'const fs=require("fs");const file="/app/dist/index.html";const tag="<script src=\"/runtime-env.js\"></script>";const html=fs.readFileSync(file,"utf8");if(html.includes(tag)){process.exit(0);}if(!html.includes("</head>")){throw new Error("Unable to find </head> marker in index.html when injecting runtime env script.");}const updated=html.replace("</head>",tag + "\n</head>");fs.writeFileSync(file,updated);'

FROM alpine:3.22 AS final
ARG BUILD_DATE=unknown
ARG VCS_REF=unknown

RUN apk add --no-cache nginx bash curl ca-certificates nodejs npm postgresql postgresql-client openssl

LABEL org.opencontainers.image.title="area" \
   org.opencontainers.image.description="Area project" \
   org.opencontainers.image.source="https://github.com/mbarleon-org/Area" \
   org.opencontainers.image.url="https://github.com/mbarleon-org/Area" \
   org.opencontainers.image.created="${BUILD_DATE}" \
   org.opencontainers.image.revision="${VCS_REF}"

COPY --from=frontend-builder /app/dist /var/www/html
COPY --from=backend-builder /app/docs /area-backend/docs
COPY --from=backend-builder /app/dist /area-backend/dist
COPY --from=backend-builder /app/package.json /area-backend/package.json
COPY --from=backend-builder /app/node_modules /area-backend/node_modules

COPY docker/nginx.conf /etc/nginx/nginx.conf

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5173
ENTRYPOINT ["/entrypoint.sh"]
