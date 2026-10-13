# HarborReply v0.1.27 — ローカル全メール索引から返信

選んだメール、関連メール、本人の文体と今回の指示から返信を作る、Apple Silicon向けmacOS試用アプリです。文体・関連メール→対象メール→調整→生成→返信を島と太い直線の流れで並べます。空の対象・文体の島全体が操作ボタンです。対象メールを取得すると保存済みの全メール索引から関連候補を探し、文体の島では本人が選んだ差出人の送信済みメールから文章を取得します。設定にはChatGPT接続とMail自動取得を置きます。

**通常のApple Mail本文差し込みは、実機受け入れ未検証のため無効です。** 診断コードは保持していますが、今回の簡素化で診断画面を外しました。検査済みの現在の返信をコピーして使えます。ビルド・自動テスト成功をMail連携完了とは扱いません。送信機能はありません。安全判断・積載可否を任せるシステムではありません。

## 起動

このMacで確認した環境: macOS 27.0.1 (26A434)、arm64、Xcode 27.0 (27A266a)、Swift 6.4、Nix 2.34.8。macOS 14 deployment targetです。macOS 26以降ではSwiftUIのLiquid Glassを補助カードと操作に使い、14〜25では標準のmaterial・ボタンへ切り替えます。メール本文と返信は読みやすい通常の背景です。14〜26での実機動作は未検証です。リポジトリのflakeがPythonと開発ツールを固定します。Macアプリのテスト・ビルドには、別途このMacにインストールされたXcodeのApple SDKが必要です。グローバルなnix-darwin設定は変更しません。

```sh
cd /Users/yui/Developer/personal/masa_mail
nix develop                        # Python / Git / rg / Nix formatter
nix flake check                    # Nix内で架空worker・性能回帰を検査
nix run .#test                     # Python + XcodeによるSwiftテスト
nix run .#build                    # build/HarborReply.app
open build/HarborReply.app
nix run .#package                  # 開発用の単独動作ZIPをdist/へ（未公証）
```

正式配布は下記の初回設定後に `nix run .#deploy` を使います。利用者のMacにはNix・Python・Xcode・GitHubアカウントは不要です。開発用ZIPは自動更新先を持たず、正式配布用とは区別します。

`nix build .#worker` はローカルworkerをNixパッケージとして作ります。Macの `.app` はホストのXcodeでビルドするため `nix run .#build` を使います。Nixのcheck/workerは固定Python 3.13.15、AirDrop配布は固定Python 3.14.8です。どちらもSQLite FTS5を使います。実メールやKeychain、DB、ログをflakeの入力に加えないでください。

従来の `scripts/test.sh` / `scripts/build-app.sh` / `python3 scripts/package-app.py` も使えます（Python 3.11+、配布スクリプトは3.12+）。開発ビルドはPython実行パスを記録します。`HARBOR_PYTHON=/absolute/path/to/python3 scripts/build-app.sh` で明示指定できます。Apple Silicon専用の `dist/HarborReply-0.1.27-apple-silicon.zip` にPythonを同梱し、開発マシンのパスや設定を含めません。[AirDropで渡す手順](docs/FRIEND_INSTALL.md) / [配布の検証](docs/DEPLOYMENT.md)。

既定はローカル用ad-hoc署名です。ad-hoc版は署名者Team IDがないためHardened Runtimeを付けません。正式配布版はDeveloper ID署名・Hardened Runtime・公証を必須にします。所有する署名IDがある場合だけ `HARBOR_SIGN_IDENTITY='実際の署名ID' scripts/build-app.sh` を使います。Team IDの仮設定やシステム変更はしません。署名変更/再ビルドでOSのAutomation許可が再確認される場合があります。

## 初回設定と操作

