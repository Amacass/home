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

## ロードマップ（今後）

今回は「ビジュアルのみ」スコープ。将来的には:
- 音楽の再生速度 / フィルター / ループといった簡易リミックス操作
- ビジュアルのプリセット切替・録画書き出し
