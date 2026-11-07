#!/usr/bin/env bash
# 抓一张真实搜索结果页，存成 fixture 并做结构体检
set -u
UA='Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1 FaiOS/0.1'
OUT=/mnt/d/faios/FAPages/Tests/FAPagesTests/Fixtures/search.html
URL='https://www.furaffinity.net/search/?q=dragon&page=1'

curl -s --retry 3 --max-time 60 -A "$UA" "$URL" -o "$OUT"
echo "size=$(wc -c < "$OUT")"
python3 - "$OUT" <<'PY'
import re, sys
html = open(sys.argv[1], encoding='utf-8', errors='replace').read()
print("title:", re.search(r'<title>(.*?)</title>', html, re.S).group(1).strip()[:120])
figs = re.findall(r'<figure[^>]*id="sid-(\d+)"[^>]*class="([^"]*)"', html)
print("figures:", len(figs))
from collections import Counter
print("t-* 分布:", Counter(c.split()[1] if len(c.split()) > 1 else c.strip() for _, c in figs).most_common())
print("分页 form:", html.count('<form'), "Next:", html.count('>Next<'), "page=:", len(re.findall(r'name="page"', html)))
m = re.search(r'<form[^>]*id="[^"]*"[^>]*>(.{0,1200}?)</form>', html, re.S)
print("form 片段:", re.sub(r'\s+', ' ', m.group(1))[:600] if m else "无")
print("searchbox:", 'id="searchbox"' in html, "| results div:", html.count('id="search-results"'))
PY
