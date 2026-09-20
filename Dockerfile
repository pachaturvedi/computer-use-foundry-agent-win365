FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY NuGet.Config .
COPY Directory.Packages.props .
COPY src/Win365Shared/Win365Shared.csproj src/Win365Shared/
COPY src/Win365Viewer/Win365Viewer.csproj src/Win365Viewer/
RUN dotnet restore src/Win365Viewer/Win365Viewer.csproj --configfile NuGet.Config
COPY src/Win365Shared/ src/Win365Shared/
COPY src/Win365Viewer/ src/Win365Viewer/
RUN dotnet publish src/Win365Viewer/Win365Viewer.csproj -c Release --no-restore -p:UseAppHost=false -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
USER $APP_UID
EXPOSE 8080 8088
ENTRYPOINT ["dotnet", "Win365Viewer.dll"]
