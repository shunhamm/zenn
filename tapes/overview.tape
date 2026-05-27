# cc-sessions の主要動作デモ
# 起動 → 一覧 → カーソル移動で preview 更新 → Esc でキャンセル

Output "/Users/shunhamm/private-dir/zenn/images/claude-code-session-browser/overview.gif"

Set Shell "zsh"
Set FontSize 16
Set Width 1400
Set Height 800
Set TypingSpeed 70ms
Set Theme "Dracula"

# cc-sessions 系関数を明示ロード（録画には映さない）
Hide
Type "source /tmp/vhs-cc-sessions.zsh && clear"
Enter
Sleep 1500ms
Show

# 起動コマンド
Type "cc-sessions --demo"
Sleep 500ms
Enter

# 一覧表示を見せる
Sleep 2500ms

# 矢印で下に移動して preview 更新を見せる
Down
Sleep 1500ms

Down
Sleep 1500ms

Down
Sleep 1500ms

# さらに下、dim な古いセッションへ
Down
Sleep 1200ms

Down
Sleep 1200ms

# 未応答セッション(⏸) のところで止める
Down
Sleep 2000ms

# Esc でキャンセル
Escape
Sleep 800ms
