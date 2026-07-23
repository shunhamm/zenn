---
title: "Claude Code が前提ゼロで質問してくるのを hook で止める（AskUserQuestion を block）"
emoji: "✋"
type: "tech"
topics: ["claudecode", "hooks", "cli", "promptengineering"]
published: false
---

## はじめに

Claude Code には `AskUserQuestion` という仕組みがある。作業の途中で判断に迷ったとき、Claude が選択肢つきの質問を出してくれる機能だ。曖昧なまま突き進んで手戻りするより、都度確認してくれるほうがありがたい。自分もこの機能自体は気に入っている。

ただ、使っているうちに困った場面が増えてきた。Claude が裏で調査やサブエージェントを動かした結果として質問を出してくるのに、**その前提（何を調べて、何が分かって、なぜその選択肢になったのか）が共有されないまま選択だけ迫られる**ことがある。

こちらは Claude が裏で進めた作業の中身を見ていない。だから「この選択肢を選ぶと何が起きるのか」が分からず、答えようがない。質問は届いているのに、会話として成立していない。

この記事では、この問題を hook で構造的に止めた話を書く。結論から言うと、`AskUserQuestion` は `PreToolUse` hook で `block` でき、前提の共有が薄い質問を差し戻せる。ネット上には「`AskUserQuestion` は hook で制御できない」という情報もあるが、それは別の話（後述）で、差し戻し目的の block は効く。

## 前提を共有せずに質問してくる、という問題

具体的には、こういう質問が飛んでくる。

```
Q: PR #12345 の対応方針はどうしますか？
  - A案
  - B案
```

`A案` `B案` が何を指すのか、なぜその2つが候補なのか、選ぶと何が変わるのかが本文にない。Claude の頭の中では調査が終わっていて文脈が揃っているが、こちらには共有されていない。いわゆるハイコンテキストな質問だ。

答えるには「A案って何？」と聞き返すことになる。せっかく確認してくれているのに、往復が一回増える。確認の意味が薄れてしまう。

そしてこれは特定の作業に限らない。調べた結果を踏まえた方針の相談でも、実装アプローチの選択でも、問い合わせや障害調査での次の一手でも、設定やインフラ変更の判断でも、同じように起きる。どの場面でも、Claude の中では調査が終わって文脈が揃っているのに、こちらには渡ってこない。

## なぜ「指示」では直らないのか

最初は指示で直そうとした。「質問する前に前提を共有して」という趣旨のルールを、設定ファイルに書いていた。

自分の環境では2箇所にこの手のルールがあった。

- グローバルの `~/.claude/CLAUDE.md`（Claude Code が毎回読む個人設定）
- メモリファイル（過去のやりとりから学習した、背景情報として渡されるもの）

それでも再発した。理由を調べて、二つの穴があると分かった。

一つ目は、**ルールが一番効く場所に無かった**こと。「前提を共有してから聞け」という肝心の一文は、効きの弱いメモリ側にしか書いておらず、Claude が毎回強く参照する `CLAUDE.md` 本文には「選択式で聞け」までしか書いていなかった。

二つ目は、**強制力がゼロ**だったこと。ルールを書いても、守るかどうかは Claude 次第だ。守り忘れても検知する仕組みがない。

指示は「お願い」であって「強制」ではない。ここが本質だった。お願いだけで再発を止めるのは無理がある。

## 方針: 誘導と強制の二層

そこで打ち手を二層に分けた。

- **誘導**: `CLAUDE.md` 本文に「質問の直前に前提を書く」ルールを昇格させる。何を書くべきかを、一番効く場所に明記する。
- **強制**: hook で「前提が書かれていない質問」を機械的に差し戻す。守り忘れを検知する底を作る。

誘導だけだと今までと同じで再発しうる。強制だけだと「何を書けばいいか」が示されない。両方あって初めて機能する。

以下、強制レイヤー（hook）を先に説明する。こちらが本題だ。

## PreToolUse hook で AskUserQuestion を止められるのか

`PreToolUse` は、Claude がツールを実行する直前に発火する hook だ。ここで `block` を返すと、そのツール実行を止められる。

