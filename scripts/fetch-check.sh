#!/usr/bin/env bash
# 检查 guest 访问 FA 详情页现在的状态（返回的是不是 "Login Required"）
cd /tmp || exit 1
UA='Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1 FaiOS/0.1'
for id in 66962680 66962944 66962931; do
  f="/tmp/v_${id}.html"
  curl -s --max-time 40 -A "$UA" "https://www.furaffinity.net/view/$id/" -o "$f"
  size=$(wc -c < "$f")
  login=$(grep -c 'Login Required' "$f")
  shadow=$(grep -c 'submission-description-header' "$f")
  echo "id=$id size=$size loginRequired=$login hasHeader=$shadow"
  sleep 2
done
