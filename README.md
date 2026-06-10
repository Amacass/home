# FluidWave 🌊🎵

Macで再生中の音楽に合わせてリアルタイムに動く、GPU流体シミュレーションのネイティブアプリです。

- **音源**: `ScreenCaptureKit` でシステム音声（ミュージックアプリ等）を直接取得 — BlackHole などの仮想オーディオデバイスは不要
- **解析**: `Accelerate (vDSP)` でFFT → 低音 / 中音 / 高音 + ビート検出
- **流体**: Metalコンピュートシェーダーによる Navier-Stokes 流体（stable fluids）
- **連動**: 低音 → 渦・勢い / 高音 → 色 / ビート → 中央からの爆発

> 対応環境: macOS 13.0 以降（システム音声キャプチャに必要）。Apple Silicon / Intel どちらも可。

---

## ビルド方法

このリポジトリには Swift / Metal のソースと、Xcodeプロジェクトを生成するための
[XcodeGen](https://github.com/yonaskolb/XcodeGen) 設定 (`project.yml`) が含まれています。

### 1. XcodeGen を使う（推奨・最短）

```bash
brew install xcodegen   # 未インストールの場合
cd <このリポジトリ>
xcodegen generate       # FluidWave.xcodeproj が生成される
open FluidWave.xcodeproj
```

Xcode で実行（⌘R）するだけです。

### 2. XcodeGen を使わない場合

1. Xcode で新規プロジェクト → **macOS → App**（SwiftUI / Swift）を作成
2. `FluidWave/` 以下のファイルをすべてプロジェクトに追加（`Fluid.metal` 含む）
3. ターゲットの **Deployment Target** を macOS 13.0 に設定
4. **Signing & Capabilities** で署名チームを設定（ローカル実行なら個人のApple IDでOK）

---

## 使い方

1. アプリを起動し、**「開始」** を押す
2. 初回は **画面収録の許可** を求められます
   - システム設定 → プライバシーとセキュリティ → 画面収録 → **FluidWave** を有効化
   - （ScreenCaptureKit はシステム音声の取得に画面収録権限を使います。映像は使いません）
3. ミュージックアプリなどで音楽を再生 → 流体が反応します
4. ウィンドウをクリックすると操作バーを隠せます（フルスクリーン鑑賞向け）

---

## 構成

```
project.yml                         # XcodeGen プロジェクト定義
FluidWave/
├── App.swift                       # @main / アプリ状態(AppModel)
├── ContentView.swift               # UI（開始/停止・ステータス）
├── Audio/
│   ├── AudioCaptureManager.swift   # ScreenCaptureKit でシステム音声を取得
│   └── AudioAnalyzer.swift         # vDSP FFT → 帯域 + ビート検出
├── Render/
│   ├── MetalFluidView.swift        # MTKView の SwiftUI ラッパー
│   ├── FluidRenderer.swift         # 流体ソルバ + 音→力のマッピング
│   └── Shaders/Fluid.metal         # 移流/発散/圧力/勾配/splat/表示
└── Resources/Info.plist
```

---

## 調整したいとき

- **見た目の激しさ**: `FluidRenderer.applyAudioForces` の `strength` / `radius` / ビート閾値
- **色**: `FluidRenderer.spectrumColor`
- **解像度・なめらかさ**: `FluidRenderer` の `simWidth` / `simHeight` / `pressureIterations`
- **反応の機敏さ**: `AudioAnalyzer.analyze` のスムージング係数とビート判定 (`* 1.45`)

## 音→光マッピングの根拠（参考文献）

「曲の表現に合わせた光」のマッピングは、以下の研究に基づいて設計しています。

| 表現 | 根拠 |
|---|---|
| ビートで光が弾ける | **スペクトラルフラックス**によるオンセット検出。Bello et al. (2005) *A Tutorial on Onset Detection in Music Signals*, IEEE TSAP / Dixon (2006) *Onset Detection Revisited*, DAFx。単純な音量変化でなく「楽音のアタック」に反応 |
| 音量→力・明るさ | **Stevensのべき法則** (Stevens 1957, *On the psychophysical law*)。人間の音量知覚は物理量の約0.6乗。体感のラウドネスに比例して動く |
| 低音=画面下 / 高音=画面上 | **音高と垂直方向の共感覚的対応** (Eitan & Granot 2006, *How Music Moves*, Music Perception)。音域レイアウトが聴覚の感覚と一致 |
| 音色が明るいと動きが速い | **スペクトル重心**は音色の「明るさ」の知覚と相関 (Schubert & Wolfe 2006, Acta Acustica) |
| 渦がくっきり残る | **Vorticity Confinement** (Fedkiw, Stam & Jensen 2001, *Visual Simulation of Smoke*, SIGGRAPH)。数値拡散で消える渦を復元 |
| 流体ソルバ本体 | Stam (1999) *Stable Fluids*, SIGGRAPH |

### ネオン表現の仕組み

染料テクスチャはRGB色ではなく「**3種の蛍光ペンキの濃度**」（x=低音・赤 / y=中音・緑 / z=高音・青）を保持。表示時に濃度をべき乗（dominance=3.0）で重み付けし、**局所的に優勢なペンキが色を支配**する合成にすることで、加算混色で白く濁るのを構造的に防いでいます。共通成分の除去＋ピークチャンネルの正規化で常にフル彩度、背景は微小濃度のカットで純黒を維持します。

## ロードマップ（今後）

今回は「ビジュアルのみ」スコープ。将来的には:
- 音楽の再生速度 / フィルター / ループといった簡易リミックス操作
- ビジュアルのプリセット切替・録画書き出し
