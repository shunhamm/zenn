---
title: "Claude Code のセッション、消えてない。全プロジェクト横断ブラウザで一発復帰"
emoji: "🔍"
type: "tech"
topics: ["claudecode", "ai", "zsh", "shell", "tips"]
published: true
publication_name: "pepabo"
---

## あなたも経験したことないですか？

僕はもはや Claude Code に住んでる、と言っても過言ではない働き方をしてます。  
PR レビューも実装も本番DB調査も、ちょっとした壁打ちまで CC に投げてるので、worktree もセッション数も日々増えていきます。

その結果、こうなる。

```text
「あの調査、どのワークツリーでやったっけ？」
「あのセッション引き継ぎたいけど、どのディレクトリで起動したやつかわからん」
```

「確かこのワークツリーだったはず…」と当たりをつけて `/resume`。出てきた履歴を一つずつ開いて、頭の中の記憶と一致するものを探す。  
違ったら別のワークツリーに移動して `/resume`、また履歴を一つずつ開く。

これがけっこう辛い…😭

おまけに、**ターミナルアプリが強制終了されることもある…**。タブをいい感じに配置して、そこにワークツリーやセッションをいい感じに並べて作り上げた作業環境が、まるごと消える。前日まで頭の中にあった「どのタブに何があったか」もろとも吹き飛んで、さらに分からなくなる（cmux 導入で多少マシになった）。

そもそも結局見つからずに諦めるパターンもあって、「あの調査ログどこ行ったんだ」と心の中だけで唸ることになります。

---

もうひとつ、こんなケースもあります。

```text
前日: リポジトリ直下の chef/ で作業してた
翌朝: リポジトリのルートで claude を起動して /resume
      → 一覧に昨日のセッションが出てこない
      → 「え、昨日のどこ行った？」
```

同じワークツリーのつもりでも、`cd` で一段潜って `claude` を起動すると Claude Code は別の場所として扱うので、ルートからの `/resume` には出てきません。起動ディレクトリが違うだけで、ちゃんと残ってます。

---

何度かイラついた末に、zsh の関数を一つ書きました。

ターミナルで `cc-sessions` と打つと、過去のセッションがズラッと一覧で出てきます（裏で **fzf** という対話型の絞り込みツールを使っています）。キーボードでスクロール・その場で絞り込み・右ペインで会話の冒頭プレビュー、目当てのものを選んで Enter で即復帰。

ランチャーやファイラーに近い操作感で、**「セッションが見つからない」問題を一発で解消できます**。

---

## なぜ「消えた」ように見えるのか

Claude Code のセッション（会話履歴）は、起動時のカレントディレクトリを元に以下のパスに保存されます。

```text
~/.claude/projects/<cwd-path>/<session-uuid>.jsonl
```

たとえばこんな感じです。

| 起動したディレクトリ | 保存先 |
|---|---|
| `~/project/api/` | `~/.claude/projects/-Users-me-project-api/` |
| `~/project/api/chef/` | `~/.claude/projects/-Users-me-project-api-chef/` |
| `~/project/api/` (worktree) | `~/.claude/projects/-Users-me-project-api-worktrees-feat-xxx/` |

`/resume`（引数なし）は**現在のディレクトリのセッションしか表示しません**。  
だから、昨日 `chef/` 配下で作業したセッションを今日のルートから `/resume` しても出てこないわけです。

---

## 解決策：全プロジェクト横断セッションブラウザ

`claude --resume <uuid>` はUUIDを直接渡せば、**どのディレクトリから起動しても**復帰できます。  
あとはそのUUIDを探す手段さえあれば勝ちですね。

設計はシンプルです。

| 役割 | 関数 |
|---|---|
| 公開エントリ。fzfで選択 → cd → resume | `cc-sessions` |
| 一覧データを生成（jsonl から ai-title, cwd, 最初のユーザーメッセージ抽出） | `_cc-sessions-list` |

以下を `.zshrc` に追加します（全部折りたたんでます。コピペでOK）。

:::details メイン関数: `cc-sessions`（fzf 起動 → cd → resume）

