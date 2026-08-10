# SonarQube Project Tool

Windows上の複数ディレクトリをSonarQube Projectとして一括作成し、SonarScannerを並列実行するPowerShellツールです。GUIとCLIの両方を提供します。

主な機能:

- ディレクトリからProject候補を生成
- Token認証の確認
- Projectの存在確認、作成、削除
- Dry Run
- SonarScannerの並列実行
- Community BuildとEnterprise Serverの切り替え
- SonarScanner propertiesファイルによる接続先・プロキシ・解析設定の管理

## ドキュメント

- [詳細設計書](docs/design.md)
- [システム概要](docs/design.md#2-システム概要)
- [設定設計](docs/design.md#4-設定設計)
- [GUI設計](docs/design.md#7-gui設計)
- [Create処理](docs/design.md#9-create処理)
- [Scan処理](docs/design.md#10-scan処理)
- [Delete処理](docs/design.md#11-delete処理)
- [CommunityとEnterprise](docs/design.md#12-communityとenterprise)
- [プロキシと通信経路](docs/design.md#14-プロキシと通信経路)
- [冪等性](docs/design.md#17-冪等性)
- [現在の制約](docs/design.md#21-現在の制約)

## ファイル構成

| ファイル | 用途 |
|---|---|
| `Start-SonarQubeToolGui.ps1` | GUI版ランチャー |
| `Invoke-SonarQubeTool.ps1` | CLI版ランチャー |
| `SonarQubeTool.psm1` | API、候補検出、Scanner実行の本体 |
| `sample-config-community.json` | ツール動作設定の例 |
| `sonar-community.properties` | SonarQube接続先、プロキシ、解析設定 |
| `podman/` | ローカルSonarQube Community Build環境 |
| `tests/` | 単体テスト、E2Eテスト |
| `testdata/` | E2E用の小さなサンプルProject |

## 動作要件

- Windows PowerShell 5.1またはPowerShell 7
- SonarScanner CLI 6.0以降（検証済み: 7.1.0）
- 接続可能なSonarQube Community BuildまたはSonarQube Server
- Project作成・解析・削除に必要な権限を持つSonarQube Token

確認:

```powershell
$PSVersionTable.PSVersion
sonar-scanner.bat --version
```

## クイックスタート: ローカルPodman環境

### 1. SonarQubeを起動する

WSLの `Ubuntu-24.04` にPodmanがある場合:

```powershell
Set-Location E:\dev\workspace\sonarqubetool\podman
Copy-Item .env.example .env   # 初回だけ
notepad .env                  # SONAR_DB_PASSWORDを変更
wsl -d Ubuntu-24.04 -- bash -lc "cd /mnt/e/dev/workspace/sonarqubetool/podman && podman compose up -d"
```

ブラウザーで `http://localhost:9000` を開きます。初期ユーザーは `admin`、初期パスワードは `admin` です。初回ログイン時にパスワードを変更してください。Podman環境の詳細は [`podman/README.md`](podman/README.md) を参照してください。

### 2. Tokenを発行する

SonarQube Web UIで次の順に開きます。

1. 右上のユーザーアイコン
2. **My Account**
3. **Security**
4. Token名（例: `sonar-util-local`）を入力
5. **Generate**
6. 表示されたTokenをコピー

Tokenは再表示できません。ツールを起動するPowerShellで環境変数へ設定します。

```powershell
$env:SONAR_TOKEN = "squ_xxxxxxxxxxxxxxxxxxxx"
```

TokenをJSON、properties、Git管理ファイルへ書き込まないでください。

### 3. 接続先を設定する

[`sonar-community.properties`](sonar-community.properties) を編集します。ローカルPodman環境では次のまま使用できます。

```properties
sonar.host.url=http://localhost:9000
sonar.sources=.
sonar.scm.disabled=true
```

社内SonarQubeへ接続する場合は `sonar.host.url` を変更します。

```properties
sonar.host.url=https://sonarqube.example.co.jp
sonar.sources=.
```

パス付きURLの場合:

```properties
sonar.host.url=https://tools.example.co.jp/sonarqube
```

末尾の `/` はなくても構いません。GUI、CLI、SonarScannerはすべてこの接続先を使用します。

### 4. Project候補のルートを設定する

[`sample-config-community.json`](sample-config-community.json) の `rootPath` を、解析候補ディレクトリが並んでいる親ディレクトリへ変更します。

```json
{
  "rootPath": "C:\\work\\sonar-testdata",
  "projectKeyPrefix": "test",
  "projectName": {
    "mode": "relativePath",
    "separator": " / "
  },
  "sonar": {
    "propertiesFile": "sonar-community.properties",
    "applicationKey": null
  },
  "scanner": {
    "executable": "sonar-scanner.bat",
    "parallelism": 4
  }
}
```

例えば次の構成では、`service-a` と `service-b` がProject候補になります。

```text
C:\work\sonar-testdata\
├─ service-a\
│  └─ src\...
└─ service-b\
   └─ src\...
```

生成されるProject Key:

| ディレクトリ | Project Key |
|---|---|
| `service-a` | `test-service-a` |
| `service-b` | `test-service-b` |

### 5. GUIを起動する

Tokenを設定した同じPowerShellで実行します。

```powershell
Set-Location E:\dev\workspace\sonarqubetool
$env:SONAR_TOKEN = "発行したToken"
.\Start-SonarQubeToolGui.ps1 -Config .\sample-config-community.json
```

実行ポリシーでブロックされる場合は、そのプロセスだけ緩和します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SonarQubeToolGui.ps1 -Config .\sample-config-community.json
```

GUIの基本手順:

1. **Load** で設定を読み込む
2. **Validate Token** で接続・認証を確認
3. 対象Projectをチェック
4. **Dry Run** で予定を確認
5. **Create** でProjectを作成
6. **Scan** でSonarScannerを並列実行
7. SonarQube Web UIで結果を確認
8. 必要な場合だけ **Delete** でProjectを削除

## 接続先とプロキシ設定

### どのプロキシ設定が使われるか

本ツールでは、処理によって通信を行うプログラムが異なるため、参照するプロキシ設定も異なります。

| 操作 | 通信主体 | 使用するプロキシ設定 |
|---|---|---|
| Token認証確認 | PowerShell API | Windows／.NETの既定プロキシ |
| Project存在確認 | PowerShell API | Windows／.NETの既定プロキシ |
| Project作成・削除 | PowerShell API | Windows／.NETの既定プロキシ |
| Applicationへの登録 | PowerShell API | Windows／.NETの既定プロキシ |
| SonarScanner実行 | SonarScanner（Java） | `sonar.scanner.proxyHost` など |
| Podmanイメージ取得 | WSL上のPodman | WSLの `HTTP_PROXY`／`HTTPS_PROXY` |

重要: propertiesファイルの `sonar.scanner.proxyHost` はSonarScanner専用です。Project作成・削除などのAPI通信には適用されません。

PowerShellによるAPI通信は、Windows／.NETが認識している既定プロキシと例外設定を使用します。現在のWinHTTP設定は次のコマンドで確認できます。

```powershell
netsh winhttp show proxy
```

組織の端末管理によっては、Windowsの **インターネット オプション** または **設定 → ネットワークとインターネット → プロキシ** で配布された設定も利用されます。実際の適用元はPowerShell／.NETのバージョンと組織ポリシーによって異なります。

ローカルPodmanや、プロキシを経由させない社内SonarQubeはWindows側のプロキシ例外へ登録します。

```text
localhost
127.0.0.1
sonarqube.example.co.jp
```

API通信だけが失敗する場合は、Scanner用propertiesを変更するのではなく、Windowsのプロキシ・例外・認証状態を確認してください。反対に、Token確認やProject作成は成功してScanだけ失敗する場合は、`sonar.scanner.proxyHost` などのScanner設定を確認します。

### SonarQube接続先

接続先はJSONではなくpropertiesファイルの `sonar.host.url` に設定します。

```properties
sonar.host.url=https://sonarqube.example.co.jp
```

JSONの `sonar.propertiesFile` は使用するpropertiesファイルを指定します。JSONからの相対パスまたは絶対パスを使用できます。

```json
"sonar": {
  "propertiesFile": "sonar-community.properties",
  "applicationKey": null
}
```

別環境ごとにファイルを分ける例:

```text
sonar-local.properties
sonar-staging.properties
sonar-production.properties
```

```json
"sonar": {
  "propertiesFile": "sonar-staging.properties",
  "applicationKey": null
}
```

### SonarScannerのプロキシ

プロキシのホストとポートはpropertiesへ設定できます。

```properties
sonar.scanner.proxyHost=proxy.example.co.jp
sonar.scanner.proxyPort=8080
```

認証情報はpropertiesへ保存せず、GUIまたはCLIを起動するPowerShellの環境変数へ設定します。

```powershell
$env:SONAR_SCANNER_PROXY_USER = "proxy-user"
$env:SONAR_SCANNER_PROXY_PASSWORD = "proxy-password"
```

認証不要のプロキシではこの2変数は不要です。ローカルや社内ホストをプロキシ対象外にする必要がある場合:

```powershell
$env:NO_PROXY = "localhost,127.0.0.1,sonarqube.example.co.jp"
```

注意: `sonar.scanner.proxy*` はSonarScanner通信に対する設定です。GUI/CLIのSonarQube API通信はWindowsのシステムプロキシ設定を利用します。

### TLS・社内CA証明書

HTTPS接続で証明書エラーになる場合、証明書検証を無効化するのではなく、社内CA証明書をWindowsの信頼されたルート証明機関とSonarScannerが使用するJava truststoreへ登録してください。本ツールには証明書検証を無効化するオプションはありません。

## JSON設定リファレンス

| 項目 | 必須 | 説明 |
|---|---:|---|
| `rootPath` | 必須 | Project候補ディレクトリの親パス |
| `projectKeyPrefix` | 必須 | 生成するProject Keyの接頭辞 |
| `projectName.mode` | 任意 | `directoryName`（末尾のみ）または `relativePath`（親階層を含む） |
| `projectName.separator` | 任意 | `relativePath`表示名の階層区切り。既定値 ` / ` |
| `sonar.propertiesFile` | 必須 | Sonar接続・解析propertiesファイル |
| `sonar.applicationKey` | 任意 | Enterprise Application Key。Communityでは `null` または省略 |
| `scanner.executable` | 必須 | Scanner実行ファイル名または絶対パス |
| `scanner.parallelism` | 任意 | Scanner最大並列数。既定値1、1以上 |
| `splitDirectories` | 任意 | 候補にする相対ディレクトリを明示指定 |
| `excludeDirectories` | 任意 | 自動候補検出から除外するディレクトリ名 |
| `allowDelete` | 任意 | Project削除を許可するか |
| `deleteOnlyCreatedByTool` | 任意 | prefixに一致するProjectだけ削除するか |

### 候補ディレクトリを限定する

`splitDirectories` が空の場合は `rootPath` の直下を自動列挙します。指定した場合は、そのディレクトリだけを候補にします。

```json
"splitDirectories": [
  "services\\api",
  "services\\batch"
]
```

### Scannerの絶対パス指定

ScannerがPATHにない場合:

```json
"scanner": {
  "executable": "E:\\tools\\sonar-scanner\\bin\\sonar-scanner.bat",
  "parallelism": 4
}
```

### サブディレクトリをProject名に含める

異なる階層に同名ディレクトリがある場合は、`relativePath`を指定すると表示名の重複を避けられます。

```json
"projectName": {
  "mode": "relativePath",
  "separator": " / "
}
```

| 相対パス | Project表示名 | Project Key |
|---|---|---|
| `services\\api` | `services / api` | `test-services-api` |
| `jobs\\api` | `jobs / api` | `test-jobs-api` |

`directoryName`を指定した場合は従来どおり、どちらの表示名も `api` になります。Project Keyはどちらのモードでも相対パスを含みます。

## properties設定例

```properties
# 接続先（必須）
sonar.host.url=https://sonarqube.example.co.jp

# 各Projectディレクトリから見た解析対象
sonar.sources=.

# Gitリポジトリでないテストデータの場合
sonar.scm.disabled=true

# 必要な場合だけプロキシを有効化
# sonar.scanner.proxyHost=proxy.example.co.jp
# sonar.scanner.proxyPort=8080

# 任意の解析除外
sonar.exclusions=**/node_modules/**,**/bin/**,**/obj/**
```

`sonar.projectKey`、`sonar.projectName`、`sonar.token` はツールが実行時に指定するため、このファイルには記載しません。

## Community BuildとEnterpriseの違い

Community Buildでは必ず次のようにします。

```json
"applicationKey": null
```

または `applicationKey` 自体を省略します。この場合、Application関連APIは一切呼び出しません。以下はEnterprise環境だけの対象です。

- ApplicationへのProject登録
- Application集約表示
- Application関連API

## CLIの使い方

### 候補一覧

```powershell
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action List
```

### Tokenと接続確認

```powershell
$env:SONAR_TOKEN = "発行したToken"
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action ValidateToken
```

### Dry Run

```powershell
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action Create -DryRun
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action Scan -DryRun
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action Delete -DryRun
```

### 作成・Scanner実行・削除

```powershell
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action Create
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action Scan
.\Invoke-SonarQubeTool.ps1 -Config .\sample-config-community.json -Action Delete -Force
```

特定Projectだけを対象にする場合:

```powershell
.\Invoke-SonarQubeTool.ps1 `
  -Config .\sample-config-community.json `
  -Action Scan `
  -ProjectKey test-service-a,test-service-b
```

## テスト

### 単体テスト

```powershell
.\tests\Unit.Tests.ps1
```

### Community Build E2E

```powershell
$env:SONAR_TOKEN = "テスト用Token"
.\tests\Invoke-CommunityE2E.ps1 -Config .\sample-config-community.json
```

Scannerも実行:

```powershell
.\tests\Invoke-CommunityE2E.ps1 `
  -Config .\sample-config-community.json `
  -RunScanner
```

既定では最大2 Projectを作成し、テスト終了時に削除します。Projectを残す場合は `-KeepProjects` を指定します。

## トラブルシューティング

### `SONAR_TOKEN environment variable is not set`

GUI/CLIを起動するのと同じPowerShellでTokenを設定してください。

```powershell
$env:SONAR_TOKEN = "発行したToken"
```

### Tokenが拒否される

- Tokenのコピー漏れや期限切れを確認
- `sonar.host.url` がTokenを発行したSonarQubeを指しているか確認
- GUIの **Validate Token** またはCLIの `ValidateToken` を実行

### SonarQubeへ接続できない

```powershell
Invoke-RestMethod http://localhost:9000/api/system/status
```

リモート環境ではURL、VPN、Windowsプロキシ、ファイアウォール、社内CA証明書を確認してください。

### `sonar-scanner.bat` が見つからない

```powershell
Get-Command sonar-scanner.bat
```

PATHへ追加するか、JSONの `scanner.executable` に絶対パスを設定します。

### Project削除が拒否される

- `allowDelete` が `true` か確認
- `deleteOnlyCreatedByTool=true` の場合、Project Keyが `projectKeyPrefix-` で始まるか確認
- TokenにProject削除権限があるか確認

### Scannerだけプロキシエラーになる

`sonar.scanner.proxyHost` と `sonar.scanner.proxyPort`、必要なら `SONAR_SCANNER_PROXY_USER` と `SONAR_SCANNER_PROXY_PASSWORD` を確認します。

## セキュリティ上の注意

- TokenやパスワードをJSON、properties、`.env.example`、Gitへコミットしない
- 本番用Tokenではなく、必要最小限の権限と期限を持つ専用Tokenを使う
- `allowDelete=true` は対象環境を十分確認してから使う
- 削除前に必ずDry Runを実行する
- TLS証明書検証を無効化しない
