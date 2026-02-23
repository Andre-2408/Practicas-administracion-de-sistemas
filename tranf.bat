@echo off
echo Enviando scripts al servidor Linux...

scp D:\Antigravity\herman\p3\AlmaLinux\DnsLinux.sh andre@192.168.175.128:/home/andre/DnsLinux.sh
scp D:\Antigravity\herman\p2\menu-dhcp.sh andre@192.168.175.128:/home/andre/menu-dhcp.sh
echo Listo!
pause