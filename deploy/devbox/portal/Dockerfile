# syntax=docker/dockerfile:1.7
# Build context: a stage devbox.sh `portal` assembles — portal/ (this dir),
# k6-stress/ and api-tests/ — so the page shows exactly the test assets a job runs.
# The UI (ui/, Vue + Vite) is built first and dropped into Spring's static/.
FROM node:20-alpine AS ui
WORKDIR /ui
COPY portal/ui/package.json portal/ui/package-lock.json ./
RUN --mount=type=cache,id=npm-devbox-portal,target=/root/.npm npm ci --no-audit --no-fund
COPY portal/ui ./
RUN npm run build

FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /workspace
COPY portal/pom.xml .
RUN --mount=type=cache,id=m2-devbox-portal,target=/root/.m2 mvn -q -B dependency:go-offline
COPY portal/src ./src
COPY --from=ui /ui/dist ./src/main/resources/static
RUN --mount=type=cache,id=m2-devbox-portal,target=/root/.m2 mvn -q -B package -DskipTests

FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /workspace/target/devbox-portal-*.jar app.jar
# The Perf page asks k6 itself what a scenario/profile will do (k6 inspect);
# the API testing page parses the Bruno collection. Same files the runner has.
COPY --from=grafana/k6:0.54.0 /usr/bin/k6 /usr/local/bin/k6
COPY k6-stress /app/k6-stress
COPY api-tests /app/api-tests
EXPOSE 8282 18282
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0" MALLOC_ARENA_MAX=2
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
