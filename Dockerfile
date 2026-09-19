FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY NuGet.Config .
COPY src/Win365Agent/Win365Agent.csproj src/Win365Agent/
RUN dotnet restore src/Win365Agent/Win365Agent.csproj --configfile NuGet.Config
COPY src/Win365Agent/ src/Win365Agent/
RUN dotnet publish src/Win365Agent/Win365Agent.csproj -c Release --no-restore -p:UseAppHost=false -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
USER $APP_UID
EXPOSE 8080 8088
ENTRYPOINT ["dotnet", "Win365Agent.dll"]