1. 歯車の設定から **Sign in with ChatGPT** で接続し、モデルを選びます。返信を生成するには「メールの抜粋をChatGPTに送って返信を生成」を明示的にONにしてください。未接続・送信無効の場合は生成を停止し、設定へ案内します。
2. 空の対象メールの島全体を押すと、Mailで選んだ1通を取得します。読み込み中・失敗は島の中に表示します。取得後は保存済みの全メール索引から関連候補を検索します。初回は関連メールの島の「全メールを索引化」を押してください。
3. 「全メールを索引化」はMailの公開Apple Eventsで、全アカウントとローカルのメールボックスを少量ずつ巡回します。本文はこのMacのSQLiteへ保存し、FTS5で索引化します。初回は全件を読むため時間がかかります。「停止」「索引を再開」で続きから再開できます。索引作成中も取得済みの範囲を検索できます。フォルダ・メール件数が変わって再開できない場合は「最初から索引を更新」を使います。
4. 文体の島を押し、自分の差出人アドレスを選ぶと、そのアカウントの送信済みから一致する文章を自動取得し、バックグラウンドで抽出します。全メールの索引は不要です。共有アドレスは選ばないでください。既定予算は32,768、文体の「確認・微調整」で変更できます。UTF-8バイト数による保守的な推計で、正確なモデルのトークン数ではありません。Mailの返す順序で候補4,096通まで確認し、最大512通の完全な文章を使います。引用・共有・別アドレス・重複を除外し、長すぎる例は切り詰めず次の例を探します。本文取得も最大1,024回・返された本文とヘッダーの合計64MiBに制限します。「再抽出」でアドレスを選び直せます。
5. 「調整」に指示を書いて生成し、検査済み本文を1回の「コピー」で使えます。Mailへの配置は実機安全確認が済むまで無効です。島を結ぶ流れは静的な描画で、常時アニメーションはありません。

返信時は全メールを再取得せず、ローカルSQLite/FTS5の索引から検索します。意味ベクトルではなく、本文・件名・送信者のキーワード、返信ヘッダー、AWS/Amazon Web Servicesなどの語を使います。候補は上限とSQL実行予算を設けて順位付けし、件名・候補理由・本文を確認できます。関連度は確定事実や承認ではありません。必要な履歴は案件へ関連付けます。

メール総数に768通の上限はありません。1回の取得はヘッダー128通、本文20通、worker入力は1.5MB以下に分割します。本文は最大250,000文字・native messageは2MiBまで、添付本文は取得しません。大容量・読めない本文もメタデータを索引に残し、件名から検索できます。本文を完全取得した資料としては扱いません。返信時の現在本文12,000文字／文脈24,000文字の安全上限は保持しています。

索引は取得時点のスナップショットで、自動同期ではありません。新着は「索引を更新」で反映します。全フォルダの巡回中に件数を保って並べ替わる等、Mail側の変化を完全に検出できるとは限りません。索引の完了は、その走査で公開APIが返したページの完了を示します。300GB・342GBの実データでは未検証です。架空10万通での件数・サイズ・検索時間・SQL処理数を [性能記録](docs/PERFORMANCE.md) に残しています。生成時は索引を一時停止し、文脈の変更で生成が中断されないようにします。

## 生成API・本人の文体

設定にはChatGPT接続とMail自動取得だけを残しました。**Sign in with ChatGPT** で本人がブラウザ認証し、取得した一覧からモデルを選び、「メールの抜粋をChatGPTに送って返信を生成」を明示的にONにします。変更はその場で保存します。サインインだけでは外部生成を有効にしません。認証情報はこのMacのKeychainに保存します。接続済みのアカウント、期限切れ・許可不足を区別し、アイドル中も30秒ごとに端末内で期限を確認します。この確認は通信もトークン更新もしません。

本人のプランの利用可否・枠に従い、別課金APIへ自動切り替えません。公式の[ローカルアプリ認証](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)と[プラン生成](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)のコードを備えていますが、本人の実認証・生成品質は未検証です。

文体抽出は選んだ差出人の送信済みを直接取得し、予算内で多通の特徴を集計してローカルで行います。アドレスの選択を本人の文章の指定として扱い、Mailの実Sent所属・アカウント・厳密なFrom一致を別に確認します。共有メールの筆者をFromだけで判定しません。引用・転送・重複を除き、観測した文体の説明と、中立的な許可された原文表現だけを表示します。該当する原文表現がなければ説明のみを表示し、架空の例文を補いません。旧版の合成例も表示・生成入力から除外します。生成へは集計プロファイルと、最大3通・各2,048バイト／合計4,096バイト以下の短い原文例だけを渡します。抽出した512通をそのまま外部へ送ることはありません。未対応の引用形式と文体品質は本人による確認が必要です。

Responses APIアダプターと旧保存設定は保持しますが、別課金API入力・アカウント管理・規程やイベントの管理・診断画面は通常UIから削除しました。既存の登録情報を削除する移行は行いません。

