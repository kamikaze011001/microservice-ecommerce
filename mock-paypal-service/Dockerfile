# Stage 1 — build
FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q -e -B dependency:go-offline
COPY src ./src
RUN mvn -q -B clean package -DskipTests

# Stage 2 — run
FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /app/target/mock-paypal-service-*.jar app.jar
EXPOSE 8585 18585
ENTRYPOINT ["java","-XX:MaxRAMPercentage=75.0","-jar","/app/app.jar"]
