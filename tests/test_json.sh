#!/usr/bin/env bash
# JSON correctness: awkward names in schedule/ and out/ (quotes, backslashes,
# control characters, spaces, non-ASCII) must produce one valid document whose
# decoded strings equal the names on disk.
. "$(dirname "$0")/lib.sh"
export TZ=UTC
set_clock "2026-11-15 12:00:00"

new_instance
gh init >/dev/null
out="$T_TMP/json.status"

# Delivery names: everything a POSIX file name may hold except "/" and NUL.
mkdir -p "$GHD/out/plain" \
         "$GHD/out/with space" \
         "$GHD/out/quote\"inside" \
         "$GHD/out/back\\slash" \
         "$GHD/out/$(printf 'tab\there')" \
         "$GHD/out/$(printf 'new\nline')" \
         "$GHD/out/$(printf 'cr\rhere')" \
         "$GHD/out/$(printf 'ctl\001\002\037x')" \
         "$GHD/out/$(printf 'del\177x')" \
         "$GHD/out/caf$(printf '\303\251')" \
         "$GHD/out/$(printf '\346\227\245\346\234\254\350\252\236')" \
         "$GHD/out/$(printf 'emoji\360\237\230\200')" \
         "$GHD/out/ends-with-backslash\\" \
         "$GHD/out/{[(brace)]}\$dollar\`tick" \
         "$GHD/out/-dash" \
         "$GHD/out/.hidden"   # dot names are skipped by the glob, as `out` skips them
age_tree "$INST"
before="$(tree_hash "$INST")"
status_to "$out"
assert_eq "awkward names: tree unchanged" "$before" "$(tree_hash "$INST")"
assert_json_valid "$out"
assert_eq "awkward names: stderr quiet" "" "$(cat "$out.err")"
if jq_py out-names "$out" "$GHD/out"; then t_ok; else t_fail "decoded delivery paths equal the directory entries on disk"; fi
assert_eq "one document, one line" 1 "$(wc -l < "$out" | tr -d ' ')"
assert_eq "no raw control characters in the document" 0 "$(LC_ALL=C tr -d '\n' < "$out" | LC_ALL=C grep -c '[[:cntrl:]]' || true)"

# Schedule names that walk_due fires although the grammar rejects them.
new_instance
gh init >/dev/null
mkdir -p "$GHD/schedule/daily/sp ace" \
         "$GHD/schedule/daily/qu\"ote" \
         "$GHD/schedule/daily/back\\slash" \
         "$GHD/schedule/daily/caf$(printf '\303\251')" \
         "$GHD/schedule/daily/$(printf '\346\227\245\346\234\254')" \
         "$GHD/schedule/daily/09/sp ace in time"
age_tree "$INST"
before="$(tree_hash "$INST")"
status_to "$out"
assert_eq "awkward schedule names: tree unchanged" "$before" "$(tree_hash "$INST")"
assert_json_valid "$out"
assert_eq "all six are listed" 6 "$(jq_py col "$out" schedule path | wc -l | tr -d ' ')"
python3 -I - "$out" "$GHD" <<'PY' && t_ok || t_fail "schedule paths decode to real directories"
import json, os, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
ghd = sys.argv[2]
for rec in doc["schedule"]:
    p = os.path.join(ghd, rec["path"])
    assert os.path.isdir(p), p
    assert rec["item_id"] == os.path.basename(rec["path"]), rec
    assert rec["eligible_now"] is True, rec
PY
# `due` agrees on what would fire.
assert_eq "same six are due" 6 "$(gh due | wc -l | tr -d ' ')"

# A tab or newline in a schedule name splits walk_due's own row (tick has the
# same limit). Status must not invent items from the fragments.
new_instance
gh init >/dev/null
mkdir -p "$GHD/schedule/daily/$(printf 'ok')" "$GHD/schedule/daily/$(printf 'a\tb')" "$GHD/schedule/daily/$(printf 'c\nd')"
status_to "$out"
assert_json_valid "$out"
python3 -I - "$out" "$GHD" <<'PY' && t_ok || t_fail "every listed schedule path is a real directory"
import json, os, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
for rec in doc["schedule"]:
    assert os.path.isdir(os.path.join(sys.argv[2], rec["path"])), rec["path"]
PY

# Many items: the shell implementation stays usable.
new_instance
gh init >/dev/null
i=0
while [ "$i" -lt 150 ]; do
  mkdir -p "$GHD/schedule/daily/item-$i" "$GHD/out/delivered-$i"
  i=$((i + 1))
done
start="$(date +%s)"
status_to "$out"
elapsed=$(( $(date +%s) - start ))
assert_json_valid "$out"
assert_eq "150 items + 150 deliveries listed" "150 150" "$(jq_py col "$out" schedule path | wc -l | tr -d ' ') $(jq_py col "$out" deliveries path | wc -l | tr -d ' ')"
if [ "$elapsed" -le 30 ]; then t_ok; else t_fail "status took ${elapsed}s for 150 items and 150 deliveries"; fi

clear_clock
t_finish
