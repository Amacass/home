# ソシャゲ自動周回 MCP サーバー

エミュレータ上でのソーシャルゲーム自動周回を支援するModel Context Protocol (MCP)サーバーです。

## 機能

- **デバイス管理**: Android エミュレータの接続・管理
- **画面操作**: タップ・スワイプの自動化
- **画像認識**: OpenCVを使った画面要素の検出
- **スクリプト実行**: JSON形式の周回スクリプトの実行
- **スクリーンショット**: 画面キャプチャとデバッグ支援

## セットアップ

### 1. 依存関係のインストール

```bash
# 自動インストール（推奨）
chmod +x install.sh
./install.sh

# 手動インストール
pip3 install -r requirements.txt

# ADBのインストール（Ubuntu/Debian）
sudo apt-get install android-tools-adb

# ADBのインストール（macOS）
brew install android-platform-tools
```

### 2. エミュレータの準備

1. Android エミュレータを起動（BlueStacks、NoxPlayer、LDPlayer等）
2. エミュレータの設定で「USBデバッグ」を有効化
3. ADB接続を確認: `adb devices`

### 3. MCPサーバーの起動

```bash
python3 mcp_game_automation_server.py
```

## 使用方法

### 基本的なツール

1. **list_devices**: 接続可能なデバイス一覧を表示
2. **connect_device**: 特定のデバイスに接続
3. **take_screenshot**: スクリーンショットを撮影
4. **tap**: 指定座標をタップ
5. **swipe**: スワイプ操作
6. **find_image**: 画像テンプレートを画面上で検索
7. **tap_image**: 画像を見つけてタップ
8. **wait_for_image**: 画像が表示されるまで待機
9. **run_farming_script**: 周回スクリプトを実行

### 周回スクリプトの作成

`farming_scripts/` ディレクトリにJSON形式でスクリプトを作成できます。

#### スクリプト例（daily_quest.json）:

```json
{
  "name": "Daily Quest Farming",
  "description": "デイリークエスト自動周回",
  "iteration_delay": 3,
  "steps": [
    {
      "action": "tap_image",
      "params": {
        "template_path": "templates/quest_button.png"
      },
      "delay": 2
    },
    {
      "action": "wait_for_image",
      "params": {
        "template_path": "templates/battle_complete.png",
        "timeout": 120
      }
    }
  ]
}
```

### テンプレート画像の準備

1. ゲーム画面のボタンやUIをスクリーンショット
2. 画像編集ソフトで必要な部分を切り出し
3. `templates/` ディレクトリに保存

推奨テンプレート画像:
- `quest_button.png` - クエストボタン
- `daily_quest_tab.png` - デイリークエストタブ
- `start_battle_button.png` - バトル開始ボタン
- `battle_complete.png` - バトル完了画面
- `retry_button.png` - リトライボタン
- `close_button.png` - 閉じるボタン

## 利用例

### 1. デバイス接続

```python
# デバイス一覧確認
await mcp_client.call_tool("list_devices", {})

# デバイス接続
await mcp_client.call_tool("connect_device", {
    "device_id": "emulator-5554"
})
```

### 2. 手動操作

```python
# スクリーンショット撮影
await mcp_client.call_tool("take_screenshot", {})

# 座標タップ
await mcp_client.call_tool("tap", {
    "x": 540,
    "y": 960
})

# 画像検索してタップ
await mcp_client.call_tool("tap_image", {
    "template_path": "templates/start_button.png"
})
```

### 3. 自動周回実行

```python
# デイリークエスト周回（10回）
await mcp_client.call_tool("run_farming_script", {
    "script_name": "daily_quest",
    "iterations": 10
})

# ストーリー周回（無限）
await mcp_client.call_tool("run_farming_script", {
    "script_name": "story_farming",
    "iterations": 999
})
```

## トラブルシューティング

### ADB接続エラー
- エミュレータでUSBデバッグが有効になっているか確認
- `adb kill-server && adb start-server` でADBを再起動
- エミュレータを再起動

### 画像認識エラー
- テンプレート画像の解像度がスクリーンショットと一致しているか確認
- 閾値（threshold）を調整（0.6-0.9の範囲で試行）
- エミュレータの表示倍率を100%に設定

### スクリプト実行エラー
- JSONファイルの構文が正しいか確認
- テンプレート画像のパスが正しいか確認
- エミュレータの画面が正しい状態になっているか確認

## 注意事項

- **テスト目的での使用**: このツールはテスト・研究目的で作成されています
- **利用規約**: 実際のゲーム利用時は各ゲームの利用規約を確認してください
- **自己責任**: 自動化ツールの使用は自己責任でお願いします
- **エミュレータ環境**: 実機ではなくエミュレータでの使用を前提としています

## サポート対象エミュレータ

- BlueStacks
- NoxPlayer
- LDPlayer
- MEmu
- Genymotion
- Android Studio AVD

## ライセンス

MIT License - テスト・研究目的での使用に限定