送信範囲は現在メール、必要履歴、本人の指示、選択した文体例、登録規程の抜粋です。社内の利用許可と保持条件は別途確認してください。`store:false` はゼロ保持・利用許可の保証ではありません。リダイレクト先へキーを転送しません。モデルにツールは渡しません。

ChatGPT接続後は、Mailの選択メールを取得して生成できます。取り込んだ関連メールの原文を開き「このメールから返信」を使うこともできます。

文面はパネルに保持します。根拠・内部注意を本文に混ぜません。対象・指示・案件・設定の変更や取消は古い結果を無効にします。重大エラーは挿入を止め、通常のスナップショット警告と区別します。意味の正しさは本人が確認してください。

## Mailと音声の権限

- メニューバーから開くか **Control + Option + R**。ショートカットはパネルを開いてMailで選択した1通を取得します。初回にはAutomationの通常のOS許可が必要です。選択0件/複数件は停止します。
- 「パネルを開いたらMailの選択メールを読み込む」は初期OFFです。本人がONにした初回は明示取得と同じOS許可フローで取得します。その後の起動・パネル表示時は、Mailが既に起動し、許可を要求しない事前確認が通り、指示・返信・追跡中の下書きがなく、録音・処理・取り込み中でない場合だけ1回取得します。待機中の定期監視や、Mailの自動起動はしません。自動取得時に未許可なら取得を見送ります。
- MailのAppleScript処理はUIと別の専用直列queueで実行します。取消後の待機中操作は実行せず、開始済みの下書き作成・挿入を取り消せなかった場合は、完了状況不明としてMailでの確認を案内します。自動再試行や下書き削除はしません。
- 関連候補と送信例の取得は読み取り専用のApple Eventsです。Mailの送信・削除・移動・既読化・アカウント設定変更を行いません。v0.1.17では明示許可の上で実Mail20通のメタデータ・本文3通を取得し、16通の索引化・検索・文体抽出まで確認しました。通常UIの操作、全Sent構成・共有アカウント・並び順・権限の全条件は未検証です。取得範囲と添付未取得を島の中に表示し、候補なしを「過去にない」と断定しません。
- Mail診断の通常UIは今回の簡素化で削除しました。診断境界のコードは保持していますが、現在版の実機受け入れは未完了です。既存の [Mail受け入れ手順](docs/MAIL_ACCEPTANCE.md) は診断を再公開するときの検証項目です。実データの画面を自動撮影しません。
- Full Disk Accessは要求しません。Mail内部DBへアクセスしません。クリップボードやAccessibilityを使って挿入しません。
- 「話して入力」で初めてマイク/Speech許可を要求します。端末内ja-JP認識が利用できる場合だけ録音し、停止後に確定した文字起こしを確認・修正して生成します。英語船名・数値・否定には特に注意してください。ローカル認識不可/権限拒否ならテキストを使えます。
- 音声は未実機検証です。SpeechAnalyzerではなく能力確認付きSFSpeechRecognizerを採用しています。
- Mailの下書きはアカウント設定によりサーバーへ同期されます。外部LLMをOFFにしてもMail本来の同期は停止しません。

## 保存・停止・削除

アプリ専用領域 `~/Library/Application Support/HarborReply/` にSQLite索引と設定を保存します。全メール索引の本文はSQLiteに一度保存し、MIME全体や大量の .eml を複製しません。旧版で取得した `mail-snapshots/` は保持します。Mailの原本・内部DBをコピーせず、添付本文は取得しません。ディレクトリ0700/ファイル0600で保護しますが、SQLite・スナップショットは自動暗号化されません。取得・索引・文体抽出だけでは外部送信せず、返信生成の明示同意は従来と別のままです。診断ログは既に本人が有効にしているか、本人が `open -a HarborReply --args --diagnostics` で明示起動した場合だけ `~/Library/Logs/HarborReply/` に保存します。時刻・段階・所要時間・件数・エラー分類/番号のみで、本文・件名・宛先・音声・認証情報は記録しません。約1MiB×2ファイルで循環します。テレメトリー・自動ログ送信・生音声保存はありません。返信の生成セッションはメモリーのみで、既定30分後またはアプリ終了時に消去します。期間変更・セッション消去の管理UIは外しました。元メール・Mail下書きは削除しません。

