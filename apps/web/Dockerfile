FROM node:24-alpine

WORKDIR /app
ARG NEXT_PUBLIC_API_URL=http://localhost:8000/v1
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL

COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build
ENV NODE_ENV=production

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=4s --start-period=10s --retries=3 \
  CMD wget -q -O - http://127.0.0.1:3000/ >/dev/null || exit 1
CMD ["npm", "run", "start", "--", "--host", "0.0.0.0"]
