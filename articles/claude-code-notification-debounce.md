---
title: "Claude Code の通知フックが重複発火する問題と対策"
emoji: "🔔"
type: "tech"
topics: ["claudecode", "cli", "notification", "wsl"]
published: false
---

## はじめに

Claude Code には hooks という仕組みがあり、特定のイベント発生時に任意のコマンドを実行できる。自分の環境では、作業完了や入力待ちのタイミングでローカルの音声通知とスマホへの webhook 通知を飛ばすように設定していた。

ところが、使っているうちに通知音が何度も重複して鳴る現象に気づいた。作業完了時に完了音だけでなく指示待ちの音まで鳴ったり、指示待ち通知が短時間に何回も繰り返されたりする。この記事では、原因の調査と対策について書く。

## 環境

- WSL2 (Ubuntu) 上で Claude Code を利用
- ローカル通知: WSL から PowerShell を呼び出して WAV 再生 + バルーン通知
- リモート通知: getmoshi の webhook API でスマホにプッシュ通知

## 通知の構成

`~/.claude/settings.json` で以下のように hooks を設定していた。

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/notify.sh 'Claude Code' '入力待ち: 確認が必要です' attention",
            "timeout": 10
          },
          {
            "type": "command",
            "command": "curl -s -X POST https://api.getmoshi.app/api/webhook -H 'Content-Type: application/json' -d '{\"token\":\"YOUR_TOKEN\",\"title\":\"Claude Code\",\"message\":\"入力待ち: 確認が必要です\"}'",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/notify.sh 'Claude Code' '作業完了: 応答が完了しました' complete",
            "timeout": 10
          },
          {
            "type": "command",
            "command": "curl -s -X POST https://api.getmoshi.app/api/webhook -H 'Content-Type: application/json' -d '{\"token\":\"YOUR_TOKEN\",\"title\":\"Claude Code\",\"message\":\"作業完了: 応答が完了しました\"}'",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

- **Stop**: Claude が応答を完了したときに発火する。完了音（`complete.wav`）を再生。
- **Notification** (`idle_prompt`): Claude が入力待ちになったときに発火する。注意音（`attention.wav`）を再生。

各イベントに対して、ローカル通知（`notify.sh`）と webhook（`curl`）の2つのコマンドを登録している。ローカルの音で気づけるようにしつつ、離席時にもスマホで気づけるようにするための構成で、これ自体は意図的なもの。

`notify.sh` の中身は以下の通り。WSL から Windows の PowerShell を呼び出して WAV ファイルを再生し、バルーン通知を表示する。

```bash
#!/bin/bash
TITLE="${1:-Claude Code}"
MESSAGE="${2:-通知}"
SOUND_TYPE="${3:-complete}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOUND_FILE="$SCRIPT_DIR/sounds/${SOUND_TYPE}.wav"
WIN_SOUND_PATH=$(wslpath -w "$SOUND_FILE")

/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command "
(New-Object System.Media.SoundPlayer '$WIN_SOUND_PATH').PlaySync()
Add-Type -AssemblyName System.Windows.Forms
\$balloon = New-Object System.Windows.Forms.NotifyIcon
\$balloon.Icon = [System.Drawing.SystemIcons]::Information
\$balloon.BalloonTipTitle = '$TITLE'
\$balloon.BalloonTipText = '$MESSAGE'
\$balloon.Visible = \$true
\$balloon.ShowBalloonTip(5000)
Start-Sleep -Seconds 2
\$balloon.Dispose()
" &
```

## 発生していた問題

1. **作業完了時に2種類の音が鳴る**: Stop フック（完了音）の直後に Notification の `idle_prompt`（指示待ち音）も発火して、完了音と注意音が立て続けに鳴る。
2. **指示待ち通知が何度も繰り返し鳴る**: `idle_prompt` が短時間に複数回発火して、同じ通知音が連続で再生される。

## 原因の調査

Claude Code の hooks の挙動を調べた結果、以下のことがわかった。

### Stop と idle_prompt の連続発火

Claude が応答を完了すると、まず `Stop` イベントが発火する。その直後に `Notification` の `idle_prompt` も発火する。Claude としては「応答が終わった = 入力待ち状態になった」という扱いなので、両方が発火するのは仕様通りの動作と言える。

しかし、通知の観点からすると「作業完了」と「入力待ち」は同じタイミングで鳴る必要がない。完了音が鳴れば、入力待ちであることは自明だからだ。

### idle_prompt の複数回発火

`idle_prompt` は Claude が応答を返すたびに発火する。GitHub Issues でも報告されている既知の挙動で（[#12048](https://github.com/anthropics/claude-code/issues/12048) など）、短い応答が連続するようなケースでは同じ通知が短時間に何回も鳴ることになる。

### デバウンス機構の欠如

`notify.sh` は呼ばれるたびに無条件で音声を再生していた。バックグラウンド実行（`&`）しているため、前の通知の完了を待たずに次の通知が走る。Claude Code の hooks 自体にもデバウンスやクールダウンの仕組みはない。

## 対策: デバウンスの導入

通知スクリプト側にタイムスタンプベースのデバウンスを入れることにした。仕組みは単純で、前回の通知時刻をファイルに記録しておき、一定時間（5秒）以内の再実行はスキップする。

### notify.sh の修正

`/tmp/claude_notify_last` にタイムスタンプを記録し、5秒以内の再実行をスキップするガード処理を追加した。

```bash
#!/bin/bash
TITLE="${1:-Claude Code}"
MESSAGE="${2:-通知}"
SOUND_TYPE="${3:-complete}"

# デバウンス: 前回通知から5秒以内ならスキップ
LOCK_FILE="/tmp/claude_notify_last"
NOW=$(date +%s)
if [ -f "$LOCK_FILE" ]; then
    LAST=$(cat "$LOCK_FILE")
    DIFF=$((NOW - LAST))
    if [ "$DIFF" -lt 5 ]; then
        exit 0
    fi
fi
echo "$NOW" > "$LOCK_FILE"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOUND_FILE="$SCRIPT_DIR/sounds/${SOUND_TYPE}.wav"
WIN_SOUND_PATH=$(wslpath -w "$SOUND_FILE")

/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command "
(New-Object System.Media.SoundPlayer '$WIN_SOUND_PATH').PlaySync()
Add-Type -AssemblyName System.Windows.Forms
\$balloon = New-Object System.Windows.Forms.NotifyIcon
\$balloon.Icon = [System.Drawing.SystemIcons]::Information
\$balloon.BalloonTipTitle = '$TITLE'
\$balloon.BalloonTipText = '$MESSAGE'
\$balloon.Visible = \$true
\$balloon.ShowBalloonTip(5000)
Start-Sleep -Seconds 2
\$balloon.Dispose()
" &
```

### webhook.sh の新規作成

webhook 側も同様にデバウンスを入れるため、`curl` を直接 `settings.json` に書くのではなく、ラッパースクリプト `webhook.sh` を経由するように変更した。

```bash
#!/bin/bash
TOKEN="$1"
TITLE="$2"
MESSAGE="$3"

# デバウンス: 前回webhook送信から5秒以内ならスキップ
LOCK_FILE="/tmp/claude_webhook_last"
NOW=$(date +%s)
if [ -f "$LOCK_FILE" ]; then
    LAST=$(cat "$LOCK_FILE")
    DIFF=$((NOW - LAST))
    if [ "$DIFF" -lt 5 ]; then
        exit 0
    fi
fi
echo "$NOW" > "$LOCK_FILE"

curl -s -X POST https://api.getmoshi.app/api/webhook \
  -H 'Content-Type: application/json' \
  -d "{\"token\":\"$TOKEN\",\"title\":\"$TITLE\",\"message\":\"$MESSAGE\"}"
```

### ロックファイルを分離した理由

当初は `notify.sh` と `webhook.sh` で同じロックファイルを共有することを考えた。しかし、`Stop` イベント内の2つのフック（`notify.sh` と `webhook.sh`）はほぼ同時に実行されるため、`notify.sh` がタイムスタンプを書き込んだ直後に `webhook.sh` がそれを読んでスキップしてしまう可能性がある。

そのため、ロックファイルを分離した。

- ローカル通知: `/tmp/claude_notify_last`
- webhook: `/tmp/claude_webhook_last`

こうすることで、同一イベント内のローカル通知と webhook は両方とも実行される。一方、直後に `idle_prompt` が発火した場合は、両方のスクリプトがそれぞれ自分のロックファイルを参照して5秒以内と判定し、スキップされる。

### settings.json の修正

`curl` の直接呼び出しを `webhook.sh` 経由に変更した。

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/notify.sh 'Claude Code' '入力待ち: 確認が必要です' attention",
            "timeout": 10
          },
          {
            "type": "command",
            "command": "bash ~/.claude/webhook.sh 'YOUR_TOKEN' 'Claude Code' '入力待ち: 確認が必要です'",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/notify.sh 'Claude Code' '作業完了: 応答が完了しました' complete",
            "timeout": 10
          },
          {
            "type": "command",
            "command": "bash ~/.claude/webhook.sh 'YOUR_TOKEN' 'Claude Code' '作業完了: 応答が完了しました'",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

## 修正後の動作

修正後の通知フローは以下のようになる。

1. Claude が応答完了 → **Stop** フック発火
   - `notify.sh`: タイムスタンプを記録、完了音を再生
   - `webhook.sh`: タイムスタンプを記録、webhook を送信
2. 直後に **Notification** (`idle_prompt`) 発火
   - `notify.sh`: 前回から5秒以内 → スキップ
   - `webhook.sh`: 前回から5秒以内 → スキップ
3. `idle_prompt` がさらに発火しても、5秒以内であればすべてスキップ
4. 5秒以上経過後に `idle_prompt` が発火した場合は通常通り通知される

## まとめ

Claude Code の hooks にはデバウンスの仕組みがないため、`Stop` と `idle_prompt` の連続発火で通知が重複する。通知スクリプト側にタイムスタンプファイルを使ったデバウンスを入れることで、同じ通知が短時間に何度も鳴る問題を解消できた。

デバウンスの閾値は現在5秒にしているが、各スクリプト内の `if [ "$DIFF" -lt 5 ]` の数値を変えれば調整できる。
