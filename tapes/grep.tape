# 全文 grep モードのデモ
# cc-sessions --demo -g "AWS" でヒット1件 → preview で内容確認 → Esc

Output "/Users/shunhamm/private-dir/zenn/images/claude-code-session-browser/grep.gif"

Set Shell "zsh"
Set FontSize 16
Set Width 1400
Set Height 800
Set TypingSpeed 70ms
Set Theme "Dracula"

Hide
Type "source /tmp/vhs-cc-sessions.zsh && clear"
Enter
Sleep 1500ms
Show

# grep モード起動
Type `cc-sessions --demo -g "AWS"`
Sleep 500ms
Enter

# ヒット結果を見せる
Sleep 2500ms

# preview の中身を読ませる時間
Sleep 2500ms

# preview スクロールを試す
Ctrl+F
Sleep 1200ms

Ctrl+B
Sleep 1200ms

# Esc でキャンセル
Escape
Sleep 800ms