```zsh
# 全プロジェクトのClaudeセッション横断ブラウザ
# 使い方:
#   cc-sessions [件数(デフォルト50)]
#   cc-sessions -g <pattern>     # 全 jsonl 全文検索してヒットしたものだけ表示
function cc-sessions() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "Error: fzf is required. Install with: brew install fzf" >&2
    return 1
  fi
  local limit=50
  local grep_pattern=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -g|--grep) shift; grep_pattern="${1:-}" ;;
      -h|--help)
        cat <<'EOF'
Usage: cc-sessions [-g <pattern>] [<件数>]
  -g, --grep <pattern>   全セッションを全文検索してヒットしたものだけ表示
  <件数>                 表示件数(デフォルト 50、grep 時は 500)
EOF
        return 0
        ;;
      *) limit="$1" ;;
    esac
    shift
  done

  local list
  if [ -n "$grep_pattern" ]; then
    list=$(_cc-sessions-list 500 "$grep_pattern")
  else
    list=$(_cc-sessions-list "$limit")
  fi
  if [ -z "$list" ]; then
    if [ -n "$grep_pattern" ]; then
      echo "grep \"$grep_pattern\" にヒットするセッションがありません"
    else
      echo "セッションが見つかりません"
    fi
    return 0
  fi

  # fzf の preview 用 Python スクリプトを環境変数で渡す
  export CC_SESSIONS_PREVIEW_PY='
import sys, json, os, re
ANSI_RE = re.compile("\033\\[[0-9;]*m")
def c(text, code):
    return "\033[" + code + "m" + str(text) + "\033[0m"
line = sys.argv[1] if len(sys.argv) > 1 else ""
plain_line = ANSI_RE.sub("", line)
parts = plain_line.split("\t")
if len(parts) < 4:
    print("(invalid line)"); sys.exit(0)
uuid = parts[3].strip()
cwd = parts[4].strip() if len(parts) > 4 else ""
proj_root = os.path.expanduser("~/.claude/projects")
jsonl = None
if os.path.isdir(proj_root):
    for d in os.listdir(proj_root):
        cand = os.path.join(proj_root, d, uuid + ".jsonl")
        if os.path.isfile(cand):
            jsonl = cand; break
if not jsonl:
    print("(jsonl not found: " + uuid + ")"); sys.exit(0)
total_turns, model, first_ts, last_ts, last_type = 0, "", None, None, ""
try:
    with open(jsonl, "rb") as f:
        for raw in f:
            try: j = json.loads(raw)
            except Exception: continue
            t = j.get("type", "")
            if t in ("user", "assistant"):
                total_turns += 1; last_type = t
            if not model:
                m = j.get("message", {}).get("model")
                if m: model = m
            ts = j.get("timestamp")
            if ts:
                if first_ts is None: first_ts = ts
                last_ts = ts
except Exception: pass
def fmt_duration(s):
    if s < 60: return str(int(s)) + "秒"
    if s < 3600: return str(int(s/60)) + "分"
    if s < 86400: return str(int(s/3600)) + "時間"
    return str(int(s/86400)) + "日"
duration = ""
if first_ts and last_ts:
    try:
        from datetime import datetime as DT
        a = DT.fromisoformat(first_ts.replace("Z", "+00:00"))
        b = DT.fromisoformat(last_ts.replace("Z", "+00:00"))
        sec = (b - a).total_seconds()
        if sec > 0: duration = fmt_duration(sec)
    except Exception: pass
home = os.path.expanduser("~")
display_file = jsonl.replace(home, "~")
unanswered = c(" ⏸ 応答待ち", "1;33") if last_type == "user" else ""
print(c("CWD ", "1;36") + ": " + cwd + unanswered)
print(c("FILE", "2") + ": " + c(display_file, "2"))
meta = ["ターン=" + str(total_turns)]
if model: meta.append("モデル=" + model)
if duration: meta.append("会話長=" + duration)
print(c("META", "2") + ": " + c(" / ".join(meta), "2"))
print(c("----", "2"))
TURNS = 10
turns = []
try:
    with open(jsonl, "rb") as f:
        f.seek(0, os.SEEK_END); size = f.tell()
        f.seek(max(0, size - 400_000))
        chunk = f.read().decode("utf-8", errors="ignore")
    lines = chunk.splitlines()
    if size > 400_000 and lines: lines = lines[1:]
    for raw in lines:
        try: j = json.loads(raw)
        except Exception: continue
        t = j.get("type", "")
        if t not in ("user", "assistant"): continue
        content = j.get("message", {}).get("content", "")
        if isinstance(content, list):
            buf = [x.get("text", "") for x in content if isinstance(x, dict) and x.get("type") == "text"]
            content = "\n".join(buf)
        content = str(content).replace("\r", "").strip()
        if not content or content.startswith("<"): continue
        turns.append((t, content))
    for t, content in turns[-TURNS:]:
        prefix = c("[USER]  ", "1;34") if t == "user" else c("[CLAUDE]", "1;32")
        if len(content) > 500: content = content[:500] + "..."
        print(prefix + " " + content); print("")
except Exception as e:
    print("(preview error: " + str(e) + ")")
'

  local fzf_header='検索: project+title  /  Enter: resume  /  Ctrl+F/B: preview scroll'
  [ -n "$grep_pattern" ] && fzf_header="grep: \"$grep_pattern\"  /  $fzf_header"

  local selected
  selected=$(printf '%s\n' "$list" \
    | fzf --ansi --delimiter=$'\t' --with-nth=1,2,3 --nth=2,3 \
          --layout=reverse --gap=1 --wrap \
          --bind='ctrl-f:preview-page-down,ctrl-b:preview-page-up' \
          --preview='python3 -c "$CC_SESSIONS_PREVIEW_PY" {}' \
          --preview-window='right:55%:wrap' \
          --prompt='session > ' --header="$fzf_header")

  unset CC_SESSIONS_PREVIEW_PY

  if [ -z "$selected" ]; then
    echo "キャンセルしました"
    return 0
  fi
  local plain uuid cwd
  plain=$(printf '%s' "$selected" | sed $'s/\x1b\\[[0-9;]*m//g')
  uuid=$(printf '%s' "$plain" | awk -F'\t' '{print $4}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  cwd=$(printf '%s' "$plain" | awk -F'\t' '{print $5}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    cd "$cwd" || return 1
    echo "→ cd $cwd"
  fi
  echo "→ claude --resume $uuid"
  claude --resume "$uuid"
}
```

