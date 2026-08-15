# Pinned to $BUILDPLATFORM so the Maven build runs ONCE on the runner's native
# architecture instead of once per target platform. Safe here because the
# runtime stage only COPYs artifacts out of this chain and never executes
# anything from it: ROOT.war and opentelemetry-javaagent.jar are both pure
# bytecode, identical for amd64 and arm64. build-distroless derives FROM
# build-hapi, so pinning this one stage covers the whole build chain, and only
# the distroless runtime stage is built per-architecture. Without this, the
# emulated arm64 leg would re-run the entire HAPI Maven build under QEMU to
# produce a byte-identical war. (TRDAT-589)
FROM --platform=$BUILDPLATFORM docker.io/library/maven:3.9.9-eclipse-temurin-17 AS build-hapi
WORKDIR /tmp/hapi-fhir-jpaserver-starter

ARG OPENTELEMETRY_JAVA_AGENT_VERSION=1.33.3
RUN curl -LSsO https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OPENTELEMETRY_JAVA_AGENT_VERSION}/opentelemetry-javaagent.jar

COPY pom.xml .
COPY server.xml .
RUN mvn -ntp dependency:go-offline

COPY src/ /tmp/hapi-fhir-jpaserver-starter/src/
RUN mvn clean install -DskipTests -Djdk.lang.Process.launchMechanism=vfork

FROM build-hapi AS build-distroless
RUN mvn package -DskipTests spring-boot:repackage -Pboot
RUN mkdir /app && cp /tmp/hapi-fhir-jpaserver-starter/target/ROOT.war /app/main.war


########### The optional `tomcat` debug stage was REMOVED (TRDAT-589).
########### It was `FROM bitnami/tomcat:10.1`, and that tag no longer exists on
########### Docker Hub — Bitnami moved their catalog — so every build that
########### resolved it failed with "docker.io/bitnami/tomcat:10.1: not found".
########### That is why maven.yml / build-images.yaml / the smoke tests have
########### been red since mid-June: build-images.yaml sets `target: tomcat`,
########### which forces BuildKit to build this otherwise-unused stage.
###########
########### Nothing consumed it: it was a debugging convenience ("comes with a
########### shell"), no deployment references a tomcat-variant hapi image, and
########### the images it fed were docker.io/hapiproject/hapi — the UPSTREAM
########### project's namespace, which we do not publish to. The distroless
########### `default` stage below is and remains the image we ship.

########### distroless brings focus on security and runs on plain spring boot - this is the default image
FROM gcr.io/distroless/java17-debian12:nonroot AS default
# 65532 is the nonroot user's uid
# used here instead of the name to allow Kubernetes to easily detect that the container
# is running as a non-root (uid != 0) user.
USER 65532:65532
WORKDIR /app

COPY --chown=nonroot:nonroot --from=build-distroless /app /app
COPY --chown=nonroot:nonroot --from=build-hapi /tmp/hapi-fhir-jpaserver-starter/opentelemetry-javaagent.jar /app

ENTRYPOINT ["java", "--class-path", "/app/main.war", "--add-opens=java.base/java.io=ALL-UNNAMED", "-Dloader.path=main.war!/WEB-INF/classes/,main.war!/WEB-INF/,/app/extra-classes", "org.springframework.boot.loader.PropertiesLauncher"]
