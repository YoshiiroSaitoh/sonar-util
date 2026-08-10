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

`rootPath` 直下のディレクトリが候補になります。`splitDirectories` を指定した場合は、その相対ディレクトリだけが候補です。Tokenは引数やJSONへ保存せず、プロセスの `SONAR_TOKEN` 環境変数だけから読み取ります。

## テスト

```powershell
.\tests\Unit.Tests.ps1
.\tests\Invoke-CommunityE2E.ps1 -Config .\sample-config-community.json
```

E2Eテストは既定で最大2 Projectを作成し、確認後に削除します。Scannerも検証する場合は `-RunScanner`、Projectを残す場合は `-KeepProjects` を指定します。Podman環境の準備と詳細な手順は [`podman/README.md`](podman/README.md) を参照してください。
