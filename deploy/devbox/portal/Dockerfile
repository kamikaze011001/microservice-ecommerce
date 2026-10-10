# syntax=docker/dockerfile:1.7
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /workspace
COPY pom.xml .
RUN --mount=type=cache,id=m2-devbox-portal,target=/root/.m2 mvn -q -B dependency:go-offline
COPY src ./src
RUN --mount=type=cache,id=m2-devbox-portal,target=/root/.m2 mvn -q -B package -DskipTests

FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /workspace/target/devbox-portal-*.jar app.jar
EXPOSE 8282 18282
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0" MALLOC_ARENA_MAX=2
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
