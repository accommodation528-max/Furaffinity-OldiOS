#!/usr/bin/env bash
# 抓一个「未登录看不到」的详情页当 fixture（FA 对成人内容直接返回 Login Required 页）
OUT=/mnt/d/faios/FAPages/Tests/FAPagesTests/Fixtures/login-required.html
UA='Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1 FaiOS/0.1'
curl -s --max-time 40 -A "$UA" "https://www.furaffinity.net/view/66962944/" -o "$OUT"
echo "size=$(wc -c < "$OUT") loginRequired=$(grep -c 'Login Required' "$OUT")"
