# syntax=docker/dockerfile:1

FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG TARGETARCH
ARG VERSION=1.0.0
WORKDIR /source

COPY src/TestDigitalOcean/TestDigitalOcean.csproj src/TestDigitalOcean/
RUN dotnet restore src/TestDigitalOcean/TestDigitalOcean.csproj -a $TARGETARCH

COPY src/ src/
RUN dotnet publish src/TestDigitalOcean/TestDigitalOcean.csproj \
    -c Release -a $TARGETARCH --no-restore \
    -p:InformationalVersion=$VERSION \
    -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app .
# aspnet images default to port 8080 and the non-root "app" user
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "TestDigitalOcean.dll"]
