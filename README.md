# SonarQube Project Tool

Windows上の複数ディレクトリをSonarQube Projectとして作成・解析・削除するPowerShellツールです。Windows PowerShell 5.1とPowerShell 7に対応します。Community Buildでは `applicationKey` を `null` または未指定にすると、Application APIを呼び出しません。

## 起動

PowerShellでTokenを設定し、GUIを起動します。

```powershell
$env:SONAR_TOKEN = "your-token"
.\Start-SonarQubeToolGui.ps1 -Config .\sample-config-community.json
```

CLI例:

```powershell
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action List
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action ValidateToken
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action Create -DryRun
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action Create
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action Scan
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action Delete -Force
```

`rootPath` 直下のディレクトリが候補になります。`splitDirectories` を指定した場合は、その相対ディレクトリだけが候補です。

SonarQube URL、Scannerの解析設定、プロキシのホスト・ポートは [`sonar-community.properties`](sonar-community.properties) に設定します。JSONの `sonar.propertiesFile` は、このファイルへの絶対パスまたはJSONからの相対パスです。Project KeyとProject名は候補ごとにツールが実行時指定します。

```properties
sonar.host.url=http://localhost:9000
sonar.sources=.
sonar.scanner.proxyHost=proxy.example.local
sonar.scanner.proxyPort=8080
```

Tokenやプロキシ認証情報はファイルへ保存せず、環境変数から読み取ります。

```powershell
$env:SONAR_TOKEN = "your-token"
$env:SONAR_SCANNER_PROXY_USER = "proxy-user"
$env:SONAR_SCANNER_PROXY_PASSWORD = "proxy-password"
```

## テスト

```powershell
.\tests\Unit.Tests.ps1
.\tests\Invoke-CommunityE2E.ps1 -Config .\sample-config-community.json
```

E2Eテストは既定で最大2 Projectを作成し、確認後に削除します。Scannerも検証する場合は `-RunScanner`、Projectを残す場合は `-KeepProjects` を指定します。Podman環境の準備と詳細な手順は [`podman/README.md`](podman/README.md) を参照してください。