取り込み停止は現在の小バッチ後に止まり、同じソースを再開できます。書き出し原本が変更された場合は既存ソースを明示削除して再取り込みしてください。Mailの索引は関連メールの島から更新できます。通常UIから管理用削除画面を外しました。保持したコアの削除操作はソースと依存索引・イベント・文体例を対象にし、WAL/DBも整理します。OSバックアップやSSDの安全消去は保証しません。

関連メールの読み込みに失敗した場合は、島の中にコピー可能なエラーコードを表示します。例: `MAIL_INDEX_PAGE_METADATA_SUBJECT_EVENT_-1700`（索引のメタデータ取得・件名・元の番号）。ローカル検索は `RELATED_PREPARE__WORKER_PREPARE__…`、保存済み索引の確認は `RELATED_INDEX_STATUS__…` と区別します。本文やAppleのエラー文はコード・診断ログへ入れません。

対象メールの `9101` は、Mailが返した選択件数が1通ではないことを表します。Mailのメール一覧で対象を1通だけ選び、対象メールの島を押してください。別ウィンドウで本文を開いているだけでは、一覧の選択が返るとは限りません。画面には操作案内を表示し、診断コードは島にポインタを置くか、右クリックの「診断コードをコピー」で確認できます。選択なし・複数選択では取得・生成を続行しません。

## 検証を再実行

```sh
nix run .#diagnose                   # OS/SDK/FTS5/静的Mail辞書。Mailデータに触れない
nix run .#test                       # 架空データのみ、APIキー不要
nix run .#build                      # .app作成と署名検査
nix run .#performance -- --quick --output docs/performance-quick.json
# 10万通の小型架空データ。384MiBで打ち切り、終了時に一時データを削除
nix run .#performance -- --counts 1000,10000,100000 --output docs/performance-scaling.json
# 全メール索引の架空10万通・本文・再開・検索SQL処理数
nix run .#performance -- --native-index --output docs/performance-native-scaling.json
```

自動テストはテスト用Mockと、本番アプリから分離した `.invalid` のテストデータで、索引・取り込み・検査・状態管理・性能を確認します。開発用の品質評価シナリオ24件は `fixtures/scenarios/` と `fixtures/scenarios.json` に置きます。Mail実機・音声・認証後の生成品質・300GB全量の確認は別に記録します。アプリと配布ZIPには固定返信や架空メール・例文を同梱しません。

実Mailを使う開発用の読み取り専用検証は、製品に同梱しない別の署名済みアプリで実行します。本人の明示許可がある場合だけ、次のコマンドを使ってください。アカウントと差出人は既定で先頭を使用し、`--account-index N --address-index N` で数値指定できます。最大2フォルダ×16通のメタデータと送信済み本文3通を一時DBで索引化・検索・文体抽出し、一時状態を削除してから件数・時間のみ出力します。通常UI・下書き配置・モデル・全履歴の検証は含みません。

```sh
scripts/verify-live-mail.sh --build-only   # コンパイルのみ。Mailへアクセスしない
HARBOR_LIVE_RUNTIME_APP="$PWD/dist/HarborReply-0.1.20/HarborReply.app" \
  scripts/verify-live-mail.sh --allow-real-mail
```

v0.1.17の実測は本文3通の取得1.606秒、検索0.146秒、文体抽出0.159秒でした。Mailのqueue待ち・Apple Events・デコード、workerの起動・実行、索引・文体・生成の各段階を単調時計で計測します。通常の診断ログを有効にした次の操作でも同じ段階IDを記録します。親の段階には子の時間を含むため合計しません。[実Mail検証記録](docs/live-mail-v0117.json) / [開発サイクルの計測](docs/cycle-v0117-timing.json)。

[性能と計算量](docs/PERFORMANCE.md) / [検証結果](docs/VERIFICATION.md) / [設計と変更理由](docs/ARCHITECTURE.md) / [進捗・未完了](docs/PROGRESS.md) / [次版](docs/NEXT.md)

実データで主要処理の計測を明示開始する開発用入口（製品には入らない）:

```sh
scripts/verify-main-real.sh --build-only   # Mailへアクセスせずコンパイル
scripts/verify-main-real.sh --allow-real-mail --preflight
scripts/verify-main-real.sh --allow-real-mail
```

