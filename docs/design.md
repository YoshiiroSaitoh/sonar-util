# SonarQube Project Tool 詳細設計

## 目次

- [1. 文書の目的](#1-文書の目的)
- [2. システム概要](#2-システム概要)
- [3. ファイルと責務](#3-ファイルと責務)
- [4. 設定設計](#4-設定設計)
- [5. Project候補生成](#5-project候補生成)
- [6. Project Key生成](#6-project-key生成)
- [7. GUI設計](#7-gui設計)
- [8. CLI設計](#8-cli設計)
- [9. Create処理](#9-create処理)
- [10. Scan処理](#10-scan処理)
- [11. Delete処理](#11-delete処理)
- [12. CommunityとEnterprise](#12-communityとenterprise)
- [13. SonarQube API](#13-sonarqube-api)
- [14. プロキシと通信経路](#14-プロキシと通信経路)
- [15. 認証とセキュリティ](#15-認証とセキュリティ)
- [16. エラー処理](#16-エラー処理)
- [17. 冪等性](#17-冪等性)
- [18. 並列実行](#18-並列実行)
- [19. ログと終了コード](#19-ログと終了コード)
- [20. テスト設計](#20-テスト設計)
- [21. 現在の制約](#21-現在の制約)
- [22. 将来拡張](#22-将来拡張)

## 1. 文書の目的

本書は、SonarQube Project Toolの保守、変更、テスト、引き継ぎに必要な内部仕様を記録する。利用者向けのセットアップと操作方法はルートの [`README.md`](../README.md) を参照する。

本書は現在の実装を正とし、未実装機能は「現在の制約」または「将来拡張」に分離して記載する。

## 2. システム概要

本ツールは、Windows上のディレクトリをSonarQube Project候補として列挙し、選択した候補に対して以下を実行する。

1. Tokenの検証
2. Projectの存在確認
3. Projectの新規作成
4. SonarScannerによる解析
5. Projectの削除
6. Enterprise環境では既存ApplicationへのProject登録

GUIとCLIは同じPowerShellモジュールを利用する。

```text
GUI / CLI
    │
    ▼
SonarQubeTool.psm1
    ├─ 設定読込
    ├─ 候補生成
    ├─ SonarQube Web API
    └─ SonarScanner並列実行
          │
          ├─ SonarQube Community Build
          └─ SonarQube Server Enterprise
```

## 3. ファイルと責務

| ファイル | 責務 |
|---|---|
| `SonarQubeTool.psm1` | 設定、候補、API、Scanner処理のコア |
| `Start-SonarQubeToolGui.ps1` | WinForms GUI、選択状態、操作イベント |
| `Invoke-SonarQubeTool.ps1` | CLI引数、Actionごとのオーケストレーション |
| `sample-config-community.json` | ツール固有設定の例 |
| `sonar-community.properties` | SonarQube URL、Scanner共通設定 |
| `tests/Unit.Tests.ps1` | 外部環境を必要としない単体テスト |
| `tests/Invoke-CommunityE2E.ps1` | Community Buildに対する実API・Scannerテスト |
| `podman/compose.yaml` | ローカルSonarQubeとPostgreSQL |

GUIとCLIにはSonarQube通信の実装を重複させず、コアモジュールを唯一の実装箇所とする。

## 4. 設定設計

### 4.1 設定ファイルの分離

設定は責務と機密性に応じて3種類へ分ける。

| 種類 | 保存先 | 例 |
|---|---|---|
| ツール固有設定 | JSON | `rootPath`、prefix、並列数、削除制御 |
| Sonar共通設定 | properties | 接続先、sources、proxy host/port |
| 機密情報 | プロセス環境変数 | Token、proxy user/password |

TokenやパスワードをGit管理ファイルへ保存しない。

### 4.2 JSON設定

| 項目 | 型 | 既定値 | 検証 |
|---|---|---|---|
| `rootPath` | string | なし | 必須、候補生成時に存在確認 |
| `projectKeyPrefix` | string | なし | 必須 |
| `projectName.mode` | string | `directoryName` | `directoryName` または `relativePath` |
| `projectName.separator` | string | ` / ` | 相対パス表示時の区切り |
| `sonar.propertiesFile` | string | なし | 必須、相対または絶対パス |
| `sonar.applicationKey` | string/null | 未指定可 | 空ならApplication API無効 |
| `scanner.executable` | string | なし | 必須 |
| `scanner.parallelism` | integer | `1` | 1以上 |
| `splitDirectories` | string[] | `[]` | 指定時は全パスの存在確認 |
| `excludeDirectories` | string[] | `[]` | 自動列挙時のみ使用 |
| `allowDelete` | boolean | `false` | falseなら削除拒否 |
| `deleteOnlyCreatedByTool` | boolean | `true` | prefix不一致を削除拒否 |

### 4.3 properties設定

`sonar.host.url` は必須であり、APIとScannerの両方が同じ値を利用する。`sonar.sources` などはScannerだけが利用する。

Scanner起動時に共有propertiesファイルを `-Dproject.settings=<path>` で指定し、候補固有の値はコマンドラインで上書きする。

### 4.4 設定の優先関係

Scannerに対する実効的な優先関係は次の通り。

```text
propertiesファイルの共通設定
    ↓ 候補固有値で上書き
-Dsonar.projectKey
-Dsonar.projectName
-Dsonar.token
```

`sonar.projectKey`、`sonar.projectName`、`sonar.token` をpropertiesへ記載しない。

## 5. Project候補生成

### 5.1 自動列挙

`splitDirectories` が空の場合、`rootPath` 直下のディレクトリを候補とする。`excludeDirectories` とディレクトリ名が一致する項目を除外する。

```text
rootPath
├─ service-a      → 候補
├─ service-b      → 候補
└─ node_modules   → excludeDirectoriesにより除外
```

### 5.2 明示指定

`splitDirectories` が1件以上の場合、自動列挙せず、指定された相対ディレクトリだけを候補とする。存在しない指定が1件でもあれば設定エラーとして停止する。

### 5.3 候補データ

候補は次のプロパティを持つPowerShellオブジェクトで表現する。

| プロパティ | 内容 |
|---|---|
| `Name` | 設定により末尾ディレクトリ名、または区切り変換した相対パス |
| `Path` | Scannerの作業ディレクトリとなる絶対パス |
| `RelativePath` | `rootPath` からの相対パス |
| `ProjectKey` | prefixと相対パスから生成したKey |

## 6. Project Key生成

Project Keyは次の規則で生成する。

1. 相対パスを小文字化
2. `\`、`/`、空白を `-` へ変換
3. `[a-z0-9_.:-]` 以外を `-` へ変換
4. 連続する `-` を1つへ圧縮
5. 前後の `-` を除去
6. `projectKeyPrefix-` を付与
7. 数字だけのKeyを拒否

例:

| prefix | 相対パス | Project Key |
|---|---|---|
| `test` | `Service A` | `test-service-a` |
| `test` | `services\API` | `test-services-api` |

Projectの同一性はProject Keyだけで判定する。

Project表示名は `projectName.mode` で決まる。`directoryName` は末尾ディレクトリ名、`relativePath` は相対パスの各階層を `projectName.separator` で連結する。

```text
services\api + relativePath + " / " → services / api
jobs\api     + relativePath + " / " → jobs / api
```

## 7. GUI設計

GUIはWindows Formsで構築する。

### 7.1 画面要素

| 要素 | 動作 |
|---|---|
| Configパス | 読み込むJSON設定 |
| Browse | JSONファイル選択 |
| Load | 設定と候補を再読込 |
| 候補一覧 | チェックボックス付きProject候補 |
| Select all | 全候補をチェック |
| Validate Token | Token認証確認 |
| Dry Run | 選択候補の存在と予定を表示 |
| Create | 選択候補のProjectを作成 |
| Scan | 選択候補だけScanner実行 |
| Delete | 選択候補だけ削除 |
| Log | 操作結果とエラーを表示 |

### 7.2 選択状態

Create、Scan、Delete、Dry Runは実行時点でチェックされている候補だけを対象とする。選択状態はSonarQubeへ保存しない。GUIを再起動すると初期化される。

### 7.3 操作中状態

操作中はWait Cursorを表示する。現在の実装はUIスレッド上で処理を待つため、長いScanner処理中は画面操作ができない。Scanner自体はバックグラウンドJobで並列実行される。

### 7.4 削除確認

Deleteは対象件数を示す確認ダイアログを表示する。Noの場合は何も変更しない。

## 8. CLI設計

CLIのActionは次の通り。

| Action | 動作 |
|---|---|
| `List` | 候補表示。Token不要 |
| `ValidateToken` | Token検証 |
| `Create` | 存在確認後に未作成Projectだけ作成 |
| `Scan` | 選択候補を並列解析 |
| `Delete` | 選択候補を削除 |
| `E2E` | 認証、作成、Application登録、Scan |

`ProjectKey` 引数を指定すると、候補のうちKeyが一致するものだけを対象とする。指定Keyが候補に存在しない場合、そのKeyに対する処理は行わない。

`DryRun` はPowerShellの `WhatIf` を利用する。ただしCreateでは存在確認API、GUIのDry Runでは存在確認APIを実行するため、完全なオフライン処理ではない。

## 9. Create処理

### 9.1 フロー

```text
選択候補を順番に処理
    │
    ▼
GET /api/projects/search
    │
    ├─ 同一Keyが存在 → EXISTSを記録して次候補へ
    │
    └─ 存在しない
           │
           ▼
       POST /api/projects/create
           │
           ▼
       CREATEDを記録
```

1件が既存でもバッチ全体を諦めず、残りの候補を継続する。

### 9.2 作成属性

Create APIへ渡す値は次の2つ。

| APIパラメータ | 値 |
|---|---|
| `project` | 候補の `ProjectKey` |
| `name` | 候補の `Name` |

Visibility、権限、タグなどは設定しない。SonarQube側の既定値を利用する。

### 9.3 既存Project

同一KeyのProjectが存在する場合、名前や設定を更新しない。既存Projectの所有者や作成元までは検証しない。

## 10. Scan処理

### 10.1 事前条件

- `SONAR_TOKEN` が設定済み
- Scanner実行ファイルが起動可能
- 候補ディレクトリが存在
- SonarQubeへ接続可能
- Tokenに解析権限がある

### 10.2 候補ごとの実行

各候補についてScanner Jobを作成し、候補の `Path` をカレントディレクトリにする。このため、Scannerのベースディレクトリは候補ごとに異なる。

```text
候補A Path → Scanner Aのベースディレクトリ
候補B Path → Scanner Bのベースディレクトリ
```

実行時引数:

```text
-Dproject.settings=<共有properties>
-Dsonar.projectKey=<候補Key>
-Dsonar.projectName=<候補名>
-Dsonar.token=<環境変数のToken>
```

### 10.3 解析結果

Scannerの標準出力と標準エラーを文字列として回収し、次の結果オブジェクトを返す。

| プロパティ | 内容 |
|---|---|
| `ProjectKey` | 対象Key |
| `ExitCode` | Scanner終了コード |
| `Output` | Scanner出力 |

CLIは1件でも非0なら終了コード1とする。GUIは各終了コードをログへ表示する。

### 10.4 Createとの関係

ツール上はCreateとScanを独立操作としている。推奨順序はCreate後にScan。SonarQubeの権限設定によってはScanが未作成Projectを作成できるが、本ツールの保証対象は明示的なCreate後のScanである。

## 11. Delete処理

Deleteは通常運用では自動実行しない。GUIのDeleteまたはCLIのDeleteを明示実行した場合だけ動作する。

### 11.1 安全制御

```text
allowDelete == true ?
    └─ No → 拒否
    └─ Yes
         │
         ▼
deleteOnlyCreatedByTool == true ?
    └─ Yes → Project Keyが "<prefix>-" で始まるか確認
    └─ No  → prefix確認を省略
```

GUIではさらに確認ダイアログを表示する。CLIでは `-Force` がない場合にPowerShell確認を表示する。

### 11.2 API

`POST /api/projects/delete` へProject Keyを渡す。通常のDelete処理は事前の存在確認を行わないため、存在しないProjectに対してはAPIエラーとなる。

### 11.3 E2Eの後片付け

Community E2Eテストは `finally` で作成Projectを削除する。`-KeepProjects` 指定時だけ残す。一部テストが失敗しても後片付けを試行する。

## 12. CommunityとEnterprise

### 12.1 Community Build

`sonar.applicationKey` がnull、空文字、または未指定の場合、Application APIを一切呼び出さない。

Community BuildではProjectは個別に存在する。ツール内では同じJSON、rootPath、prefixに属する候補が処理上のまとまりだが、SonarQube Web UI上のApplicationにはならない。

### 12.2 Enterprise

`applicationKey` が設定されている場合、Create処理の後で選択候補を既存Applicationへ登録する。

現在の実装はApplication自体を作成しない。Applicationは事前に存在する必要がある。

```text
Project Create処理
    │
    ▼
applicationKeyあり
    │
    ▼
選択Projectごとに /api/applications/add_project
```

## 13. SonarQube API

| 目的 | Method | Path |
|---|---|---|
| Token検証 | GET | `/api/authentication/validate` |
| Project検索 | GET | `/api/projects/search` |
| Project作成 | POST | `/api/projects/create` |
| Project削除 | POST | `/api/projects/delete` |
| Application登録 | POST | `/api/applications/add_project` |

GETパラメータはURLエンコードする。POSTは `application/x-www-form-urlencoded` を使用する。

TokenはBasic認証のユーザー名部分として使用し、パスワード部分を空にする。

## 14. プロキシと通信経路

| 操作 | 通信主体 | プロキシ |
|---|---|---|
| 認証、検索、作成、削除 | PowerShell `Invoke-RestMethod` | Windows／.NET既定設定 |
| Scanner | SonarScanner Javaプロセス | `sonar.scanner.proxy*` |
| Podman pull | WSL上のPodman | WSL環境変数 |

Scanner用プロキシはPowerShell API通信には適用されない。逆も同様である。

API用の明示的な `-Proxy`、プロキシ資格情報、環境別切替は現在実装していない。

## 15. 認証とセキュリティ

### 15.1 Token

Tokenはプロセス環境変数 `SONAR_TOKEN` だけから取得する。空または未設定ならAPI・Scanner処理を開始せずエラーにする。

### 15.2 秘密情報の出力

API認証ヘッダーはログへ出力しない。Scannerにはコマンド引数でTokenを渡すため、OS上でプロセス引数を閲覧できる管理者から完全に秘匿されるわけではない。Scanner出力を保存する場合もTokenが含まれないことを確認する。

### 15.3 削除

誤削除防止は `allowDelete`、prefix検証、GUI確認、CLI確認の組み合わせで行う。ただしprefixは所有権の暗号学的証明ではない。信頼できない既存環境での完全な作成元判定には、台帳またはタグによる追跡が必要である。

### 15.4 TLS

証明書検証を無効化する機能は提供しない。社内CAはWindowsとScannerのJava truststoreへ正しく登録する。

## 16. エラー処理

### 16.1 API

API失敗時はMethod、Path、HTTPステータス、元例外メッセージを含む例外へ変換する。Tokenそのものは含めない。

Createの候補ループでは、API例外を候補単位で捕捉して継続する実装ではない。1件でAPI例外が発生すると、そのCreate操作は停止する。既存Projectは例外ではなく正常スキップなので継続する。

### 16.2 Scanner

Scanner Jobは終了コードと出力を結果として返す。他のScanner Jobは独立して実行されるため、1件失敗しても既に起動済みのJobは完了まで回収する。

### 16.3 GUI

操作イベントの例外を捕捉してログとMessageBoxへ表示し、GUIプロセス自体は維持する。

### 16.4 E2E

`try/finally` で削除を実行する。Scanner失敗時も後片付けへ進む。

## 17. 冪等性

| 操作 | 冪等性 | 詳細 |
|---|---|---|
| 候補生成 | あり | 同じ構成・設定なら同じKey |
| Project作成 | あり | 同一Keyが存在すればスキップ |
| 既存Project更新 | 対象外 | 名前や設定を更新しない |
| Scan | 再実行可能 | 実行ごとに新しい解析として登録 |
| Delete | 厳密にはなし | 存在確認せず削除APIを呼ぶ |
| Application登録 | 保証なし | 登録済み事前確認を行わない |

Createの冪等性はProject Keyに限定される。同一Keyの既存Projectが意図したProjectかは検証しない。

## 18. 並列実行

Scannerだけを並列化する。APIによるProject作成・削除は逐次実行する。

`scanner.parallelism` を最大同時Job数として、Queueから候補を取り出す。

```text
Pending Queue
    │
    ├─ Job 1 ─ Scanner A
    ├─ Job 2 ─ Scanner B
    └─ 上限到達時は完了待ち
```

1件完了するたびに結果を回収・Jobを削除し、次候補を開始する。初回Scanner実行では複数Jobが同時にランタイムやPluginを取得し、共有キャッシュ競合が起こる可能性がある。事前に `sonar-scanner.bat --version` を実行し、必要なキャッシュを準備することを推奨する。

## 19. ログと終了コード

### 19.1 GUI

時刻、操作種別、Project Key、結果またはエラーを画面下部へ表示する。ファイルへの永続保存はしない。

### 19.2 CLI

候補や結果を標準出力へ表示する。Scanner結果に非0が1件以上あればプロセス終了コード1とする。PowerShell例外が未処理の場合も非0終了となる。

### 19.3 Scanner出力

コアモジュールはScanner出力を結果オブジェクトへ格納する。現在のGUIは終了コードだけを要約表示し、Scanner全文をGUIログへ表示しない。

## 20. テスト設計

### 20.1 単体テスト

外部SonarQubeを使用せず次を確認する。

- Project Key正規化
- パス区切りの変換
- 数字のみKeyの拒否
- properties読込
- 除外ディレクトリ
- 候補Key
- null Application guardの存在

### 20.2 Community E2E

ローカルCommunity Buildに対して次を確認する。

1. Token認証
2. 候補取得
3. 最大指定件数のProject作成
4. Project存在確認
5. Application APIスキップ
6. 任意でScanner並列実行
7. Project削除

### 20.3 手動GUIテスト

次を手動確認対象とする。

- 設定ファイル選択
- Load後の一覧
- 複数チェック
- Dry Run
- Create
- Scan
- Delete確認ダイアログ
- エラーMessageBox

### 20.4 保証対象外

- Enterprise Applicationの実環境E2E
- 認証プロキシ環境の自動E2E
- 社内CA環境
- 大規模Projectでの性能上限
- GUI自動操作テスト

## 21. 現在の制約

- 1候補ディレクトリを1 Projectとして扱う
- 同じベースディレクトリをProject別includeで分割できない
- Project表示名、Key、sourcesを候補ごとに明示するProjectリストがない
- Community Build上でProjectを束ねるタグ機能がない
- Application作成を行わない
- Application登録の重複確認を行わない
- Delete前の存在確認を行わない
- ツールが作成したProjectの厳密な台帳を持たない
- GUI処理中は画面操作できない
- Scanner出力のファイル保存がない
- API用プロキシをツール設定で明示できない

## 22. 将来拡張

優先候補:

1. 明示的なProject定義

   ```json
   {
     "projectKey": "system-frontend",
     "name": "Frontend",
     "baseDirectory": "C:\\work\\system",
     "inclusions": ["frontend/**/*"]
   }
   ```

2. 同一ベース＋Project別 `sources`／`inclusions`／`exclusions`
3. Community向けProjectタグとGUIグループ
4. 作成Project台帳による削除安全性向上
5. Deleteの存在確認による冪等化
6. Application存在確認・作成・登録済み確認
7. GUIの非同期化、進捗、キャンセル
8. Scannerログのファイル保存
9. API用明示プロキシ設定
10. PesterによるAPIモックテストとGUI自動テスト
