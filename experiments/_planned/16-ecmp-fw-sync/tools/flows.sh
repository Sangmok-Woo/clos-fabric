#!/bin/sh
# h1 안에서 실행: 출발포트 BASE..BASE+N-1 로 curl 을 N번 (PAR개씩 동시에).
# 한 줄 = "출발포트 http코드 connect시간 total시간"
# sh /lab/tools/flows.sh <BASE> <N> [PAR] [URL]
BASE=$1; N=$2; PAR=${3:-20}; URL=${4:-http://10.15.2.10/}
seq "$BASE" $((BASE + N - 1)) | xargs -P "$PAR" -I{} \
  curl -s -o /dev/null --local-port {} --connect-timeout 2 -m 3 \
       -w '{} %{http_code} %{time_connect} %{time_total}\n' "$URL"
