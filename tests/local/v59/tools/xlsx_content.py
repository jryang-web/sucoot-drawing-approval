import sys, json, re, collections, unicodedata
rows = json.load(open(sys.argv[1]))[1:]
C = collections.Counter
codes = [r[1].get("A") for r in rows]; names = [r[1].get("B") for r in rows]; specs = [r[1].get("C") for r in rows]
def ws(x): return x is not None and x != x.strip()
print("data rows:", len(rows))
for lab, arr in (("code", codes), ("name", names), ("spec", specs)):
    print(f"[{lab}] empty:", sum(1 for x in arr if x is None or x.strip() == ""),
          "lead/trail ws:", sum(1 for x in arr if ws(x)),
          "inner double-space:", sum(1 for x in arr if x and "  " in x.strip()),
          "newline/tab:", sum(1 for x in arr if x and re.search(r"[\r\n\t]", x)),
          "fullwidth space:", sum(1 for x in arr if x and "　" in x),
          "maxlen:", max(len(x.strip()) for x in arr if x))
t = [c.strip() for c in codes]
rule = re.compile(r"^[A-Za-z0-9_./-]{1,30}$")
bad = [c for c in t if not rule.match(c)]
print("codes failing V5.8 rule:", len(bad), "samples:", bad[:15])
badchars = C(ch for c in bad for ch in c if not re.match(r"[A-Za-z0-9_./-]", ch))
print("offending chars:", [(repr(k), unicodedata.name(k, "?"), n) for k, n in badchars.most_common(15)])
print("len>30:", sum(1 for c in t if len(c) > 30))
dup = [k for k, n in C(t).items() if n > 1]
print("exact dup codes (after trim):", len(dup), dup[:10])
ci = [k for k, n in C(c.upper() for c in t).items() if n > 1]
print("case-insensitive dup groups:", len(ci), ci[:10])
print("codes with leading zero:", sum(1 for c in t if c[:1] == "0"), [c for c in t if c[:1] == "0"][:5])
print("all-digit codes:", sum(1 for c in t if c.isdigit()))
print("has lowercase:", sum(1 for c in t if re.search("[a-z]", c)))
print("char classes in codes:", C("".join(sorted(set(re.sub(r"[A-Z0-9]", "", c)))) for c in t).most_common(10))
print("code length dist:", sorted(C(len(c) for c in t).items()))
nm = collections.defaultdict(set)
for c, n, s in zip(t, names, specs): nm[(n or "").strip()].add((s or "").strip())
print("names shared by >1 product:", sum(1 for k, v in nm.items() if len(v) > 1 or False),
      "| same name+same spec, diff code:", sum(1 for k, n in C(((n or "").strip(), (s or "").strip()) for n, s in zip(names, specs)).items() if n > 1))
ex = [(k, sorted(v)[:3]) for k, v in nm.items() if len(v) > 1][:3]
print("same-name-diff-spec examples:", ex)
print("sample rows:", [(t[i], names[i], specs[i]) for i in (0, 1, 2, 3500, 7003)])
