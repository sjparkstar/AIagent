FROM node:20-alpine AS base

RUN corepack enable && corepack prepare pnpm@latest --activate

WORKDIR /app

COPY package.json pnpm-workspace.yaml tsconfig.base.json ./
COPY packages/shared/package.json ./packages/shared/
COPY packages/signaling-server/package.json ./packages/signaling-server/

RUN pnpm install --frozen-lockfile

COPY packages/shared/ ./packages/shared/
COPY packages/signaling-server/ ./packages/signaling-server/

RUN pnpm --filter @remote-desktop/shared build
RUN pnpm --filter @remote-desktop/signaling-server build

FROM node:20-alpine AS runner

RUN corepack enable && corepack prepare pnpm@latest --activate

WORKDIR /app

COPY package.json pnpm-workspace.yaml tsconfig.base.json ./
COPY packages/shared/package.json ./packages/shared/
COPY packages/signaling-server/package.json ./packages/signaling-server/

RUN pnpm install --frozen-lockfile --prod

COPY --from=base /app/packages/shared/dist ./packages/shared/dist
COPY --from=base /app/packages/signaling-server/dist ./packages/signaling-server/dist

EXPOSE 8080

ENV NODE_ENV=production

CMD ["node", "packages/signaling-server/dist/index.js"]
