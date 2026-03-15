FROM directus/directus:11

WORKDIR /directus

USER root
RUN apk add --no-cache curl

USER node
RUN pnpm add @directus/sdk
