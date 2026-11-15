#!/usr/bin/env python3
"""JSON helper for the Groundhog tests (the script under test never uses it).

  jsonq.py valid FILE              exactly one JSON object, one line, final newline
  jsonq.py get FILE PATH           compact JSON at PATH (dotted; digits index arrays),
                                   or the text <missing>
  jsonq.py find FILE ARR KEY VAL   compact JSON of the first ARR element whose KEY == VAL
  jsonq.py col FILE ARR KEY        KEY of every ARR element, one compact JSON per line
  jsonq.py strings FILE ARR KEY    KEY decoded and written raw, NUL-terminated
  jsonq.py dget FILE KEY VAL PATH  compact JSON at the dotted PATH inside the first delivery whose
                                   KEY equals the string VAL, or the text <missing>
  jsonq.py out-names FILE DIR      delivery paths == the entries of DIR (minus *.landing and dotfiles, as `out` lists)
  jsonq.py where FILE ARR KEY JSON OUT
                                   OUT (raw text) of every ARR element whose KEY equals
                                   the JSON value JSON, one per line, sorted
"""
import json
import sys


def load(path):
    with open(path, "rb") as f:
        raw = f.read()
    return json.loads(raw.decode("utf-8", errors="strict"))


def dump(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def main(argv):
    cmd, path = argv[1], argv[2]
    if cmd == "valid":
        with open(path, "rb") as f:
            raw = f.read()
        text = raw.decode("utf-8", errors="strict")
        if not text.endswith("\n") or text.count("\n") != 1:
            print("not exactly one line ending in a newline", file=sys.stderr)
            return 1
        if not isinstance(json.loads(text), dict):
            print("top level is not an object", file=sys.stderr)
            return 1
        return 0
    doc = load(path)
    if cmd == "get":
        cur = doc
        for part in argv[3].split("."):
            try:
                cur = cur[int(part)] if isinstance(cur, list) else cur[part]
            except (KeyError, IndexError, ValueError, TypeError):
                print("<missing>")
                return 0
        print(dump(cur))
        return 0
    if cmd == "find":
        for rec in doc[argv[3]]:
            if rec.get(argv[4]) == argv[5]:
                print(dump(rec))
                return 0
        print("<missing>")
        return 0
    if cmd == "col":
        for rec in doc[argv[3]]:
            print(dump(rec.get(argv[4])))
        return 0
    if cmd == "strings":
        out = sys.stdout.buffer
        for rec in doc[argv[3]]:
            out.write(rec[argv[4]].encode("utf-8") + b"\0")
        return 0
    if cmd == "dget":
        for rec in doc["deliveries"]:
            if rec.get(argv[3]) == argv[4]:
                cur = rec
                for part in argv[5].split("."):
                    try:
                        cur = cur[int(part)] if isinstance(cur, list) else cur[part]
                    except (KeyError, IndexError, ValueError, TypeError):
                        print("<missing>")
                        return 0
                print(dump(cur))
                return 0
        print("<missing>")
        return 0
    if cmd == "out-names":
        import os
        want = {d["path"][len("out/"):] for d in doc["deliveries"]}
        have = {n for n in os.listdir(argv[3]) if not n.endswith(".landing") and not n.startswith(".")}
        if want != have:
            print("status only:", sorted(want - have), "disk only:", sorted(have - want))
            return 1
        return 0
    if cmd == "where":
        want = json.loads(argv[5])
        for line in sorted(rec[argv[6]] for rec in doc[argv[3]] if rec.get(argv[4]) == want):
            print(line)
        return 0
    print("unknown command", cmd, file=sys.stderr)
    return 2


sys.exit(main(sys.argv))