問題は、`AskUserQuestion` がこの hook の対象になるのか、という点だった。調べると、GitHub に [AskUserQuestion Hook Support (#12605)](https://github.com/anthropics/claude-code/issues/12605) という issue があり、そこには「`AskUserQuestion` はインターセプトできない」という記述が見える。

これを読んで一瞬あきらめかけたが、issue の中身をよく読むと、求められているのは別の機能だった。#12605 が「できない」と言っているのは、**hook から質問に自動で回答を返して、CLI の入力待ちをスキップする**機能のことだ。カスタム UI で質問に答えたい、という文脈である。

自分がやりたいのは自動回答ではない。「前提が薄い質問を止めて、Claude に書き直させる」だけだ。これは `PreToolUse` の標準的な `block` の範囲で、issue の制約とは関係ない。

実際、公式の hooks ドキュメントを見ると、`PreToolUse` の matcher に指定できるツール名の一覧に `AskUserQuestion` が含まれている。つまり hook 自体は発火する。あとは block が効くかどうかで、これは後で実証する。

## hook の実装

やることは単純だ。`AskUserQuestion` が呼ばれたとき、「前提がどれだけ共有されているか」を文字数で測り、少なすぎたら block する。前提の量は次の二つを合算して見る。

1. 直前の地の文（Claude が質問の前に書いた説明）の長さ
2. 質問本文と各選択肢の説明の長さ

どちらかが充実していれば通す。両方とも薄いときだけ止める。単純な確認質問まで毎回止められると、それはそれで邪魔だからだ。あくまで「前提ゼロ」の最悪ケースだけを潰す、ゆるいガードにする。

### transcript の構造（text と tool_use は別行）

「直前の地の文」を測るには、会話ログ（transcript）を読む必要がある。`PreToolUse` hook には `transcript_path` が渡されるので、これを開く。

transcript は JSONL 形式で、1行が1つのメッセージに対応する。ここで一つ実測で分かったことがある。Claude のメッセージは、**地の文（text ブロック）とツール呼び出し（tool_use ブロック）が別々の行に書かれる**。

`jq` で構造を覗くと、こうなっている。

```bash
jq -rc 'select(.type=="assistant") | [.message.content[].type]' transcript.jsonl
```

```
["text"]
["tool_use"]   # ← AskUserQuestion はこの行。text は同居しない
```

つまり `AskUserQuestion` を含む行に地の文は入っていない。前提の説明は「直前の別の行」にある。だから判定は「その行の text を見る」ではなく「直近の text 行をまとめて数える」必要がある。ここを勘違いすると、常に「地の文ゼロ」と判定してしまう。

もう一つ、実行時点で直前の text 行が transcript に書き込み済みとは限らない。そこで前述の「質問本文＋選択肢の説明」の長さを併用して、transcript が読めなくても選択肢の説明が厚ければ通るようにしている。

### 判定と fail-open

設計で一番大事にしたのは fail-open だ。つまり、**判定に必要な入力がパースできないなど「判定できない」ときは、必ず通す**。

hook のバグで質問そのものが出せなくなると、確認が必要な場面で Claude が詰む。これは検知漏れよりずっと害が大きい。だから迷ったら通す方に倒す。

hook スクリプトの全文は以下の通り。`jq` に依存している。

```bash:require-context-before-question.sh
#!/bin/bash
# PreToolUse hook: AskUserQuestion を出す前に前提共有があるかを見て、
# 前提ゼロの質問だけを差し戻すゆるいガード。判定不能時は必ず通す(fail-open)。

# 前提共有量の閾値(文字数)。厳しすぎ/ゆるすぎならここを調整する。
THRESHOLD=120

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
if [ "$tool_name" != "AskUserQuestion" ]; then
  echo '{"decision":"approve"}'
  exit 0
fi

# questions が無い/空の呼び出しは判定対象外 → 通す
qcount=$(printf '%s' "$input" | jq -r '(.tool_input.questions // []) | length' 2>/dev/null)
if ! [[ "$qcount" =~ ^[0-9]+$ ]] || [ "$qcount" -eq 0 ]; then
  echo '{"decision":"approve"}'
  exit 0
fi

# (b) 質問本文＋各選択肢説明の情報量。パースできなければ判定不能 → 通す
input_len=$(printf '%s' "$input" \
  | jq -r '[ .tool_input.questions[]? | (.question // ""), ( .options[]?.description // "" ) ] | add // "" | length' 2>/dev/null)
if ! [[ "$input_len" =~ ^[0-9]+$ ]]; then
  echo '{"decision":"approve"}'
  exit 0
fi

# (a) 直近ターンの地の文(transcript 末尾 40 行の assistant text 合計)。読めなければ 0。
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
text_len=0
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  t=$(tail -n 40 "$transcript" 2>/dev/null \
    | jq -rs 'map(select(.type=="assistant") | (.message.content // []) | map(select(.type=="text").text) | add // "") | add // "" | length' 2>/dev/null)
  [[ "$t" =~ ^[0-9]+$ ]] && text_len=$t
fi

total=$((text_len + input_len))

if [ "$total" -lt "$THRESHOLD" ]; then
  reason="AskUserQuestion の前に、ユーザーに見える地の文で次の3点を共有してから質問してください: ①今理解したこと（現状サマリ） ②なぜ聞くのか（背景・調査結果・トレードオフ） ③各選択肢を選ぶと何が起きるか。前提の共有が不足しているため、ユーザーは判断材料を持てません（現在の共有量 約 ${total} 字 / 目安 ${THRESHOLD} 字）。地の文での説明を追加するか、各選択肢の description を充実させてから再度 AskUserQuestion を呼んでください。"
  jq -n --arg r "$reason" '{decision:"block", reason:$r}'
  exit 0
fi

echo '{"decision":"approve"}'
exit 0
```

登録は `~/.claude/settings.json` の `PreToolUse` に matcher `AskUserQuestion` で行う。

```json:~/.claude/settings.json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/require-context-before-question.sh"
          }
        ]
      }
    ]
  }
}
```

## CLAUDE.md 本文への昇格（誘導）

強制の底ができたら、次は「何を書くべきか」を一番効く場所に明記する。`~/.claude/CLAUDE.md` 本文に、質問の直前に書く3点を追記した。

```markdown:~/.claude/CLAUDE.md
## AskUserQuestion の直前に必ず前提を共有する

AskUserQuestion を呼ぶ直前のテキストで、次の3点を必ず共有してから質問する。

1. 今理解したこと(現状のサマリ)
2. なぜ聞くのか(背景・経緯・トレードオフ)
3. 各選択肢を選ぶと何が起きるか
```

hook が止めるのは最悪ケースだけなので、通常運用の質は誘導側が担保する。hook はあくまで底だ。

## block が本当に効くか実証する

ここまで来て、まだ確かめていないことがあった。`decision: block` が本当に `AskUserQuestion` を差し戻すのか、だ。#12605 の「ブロック不可」という言葉が頭に残っていた。

確かめるために、閾値を一時的に極端な値にした。

```bash
THRESHOLD=999999
```

こうすればどんな質問でも `total < THRESHOLD` になり、必ず block されるはずだ。この状態でわざと質問を出してみた。

結果、質問は自分（ユーザー）に届かず、代わりに hook が返した理由が Claude 側にエラーとして返った。

```
AskUserQuestion の前に、ユーザーに見える地の文で次の3点を共有してから質問してください: ...
前提の共有が不足しているため、ユーザーは判断材料を持てません（現在の共有量 約 1471 字 / 目安 999999 字）。
```

`block` は効いた。質問は止まり、Claude は理由を受け取って書き直しに回る。#12605 の「ブロック不可」は、やはり自動回答の話であって、差し戻し目的の block とは別だと確認できた。

確認が終わったら `THRESHOLD` を実運用値（120）に戻す。極大値のまま忘れると、すべての質問が止まってしまうので注意する。

## ハマったところ

実装と実証で引っかかった点をまとめておく。

一つ目は、前述の transcript の構造だ。`AskUserQuestion` の行に地の文が同居していると思い込むと、判定が壊れる。text は別の行にある。

二つ目は、1回の `AskUserQuestion` で hook が複数回呼ばれることだ。デバッグ用のログを仕込んで確認したら、質問を1回出しただけなのに発火が2回記録された。判定を冪等（同じ入力なら同じ結果を返す）にしておけば実害はないが、副作用のある処理を hook に書くときは気をつけたほうがいい。

三つ目は閾値の調整だ。日本語は `jq` の `length` が文字数（コードポイント）で数えるので、体感より少ない字数になる。最初は 200 字にしていたが、選択肢の説明がそこそこ充実した質問まで止まってしまった。120 字まで下げて、前提ゼロだけを止めるバランスに落ち着いた。ここは環境や好みで変えればいい。

## まとめ

`AskUserQuestion` が前提ゼロで飛んでくる問題は、指示だけでは再発した。原因は「ルールが一番効く場所に無い」ことと「強制力がゼロ」なことの二つだった。

対策は誘導と強制の二層にした。誘導は `CLAUDE.md` 本文への昇格、強制は `PreToolUse` hook での差し戻しだ。

`AskUserQuestion` は `PreToolUse` の対象で、`block` で実際に差し戻せる。「hook で制御できない」という情報は自動回答の話であって、差し戻しは問題なくできる。判定は fail-open にして、hook のバグで質問が詰まないようにしておくのが肝心だ。
