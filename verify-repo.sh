#!/usr/bin/env bash
# prompt-refiner 저장소 검증
#
# 사용법 — 저장소 폴더 안에서:
#   bash verify-repo.sh
#
# 확인하는 것: ① 원격에 실제로 올라갔는가 ② 파일 내용이 원본과 같은가
#              ③ 플러그인 규격이 맞는가 ④ 스킬 핵심 규칙이 살아 있는가

set -uo pipefail
PASS=0; FAIL=0; WARN=0
ok(){   printf '  \033[32m OK \033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ng(){   printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
wn(){   printf '  \033[33mWARN\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
sec(){  printf '\n\033[1m%s\033[0m\n' "$1"; }

[ -d .git ] || { echo "여기는 git 저장소가 아닙니다. 저장소 폴더에서 실행하세요."; exit 1; }

# ─────────────────────────────────────────────
sec "1. 원격에 올라갔는가"

REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
if [ -z "$REMOTE" ]; then
  ng "origin remote가 없습니다"
else
  ok "origin = $REMOTE"
fi

if git ls-remote --exit-code origin >/dev/null 2>&1; then
  ok "원격 접근 가능 (인증 정상)"
  RHEAD=$(git ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
  LHEAD=$(git rev-parse HEAD 2>/dev/null)
  if [ -z "$RHEAD" ]; then
    ng "원격에 main 브랜치가 없습니다 — push가 아직 안 됐습니다"
    echo "       → git push -u origin main"
  elif [ "$RHEAD" = "$LHEAD" ]; then
    ok "원격 main = 로컬 HEAD (${LHEAD:0:8}) — 올라간 내용이 지금 이 폴더와 같습니다"
  else
    wn "원격 main(${RHEAD:0:8}) 과 로컬 HEAD(${LHEAD:0:8}) 가 다릅니다"
    echo "       → git status / git log --oneline origin/main..HEAD 로 확인"
  fi
else
  ng "원격에 접근할 수 없습니다 — 저장소 이름이 틀렸거나 인증이 안 됐습니다"
  echo "       → gh auth status  로 계정 확인"
  echo "       → gh repo list KimSeol-KR --limit 30  으로 실제 이름 확인"
fi

case "$REMOTE" in
  *prompt-refiner_SKILL*) ok "remote가 새 저장소 이름을 가리킵니다" ;;
  *prompt_-correction_SKILL*|*claude-skills*)
    wn "remote가 옛 이름입니다 — GitHub이 리다이렉트해주지만 명시적으로 바꾸는 게 안전합니다"
    echo "       → git remote set-url origin https://github.com/KimSeol-KR/prompt-refiner_SKILL.git" ;;
  "") ;;
  *) wn "remote 주소를 확인하세요: $REMOTE" ;;
esac

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  wn "커밋 안 된 변경이 있습니다 (아래 목록이 원격에는 없습니다)"
  git status --porcelain | sed 's/^/       /'
else
  ok "작업 트리 깨끗함"
fi

# ─────────────────────────────────────────────
sec "2. 파일 내용이 원본과 같은가"

# 형식: <sha256 앞16자>  <경로>
EXPECTED="
61929c176f3aee60  .claude-plugin/marketplace.json
0cf801cd16e807f9  .gitignore
750f34a35038c3b8  CHANGELOG.md
61fe4ef54d42bd44  LICENSE
12e37233eddddf3c  README.md
ba016e1c04c67ace  plugins/prompt-refiner/.claude-plugin/plugin.json
5f83e7383d801506  plugins/prompt-refiner/skills/prompt-refiner/SKILL.md
c629988aca9035ff  plugins/prompt-refiner/skills/prompt-refiner/references/defaults.md
0b420bf659d8c2df  plugins/prompt-refiner/skills/prompt-refiner/references/examples.md
b91186077e954435  plugins/prompt-refiner/skills/prompt-refiner/references/gap-types.md
"

hash_of(){ shasum -a 256 "$1" 2>/dev/null | cut -c1-16; }

while read -r want path; do
  [ -z "${path:-}" ] && continue
  if [ ! -f "$path" ]; then
    ng "없음: $path"
  else
    got=$(hash_of "$path")
    if [ "$got" = "$want" ]; then ok "$path"
    else ng "$path — 내용이 다릅니다 (기대 $want / 실제 $got)"; fi
  fi
done <<< "$EXPECTED"

[ -f dist/prompt-refiner.zip ] && ok "dist/prompt-refiner.zip 있음 (claude.ai 업로드용)" \
                               || wn "dist/prompt-refiner.zip 없음 — claude.ai 업로드 경로가 빠집니다"

# 예상에 없는 파일이 섞였는지
EXTRA=$(git ls-files | grep -v -e '^\.claude-plugin/' -e '^plugins/' -e '^dist/' \
        -e '^README\.md$' -e '^CHANGELOG\.md$' -e '^LICENSE$' -e '^\.gitignore$' || true)
