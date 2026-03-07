[English](README.md) | 日本語

# Sessylph

<p align="center">
  <img src="images/appicon.png" width="128" height="128" alt="Sessylph icon">
  <br>
  タブ付きターミナル、tmux永続化、デスクトップ通知を備えた <a href="https://docs.anthropic.com/en/docs/claude-code">Claude Code</a> / Codex CLI のネイティブ macOS ラッパー。
</p>

## 特徴

- **タブインターフェース** — 各タブが独立した Claude Code または Codex セッションを実行。macOS ネイティブのウィンドウタブを使用
- **tmux 永続化** — セッションはアプリの再起動後も維持され、スクロールバック履歴付きでシームレスに再接続
- **リモート SSH セッション** — リモートホストに SSH 接続して Claude Code を実行。ディレクトリブラウジングとセッション履歴対応
- **セッション履歴** — Launcher から最近の Claude Code / Codex セッションをそのまま再開可能（リモートの host:directory ペアも含む）
- **デスクトップ通知** — Claude Code の完了通知（ローカルは hook 経由、リモートはタイトルポーリング）や、Codex が user turn に戻った時の通知を表示
- **自動アクティブ化** — タスク完了時にアプリとタブを自動的に前面に表示（設定で切り替え可能）
- **画像ペースト** — Cmd+V でターミナルに直接画像を貼り付け
- **カスタマイズ** — CLI 種別、モデル、承認モード、外観、動作を設定画面から変更可能

## 必要環境

- macOS 15.0 (Sequoia) 以降
- 少なくともどちらか 1 つの CLI がインストール済み:
  [Claude Code](https://docs.anthropic.com/en/docs/claude-code) または Codex CLI
- [tmux](https://github.com/tmux/tmux) がインストール済み

---

## 開発

### アーキテクチャ

```
新しいタブを開く
        ↓
  LauncherView (CLI + ディレクトリ + オプション選択)
        ↓
  TmuxManager.createAndLaunchSession()  ← 単一の tmux 呼び出し
        ↓
  TerminalViewController (GhosttyKit/Metal が tmux に接続)

通知 (ローカル):
  Claude Code hook / Codex notify → sessylph-notifier CLI
        ↓
  DistributedNotificationCenter
        ↓
  NotificationManager → UNUserNotificationCenter

通知 (リモート):
  ClaudeStateTracker が tmux pane title をポーリング (1秒間隔)
        ↓
  working → idle 遷移を検出
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
│   ├── Models/            # Session, LaunchConfig, Claude/Codex オプション + 履歴, RemoteHost
│   ├── Notifications/     # Hook連携 + デスクトップ通知
│   ├── Settings/          # 設定ウィンドウ (NSToolbar + SwiftUI)
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
