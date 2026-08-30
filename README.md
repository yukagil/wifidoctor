# WiFiDoctor

Wi-Fiが遅いときに、**どこが原因かを切り分けて、打てる手を提示する** macOS メニューバーアプリ。

会議室を移動しながらノートPCを使っていると「なんか遅い」が頻発する。
その原因が電波なのか、APの混雑なのか、回線なのか、あるいは Mac 自身なのかが分からないと、
待つ以外の対処ができない。それを分かるようにするためのツール。

> A macOS menu bar app that continuously measures Wi-Fi quality, isolates *where* the
> slowness comes from (radio link / access point / upstream / the Mac itself), and
> suggests what to actually do about it. UI and code comments are in Japanese.

## 考え方

**レイヤを下から順に潰す。** `自分 → Wi-Fi機器 → インターネット` を別々に測ることが本体で、
これで「Wi-Fi区間が悪い」のか「その先が悪い」のかが確定する。

```
💻 ──────── 📡 ──────── 🌐
このMac      Wi-Fi機器    インターネット
     ここが原因
     ゆらぎ大
     45 ミリ秒
```

| 判定 | 条件 | 提示する手 |
|---|---|---|
| `MEASURING` | まだ一度も測れていない | （待つ） |
| `STICKY` | 同一APのまま電波が12dB以上低下し、より良いAPが2回続けて見えている | つなぎ直す |
| `WEAK` | 電波が弱く、乗り換え先も無い | APに近づく |
| `CONGESTED` | リンクは健全なのに第一ホップが遅い | 別の回線へ切り替える |
| `SELF_TRAFFIC` | 第一ホップが遅く、かつ自分が大量に流している | 転送を止める |
| `MAC_BUSY` | 回線は正常だが CPU/メモリが逼迫 | 重いアプリを閉じる |
| `ISP` | 第一ホップは健全、その先が遅い | 情シスへ（レポート添付） |
| `DNS` | 名前解決だけ遅い | DNS変更を検討 |
| `NO_INTERNET` | 経路が無い、または外部もDNSも到達不能 | サインインが必要か確認 |
| `OFFLINE` | 未接続 | Wi-Fiをオンに |

### 設計上こだわった点

- **画面と判定は必ず同じ値から出す。** 別々に計算すると「混雑と判定しているのに区間は緑で速い」
  のような矛盾が起きる。健全に見える区間を「ここが原因」と名指ししないことをテストで縛っている。
- **計測が計測対象を壊さないようにする。** ping を5秒間隔で撃ち続けると自分で電波時間を食う
  （実測で第一ホップが 17〜49ms → 4〜6ms に改善した）。状態が落ち着いていれば間隔を伸ばし、
  バッテリー駆動ならさらに控える。画面が消えている間は測らない。
- **打てる手が無いときはボタンを出さない。** 実用的なAPが1台しかない場所では、
  つなぎ直しても切り替えても混雑は解消しない。その事実を伝えるほうが役に立つ。

## ビルドと実行

```sh
./build.sh                        # ビルドして ~/Applications へ設置
open ~/Applications/WiFiDoctor.app
```

`.app` バンドルにしているのは、位置情報の許可（SSID/BSSID の取得に必須）と
通知の許可が、バンドル＋署名なしでは取れないため。初回起動時に位置情報の許可を求める。
許可しなくても動くが、接続先の識別と乗り換え候補の提示ができなくなる。

依存ライブラリなし。Swift と macOS 標準フレームワークのみ。

## テスト

```sh
~/Applications/WiFiDoctor.app/Contents/MacOS/WiFiDoctor --test
```

約 2,900 チェック。

- `--selftest` … 判定ロジック、点数と判定の整合、ping解析、保存と差分読み、
  通知の抑制、集計、保持期間、文言の網羅
- `--uitest` … 全状態でのパネル高さの一致、文字切れ、全画面の描画、
  グラフの断面表示、大量・欠損データでの描画、負荷分析、スキャン蓄積

実ネットワークに依存して自動化できないものは専用フラグで確認する。

```sh
WiFiDoctor --status      # 自動起動の登録状態、ホットキー、経路、ログ保存先
WiFiDoctor --scan        # スキャン結果と乗り換え候補の判定内訳
WiFiDoctor --speedtest   # 実効速度（回線を約20秒占有する）
WiFiDoctor --roamtest    # つなぎ直しの所要時間（数秒切断される）
```

## 記録

`~/Library/Application Support/WiFiDoctor/YYYY-MM-DD.jsonl` に1行ずつ。
30日を超えたものは自動削除する。外部への送信は一切ない。

## macOS の制約でできないこと

作る過程で実測して分かったこと。UIにも明記している。

- **APを指定して張り替えられない。** `CWInterface.associate` も
  `networksetup -setairportnetwork` も `-3900 (tmpErr)` で拒否される。
  `disassociate()` は0.2秒で切れるが macOS が自動再接続しない。
  結局 Wi-Fi の電源を入れ直すしかない（ネットワーク機器ベンダーが案内している回避策と同じ）。
- **APごとの接続台数・電波利用率が取れない。** ビーコンの QBSS Load 要素が必要だが、
  `CWNetwork.informationElementData` が nil を返す。
- **ノイズフロアが取れないことがある。** `noiseMeasurement()` も `system_profiler` も 0 を返す。
  取れない場合は SNR を判定から外す（0として扱うと SNR が負になり誤判定する）。
- **実効スループットを常時計測できない。** 回線を占有するため手動のみ。
  代わりにインターフェースの累積バイト数から実際に流れた量を受動観測している。

## ライセンス

MIT
