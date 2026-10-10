#!/bin/bash
# fwlab:2 이미지를 만든다 (최초 1회). fwlab:1 이 먼저 있어야 한다 -> ../14-acl-vs-firewall/image/build.sh
cd "$(dirname "$0")" && docker build -t fwlab:2 .
