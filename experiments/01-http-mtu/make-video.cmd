@echo off
rem Playable test video (~70MB) for Wireshark Export Objects demo.
cd /d "%~dp0"
if not exist files mkdir files
ffmpeg -y -hide_banner -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine=frequency=440 -t 60 -c:v libx264 -b:v 9M -maxrate 9M -bufsize 18M -c:a aac -shortest files\video-small.mp4
certutil -hashfile files\video-small.mp4 MD5
