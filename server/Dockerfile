FROM oven/bun:1.3-slim
WORKDIR /app
COPY package.json ./
COPY src ./src
COPY public ./public
ENV NODE_ENV=production PORT=8080 DATABASE_PATH=/data/murmur.db
EXPOSE 8080
CMD ["bun", "src/index.ts"]
