uname -r
echo "--- 1 dmesg"; dmesg | grep -i -e AMD-Vi -e iommu | head
echo "--- 2 groups"; ls /sys/kernel/iommu_groups 2>&1 | wc -l; ls -la /sys/kernel/iommu_groups 2>&1 | head -5
which lspci; lspci 2>&1 | head -10
echo "--- 3 ats"; lspci -vvv 2>/dev/null | grep -i -c 'Address Translation'
lspci -vvv 2>/dev/null | grep -i -e '^[0-9a-f]' -e 'Access Control' -e 'Address Translation' | head -20
echo "--- cpu"; grep -m1 'model name' /proc/cpuinfo; grep -o -m1 -w svm /proc/cpuinfo
