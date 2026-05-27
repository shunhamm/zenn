# インクリメンタル検索のデモ
# 起動 → "Go" とタイプして即座に絞り込み → Esc

Output "/Users/shunhamm/private-dir/zenn/images/claude-code-session-browser/search.gif"

Set Shell "zsh"
Set FontSize 16
Set Width 1400
Set Height 800
Set TypingSpeed 80ms
Set Theme "Dracula"

Hide
Type "source /tmp/vhs-cc-sessions.zsh && clear"
Enter
Sleep 1500ms
Show

Type "cc-sessions --demo"
Sleep 500ms
Enter

# 一覧を一瞬見せる
Sleep 1800ms

# "Go" とタイプして絞り込み（title に "Go CLI" を含む1件にヒット）
Type "Go"
Sleep 2500ms

# 絞り込み結果を見せる
Sleep 1500ms

# 別のキーワードに切替: "Tail" → Tailwind Dark mode 設計 にヒット
Backspace 2
Sleep 500ms
Type "Tail"
Sleep 2500ms

# ヒット状態で見せて終わり
Sleep 1500ms

Escape
Sleep 600ms