検証前にMailの一覧で1通選ぶ。私用一時索引で20通保存→128通までの再開、差出人の文体予算4,096/通常予算、検索9回、native layoutを計測する。各索引/文体段階を180秒で中断し、待機中のネイティブ読み取りが戻るまで終了が遅れることがある。選択なし・設定不足・無効なMail配置・音声権限は成功にせず区別する。本文・宛先・IDを出力しない。`--build-only`の作業ディレクトリは呼出側が削除し、通常実行は中断時も専用の私用状態を後始末する。`--allow-cloud-generation`は別の送信許可と所有者の有効な外部生成/モデル設定が揃う場合だけ使用し、設定を自動変更しない。今回の実データでは120通の索引、予算4,096の8例抽出と検索を確認したが、標準予算の文体は70例を採用した後180秒を超え、未完了だった。[最新の実測と限界](docs/PERFORMANCE.md)。

## 開発とリリースの流れ（Sparkle）

### 普段の開発

1. `nix develop` で開発環境へ入り、変更する。
2. `nix run .#test` で架空データの回帰・性能テスト、`nix run .#build` でネイティブアプリをビルドする。Mail実機、音声、実モデル、全履歴の確認は別の受け入れ作業。
3. 実データや秘密情報が含まれていないことを確認し、対象ファイルを選んでコミットする。`git add .` を無条件に実行しない。
4. 配布時は `scripts/Info.plist` の `CFBundleShortVersionString`（例: 0.1.27）と `CFBundleVersion`（単調増加する整数）を上げる。バージョンの正はこのファイル。`release.json` の `minimum_build` も必要に応じて更新し、リリース対象の変更をコミットする。
5. `nix run .#deploy`。テスト → ビルド → 同梱Python/署名検査 → 移動先での起動前検査 → Apple公証・staple → Sparkle署名 → GitHub Releases公開 → 更新情報の公開まで実行する。処理が一つでも失敗すれば後続は実行しない。

`deploy` は作業ツリーが未コミットなら停止します。ソースのコミットIDを配布manifestに記録しますが、ソースリポジトリ自体はGitHubへpushしません。現状の未コミット作業をこの仕組みが勝手にコミットすることもありません。

### 初回だけ必要な準備

- Apple Developer Programの **Developer ID Application** 証明書と秘密鍵を、このMacのKeychainに用意する。Apple Development証明書では正式配布できません。
- `gh auth login --hostname github.com` で配布アカウントに接続する。ソースとリリースは公開リポジトリ `yuidvg/harborreply` に統一します。GitHub Pagesの設定は不要で、`updates` ブランチの固定raw URLを利用します。
- `nix run .#build` で固定版Sparkleを取得後、次で専用の更新鍵をKeychainに作る。秘密鍵をリポジトリやNix storeへ保存しない。鍵の安全なバックアップは別途管理する。

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account HarborReply
xcrun notarytool store-credentials HarborReply
```

`notarytool` の対話入力には自分のApple認証情報を使う。パスワードをREADME、コマンド履歴やJSONに記載しない。

`release.json` の次の項目を実値で設定してコミットする。このファイルは公開可能な設定のみです。

| 設定 | 内容 |
|---|---|
| `repository` | リリース先 `所有者/リポジトリ`。公開ZIPを誰でも取得できることを前提とする |
| `signing_identity` | Keychainの実際の `Developer ID Application: ...` 証明書名 |
| `notary_profile` | 上で保存した公証用Keychainプロファイル名 |
| `sparkle_key_account` | 上で作ったSparkle鍵のKeychainアカウント名 |
| `sparkle_public_key` | `generate_keys` が表示した**公開鍵**。秘密鍵ではない |
| `minimum_build` | 期限後も生成を許可する最低ビルド番号。既定nullは今回の配布ビルド（毎回72時間後に必須）。数値指定なら配布ビルド以下 |
| `mandatory_after_hours` | 準備時刻から必須更新までの時間。既定72時間 |
| `policy_valid_days` | 署名付きポリシーの有効日数。既定90日 |

```sh
nix run .#deploy -- --check         # 公開せず、設定・コミット・証明書・GitHub・公証資格を確認
nix run .#deploy -- --prepare-only  # テスト・署名・公証まで。Appleへの公証送信は行う
nix run .#deploy -- --resume        # 準備済みの同一成果物から公開を再開
nix run .#deploy                   # 通常はこの一つで準備と公開
```

初回の未設定状態では `--check` も具体的な不足項目を表示して終了します。Sparkle秘密鍵と公開鍵の一致は準備中の実署名で検証します。`--prepare-only` 後は `--resume` で公開してください。公開失敗後も `--resume` を使い、同じ版を再ビルドして上書きしないでください。準備中に失敗してmanifestがない場合は `dist/releases/v…` の失敗成果物を確認してから、その生成ディレクトリだけを取り除いて再実行します。

### 更新の正と公開順序

- アプリが参照する更新一覧: `https://raw.githubusercontent.com/所有者/リポジトリ/updates/appcast.xml`
- 期限と最低ビルド番号: 同じ場所の `policy.json`（公開鍵で検証する署名付きJSON）。設定元は `release.json` に一本化。
- 配布本体: GitHub Releasesの `vバージョン/HarborReply-バージョン-apple-silicon.zip`。公開用ZIPの最上位は `HarborReply.app`。
- 来歴: `release-manifest.json` のソースコミット・ビルド番号・SHA-256。公開manifestに秘密鍵・認証情報・メール・ローカル設定は含めない。

