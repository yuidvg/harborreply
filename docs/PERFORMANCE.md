# 返信準備の性能と計算量

## v0.1.19 実データ計測（2026-10-11）

[集計のみの実測記録](live-main-real-v0119.json)。実Mailの取得・索引・文体は製品の実装を使い、所有者のDBを更新せず私用一時DBで実行した。メタデータ120通、本文115通、本文サイズ250,774bytesの範囲であり、300GB/342GBの合格ではない。索引20通で停止→同じscan/epochで再開を確認したが、128通目標は180秒で打ち切った。

| 実データ処理 | 測定値 | 範囲 |
|---|---:|---|
| 索引の最初20通 | 38.667秒 | 18本文、2サイズ除外、27フォルダ発見 |
| 再開→120通 | 180.904秒 | 115本文、5サイズ除外、保存後停止 |
| 文体予算4,096 | 82.904秒 | 40本文試行→8例、4,080単位で公開 |
| 文体予算32,768 | 184.884秒 | 158試行→70例、32,735単位、中断・未公開 |
| worker返信準備p50/p95 | 144.738 /146.002ms | 9回、実取得サンプルを対象に使用 |
| SQL＋文脈p50/p95 | 1.265 /2.077ms | 9回、3,200VM処理、169SQL文 |
| 関連順位付けp95 | .676ms | 1候補、5メタデータpoint lookup |
| 索引後の検索ID p95 | .106ms | 22一致、600VM処理 |

録画・Mail送信・本文配置・外部モデルは実行していない。対象未選択のため、通常の成功capture/Coordinator先読み/生成/コピーは未検証。SQLのp95はアプリのp95と混同しない。検索一致や候補数は関連品質・AWS全履歴の再現率を証明しない。文体70例は採用途中で、完成したプロファイルは以前の8例。

記録されたMailイベントは328回/481.884秒、worker要求は43回/6.720秒。本文20通バッチの最大は62.482秒で、主な待ち時間はMailの本文取得にある。nativeのID探索/本文生成/キャッシュ/ダウンロードそれぞれの内部コストは切り分けていない。常駐workerを採用しても、この待ち時間の大半は解消しない。

残32単位で読み続ける停止条件は修正した。通常予算の残33で非空1byteの例は理論上入るため、その修正だけでは探索の長さを制限できず、実際に標準抽出が診断の180秒上限を超えた。次は十分な例を採用した後の無進捗探索を制限するポリシーを実測し、全件初回取得についてMailのlookup/contentコストを分離する。個別の正常な例を切り詰めて上限へ合わせない。

VerifierのピークRSSは120,045,568bytes。別Python計測は41,533,440bytes。各プロセスの生涯high-water markで、Mailや他の子プロセスを含めた合計メモリーではない。native layoutは保存済み実文体＋空の対象のReplyViewで9回、初回を含むp95 72.131ms。ウィンドウ表示/compositor/実操作の250ms目標の確認ではない。

以下は以前の設計・合成試験の記録で、上の実測に置き換えない。


## v0.1.15のMail ID取得

IDの範囲取得は使わず、128通ごとのページでIDを前後に256回個別取得する。他6列が範囲取得できれば6回で済み、全列が個別取得になっても1024回／ページが上限。範囲対応の確認は残り6列だけをキャッシュする。架空のネイティブ受信プロセスで、IDの範囲GETと余分なメール参照GETが0回であることを通常テストで検証する。実Mail内部の探索コストと実時間は未計測。IDイベント数を増やす信頼性の選択であり、300GBの初回索引化の性能合格ではない。索引後のSQLite/FTS検索は従来の予算・候補上限を維持する。

実メールは使わず、複数サイズの架空メールをストリーミングで取り込んで測定する。300GBを読み切ったという証明ではない。原本の容量、メール件数、索引容量、本文長、添付比率は別の変数として扱う。

## 再実行

```sh
nix run .#test
nix flake check
nix run .#performance -- --quick --output docs/performance-quick.json
nix run .#performance -- --counts 1000,10000,100000 --output docs/performance-scaling.json
```

