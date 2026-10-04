#!/usr/bin/env bash
# organize_mv.sh — 依番號查詢演員/標題，並依「第一位演員」建立目錄歸檔 (macOS bash 3.2 相容)
# 用法:
#   ./organize_mv.sh lookup  [目錄]   查詢並產生 metadata.tsv（番號,演員,標題,說明,關鍵字,標題繁中,說明繁中,關鍵字繁中；TAB 分隔）
#   ./organize_mv.sh translate [目錄] 將標題/說明/關鍵字翻成繁體中文（需 ANTHROPIC_API_KEY；lookup 結束後會自動執行）
#   ./organize_mv.sh move    [目錄]   讀取 metadata.tsv，預設只預覽(dry-run)
#   APPLY=1 ./organize_mv.sh move 目錄 真正搬移
# 注意: lookup 的網頁解析(JavBus)未經測試，網站改版可能失效；可直接手動編輯 metadata.tsv
#       (欄位以 TAB 分隔，演員欄以「、」分隔，第一位為歸檔目錄)。
#       也可改用 JavSP 等現成工具產生同格式 tsv 後再執行 move。
set -u
MODE="${1:-}"; DIR="${2:-.}"
cd "$DIR" || exit 1
META="metadata.tsv"
BASE="https://www.javbus.com"
MODEL="${TRANSLATE_MODEL:-claude-haiku-4-5-20251001}"
API_URL="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 Safari/605.1.15"

sanitize() { printf '%s' "$1" | tr '/:\\' '___' | sed 's/^ *//;s/ *$//'; }

# 影片番號: 開頭英文字母-數字，如 adn-760
code_of() {
  printf '%s' "$1" | sed -nE 's/^([A-Za-z]+-[0-9]+)\..*/\1/p' | tr 'a-z' 'A-Z'
}

# 非 JAV 檔案的規則（演奏者/頻道）
special_actor() {
  case "$1" in
    [Bb][Aa][Nn][Dd][-\ ][Mm][Aa][Ii][Dd]*|*"Band Maid"*|*"BAND-MAID"*|*"Band-Maid"*) echo "BAND-MAID" ;;
    *"THE FIRST TAKE"*) echo "THE FIRST TAKE" ;;
    *) echo "" ;;
  esac
}

lookup_one() {
  local code="$1" html title actors desc kw
  html=$(curl -fsSL -A "$UA" -H "Cookie: existmag=all; age=verified; dv=1" \
         -H "Accept-Language: zh-TW,zh;q=0.9,ja;q=0.8" "${BASE}/${code}" 2>/dev/null) || return 1
  # 年齡驗證頁或非影片頁 -> 視為失敗，不寫入垃圾標題
  case "$html" in *"Age Verification"*|*"age_verification"*|*"driver-verify"*) echo "  被年齡驗證頁擋下: ${code}" >&2; return 1 ;; esac
  title=$(printf '%s' "$html" | sed -nE 's#.*<title>([^<]*)</title>.*#\1#p' | head -1 \
          | sed -E "s/^$code +//; s/ - JavBus.*//")
  # 演員: <a href=".../star/xxx" title="名字"> ... 取 star-name 區塊
  actors=$(printf '%s' "$html" | grep -oE 'class="star-name"><a href="[^"]*" title="[^"]*"' \
           | sed -E 's/.*title="([^"]*)"/\1/' | paste -sd'、' -)
  [ -z "$actors" ] && actors=$(printf '%s' "$html" | grep -oE '/star/[a-z0-9]+"><img[^>]*title="[^"]*"' \
           | sed -E 's/.*title="([^"]*)"/\1/' | paste -sd'、' -)
  # 保底: 找不到演員區塊時，單體作品通常標題最後一個詞就是演員名
  if [ -z "$actors" ]; then
    actors=$(printf '%s' "$title" | awk '{print $NF}')
    echo "  ${code}: 演員區塊解析失敗，暫用標題尾詞「${actors}」，請人工確認" >&2
  fi
  desc=$(printf '%s' "$html" | sed -nE 's#.*<meta name="description" content="([^"]*)".*#\1#p' | head -1)
  kw=$(printf '%s' "$html" | sed -nE 's#.*<meta name="keywords" content="([^"]*)".*#\1#p' | head -1)
  printf '%s\t%s\t%s\t%s\t%s\t\t\t\n' "$code" "$actors" "$title" "$desc" "$kw"
}

