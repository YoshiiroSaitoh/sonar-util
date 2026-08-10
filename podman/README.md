# Podman SonarQube Community Build E2E 環境

SonarQube Community Build と PostgreSQL を Podman Compose で起動する、破棄可能な開発・E2Eテスト環境です。Docker Desktop は不要です。SonarQube のみ `http://localhost:9000` に公開し、PostgreSQL のポートはホストへ公開しません。

## 前提

- Windows に Podman Desktop または Podman CLI がインストール済みであること
- Podman machine が作成・起動済みであること
- `podman compose version` が成功すること（Compose provider が利用可能であること）
- SonarScanner CLI が Windows 側にインストールされ、`sonar-scanner.bat` が `PATH` 上にあること

確認例:

```powershell
podman machine list
podman machine start
podman compose version
sonar-scanner.bat --version
```

## 初期設定と起動

このディレクトリで `.env.example` を `.env` にコピーし、`SONAR_DB_PASSWORD` を十分に長いランダムな値へ変更します。`.env` は `.gitignore` の対象です。

```powershell
Set-Location podman
Copy-Item .env.example .env
notepad .env
podman compose up -d
```

イメージを厳密に再現したい場合は、`.env` の `SONARQUBE_IMAGE` と `POSTGRES_IMAGE` を検証済みのバージョンタグまたは digest に固定してください。

## 運用コマンド

```powershell
# 起動
podman compose up -d

# 状態確認
podman compose ps

# SonarQube のログ
podman compose logs -f sonarqube

# 停止（named volume は保持）
podman compose down

# コンテナ、ネットワーク、データを含めて完全削除
podman compose down -v
```

初回起動はDBの初期化や検索インデックスの作成に時間がかかります。`sonarqube` が healthy になり、`http://localhost:9000` を表示できるまでログを確認してください。データは `postgresql_data`、`sonarqube_data`、`sonarqube_extensions`、`sonarqube_logs` の named volume に保存されます。

## Podman machine のカーネル設定

SonarQube の検索エンジンは Linux VM の `vm.max_map_count` が少なくとも `524288`、`fs.file-max` とプロセスのファイル記述子上限が少なくとも `131072`、ユーザーが作成できるスレッド数が少なくとも `8192` であることを要求します。コンテナの `nofile` と `nproc` は `compose.yaml` にも設定しています。machine 側の現在値は PowerShell から確認できます。

```powershell
podman machine ssh "sysctl vm.max_map_count"
podman machine ssh "sysctl fs.file-max"
podman machine ssh "ulimit -n"
podman machine ssh "ulimit -u"
```

`vm.max_map_count` が不足する場合の一時設定例:

```powershell
podman machine ssh "sudo sysctl -w vm.max_map_count=524288"
podman machine ssh "sudo sysctl -w fs.file-max=131072"
```

machine 再起動後も維持する設定例:

```powershell
podman machine ssh "printf 'vm.max_map_count=524288\nfs.file-max=131072\n' | sudo tee /etc/sysctl.d/99-sonarqube.conf"
podman machine ssh "sudo sysctl --system"
```

反映後に `podman machine stop`、`podman machine start` を行い、値を再確認してください。machine の実装や更新によって永続設定が保持されない場合があるため、SonarQube が起動しないときはログと設定値を再確認します。ファイル記述子不足がログに出る場合は、Podman machine 側の limits 設定も見直してください。

## 初回ログイン、Token発行、ツール設定

1. ブラウザーで `http://localhost:9000` を開きます。
2. 初期資格情報 `admin` / `admin` でログインし、画面の指示に従ってパスワードを変更します。
3. 右上のユーザーメニューから **My Account** → **Security** を開きます。
4. Token 名（例: `local-e2e`）を入力して Token を生成し、表示された値を安全な場所へ一度だけコピーします。
5. ツールを起動する同じ PowerShell セッションで Token を環境変数に設定します。

```powershell
$env:SONAR_TOKEN = "発行したToken"
```

値をソースコード、JSON設定、`.env`、ログへ書き込まないでください。新しい PowerShell では再設定が必要です。本ツールは `SONAR_TOKEN` を認証に使用します。

## Community Build 用設定

リポジトリ直下の [`sample-config-community.json`](../sample-config-community.json) と [`sonar-community.properties`](../sonar-community.properties) を使用します。テスト対象に合わせて `rootPath` を変更してください。SonarQube URLとScanner設定はpropertiesファイルで管理します。

Community Build には Enterprise の Application 機能がないため、`sonar.applicationKey` は `null` のままにするか、プロパティ自体を省略します。ツールはその場合、Application の作成、Application への Project 登録、Application 集約表示を含む Application 関連APIを一切呼び出してはいけません。これらは Enterprise 環境でのみ統合テストします。

この構成で Token 認証、Project存在確認、Project作成・削除、Dry Run、SonarScanner実行と並列実行、結果登録、エラーハンドリングを検証できます。

## 開発用E2Eテスト手順

1. `podman` ディレクトリで `podman compose up -d` を実行します。
2. `podman compose ps` とログで healthy を確認し、`http://localhost:9000` にログインします。
3. **My Account** → **Security** でテスト用Tokenを作成します。
4. PowerShellで `$env:SONAR_TOKEN = "発行したToken"` を設定します。
5. 本ツールで `sample-config-community.json` を読み込みます。
6. `rootPath` 配下のテスト用ディレクトリがProject候補として表示されることを確認します。
7. Dry Runを実行し、作成・Scanner実行・削除予定が表示される一方、SonarQubeが変更されないことを確認します。
8. GUIから候補を数件選び、Projectを作成します。
9. GUIからSonarScannerを実行し、設定した並列数でも正常に完了することを確認します。
10. SonarQube Web UIのProjects画面で解析結果を確認します。
11. GUIから作成したProjectを削除し、Web UIから消えることを確認します。
12. 初期状態へ戻す必要があれば `podman compose down -v` を実行し、再度 `podman compose up -d` で作り直します。

削除テストは必ずローカル環境で行い、`allowDelete` と `deleteOnlyCreatedByTool` を有効にしたまま、ツール自身が作成したProjectだけを対象にしてください。`down -v` はこのComposeプロジェクトの全DB・SonarQubeデータを削除します。

## トラブルシューティング

- `database` が unhealthy: `podman compose logs database` と `.env` のDB設定を確認します。
- `sonarqube` が起動を繰り返す: `podman compose logs sonarqube`、`vm.max_map_count`、Podman machine のメモリ割当を確認します。
- 9000番ポートが使用中: `.env` の `SONAR_HOST_PORT` を変更し、設定JSONの `sonar.url` も同じポートへ変更します。
- 完全にやり直す: `podman compose down -v` の後、再起動します。