[ -z "$EXTRA" ] && ok "예상 밖 파일 없음" || wn "예상에 없던 파일: $(echo "$EXTRA" | tr '\n' ' ')"

# ─────────────────────────────────────────────
sec "3. 플러그인 규격"

if command -v python3 >/dev/null 2>&1; then
python3 - <<'PYEOF'
import json, sys, os
def r(p):
    try: return json.load(open(p, encoding="utf-8"))
    except Exception as e: print(f"  \033[31mFAIL\033[0m {p} — JSON 오류: {e}"); return None

m = r(".claude-plugin/marketplace.json")
if m:
    need = ["name","owner","plugins"]
    miss = [k for k in need if k not in m]
    if miss: print(f"  \033[31mFAIL\033[0m marketplace.json 필수 항목 없음: {miss}")
    else:    print(f"  \033[32m OK \033[0m marketplace 이름 = {m['name']}")
    for pl in m.get("plugins", []):
        src = pl.get("source","")
        d = src.lstrip("./")
        if os.path.isdir(d): print(f"  \033[32m OK \033[0m 플러그인 경로 존재: {src}")
        else:                print(f"  \033[31mFAIL\033[0m 플러그인 경로 없음: {src}")

p = r("plugins/prompt-refiner/.claude-plugin/plugin.json")
if p:
    need = ["name","description","version","author"]
    miss = [k for k in need if k not in p]
    if miss: print(f"  \033[31mFAIL\033[0m plugin.json 필수 항목 없음: {miss}")
    else:    print(f"  \033[32m OK \033[0m 플러그인 {p['name']} v{p['version']}")

s = "plugins/prompt-refiner/skills/prompt-refiner/SKILL.md"
if os.path.isfile(s):
    t = open(s, encoding="utf-8").read()
    if t.startswith("---") and "name:" in t.split("---")[1] and "description:" in t.split("---")[1]:
        print("  \033[32m OK \033[0m SKILL.md frontmatter 정상")
    else:
        print("  \033[31mFAIL\033[0m SKILL.md frontmatter 문제")
PYEOF
else
  wn "python3 없음 — 규격 검사 건너뜀"
fi

# ─────────────────────────────────────────────
sec "4. 스킬 핵심 규칙이 살아 있는가"

S="plugins/prompt-refiner/skills/prompt-refiner/SKILL.md"
D="plugins/prompt-refiner/skills/prompt-refiner/references/defaults.md"
chk(){ grep -qF "$2" "$1" 2>/dev/null && ok "$3" || ng "$3 — 문구가 없습니다"; }

chk "$S" "이 스킬이 하지 않는 일"        "경계 선언 절"
chk "$S" "안전장치가 아니다"             "안전장치 아님 명시"
chk "$S" "0단계"                        "0단계(먼저 찾기)"
chk "$S" "연결된 도구에 이미 있는지"      "커넥터 탐색"
chk "$S" "그냥 진행"                     "탈출구"
chk "$S" "최대 2개"                      "질문 상한"
chk "$D" "기본값이 아니라 훈수다"         "기본값 근거 규칙"

# 커밋에 Claude 귀속이 남아 있는지
if git log --all --format='%B' | grep -qiE '^(co-authored-by|claude-session)'; then
  ng "커밋 메시지에 Claude 귀속 트레일러가 남아 있습니다"
  echo "       → git commit --amend  로 해당 줄 삭제 (푸시했으면 --force-with-lease)"
else
  ok "커밋에 Claude 귀속 없음"
fi
AUTHORS=$(git log --all --format='%an <%ae>|%cn <%ce>' | tr '|' '\n' | sort -u)
if echo "$AUTHORS" | grep -qi 'claude\|anthropic'; then
  ng "커밋 author/committer에 Claude가 있습니다: $(echo "$AUTHORS" | tr '\n' ' ')"
else
  ok "author/committer 정상: $(echo "$AUTHORS" | tr '\n' ' ')"
fi

# 되돌린 규칙이 되살아나지 않았는지
if grep -qF "새 산출물의 첫 줄" "$S" 2>/dev/null; then
  ng "되돌린 A-6 규칙이 다시 들어와 있습니다 (범위 밖)"
else
  ok "되돌린 A-6 규칙 없음"
fi

# ─────────────────────────────────────────────
printf '\n\033[1m결과\033[0m  통과 %d · 경고 %d · 실패 %d\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf '\n저장소 상태 정상입니다. 설치해서 확인해보세요:\n'
  printf '  claude plugin marketplace add %s\n' "$(git remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')"
  printf '  claude plugin install prompt-refiner@kimseol-skills\n'
  exit 0
else
  printf '\n위 FAIL 항목부터 해결하세요.\n'
  exit 1
fi
