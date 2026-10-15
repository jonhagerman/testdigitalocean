# syntax=docker/dockerfile:1

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
# Not named VERSION: build args are visible as env vars during RUN, and MSBuild
# would pick VERSION up as the $(Version) property (e.g. "main" breaks restore).
ARG APP_VERSION=1.0.0
# NuGet enhanced HTTP retry for transient feed failures
ENV NUGET_ENABLE_ENHANCED_HTTP_RETRY=true \
    NUGET_ENHANCED_MAX_NETWORK_TRY_COUNT=6 \
    NUGET_ENHANCED_NETWORK_RETRY_DELAY_MILLISECONDS=1000
WORKDIR /source

COPY src/TestDigitalOcean/TestDigitalOcean.csproj src/TestDigitalOcean/
RUN dotnet restore src/TestDigitalOcean/TestDigitalOcean.csproj

COPY src/ src/
RUN dotnet publish src/TestDigitalOcean/TestDigitalOcean.csproj \
    -c Release --no-restore \
    -p:InformationalVersion=$APP_VERSION \
    -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app .
# aspnet images default to port 8080 and the non-root "app" user
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "TestDigitalOcean.dll"]
