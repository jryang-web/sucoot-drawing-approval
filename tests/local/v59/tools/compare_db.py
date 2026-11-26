"""逐筆比對：資料庫產品主檔 vs Excel 原始 XML 文字（編碼完全相同；品名、規格僅去除前後空白）。"""
import sys, json
excel = json.load(open(sys.argv[1]))[1:]
db = {r["code"]: r for r in json.load(open(sys.argv[2]))}
expected = {(v.get("A") or "").strip(): ((v.get("B") or "").strip(), (v.get("C") or "").strip()) for _, v, _ in excel}
missing = [c for c in expected if c not in db]
extra = [c for c in db if c not in expected]
diff = [(c, expected[c], (db[c]["name"], db[c]["spec"])) for c in expected if c in db and expected[c] != (db[c]["name"], db[c]["spec"])]
inactive = [c for c in expected if c in db and not db[c]["is_active"]]
bad_chars = [c for c, r in db.items() if "�" in r["name"] + r["spec"] + c]
code_exact = sum(1 for _, v, _ in excel if (v.get("A") or "") in db)
print(f"Excel 列數 {len(excel)}｜資料庫產品 {len(db)}")
print(f"缺少 {len(missing)}｜多出 {len(extra)}｜品名/規格不符 {len(diff)}｜未啟用 {len(inactive)}｜含亂碼 {len(bad_chars)}")
print(f"編碼與 Excel 原文完全相同（未經任何清理）：{code_exact}/{len(excel)}")
for d in diff[:5]: print("  不符:", d)
sys.exit(0 if not (missing or extra or diff or inactive or bad_chars) else 1)
