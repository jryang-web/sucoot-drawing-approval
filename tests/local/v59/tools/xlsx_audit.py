"""以原始 XML 解析 xlsx，逐格回報型別與原文，不經 Excel 函式庫轉換。"""
import sys, zipfile, re, collections, json
import xml.etree.ElementTree as ET
NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
      "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships"}
z = zipfile.ZipFile(sys.argv[1])
wb = ET.fromstring(z.read("xl/workbook.xml"))
print("sheets:", [(s.get("name"), s.get("state")) for s in wb.find("m:sheets", NS)])
ss = []
for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", NS):
    ss.append("".join(t.text or "" for t in si.iter("{%s}t" % NS["m"])))
st = ET.fromstring(z.read("xl/styles.xml"))
numfmts = {int(n.get("numFmtId")): n.get("formatCode") for n in st.findall("m:numFmts/m:numFmt", NS)}
xfs = [int(x.get("numFmtId", 0)) for x in st.findall("m:cellXfs/m:xf", NS)]
sh = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
print("dimension:", sh.find("m:dimension", NS).get("ref") if sh.find("m:dimension", NS) is not None else None)
print("merged:", len(sh.findall("m:mergeCells/m:mergeCell", NS)))
rows = []; types = collections.Counter(); fmts = collections.Counter()
def col(ref): return re.match(r"[A-Z]+", ref).group()
for r in sh.find("m:sheetData", NS).findall("m:row", NS):
    vals = {}
    for c in r.findall("m:c", NS):
        t = c.get("t", "n"); v = c.find("m:v", NS); s = int(c.get("s", 0))
        if t == "s": text = ss[int(v.text)]
        elif t == "inlineStr": text = "".join(x.text or "" for x in c.iter("{%s}t" % NS["m"]))
        else: text = v.text if v is not None else None
        vals[col(c.get("r"))] = (text, t, xfs[s] if s < len(xfs) else 0)
        types[(col(c.get("r")), t)] += 1
        if t == "n" and v is not None: fmts[(col(c.get("r")), xfs[s], numfmts.get(xfs[s]))] += 1
    rows.append((int(r.get("r")), vals))
print("row elements:", len(rows), "first row#", rows[0][0], "last row#", rows[-1][0])
print("cell types (col,type):", dict(types))
print("numeric cell formats:", dict(fmts))
hdr = rows[0][1]; print("header:", {k: v[0] for k, v in hdr.items()})
json.dump([[n, {k: v[0] for k, v in vals.items()}, {k: v[1] for k, v in vals.items()}] for n, vals in rows],
          open(sys.argv[2], "w"), ensure_ascii=False)
