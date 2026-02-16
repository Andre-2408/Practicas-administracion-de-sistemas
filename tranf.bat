@echo off
echo Enviando scripts al servidor Linux...

scp D:\Antigravity\herman\p3\AlmaLinux\DnsLinux.sh andre@192.168.175.128:/home/andre/DnsLinux.sh
scp D:\Antigravity\herman\p3\cliente\dnsCliente.sh andre@192.168.175.139:/home/andre/dnsCliente.sh
echo Listo!
pause