:::

:::details 一覧データ生成: `_cc-sessions-list`（タイトル抽出・色付け・相対時刻）

```zsh
function _cc-sessions-list() {
  local limit="${1:-50}"
  local pattern="${2:-}"
  local file_list
  file_list=$(find "$HOME/.claude/projects" -maxdepth 2 -name "*.jsonl" -not -path "*/subagents/*" \
    -exec ls -t {} + 2>/dev/null \
    | head -"$limit")
  [ -z "$file_list" ] && return 0
  CC_FILE_LIST="$file_list" CC_GREP_PATTERN="$pattern" python3 -c '
import sys, os, json, time, re, unicodedata, datetime, hashlib

ANSI_RE = re.compile("\033\\[[0-9;]*m")
def c(text, code):
    return "\033[" + code + "m" + str(text) + "\033[0m"
def display_width(s):
    s_plain = ANSI_RE.sub("", s)
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in s_plain)
def pad_to(s, width):
    return s + " " * max(0, width - display_width(s))

PROJECT_COLORS = ["36", "35", "33", "32", "1;36", "1;35", "1;33", "1;32"]
def project_color_code(name):
    h = int(hashlib.md5(name.encode()).hexdigest(), 16) % len(PROJECT_COLORS)
    return PROJECT_COLORS[h]

def relative_time(ts):
    now = datetime.datetime.now()
    dt = datetime.datetime.fromtimestamp(ts)
    s = (now - dt).total_seconds()
    if s < 60: return "たった今"
    if s < 3600: return str(int(s/60)) + "分前"
    if s < 86400: return str(int(s/3600)) + "時間前"
    if s < 7*86400: return str(int(s/86400)) + "日前"
    if dt.year == now.year: return dt.strftime("%m/%d %H:%M")
    return dt.strftime("%Y/%m/%d")

BAD_PREFIXES = ("<", "[Request interrupted", "[Request canceled", "Caveat:")
def clean_first_user(text):
    if not text: return ""
    text = re.sub(r"\s+", " ", text).strip()
    if any(text.startswith(p) for p in BAD_PREFIXES):
        return ""
    return text

def extract(path):
    cwd, ai_title, custom_title, first_user, last_type = "", "", "", "", ""
    try:
        with open(path, "rb") as f:
            head_bytes = f.read(200_000)
        for raw in head_bytes.decode("utf-8", errors="ignore").splitlines():
            try: d = json.loads(raw)
            except Exception: continue
            t = d.get("type", "")
            if not cwd and d.get("cwd"): cwd = d["cwd"]
            if not ai_title and t == "ai-title":
                ai_title = d.get("aiTitle") or d.get("ai_title") or ""
            if not custom_title and t == "custom-title":
                custom_title = d.get("customTitle") or d.get("custom_title") or ""
            if not first_user and t == "user":
                content = d.get("message", {}).get("content", "")
                if isinstance(content, list):
                    content = " ".join(x.get("text", "") for x in content if isinstance(x, dict))
                cleaned = clean_first_user(str(content))
                if cleaned: first_user = cleaned
        if not ai_title and not custom_title:
            try:
                size = os.path.getsize(path)
                if size > 200_000:
                    with open(path, "rb") as f:
                        f.seek(max(0, size - 200_000))
                        tail = f.read().decode("utf-8", errors="ignore").splitlines()
                    for raw in tail:
                        try: d = json.loads(raw)
                        except Exception: continue
                        t = d.get("type", "")
                        if not ai_title and t == "ai-title":
                            ai_title = d.get("aiTitle") or d.get("ai_title") or ""
                        if not custom_title and t == "custom-title":
                            custom_title = d.get("customTitle") or d.get("custom_title") or ""
            except Exception: pass
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as f:
                f.seek(max(0, size - 50_000))
                tail = f.read().decode("utf-8", errors="ignore").splitlines()
            for raw in reversed(tail):
                try: d = json.loads(raw)
                except Exception: continue
                t = d.get("type", "")
                if t in ("user", "assistant"):
                    last_type = t; break
        except Exception: pass
    except Exception: pass
    return cwd, ai_title, custom_title, first_user, last_type

grep_pattern = os.environ.get("CC_GREP_PATTERN", "").lower()
def matches_grep(path, pattern):
    if not pattern: return True
    try:
        with open(path, "rb") as f:
            return pattern in f.read().decode("utf-8", errors="ignore").lower()
    except Exception: return False

home = os.path.expanduser("~")
projects_root = os.path.join(home, ".claude/projects")
for raw_path in os.environ.get("CC_FILE_LIST", "").splitlines():
    path = raw_path.strip()
    if not path: continue
    if not matches_grep(path, grep_pattern): continue
    uuid = os.path.basename(path).rsplit(".jsonl", 1)[0]
    project = path.replace(projects_root + "/", "")
    project = project.rsplit("/", 1)[0]
    # ↓ 自分のパス構成に合わせて調整(後述)
    project = project.replace("-Users-shunhamm-ghq-git-pepabo-com-hosting-", "")
    project = project.replace("-Users-shunhamm-", "")
    if len(project) > 30: project = project[:29] + "…"
    mtime_raw = os.path.getmtime(path)
    age_sec = time.time() - mtime_raw
    mtime_str = relative_time(mtime_raw)
    cwd, ai_title, custom_title, first_user, last_type = extract(path)
    title = custom_title or ai_title or first_user or "(no title)"
    title = title.replace("\t", " ").replace("\n", " ")
    if display_width(title) > 80:
        out = ""
        for ch in title:
            if display_width(out + ch) > 79: break
            out += ch
        title = out + "…"
    if last_type == "user": title = "⏸ " + title

    mtime_padded = pad_to(mtime_str, 11)
    project_padded = pad_to(project, 32)
    is_old = age_sec > 7*86400
    if is_old:
        mtime_out = c(mtime_padded, "2")
        project_out = c(project_padded, "2")
        title_out = c(title, "2")
    else:
        mtime_out = mtime_padded
        project_out = c(project_padded, project_color_code(project))
        title_out = title

    print(mtime_out + "\t" + project_out + "\t" + title_out + "\t" + uuid + "\t" + cwd)
'
}
```

