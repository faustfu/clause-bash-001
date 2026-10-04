#!/usr/bin/env bash
# organize_mv.sh — 依番號查詢演員/標題，並依「第一位演員」建立目錄歸檔 (macOS bash 3.2 相容)
# 用法:
#   ./organize_mv.sh lookup  [目錄]   查詢並產生 metadata.tsv（番號<TAB>演員們<TAB>標題）
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
  local code="$1" html title actors
  html=$(curl -fsSL -A "$UA" -H "Cookie: existmag=all" "$BASE/$code" 2>/dev/null) || return 1
  title=$(printf '%s' "$html" | sed -nE 's#.*<title>([^<]*)</title>.*#\1#p' | head -1 \
          | sed -E "s/^$code +//; s/ - JavBus.*//")
  # 演員: <a href=".../star/xxx" title="名字"> ... 取 star-name 區塊
  actors=$(printf '%s' "$html" | grep -oE 'class="star-name"><a href="[^"]*" title="[^"]*"' \
           | sed -E 's/.*title="([^"]*)"/\1/' | paste -sd'、' -)
  [ -z "$actors" ] && actors=$(printf '%s' "$html" | grep -oE '/star/[a-z0-9]+"><img[^>]*title="[^"]*"' \
           | sed -E 's/.*title="([^"]*)"/\1/' | paste -sd'、' -)
  printf '%s\t%s\t%s\n' "$code" "$actors" "$title"
}

case "$MODE" in
lookup)
  : > "$META"
  for f in *; do
    [ -f "$f" ] || continue
    c=$(code_of "$f"); [ -z "$c" ] && continue
    echo "查詢 ${c} ..." >&2
    if ! lookup_one "$c" >> "$META"; then
      printf '%s\t\t\n' "$c" >> "$META"; echo "  失敗: ${c}" >&2
    fi
    sleep 2   # 避免過度請求
  done
  echo "完成，請檢查 ${DIR}/${META} （空白演員欄請手動補上）" >&2
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
      [ -n "$c" ] && awk -F'\t' -v c="$c" '$1==c{printf "番號: %s\n演員: %s\n標題: %s\n",$1,$2,$3}' "$META" > "$actor/${f%.*}.txt"
    else
      echo "[dry-run] $f -> $actor/"
    fi
  done
  [ "${APPLY:-0}" = "1" ] || echo "以上為預覽；確認後以 APPLY=1 執行。" >&2
  ;;
*) sed -n '2,10p' "$0"; exit 1 ;;
esac
