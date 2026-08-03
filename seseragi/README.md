# せせらぎ (Seseragi)

雨音とピアノを、かさねて眠る。
**2つの「流れ」を同時に再生できる iOS デュアル音楽プレイヤー**です。

清流をイメージした深い青緑の画面の上に、2つのデッキ（ながれ A / ながれ B）が並びます。
それぞれのデッキで iPhone のミュージックライブラリから曲を選び、
**別々の音量・別々のリピート設定**で同時に流せます。

## 主な機能

- 🎵 **2デッキ並列再生** — 雨音のプレイリストとピアノのプレイリストを同時に再生
- 📚 **ながれ A：端末ライブラリ連携** — iPhone の「ミュージック」から端末内の曲を複数選択
- 🔎 **ながれ B：Apple Music（MusicKit）** — 自分の**ライブラリ**（プレイリスト・アーティスト・アルバム・曲）の閲覧と、**カタログ全体の検索**の両対応。ライブラリ未追加の曲でもそのまま再生。ストリーミング曲・DRM 曲を含む全曲対応
- 🔊 **音量バランス調整** — ながれ A はアプリ内スライダーで独立調整（ながれ B は本体音量と連動）
- 🔁 **独立リピート** — 「一曲リピート / プレイリストリピート / リピートなし」をデッキごとに選択
- 🌙 **おやすみタイマー** — 15〜90分後に停止（ながれ A はゆっくりフェードアウト）
- 🔒 **バックグラウンド再生** — 画面を消しても両デッキの再生が継続

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
4. **App ID で MusicKit を有効化**（ながれ B のカタログ検索に必須。下記参照）
5. iPhone を接続して Run

初回起動時にミュージックライブラリ／Apple Music へのアクセス許可を求められます。

### MusicKit の有効化（ながれ B に必須）

ながれ B の Apple Music カタログ検索は MusicKit を使うため、
**Apple Developer ポータルでこのアプリの App ID に MusicKit を有効化**する必要があります。

1. [developer.apple.com](https://developer.apple.com/account) → Certificates, IDs & Profiles → **Identifiers**
2. 本アプリの App ID を開き、**App Services** の **MusicKit** にチェックして保存
3. Xcode で再ビルド（プロビジョニングは自動更新）

> ⚠️ MusicKit の利用には **有料の Apple Developer Program 加入** が必要です
> （無料の個人開発アカウントでは MusicKit を有効化できません）。
> また、ストリーミング再生には端末で **Apple Music のサブスクリプション**が有効であることが必要です。
> ながれ A（端末ライブラリ再生）だけなら MusicKit は不要で、無料アカウントでも動きます。

## 2つのデッキの違い（ハイブリッド構成）

DRM 曲を再生できるシステムプレイヤーは1アプリ1系統しか鳴らせないため、
2つのデッキは役割の違うエンジンを使っています。

| | ながれ A（ライブラリ） | ながれ B（ミュージック） |
|---|---|---|
| 選曲 | 端末ライブラリから選ぶ | **カタログ全体を検索** |
| Apple Music・DRM 曲 | ❌ | ✅ すべて再生可能 |
| ライブラリ未追加の曲 | ❌ | ✅（検索して直接再生） |
| アプリ内の独立音量スライダー | ✅ | ❌（本体音量と連動） |
| おやすみタイマーのフェード | ✅ | ❌（停止のみ） |

**おすすめの使い方**: 雨音（購入曲・取り込み曲）を ながれ A に、
Apple Music のピアノを ながれ B に。全体の音量は本体ボタンで、
雨音の混ざり具合は ながれ A のスライダーで調整します。

**ながれ A で「再生できない曲」と出る場合**: iCloud ミュージックライブラリ経由で
実体ファイルが端末にないことがほとんどです。ミュージックアプリで該当曲を
「ダウンロード」すると再生できるようになります。または **ながれ B のカタログ検索**で
同じ曲を探して流せば、ダウンロード不要で再生できます。
詳細は [docs/SPEC.md](docs/SPEC.md) を参照してください。

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
    ├── Models/              # RepeatMode / CatalogTrack などのモデル
    ├── Playback/            # 再生エンジン（DeckControlling / DeckPlayer / MusicDeckPlayer / PlaybackHub / SleepTimer）
    └── Views/               # SwiftUI ビュー（ContentView / DeckView / MediaPickerView / MusicSearchView / WaterBackground）
```
