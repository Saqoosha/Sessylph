[English](README.md) | 日本語

# Sessylph

<p align="center">
  <img src="images/appicon.png" width="128" height="128" alt="Sessylph icon">
  <br>
  タブ付きターミナル、tmux永続化、デスクトップ通知を備えた <a href="https://docs.anthropic.com/en/docs/claude-code">Claude Code</a> のネイティブ macOS ラッパー。
</p>

## 特徴

- **タブインターフェース** — 各タブが独立した Claude Code セッションを実行。macOS ネイティブのウィンドウタブを使用
- **tmux 永続化** — セッションはアプリの再起動後も維持され、スクロールバック履歴付きでシームレスに再接続
- **デスクトップ通知** — Claude Code がタスクを完了したり、応答を待っている時に通知
- **自動アクティブ化** — タスク完了時にアプリとタブを自動的に前面に表示（設定で切り替え可能）
- **画像ペースト** — Cmd+V でターミナルに直接画像を貼り付け
- **カスタマイズ** — モデル、権限モード、外観、動作を設定画面から変更可能

## 必要環境

- macOS 15.0 (Sequoia) 以降
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI がインストール済み
- [tmux](https://github.com/tmux/tmux) がインストール済み

---

## 開発

### アーキテクチャ

```
新しいタブを開く
        ↓
  LauncherView (ディレクトリ + オプション選択)
        ↓
  TmuxManager.createAndLaunchSession()  ← 単一の tmux 呼び出し
        ↓
  TerminalViewController (GhosttyKit/Metal が tmux に接続)

通知:
  Claude Code hook → sessylph-notifier CLI
        ↓
  DistributedNotificationCenter
        ↓
  NotificationManager → UNUserNotificationCenter
```

詳細は [ARCHITECTURE.md](docs/ARCHITECTURE.md) を参照。

### 開発要件

- Xcode 16.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### ソースからビルド

```bash
git clone https://github.com/Saqoosha/Sessylph.git
cd Sessylph
xcodegen generate
xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build

# アプリの出力先:
# build/Build/Products/Debug/Sessylph.app
```

### ビルドコマンド

```bash
xcodegen generate                                                          # Xcode プロジェクト生成
xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build   # デバッグビルド
/usr/bin/python3 scripts/generate_icon.py                                  # アプリアイコン再生成
```

### プロジェクト構成

```
Sources/
├── Sessylph/              # メインアプリ (AppKit + SwiftUI)
│   ├── App/               # AppDelegate, エントリポイント
│   ├── Launcher/          # ディレクトリ選択 + オプション (SwiftUI)
│   ├── Models/            # Session, SessionStore, ClaudeCodeOptions
│   ├── Notifications/     # Hook連携 + デスクトップ通知
│   ├── Settings/          # 設定ウィンドウ (SwiftUI)
│   ├── Tabs/              # TabManager, TabWindowController
│   ├── Terminal/          # GhosttyKit ターミナルビュー (Metal)
│   ├── Tmux/              # tmux セッション管理
│   └── Utilities/         # CLI パス解決, 環境変数, ヘルパー
└── SessylphNotifier/      # バンドル済み CLI (hook → 通知ブリッジ)
```

## 使用ライブラリ

- [GhosttyKit (libghostty)](https://github.com/ghostty-org/ghostty) — Metal GPU レンダリング対応のターミナルエミュレータライブラリ

## ライセンス

MIT
