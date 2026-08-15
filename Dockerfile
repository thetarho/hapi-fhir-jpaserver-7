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


########### bitnami tomcat version is suitable for debugging and comes with a shell
########### it can be built using eg. `docker build --target tomcat .`
FROM bitnami/tomcat:10.1 AS tomcat

USER root
RUN rm -rf /opt/bitnami/tomcat/webapps/ROOT && \
    mkdir -p /opt/bitnami/hapi/data/hapi/lucenefiles && \
    chown -R 1001:1001 /opt/bitnami/hapi/data/hapi/lucenefiles && \
    chmod 775 /opt/bitnami/hapi/data/hapi/lucenefiles

RUN mkdir -p /target && chown -R 1001:1001 target
USER 1001

COPY --chown=1001:1001 catalina.properties /opt/bitnami/tomcat/conf/catalina.properties
COPY --chown=1001:1001 server.xml /opt/bitnami/tomcat/conf/server.xml
COPY --from=build-hapi --chown=1001:1001 /tmp/hapi-fhir-jpaserver-starter/target/ROOT.war /opt/bitnami/tomcat/webapps/ROOT.war
COPY --from=build-hapi --chown=1001:1001 /tmp/hapi-fhir-jpaserver-starter/opentelemetry-javaagent.jar /app

ENV ALLOW_EMPTY_PASSWORD=yes

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
