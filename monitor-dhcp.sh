#!/bin/bash


echo "Monitor DHCP SERVER "
echo ""


echo "Estado del Servicio:"
systemctl status dnsmasq --no-pager | head -n 10
echo ""
echo "Concesiones Activas:"
if [ -f /var/lib/misc/dnsmasq.leases ]; then
    cat /var/lib/misc/dnsmasq.leases
    echo ""
    echo "Total concesiones: $(wc -l < /var/lib/misc/dnsmasq.leases)"
else
    echo "No hay concesiones activas"
fi
echo ""

echo "Configuracion Actual:"
cat /etc/dnsmasq.conf | grep -v "^#" | grep -v "^$"
echo ""
echo "Ultimos Logs:"
journalctl -u dnsmasq -n 10 --no-pager