:::

### 自分の環境に合わせるには？

`_cc-sessions-list` の Python 内に、プロジェクト名表示の前置 path を削る `replace` が並んでいます。**自分のパス構成に合わせて書き換えてください**。デフォルトは僕の環境（pepabo）向けです。

```python
# ↓ 自分のパス構成に合わせて調整
project = project.replace("-Users-shunhamm-ghq-git-pepabo-com-hosting-", "")
project = project.replace("-Users-shunhamm-", "")
```

`shunhamm` も自分の username に置き換えてください。

---

## 動作イメージ

ターミナルで `cc-sessions` を叩くと、fzf がこんな2ペイン構成で起動します。

![cc-sessions の起動と一覧スクロール。カーソル移動に合わせて右ペインの preview がリアルタイムに切り替わる](/images/claude-code-session-browser/overview.gif)

ポイントは右ペインの preview。選択中のセッションについて、

- `CWD` 行: どのディレクトリで開かれていたか
- `META` 行: 総ターン数 / 使用モデル / 会話の所要時間
- 直近10ターンのやりとり（`[USER]` / `[CLAUDE]` 交互）

がそのまま見えるので、「これだ」と判別する精度がぐっと上がります。

そのままタイプすると fzf のインクリメンタル検索が効くので、プロジェクト名や主題で一気に絞り込めます。