通常のテストに小さな複数サイズの性能回帰が入る。`nix flake check` は同じ回帰とquick計測を実行する。大きな計測は別の入口で行う。一時データは終了時に削除し、384MiBで打ち切る。日常テストの判定に、デスクトップの負荷で変わる時間だけを使わない。

## 何を測るか

- 件数が増えたときの検索・履歴範囲集計・案件取得・返信文脈組み立ての所要時間。
- SQLiteの仮想マシン処理回数、実行計画、索引の使用、全件走査や一時ソートの有無。
- 全メールに一致する一般語、少数に一致する語、同時には一致しない語の検索。
- 原本検証で実際に読み込んだ範囲のバイト数、ピークRSS、索引容量、取り込み速度。
- 旧方式の全件集計と全ヒット順位付けを負の対照として実行し、回帰判定がその線形増加を検出すること。

SQLiteのVM処理回数は、SQLite内部のFTS処理の全CPU命令数を数えるものではない。実行計画・時間・読み込み量も併せて評価する。小さい合成コーパスでの増加率は、一般的な計算量の数学的証明ではない。

## 通常経路の設計

Nを索引のメール件数、Bを原本の総バイト数、Kを今回参照するメール件数、Rを今回検証する原本範囲のバイト数、Sを原本ファイル数とする。

| 処理 | 実装上のコストと上限 |
|---|---|
| 初回取り込み | O(B)のストリーム解析に索引の更新コストが加わる。RAMは全量ではなく単一メール・小バッチで制限 |
| 履歴件数・期間 | 維持した件数/サイズと日時索引の両端を読む。件数O(1)、期間O(log N)。通常返信でS個の原本を走査しない |
| 返信ヘッダー・確認済み案件 | B-treeのキー探索と今回の候補取得。O(log N + K)、候補60、案件100通/100イベント。超過は絞り込み要求 |
| 全文検索 | FTSのposting listの探索と最大100件の取得。全ヒットのBM25評価を毎回行わない。一般の複数語検索はposting listの長さに依存 |
| 関連候補の順位付け | 最大3つのFTS検索で各60件、重複除去後最大180件だけをスコア順に並べる。候補をPとするとO(P log P)、FTS内部探索はposting listに依存 |
| Mailの限定履歴 | 最大3メールボックス・各256件で合計768件のメタデータを読み、順位付け後最大20件だけ本文取得。アプリ側の候補数は固定上限だがMail内部のcount/range実装のコストは未計測 |
| 原本検証 | 索引位置から今回の範囲を読みSHA-256を再照合。O(R)。300GBのファイル全体を返信のたびにハッシュしない |
| 文体特徴の抽出 | 例の追加/除外で数値特徴を更新。説明・定型フレーズ・書式例は明示した抽出ボタンでのみ保存。最大3通の本文量に比例し、Nには比例しない。返信時は保存したプロファイルを読み、例の範囲を再照合 |
| 文脈 | 重要な根拠を優先し24,000文字以内。必須根拠が収まらない場合は生成を止める |
| ソースの状態診断・削除 | 明示した管理操作。全ソースのstatや索引再集計/VACUUMを行い得る。通常返信とは分離 |

一般の全文検索は「後に取り込んだ一致メール」を先に返す。v0.1.7の返信関連候補は、その限定プール内で件名・送信者・サービス名・話題を使って順位付けする。全ヒットの関連度順や送信日時順を保証しない。確認済み案件と返信関係を先に扱い、検索候補を根拠へ自動昇格させない。関連メールの正解率は速度とは別に評価する。

検索には0.75秒/200,000 VM処理回数の予算を設け、超えた場合は結果を完成扱いせず `SEARCH_BUDGET_EXCEEDED_NARROW_QUERY` を返す。これはSQLiteの進捗コールバックで確認する打ち切りであり、FTS内部処理・OSのI/O待ち・プロセス起動を含めた厳密な0.75秒保証ではない。

