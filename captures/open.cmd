@echo off
REM Open a capture in Wireshark with an EVPN column profile + filter preset.
REM   open.cmd                   -> 01-vxlan-data.pcap      (VXLAN dataplane view)
REM   open.cmd bgp               -> 02-bgp-evpn-type2.pcap  (EVPN control plane view)
REM   open.cmd vxlan myfile.pcap
REM   open.cmd bgp   myfile.pcap
setlocal
set "WS=C:\Program Files\Wireshark\Wireshark.exe"
set "MODE=%~1"
if "%MODE%"=="" set "MODE=vxlan"
set "FILE=%~2"

if /i "%MODE%"=="bgp" goto bgp

if "%FILE%"=="" set "FILE=%~dp001-vxlan-data.pcap"
set "PROF=EVPN-VXLAN"
set "FLT=vxlan"
goto run

:bgp
if "%FILE%"=="" set "FILE=%~dp002-bgp-evpn-type2.pcap"
set "PROF=EVPN-BGP"
set "FLT=bgp.evpn.nlri.rt"

:run
echo Opening "%FILE%"   profile=%PROF%   filter=%FLT%
start "" "%WS%" -C "%PROF%" -Y "%FLT%" -r "%FILE%"
endlocal
