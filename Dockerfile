# Matches the node version of the upstream unleashorg/unleash-server image
# (see Dockerfile in https://github.com/Unleash/unleash).
ARG NODE_VERSION=22.23-alpine3.23

FROM node:$NODE_VERSION AS builder

WORKDIR /unleash

COPY package.json package-lock.json index.js oidc-auth-hook.js ./

RUN npm ci --omit=dev

FROM node:$NODE_VERSION

ENV NODE_ENV=production
ENV TZ=UTC

WORKDIR /unleash

COPY --from=builder /unleash /unleash

RUN rm -rf /usr/local/lib/node_modules/npm/ && apk upgrade --no-cache

EXPOSE 4242

USER node

CMD ["node", "index.js"]
