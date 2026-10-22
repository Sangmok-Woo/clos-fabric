#!/bin/bash
# fwlab:1 이미지를 만든다 (랩 최초 1회). WSL root 에서 실행.
cd "$(dirname "$0")" && docker build -t fwlab:1 .