# 以 Anthropic Messages API 批次翻譯 tsv 第 3~5 欄 -> 第 6~8 欄（已翻過的列會跳過）
translate_meta() {
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "未設定 ANTHROPIC_API_KEY，略過翻譯（export ANTHROPIC_API_KEY=... 後執行 translate）" >&2; return 0
  fi
  command -v python3 >/dev/null 2>&1 || { echo "找不到 python3（macOS 可執行 xcode-select --install）" >&2; return 1; }
  python3 - "$META" "$MODEL" "$API_URL" <<'PY'
import sys, json, re, time, os, urllib.request, urllib.error
meta, model, base = sys.argv[1:4]
rows = [l.rstrip("\n").split("\t") for l in open(meta, encoding="utf-8")]
rows = [r + [""] * (8 - len(r)) for r in rows]
todo = [i for i, r in enumerate(rows) if r[2].strip() and not r[5].strip()]
print(f"待翻譯 {len(todo)} 筆", file=sys.stderr)
SYS = ("你是影片資料翻譯員。把日文/英文的影片標題、內容說明、關鍵字翻譯成自然的繁體中文（台灣用語）。"
       "人名、演員名、番號、作品系列名保留原文；已是中文者轉為繁體。只輸出 JSON 陣列，"
       '每個元素格式 {"id":編號,"title":"…","desc":"…","kw":"…"}，不得加任何其他文字。')
def call(batch):
    items = [{"id": i, "title": rows[i][2], "desc": rows[i][3], "kw": rows[i][4]} for i in batch]
    body = json.dumps({"model": model, "max_tokens": 4096, "system": SYS,
        "messages": [{"role": "user", "content": json.dumps(items, ensure_ascii=False)}]}).encode()
    req = urllib.request.Request(base.rstrip("/") + "/v1/messages", data=body, headers={
        "x-api-key": os.environ["ANTHROPIC_API_KEY"], "anthropic-version": "2023-06-01",
        "content-type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                txt = "".join(b.get("text", "") for b in json.load(r)["content"])
            txt = re.sub(r"^```(?:json)?\s*|\s*```$", "", txt.strip())
            return json.loads(txt)
        except (urllib.error.URLError, ValueError, KeyError) as e:
            print(f"  批次失敗({attempt+1}/3): {e}", file=sys.stderr); time.sleep(2 * (attempt + 1))
    return []
clean = lambda v: str(v).replace("\t", " ").replace("\n", " ")
for k in range(0, len(todo), 10):
    batch = todo[k:k + 10]
    for it in call(batch):
        i = it.get("id")
        if i in batch:
            rows[i][5], rows[i][6], rows[i][7] = clean(it.get("title", "")), clean(it.get("desc", "")), clean(it.get("kw", ""))
    print(f"  已處理 {min(k + 10, len(todo))}/{len(todo)}", file=sys.stderr)
    with open(meta, "w", encoding="utf-8") as f:   # 每批都存檔，可中斷續跑
        f.write("".join("\t".join(r) + "\n" for r in rows))
PY
}

case "$MODE" in
lookup)
  : > "$META"
  for f in *; do
    [ -f "$f" ] || continue
    c=$(code_of "$f"); [ -z "$c" ] && continue
    echo "查詢 ${c} ..." >&2
    if ! lookup_one "$c" >> "$META"; then
      printf '%s\t\t\t\t\t\t\t\n' "$c" >> "$META"; echo "  失敗: ${c}" >&2
    fi
    sleep 2   # 避免過度請求
  done
  translate_meta
  echo "完成，請檢查 ${DIR}/${META} （空白演員欄請手動補上）" >&2
  ;;
translate)
  translate_meta
  ;;
move)
  for f in *; do
    [ -f "$f" ] || continue
    case "$f" in metadata.tsv|*.sh) continue ;; esac
    actor=$(special_actor "$f")
    if [ -z "$actor" ]; then
      c=$(code_of "$f")
      [ -n "$c" ] && actor=$(awk -F'\t' -v c="$c" '$1==c{print $2; exit}' "$META" 2>/dev/null | awk -F'、' '{print $1}')
    fi
    [ -z "$actor" ] && actor="_未知演員"
    actor=$(sanitize "$actor")
    # 同一影片的附屬檔（.webp/.srt 等）因檔名相同開頭也會各自處理
    if [ "${APPLY:-0}" = "1" ]; then
      mkdir -p "$actor" && mv -n "$f" "$actor/"
      # 存放說明文字
      c=$(code_of "$f")
      [ -n "$c" ] && awk -F'\t' -v c="$c" '$1==c{printf "番號: %s\n演員: %s\n標題: %s\n原標題: %s\n說明: %s\n關鍵字: %s\n",$1,$2,($6!=""?$6:$3),$3,($7!=""?$7:$4),($8!=""?$8:$5)}' "$META" > "$actor/${f%.*}.txt"
    else
      echo "[dry-run] $f -> $actor/"
    fi
  done
  [ "${APPLY:-0}" = "1" ] || echo "以上為預覽；確認後以 APPLY=1 執行。" >&2
  ;;
*) sed -n '2,10p' "$0"; exit 1 ;;
esac
