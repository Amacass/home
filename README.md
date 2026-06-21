# イヤホン探し (EarbudFinder)

Bluetoothイヤホンの**接続が切れた瞬間の位置(GPS)を自動で記録**して、後から地図で探せるようにするiOSアプリです。

イヤホンケースには AirTag を付けられますが、**イヤホン本体には付けられません**。ポケットに入れたまま無くす…そんなときに「最後にBluetoothが切れた場所」が分かれば見つけやすくなる、という発想で作りました。

## 仕組み

iOSでは、AirPodsのようなオーディオ用Bluetooth機器は CoreBluetooth では直接扱えません。そこで本アプリは **`AVAudioSession` のオーディオ経路（ルート）変更通知** を使って、イヤホンが外れた／圏外になった瞬間（`oldDeviceUnavailable`）を検知します。検知すると、その時点の GPS 位置を記録します。

```
イヤホンで再生中 → 接続が切れる → ルート変更通知を受信 → 現在地を保存 + 通知
```

### バックグラウンドでも検知するための工夫
他アプリ（Apple Music / Spotify など）で音楽を聴いている最中にイヤホンが切れても捕まえられるよう、アプリは「音量ゼロの無音」を `.mixWithOthers` でループ再生し、自分のオーディオセッションをアクティブに保ちます（`KeepAliveAudio`）。これにより、アプリがバックグラウンドにいてもルート変更通知を受け取れます。設定でON/OFFできます（電池を消費するため）。

> ⚠️ この「無音再生によるキープアライブ」は個人利用では有効な手法ですが、App Store のガイドライン上はグレーゾーンです。ストア配布を考える場合は注意してください。

## 主な機能
- 接続が切れた場所を自動で記録（端末ローカルに保存）
- 最後の場所を地図表示 ＆ Apple マップで道順表示
- 切断時にローカル通知
- 切断履歴の一覧・削除
- 「いまの位置でテスト記録」ボタン（動作確認用）

## 構成
| ファイル | 役割 |
|---|---|
| `EarbudFinderApp.swift` | アプリのエントリポイント |
| `AppModel.swift` | 全体の取りまとめ（許可リクエスト・監視開始・記録） |
| `AudioRouteMonitor.swift` | オーディオ経路を監視し切断を検知 |
| `LocationManager.swift` | 位置情報の取得（常時許可・バックグラウンド更新） |
| `KeepAliveAudio.swift` | バックグラウンド検知用の無音再生 |
| `DisconnectStore.swift` | 切断イベントのJSON永続化 |
| `DisconnectEvent.swift` | 1件の切断イベントのモデル |
| `NotificationManager.swift` | ローカル通知 |
| `ContentView.swift` | 画面（地図・履歴・設定） |

## ビルド方法
1. macOS + Xcode 15 以降
2. `EarbudFinder/EarbudFinder.xcodeproj` を Xcode で開く
3. 署名チーム（Signing & Capabilities）を自分の Apple ID に設定
   - `PRODUCT_BUNDLE_IDENTIFIER` は `com.example.EarbudFinder` なので、必要に応じて自分のものに変更
4. **実機（iPhone）** を接続して Run
   - 位置情報・通知・バックグラウンドオーディオは実機での確認を推奨

### 使う権限（Info.plist 設定済み）
- 位置情報（常に許可を推奨）: `NSLocationAlwaysAndWhenInUseUsageDescription` ほか
- Background Modes: `audio`, `location`
- 通知（コードから実行時に要求）

## 動作確認の手順（実機）
1. アプリを起動し、位置情報を「常に許可」、通知を許可
2. Bluetoothイヤホンを接続（ステータスにデバイス名が出る）
3. イヤホンの電源を切る／ケースにしまう／十分離れる → 切断
4. 通知が来て、アプリに「最後に切れた場所」が地図表示される

> シミュレータでは Bluetooth ルート変更を再現しにくいため、「テスト記録」ボタンで保存・地図表示・マップ連携の動作確認ができます。

## 既知の制限
- 片方だけ外れて mono に切り替わる等、完全切断でない場合は記録されないことがあります（仕様上、完全な切断を検知）。
- 端末が完全に電源オフ・アプリが強制終了・OSにkillされた状態では検知できません。
- 位置精度は GPS 環境に依存します（屋内・地下などは粗くなります）。
