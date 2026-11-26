"""由原始 xlsx 產生測試用變體（只改 sheet1.xml 的列）：incomplete＝刪除第 2–1001 列；broken＝第 3 列編碼改成與第 2 列相同、第 4 列品名清空。"""
import sys, zipfile, re
src, out, kind = sys.argv[1:4]
zin = zipfile.ZipFile(src)
sheet = zin.read("xl/worksheets/sheet1.xml").decode()
ss = zin.read("xl/sharedStrings.xml").decode()
if kind == "incomplete":
    sheet = re.sub(r'<row r="(\d+)"[^>]*>.*?</row>', lambda m: "" if 2 <= int(m.group(1)) <= 1001 else m.group(0), sheet, flags=re.S)
else:
    rows = {int(m.group(1)): m.group(0) for m in re.finditer(r'<row r="(\d+)"[^>]*>.*?</row>', sheet, flags=re.S)}
    a2 = re.search(r'<c r="A2"[^>]*><v>(\d+)</v>', rows[2]).group(1)
    r3 = re.sub(r'(<c r="A3"[^>]*><v>)\d+(</v>)', rf'\g<1>{a2}\2', rows[3])
    r4 = re.sub(r'<c r="B4"[^>]*><v>\d+</v></c>', '', rows[4])
    sheet = sheet.replace(rows[3], r3).replace(rows[4], r4)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for i in zin.infolist():
        z.writestr(i, sheet if i.filename == "xl/worksheets/sheet1.xml" else zin.read(i.filename))
print(out)