![インクリメンタル絞り込み。"Go" → "Tail" の順で title マッチさせている](/images/claude-code-session-browser/search.gif)

これを導入してから、もうこれ無しの生活には戻れない体になりました。  
記憶のかけらだけ覚えていれば、ai-title と preview のおかげで目当てがほぼ一発でヒットします。

### 一覧に出てる小ネタ

| 表示 | 意味 |
|---|---|
| `5分前` `1時間前` `3日前` `5/12 10:00` | 相対時刻（7日以内は相対、それ以降は日付） |
| 7日より前の行が薄く（dim） | 古いセッションを視覚的にトーンダウン |
| プロジェクト名の色分け | ハッシュベース、同じプロジェクト名は必ず同じ色 |
| 主題の前に `⏸` | 末尾がユーザー発話で終わってる「未応答セッション」 |

---

## 過去メッセージまで含めて全文検索する

「あの "k8s 移行" の話、どのセッションだっけ…」みたいなとき、`-g` で過去メッセージを含めた全文検索ができます。

```zsh
cc-sessions -g "k8s移行"
cc-sessions --grep "PR #1234"
```

最近 500 セッションの jsonl の中身まで grep して、ヒットしたセッションだけを一覧化します。検索後も普通通り preview で内容確認 → Enter で復帰までの流れは同じ。

![cc-sessions -g "AWS" で全文検索。"Lambda コールドスタート対策" の1件にヒットして preview に内容が出ている](/images/claude-code-session-browser/grep.gif)

---

## ショートカットキーに割り当てると最高

関数名をタイプするのも悪くないですが、**キーバインドにすると一瞬**で呼び出せます。

```zsh
# Ctrl+X Ctrl+R で cc-sessions を起動
function _cc_sessions_widget() {
  cc-sessions
  zle reset-prompt
}
zle -N _cc_sessions_widget
bindkey '^X^R' _cc_sessions_widget
```

`Ctrl+X` → `Ctrl+R` の2キーで fzf が起動します。  
`Ctrl+R`（ヒストリ検索）の隣のキーにしておくと、体が勝手に覚えてくれます。

もちろん好みのキーに変えても OK です。

---

## 前提ツール

| ツール | インストール | 補足 |
|---|---|---|
| fzf | `brew install fzf` | preview ペイン・`--gap`・`--wrap` を使うため **0.51 以降** 推奨 |
| python3 | macOS 標準で入っています | jsonl のパース・タイトル抽出・色付け整形に使用 |

peco 派の人は fzf 部分を peco に差し替えれば一覧は動きますが、preview ペイン・相対時刻整形・色付けは fzf 前提です（peco には preview の概念がない）。

---

## 「導入してみたい」と思った人へ

「面白そうだけど、設定ファイルいじるのめんどくさいな…」と思った人。  
やらなくていいです。

**この記事のURLを Claude Code に貼って「やっといて」と送るだけ**で、`.zshrc` への追記もキーバインド設定も全部やってくれる🪄

僕もこれを書いてる最中、他のブログ記事を読んで「これ導入したい！」と思った瞬間、URLごと CC に雑に投げるのがほぼデフォルトになってます。自分の環境（パス構成や好みのキーバインド）に合わせて書き換えてくれるところまで含めて、勝手にやってくれます。

---

## まとめ

| やりたいこと | コマンド / 機能 |
|---|---|
| 同じディレクトリのセッションを見たい | `claude --resume`（引数なし）でOK |
| 別ディレクトリ・別ワークツリーのセッションを見たい | `cc-sessions` で全プロジェクト横断 |
| 主題ではなく **過去のメッセージ内容** で検索したい | `cc-sessions -g "<キーワード>"` |
| 「これだ」と確信してから復帰したい | preview ペインで CWD / メタ / 直近10ターンを確認 |
| さらに素早く呼び出したい | `Ctrl+X Ctrl+R` などキーバインドに割り当て |

セッションは消えてない。棚が違うだけだった。  
fzf + 一行の preview を挟むだけで、棚から「目当ての一冊」を見つけるストレスがすっと消えます。
