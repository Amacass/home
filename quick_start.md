# クイックスタートガイド

## 1. セットアップ（5分）

```bash
# リポジトリをクローンまたはダウンロード
git clone <このリポジトリ>
cd game-automation-mcp

# 自動インストール
./install.sh
```

## 2. エミュレータ準備（3分）

1. **エミュレータを起動** (BlueStacks/NoxPlayer/LDPlayer等)
2. **開発者オプションを有効化**:
   - 設定 → 端末情報 → ビルド番号を7回タップ
3. **USBデバッグを有効化**:
   - 設定 → 開発者向けオプション → USBデバッグをON
4. **ADB接続確認**:
   ```bash
   adb devices
   ```

## 3. テンプレート画像作成（10分）

```bash
# 1. スクリーンショット撮影
python3 -c "
import asyncio
from mcp_game_automation_server import GameAutomationServer
async def main():
    server = GameAutomationServer()
    server.current_device = 'emulator-5554'  # あなたのデバイスIDに変更
    await server._take_screenshot('game_screen.png')
asyncio.run(main())
"

# 2. テンプレート画像を手動で切り出し
# - game_screen.png を画像編集ソフトで開く
# - ボタンやUIを切り出して templates/ に保存
```

### 推奨テンプレート:
- `quest_button.png` - クエストボタン
- `start_battle_button.png` - バトル開始ボタン  
- `battle_complete.png` - バトル完了画面
- `retry_button.png` - リトライボタン

## 4. 自動周回開始（1分）

```bash
# MCPサーバーを起動
python3 mcp_game_automation_server.py &

# 使用例を実行
python3 example_usage.py

# または直接スクリプト実行
python3 -c "
import asyncio
from example_usage import main
asyncio.run(main())
"
```

## 5. カスタムスクリプト作成

### 簡単な周回スクリプト例:

```json
{
  "name": "Simple Farming",
  "steps": [
    {"action": "tap_image", "params": {"template_path": "templates/quest_button.png"}, "delay": 2},
    {"action": "tap_image", "params": {"template_path": "templates/start_button.png"}, "delay": 3},
    {"action": "wait_for_image", "params": {"template_path": "templates/complete.png", "timeout": 120}},
    {"action": "tap", "params": {"x": 540, "y": 960}, "delay": 2}
  ]
}
```

## トラブルシューティング

### デバイスが見つからない
```bash
adb kill-server
adb start-server
adb devices
```

### 画像認識が失敗する
- 閾値を下げる（0.8 → 0.6）
- テンプレート画像を再作成
- エミュレータの解像度を確認

### スクリプトが止まる
- JSONの構文エラーを確認
- テンプレート画像のパスを確認
- タイムアウト値を増加

## 高度な使用法

### 複数ゲーム対応
```bash
mkdir -p games/game1/templates games/game1/scripts
mkdir -p games/game2/templates games/game2/scripts
```

### バッチ実行
```bash
# 複数スクリプトを順次実行
for script in daily_quest story_farming gacha_farming; do
  python3 example_usage.py --script $script --iterations 5
done
```

これで準備完了です！🎮