索引・対象件数・取得上限による判断は実装と合成測定に基づく。基礎資料: [SQLiteの索引探索](https://sqlite.org/queryplanner.html)、[FTS5](https://sqlite.org/fts5.html)。

## 残る検証

300GBの実際のメール構成、添付の多い書き出し、HDD/外部ドライブ、10,000原本ファイル、一般語の大きなposting list、長期の索引更新と最適化、古い大規模DBの一度だけの移行は未検証。実サイズの全体取り込みを勝手に始めず、利用者が指定した範囲を段階的に増やし、p95とRSS・ディスク容量・正解率を確認する。


## 2026-10-09の合成実測

[performance-100000.json](performance-100000.json)。Apple M3 Max / RAM36GiB、macOS27.0.1、Python3.14.7 / SQLite3.53.3。各サイズを実際にMIME解析して索引化した。固定20通の案件、各操作7回の時間サンプル（少数サンプルのp95）、ステップ数は別の測定パス。モデルとSwift→Pythonのプロセス起動は含まない。

| 全体メール件数 | 文脈p95 | 文脈VM処理回数 | 一般語検索p95 | 原本確認バイト数 | プロセス最大RSS |
|---:|---:|---:|---:|---:|---:|
| 1,000 | 4.318ms | 1,100 | 3.332ms | 6,810 | 42.2MB |
| 10,000 | 3.903ms | 1,100 | 2.926ms | 6,850 | 42.7MB |
| 100,000 | 3.441ms | 1,100 | 7.304ms | 6,890 | 42.7MB |

10万通の原本は34.4MB、索引218.3MB。取り込み81.282秒、毎秒1,230通、失敗0。短い合成本文なので索引/原本の比率は実メールへ外挿しない。最大RSSはプロセス全期間のhigh-water markで、サイズごとの純粋な割り当て量ではない。

負の対照の全件集計は8,000→80,000→800,000ステップ、全ヒット順位付けは17,000→161,000→1,601,800ステップへ増え、テストの回帰検出条件で区別できた。新経路の全gatesが成功。共存しない2語の検索は10万通でp95 2.048msだが、posting listの処理量の増加は残る。

[Nix quick測定](performance-nix.json)は固定Python3.13.15で別実行したもの。Nix内の回帰テストと合わせて成功。全300GB、実モデル、実機のMail往復を成功と扱わない。

## v0.1.4 の通常画面と抽出 (2026-10-10)

対象メール取得後の `prepare` は、文脈と最大20件の候補メタデータを1回のworker呼び出しで返す。候補ごとにPythonプロセスを起動しない。本文の原本確認は選んだ候補だけを読み、全候補を事実へ昇格させない。画面の `overview` は維持した集計と文体プロファイルだけを取得し、全ソースの診断を呼ばない。取り込みの各バッチも概要だけを更新し、管理用の全ソース列挙は終了時に行う。

通常の `test_style_extraction.py` は、本人確認済み送信例3通を固定し、未選択の合成メタデータを128→4,096件へ増やして、原本読み込み3範囲・合計バイト数一定・SQL VM処理回数3,000未満・増加300以内を検査する。これは抽出の計算量回帰であり、未選択メールのMIME取り込み性能を測った試験ではない。実際の全文取り込みと検索は別の `test_performance.py` と上の合成測定で扱う。

説明はローカルの書式統計から作る。実例のフレーズは選んだ原文の1行が安全な挨拶・結びの許可リストに完全一致したものだけ最大3件。名前・数値・判断を含む部分一致や引用は採用しない。架空の構成例を原文の実例と区別する。例がない場合は抽出を成功にせず、元メール変更で保存結果を無効化する。外部モデル呼び出しは0回。

SwiftUIからのworkerプロセス起動、Mail応答待ち、モデル推論は上のSQLite測定に含まれない。MailのApple Eventsは専用FIFO queueに移したためUIスレッドをブロックしないが、実Mailの応答時間は未計測。Liquid GlassはmacOS26以降のネイティブ描画で、全メールのビューや常時ポーリングを作らない。各対応OSでのスクロール・入力・視覚効果の実機性能は引き続き別の確認項目。

## v0.1.5 初回の文体登録と静的フロー

初回抽出は明示選択した `.eml` 1〜3通だけを登録・取り込みし、索引から各ソース最大2件のIDを解決して、文体例の選択をトランザクションで置き換える。既存ソースの `path UNIQUE` 索引と `locations` の主キーを使う。通常テストは128→4,096ソースで選択した1原本だけの確認・SEARCH計画・登録VM処理数400未満/増加100以内を検査し、4,097 locationsでもID解決が300ステップ未満・最大2件になることを検査する。これは原本ファイル数Sが増えた際の回帰検出であり、実際の4,096ファイルを取り込んだ測定ではない。

[v0.1.5 Nix quick実測](performance-v015.json)では1,000/4,000/16,000通の固定20通文脈が各1,100 VM処理、p95 3.369/3.550/2.628ms。原本340,280/1,367,780/5,489,780 bytes、索引2,334,720/8,802,304/35,209,216 bytes。回帰gatesと線形の負の対照を区別した。全300GBの測定ではない。

島の間の流れは少数の静的なSwiftUI Pathで描き、常時タイマー・アニメーション・全メール分のViewは作らない。空の島はネイティブButtonのヒット範囲を広げるだけで、抽出や検索の処理量を増やさない。画面描画の実機p95やフレーム時間は未計測。

## v0.1.7 限定履歴と候補順位付け (2026-10-10)

Mailの取得は同じアカウントの対象・受信・送信済み最大3メールボックスに限り、各先頭/末尾の合計256件、全体768件のメタデータをproperty列で読み取る。全メールの`whose`検索・本文先読み・添付データ取得をしない。Mailの並び順は保証できず、サンプル内の日付順と全履歴の最新順は異なる。候補上位20件だけ本文を読み、文体の島を押した場合は本人確認したSentから最大3件を読む。実Mail内部の件数取得・範囲応答・属性取得のコストと副作用は未実測なので、300GBのMailアーカイブでも一定時間とは主張しない。

ローカル関連検索は最大3つのFTS経路・各LIMIT60を重複除去し、最大180メタデータだけを順位付けする。全一致メールのBM25ソートは行わず、200,000 VM処理/0.75秒の予算を超えると明示エラーを返す。AWSは件名/送信者表示名の明示語か専用ドメイン境界で判定し、一般のAmazon買い物通知を同じサービスとみなさない。候補漏れ・誤関連の品質評価はこの処理量計測とは別。

[performance-v017.json](performance-v017.json) はPython3.14.7/SQLite3.53.3での架空計測。通常テストの関連索引回帰は次のサイズでFTS候補上限・VM処理数と増加を検査する。値はworker内だけの時間で、Swiftのプロセス起動・Mail・モデルは含まない。

| 合成索引件数 | 関連取得の時間 | SQLite VM処理数 | プロセス最大RSS |
|---:|---:|---:|---:|
| 128 | 2.10ms | 2,700 | 41.7MB |
| 1,024 | 2.18ms | 3,700 | 42.5MB |
| 4,096 | 2.43ms | 4,300 | 44.2MB |

同じJSONのquick計測は1,000/4,000/16,000通を実際に取り込み、固定20通文脈は各1,300 VM処理、p95 3.045/2.977/3.190ms。原本340,280/1,367,780/5,489,780 bytes、索引2,375,680/8,974,336/36,016,128 bytes。一般語検索は各3,100 VM処理、p95 2.402/2.592/2.506ms。回帰gatesと線形の負の対照を通過し、時間だけを判定基準にしない。RSSはプロセス全期間のhigh-water markで、件数ごとの純粋なメモリ量ではない。

大きな日本語メタデータでもworkerの2MiB要求上限を超えないよう、シリアライズした行を最大1,500,000 bytesで分割する。本文は順位付けに送らない。スナップショット本文12,000文字/ヘッダー32,768文字の上限を超える候補・送信例は切り詰めず除外し件数を表示する。架空アプリで768件の分割と大きな送信例1件の除外を検証済み。これらは巨大な実メール・添付・実Mail応答の受け入れではない。

## v0.1.8 全Mail catalog と保存済み本文の索引 (2026-10-10)

利用者がアプリで開始した走査は、Mailの公開オブジェクトからアカウントとメールボックス階層を最大32件ずつ発見し、SQLiteのqueueへ保存する。メールのmetadataは最大128件、本文のネイティブ取得は最大20件ずつ。本文付きworker要求はシリアライズ後1,500,000 bytesで分割し、workerのIPC上限2MiBを守る。全体のqueueや本文をRAMに載せず、チェックポイントとmetadata/本文/失敗理由を同じトランザクションで更新する。中断後は確定済みのカーソルから再開する。

チェックポイントと再送内容のhashは、JSONオブジェクトのキーを再帰的に整列して計算する。Swift/FoundationとPythonで辞書のキー順が変わっても同じ内容を受け入れ、配列順・型・本文などの内容変更は同一再送とみなさない。確定済みの再送は件数やrevisionを増やさない。比較対象は制限した1ページとカーソルで、全catalogの列挙は不要。

catalogのキーはアカウント・全メールボックスpath・Mail native IDで、Message-ID単独ではない。送信日時と受信日時を両方正規化して取得時のmetadata hashに含め、表示/選択用の日付は送信日時、なければ受信日時を使う。本文はSQLiteへplaintextとして保存する。本文hashとmetadata hashを使ったimmutable versionを保持し、raw MIMEや添付原本を`.eml`へ無条件複製しない。FTS更新はcatalogに保存したrowidから行い、FTSのUNINDEXED ID列を全件検索して更新しない。

今回の全体走査のコストは取得するmetadata/本文量と索引書き込みに比例し、1バッチのメモリ量を制限する。最初の全件取得が一定時間で終わるという意味ではない。metadataは各文字列16,384 UTF8 bytes、階層32、本文250,000文字、取得ヘッダー32,768文字まで。native側は報告されたメールサイズ2MiB超を本文取得前に除外するため、大きな添付付きのメールもmetadataだけになる場合がある。失敗・サイズ超過・本文未取得をcaptured件数に混ぜない。Mail内部のcount、範囲取得、contentの生成、サイズが不明/不正確な場合のメモリ量は未実測であり、workerの上限だけで実Mailの全RAM使用量を保証しない。

通常返信はこの保存済みFTSを既存の指定ファイル索引と同じ最大3経路×LIMIT60で検索し、最大180件のmetadataだけを順位付けする。ネイティブcatalogの本文payloadを順位付けのためにPythonへdecodeしない。候補previewもcatalogのmetadataだけを返す。旧768件window外にある900件の架空メールの最古のAWS関連を取得できる回帰がある。これは全文の関連度順保証ではなく、posting list探索と限定候補プール内の順位付けである。

文体は本人確認した送信者アドレスとactual Sent区分をSQL索引で絞り、アドレスごとに64件のkeysetページを読む。全一致を一度にソートしない。最大4,096候補、512採用例、設定されたUTF8バイト数によるtoken上限見積りで止める。通常は32,768 units、上限131,072 units。これはモデルのtokenizerによる実測ではない。選んだ本文だけを背景抽出し、返信時に送る原文例は最大3件・各2,048 bytes・合計4,096 bytesと集計profileに限る。引用/転送/署名区切り以降は文体集計から除く。全MailのLLM解析やembeddingは行わない。profileのmanifestは最大512個のindexed point lookupで検証し、返信時の本文hash検証は最大3件に限る。

## v0.1.8 合成native catalog 実測

[performance-v018.json](performance-v018.json) はPython3.14.7 / SQLite3.53.3 / Darwin arm64のworker内測定。native APIを呼ばず、架空`.invalid`のmetadataと269 bytesのplaintextを実際のバッチAPIへ渡してSQLite/FTSへ保存した。native Mail、Swiftのプロセス起動、画像/添付、モデルは含まない。

再実行:

```sh
nix develop --command python3 scripts/index-performance.py --quick --output /tmp/native-index-quick.json
nix develop --command python3 scripts/index-performance.py --output /tmp/native-index-100000.json
```

| catalog件数 | 保存したplaintext | JSON入力量 | DB/WAL等の合計 | 関連rank p95* | rank VM処理/回 | プロセス最大RSS |
|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 269,000 bytes | 580,769 bytes | 6,627,360 bytes | 2.580ms | 9,340 | 36.2MB |
| 10,000 | 2,690,000 bytes | 5,827,769 bytes | 41,000,384 bytes | 2.483ms | 6,460 | 36.7MB |
| 100,000 | 26,900,000 bytes | 58,477,769 bytes | 343,426,640 bytes | 2.792ms | 6,720 | 36.9MB |

*5回の少数サンプルの最大値をp95欄へ記録している。VM処理回数は100-step解像度。RSSはプロセス全期間のhigh-water mark。JSON入力量は実際に生成したbatch recordsの累積サイズで、rawメール容量ではない。fixtureの`messageSize`合計35,000,000 bytesは架空metadataであり、35MBのraw MIMEを取得した測定ではない。

10万catalog rows・10万body version rows・784 checkpoint rowsを実DBで確認した。workerでの保存と途中の計測を含む累積時間32.991秒、raw MIMEの保存0件。全gates成功、時間だけをpass/failにせず、VM処理数・growth・実行計画に一時的な全件sortがないことを普通のテストにも含める。FTS内部の全CPU作業はVM処理数へ出ない。SQLiteの索引量/本文量の比率は短い合成メール特有であり、実メールへ外挿しない。

nativeの取得時snapshotはその時点のplaintext hashを照合する。`snapshot_hash_verified`と`live_verified:false`を付け、指定ファイルの原本range確認を表す`range_verified`はfalseのまま。再走査でbody/metadataが変わると新versionへ切り替え、旧versionの確認済み案件リンクはfail closedする。current/header検索にはcatalogの現versionと有効epochだけを使い、保持した古いversionを再び現状の根拠にしない。完成epochの更新は全catalogのUPDATEでなく状態rowのwatermarkで行う。

immutable body versions、古いcatalog場所、過去scanのcheckpoint rowsは累積保存され、自動pruningや全体ディスク上限はない。通常走査の上限はRAM/ページ/IPCであり、長期間のディスク成長を制限するものではない。benchmarkの384MiB gateはこの合成実行のDB/WAL量の回帰チェックで、製品の保存容量制限ではない。長期の更新・削除・移動・アカウント変更後の増加量、保持期限と削除UI、FTS最適化、実Mailの取得速度、失敗率、関連メールの正解率、全300GBの受け入れは未検証として残る。


## v0.1.9 address-scoped Sent acquisition

Ordinary tests measure the separate journal without Mail/Swift IPC:64/256/600 fictional headers retain64/256/512 complete samples and perform64/256/512 source verifications;8.686/34.865/82.561ms for the journal-plus-extract path,79,788/319,524/639,268 stored JSON characters. The candidate cap is4,096 and the retained authored-text/token cap is131,072 conservative units in this scaling fixture. See style-acquisition-v019.json. These measurements are synthetic, not native Mail speed.

The Swift native-read budget test supplies128/4,096/100,000 failed/empty fictional messages. Attempts are128/1,024/1,024 and batches7/52/52, maximum20 reads per batch; increasing fixture count cannot increase native attempts after the cap. Worst-permitted returned bodies/headers allow30 reads within64MiB. Byte reservation is pessimistic before reading, then actual UTF-8 bytes are charged. These counters bound attempted public reads and returned text, not Mail's internal disk/network work or initial whole-archive indexing. Body retrieval can stop with an unused residual allowance smaller than one worst-case read. No300GB acceptance or latency extrapolation is implied.
