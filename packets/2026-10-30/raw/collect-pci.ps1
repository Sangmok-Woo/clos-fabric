[Console]::OutputEncoding=[Text.Encoding]::UTF8
function Short($s){ if($s){ $s.Split([char]92)[1] } }
$devs=Get-PnpDevice -PresentOnly | Where-Object InstanceId -like 'PCI*'
$rows=foreach($x in $devs){
 $h=@{}; foreach($q in (Get-PnpDeviceProperty -InstanceId $x.InstanceId -ErrorAction SilentlyContinue)){ $h[$q.KeyName]=$q.Data }
 $a=[int64]$h['DEVPKEY_Device_Address']
 [pscustomobject]@{Bus=[int]$h['DEVPKEY_Device_BusNumber'];Dev=[int][math]::Floor($a/65536);Fn=[int]($a%65536);Id=Short $x.InstanceId;Type=$h['DEVPKEY_PciDevice_DeviceType'];Acs=$h['DEVPKEY_PciDevice_AcsSupport'];Up=$h['DEVPKEY_PciDevice_AcsCompatibleUpHierarchy'];Reg=$h['DEVPKEY_PciDevice_AcsCapabilityRegister'];Ats=$h['DEVPKEY_PciDevice_AtsSupport'];Ari=$h['DEVPKEY_PciDevice_AriSupport'];P=Short $h['DEVPKEY_Device_Parent'];Name=$x.FriendlyName}
}
$rows | Sort-Object Bus,Dev,Fn | ForEach-Object { '{0:x2}:{1:x2}.{2} {3} t={4} acs={5} up={6} reg={7} ats={8} ari={9} p={10} {11}' -f $_.Bus,$_.Dev,$_.Fn,$_.Id,$_.Type,$_.Acs,$_.Up,$_.Reg,$_.Ats,$_.Ari,$_.P,$_.Name }