ZIPを署名・公証してDraft Releaseにアップロードし、公開後に匿名ダウンロードのハッシュを検査します。その後だけ `updates` ブランチを進め、appcastとポリシーを一つのGitコミットで公開します。GitHubの「Latest」表示は更新判定には使いません。既存の異なる配布物は上書きせず、競合した公開やビルド番号の巻き戻しは停止します。GitHubのキャッシュにより端末への反映に時間差が生じます。

### 利用者側の動きと必須更新

正式配布版は自動チェック・自動ダウンロード/インストールを既定で有効化します。メニューバーの「アップデートを確認…」から手動確認もできます。処理中・録音中・入力や返信が残っている場合は終了を拒否します。更新前に文章をコピーし、確認ダイアログから返信をクリアして進めます。未保存文をディスクへ追加保存する機能ではなく、実行中のアプリ内に保持する方式です。

期限を過ぎた旧版は新しい生成・返信作成・挿入を停止します。既存文の表示・コピーは残ります。ポリシーは起動時と1時間ごとに取得し、期限判定は毎分行います。通信・署名検証失敗時は最後に検証できたポリシーと元の有効期限を維持し、失敗のたびに期限を延長しません。初回に有効なポリシーがない場合や有効期限切れでは生成を停止します。

**90日以上リリースを止める場合も、有効期限が切れる前に新しいビルドを配布してください。** 期限・最低ビルド番号の変更だけでも新しい版を用意します。強制更新にはオンライン確認が必要で、ローカル管理者の改変・時計変更まで防ぐDRMではありません。対応OSを上げる際は旧OSの利用者に更新先がなくなるため、最低ビルド番号を一律に上げないでください。

問題のある版を戻すときは、正常だったコードから**新しいビルド番号**で修正版を配布します。古いZIPの差し替えや既公開の番号への巻き戻しはしません。更新機構を持たない従来版には、最初の正式配布版だけ手動で入れてもらう必要があります。

### このMacで済ませた初回準備

配布先は [yuidvg/harborreply](https://github.com/yuidvg/harborreply) に作成済みです。Sparkle署名鍵はKeychainの `HarborReply` アカウントに作成し、公開鍵を設定済みです。初回の署名検証はKeychainのアクセス許可待ちになる場合があります。`release.json` に配布先と公開鍵を設定しています。

Developer ID証明書の申請ファイルは `~/Library/Application Support/HarborReply Signing/HarborReply-Developer-ID.certSigningRequest` にあります。対応する秘密鍵はlogin Keychainに保存済みです。[Appleの証明書ページ](https://developer.apple.com/account/resources/certificates/add)で **Developer ID Application** を選び、このCSRをアップロードして発行してください。取得した証明書をこのMacにインポートし、`release.json` の `signing_identity` に実際の証明書名を設定します。

公証認証は未登録です。`xcrun notarytool store-credentials HarborReply` の対話入力でAppleアカウント・Team ID・App用パスワードを登録してください。パスワードをチャットや設定ファイルに貼り付ける必要はありません。証明書・公証認証・レビュー済みソースのコミットが揃った後に `nix run .#deploy` を実行します。
