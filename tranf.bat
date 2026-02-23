@echo off
echo Enviando scripts al servidor Linux...

set SRV=andre@192.168.175.128
set LOCAL=D:\Antigravity\herman\p4\AlmaLinux
set REMOTE=/home/andre

scp %LOCAL%\main.sh             %SRV%:%REMOTE%/main.sh
scp %LOCAL%\common-functions.sh %SRV%:%REMOTE%/common-functions.sh
scp %LOCAL%\ssh-functions.sh    %SRV%:%REMOTE%/ssh-functions.sh

echo.
echo Ajustando permisos de ejecucion...
ssh %SRV% "chmod +x %REMOTE%/main.sh %REMOTE%/common-functions.sh %REMOTE%/ssh-functions.sh"

echo Listo!
pause