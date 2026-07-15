# せせらぎ (Seseragi)

雨音とピアノを、かさねて眠る。
**2つの「流れ」を同時に再生できる iOS デュアル音楽プレイヤー**です。

清流をイメージした深い青緑の画面の上に、2つのデッキ（ながれ A / ながれ B）が並びます。
それぞれのデッキで iPhone のミュージックライブラリから曲を選び、
**別々の音量・別々のリピート設定**で同時に流せます。

## 主な機能

- 🎵 **2デッキ並列再生** — 雨音のプレイリストとピアノのプレイリストを同時に再生
- 📚 **ミュージックライブラリ連携** — iPhone の「ミュージック」から曲を複数選択（デッキごとに独立）
- 🔊 **独立音量調整** — デッキごとにスライダーで音量バランスを調整
- 🔁 **独立リピート** — 「一曲リピート / プレイリストリピート / リピートなし」をデッキごとに選択
- 🌙 **おやすみタイマー** — 15〜90分後にゆっくりフェードアウトして停止
- 🔒 **バックグラウンド再生** — 画面を消しても再生が続き、ロック画面から一時停止/再開が可能

## スクリーンショット

（実機ビルド後に追加予定）

## 必要環境

| 項目 | 要件 |
|---|---|
| Xcode | 16 以降 |
| iOS | 17.0 以降 |
| 実行環境 | **実機必須**（シミュレータにはミュージックライブラリがないため） |

## ビルド方法

1. `Seseragi.xcodeproj` を Xcode で開く
2. TARGETS → Seseragi → Signing & Capabilities で自分の Apple ID の Team を選択
3. 必要なら Bundle Identifier（`com.amacass.seseragi`）を自分のものに変更
4. iPhone を接続して Run

初回起動時にミュージックライブラリへのアクセス許可を求められます。

## ⚠️ 重要な制約: Apple Music のストリーミング曲は再生できません

2曲の同時再生には `AVAudioPlayer` を2基使う必要がありますが、
Apple Music（サブスクリプション）の曲は DRM 保護されており、
システムのミュージックプレイヤー（`MPMusicPlayerController`）でしか再生できません。
そしてシステムプレイヤーは **1アプリにつき1系統しか同時に鳴らせません**。

そのため本アプリで再生できるのは、端末内にある **DRM フリーの曲** です:

- iTunes Store で購入した曲
- CD から取り込んで PC / Mac 経由で同期した曲
- ファイルとして転送した曲

Apple Music のストリーミング曲やそのダウンロードを選んだ場合は、
自動的に除外してお知らせします。詳細は [docs/SPEC.md](docs/SPEC.md) を参照してください。

## ドキュメント

- [仕様書 — docs/SPEC.md](docs/SPEC.md)
- [設計書 — docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## リポジトリ構成

```
seseragi/
├── README.md
├── docs/
│   ├── SPEC.md              # 仕様書（要件・画面仕様・制約）
│   └── ARCHITECTURE.md      # 設計書（構成・クラス責務・再生フロー）
├── Seseragi.xcodeproj/      # Xcode プロジェクト
└── Seseragi/                # ソースコード
    ├── SeseragiApp.swift    # エントリポイント
    ├── Info.plist
    ├── Models/              # RepeatMode などのモデル
    ├── Playback/            # 再生エンジン（DeckPlayer / PlaybackHub / SleepTimer）
    └── Views/               # SwiftUI ビュー
```
