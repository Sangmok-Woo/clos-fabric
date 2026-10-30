$cs=Get-CimInstance Win32_ComputerSystem; $bb=Get-CimInstance Win32_BaseBoard; $cpu=Get-CimInstance Win32_Processor
"$($cs.Manufacturer) / $($cs.Model) / $($bb.Manufacturer) $($bb.Product)"
"$($cpu.Name) VirtFW=$($cpu.VirtualizationFirmwareEnabled) SLAT=$($cpu.SecondLevelAddressTranslationExtensions)"
"BIOS: $((Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion)"
"--- DeviceGuard"
try { $d=Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard Win32_DeviceGuard -ErrorAction Stop
"AvailableSecurityProperties=$($d.AvailableSecurityProperties) (3=DMA protection)"; "VBSstatus=$($d.VirtualizationBasedSecurityStatus)"; "Required=$($d.RequiredSecurityProperties)" } catch { "DeviceGuard n/a: $_" }
"--- ACPI tables"
Add-Type -Namespace W -Name F -MemberDefinition '[DllImport("kernel32")] public static extern uint EnumSystemFirmwareTables(uint p, byte[] b, uint s);'
$p=0x41435049; $n=[W.F]::EnumSystemFirmwareTables($p,$null,0); $b=New-Object byte[] $n; [void][W.F]::EnumSystemFirmwareTables($p,$b,$n)
$t=@(); for($i=0;$i -lt $n;$i+=4){$t+=[Text.Encoding]::ASCII.GetString($b,$i,4)}; ($t|Sort-Object -Unique) -join ' '
"--- PCI"
$names='DEVPKEY_PciDevice_AcsSupport','DEVPKEY_PciDevice_AtsSupport','DEVPKEY_PciDevice_AriSupport','DEVPKEY_PciDevice_SriovSupport','DEVPKEY_PciDevice_AcsCompatibleUpHierarchy','DEVPKEY_PciDevice_CurrentLinkSpeed','DEVPKEY_PciDevice_CurrentLinkWidth','DEVPKEY_Device_LocationPaths','DEVPKEY_PciDevice_DeviceType'
$devs=Get-PnpDevice -PresentOnly | Where-Object InstanceId -like 'PCI\*'
"count=$($devs.Count)"
foreach($x in $devs){ $o=[ordered]@{Name=$x.FriendlyName;Class=$x.Class}
 $pp=Get-PnpDeviceProperty -InstanceId $x.InstanceId -ErrorAction SilentlyContinue
 foreach($q in $pp){ if($q.KeyName -match 'PciDevice_(Acs|Ats|Ari|Sriov|DeviceType|Current)'){ $o[$q.KeyName -replace 'DEVPKEY_PciDevice_','']=$q.Data } }
 ($o.GetEnumerator()|ForEach-Object{"$($_.Key)=$($_.Value)"}) -join ' | ' }
