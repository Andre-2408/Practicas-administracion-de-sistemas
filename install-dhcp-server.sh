#!/bin/bash

set -e

echo "=== INSTALANDO DHCP SERVER ==="

sudo dnf install -y kea

IP=$(hostname -I | awk '{print $1}')
[ -z "$IP" ] && IP="192.168.100.10"

sudo tee /etc/kea/kea-dhcp4.conf > /dev/null << CFG
{
"Dhcp4": {
    "interfaces-config": {"interfaces": ["*"]},
    "valid-lifetime": 7200,
    "subnet4": [
    {
    "subnet": "192.168.100.0/24",
    "pools": [{"pool":"192.168.100.50 - 192.168.100.150"}],
    "option-data": [
    {"name": "routers", "data": "192.168.100.1"},
    {"name": "domain-name-servers", "data": "$IP"}
    ]
    }
    ]
}
}
CFG


sudo kea-dhcp4 -t /etc/kea/kea-dhcp4.conf


sudo systemctl enable --now kea-dhcp4

sudo firewall-cmd --add-service=dhcp --permanent --reload 2>/dev/null
