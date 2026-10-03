@echo off
REM Live capture from the lab straight into Wireshark on Windows.
REM Packets live inside WSL containers, so tcpdump runs there and streams
REM the pcap over a pipe into Wireshark here.
REM
REM   live.cmd              leaf1, VXLAN traffic    (EVPN-VXLAN columns)
REM   live.cmd bgp          leaf1, BGP EVPN routes  (EVPN-BGP columns)
REM   live.cmd all          leaf1, everything
REM   live.cmd vxlan leaf3  pick a different node
REM
REM Close Wireshark to stop the capture.
setlocal
set "WS=C:\Program Files\Wireshark\Wireshark.exe"
set "MODE=%~1"
if "%MODE%"=="" set "MODE=vxlan"
set "NODE=%~2"
if "%NODE%"=="" set "NODE=leaf1"
set "IFACE=any"

if /i "%MODE%"=="bgp" goto bgp
if /i "%MODE%"=="all" goto all

set "FLT=udp port 4789"
set "PROF=EVPN-VXLAN"
goto run

:bgp
set "FLT=tcp port 179"
set "PROF=EVPN-BGP"
goto run

:all
set "FLT=not port 22"
set "PROF=Default"

:run
echo Capturing %NODE%:%IFACE%  filter="%FLT%"  profile=%PROF%
echo Close Wireshark to stop.
wsl -d Ubuntu -u root -e bash -lc "cd /root/labs/clos-fabric && ./scripts/stream.sh %NODE% %IFACE% '%FLT%'" | "%WS%" -k -i - -C "%PROF%"
endlocal
