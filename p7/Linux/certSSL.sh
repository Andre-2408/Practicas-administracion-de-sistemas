#!/bin/bash
#
# certSSL.sh -- Gestion de certificados SSL autofirmados
#

[[ -n "${_CERT_SSL_LOADED:-}" ]] && return 0
readonly _CERT_SSL_LOADED=1

# ------------------------------------------------------------
# Generar certificado autofirmado
# ------------------------------------------------------------

ssl_cert_generar() {
    aputs_info "Generando certificado SSL autofirmado..."
    echo ""

    if ! command -v openssl &>/dev/null; then
        aputs_info "openssl no encontrado -- instalando..."
        dnf install -y openssl &>/dev/null \
            && aputs_success "openssl instalado" \
            || { aputs_error "No se pudo instalar openssl"; return 1; }
    fi

    mkdir -p "${SSL_DIR}"
    chmod 700 "${SSL_DIR}"

    openssl req -x509 -nodes \
        -newkey rsa:${SSL_KEY_BITS} \
        -keyout "${SSL_KEY}" \
        -out    "${SSL_CERT}" \
        -days   "${SSL_DAYS}" \
        -subj   "${SSL_SUBJECT}" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        aputs_error "Error al generar el certificado"
        return 1
    fi

    chmod 600 "${SSL_KEY}"
    chmod 644 "${SSL_CERT}"

    aputs_success "Certificado generado exitosamente"
    echo ""
    printf "  %-20s %s\n" "Certificado:" "${SSL_CERT}"
    printf "  %-20s %s\n" "Clave privada:" "${SSL_KEY}"
    printf "  %-20s %s\n" "Dominio:" "${SSL_DOMAIN}"
    printf "  %-20s %s dias\n" "Vigencia:" "${SSL_DAYS}"
    echo ""
}

# ------------------------------------------------------------
# Mostrar informacion del certificado
# ------------------------------------------------------------

ssl_cert_mostrar_info() {
    if ! ssl_cert_existe; then
        aputs_warning "No hay certificado en ${SSL_DIR}"
        return 1
    fi

    echo ""
    printf "  %-20s %s\n" "Archivo:" "${SSL_CERT}"

    local subject notbefore notafter
    subject=$(openssl x509 -noout -subject -in "${SSL_CERT}" 2>/dev/null | sed 's/subject=//')
    notbefore=$(openssl x509 -noout -startdate -in "${SSL_CERT}" 2>/dev/null | sed 's/notBefore=//')
    notafter=$(openssl x509 -noout -enddate -in "${SSL_CERT}" 2>/dev/null | sed 's/notAfter=//')

    printf "  %-20s %s\n" "Subject:" "$subject"
    printf "  %-20s %s\n" "Valido desde:" "$notbefore"
    printf "  %-20s %s\n" "Valido hasta:" "$notafter"
    echo ""
}

# ------------------------------------------------------------
# Menu de gestion de certificado
# ------------------------------------------------------------

ssl_menu_cert() {
    while true; do
        clear
        ssl_mostrar_banner "Gestion de Certificado SSL"

        if ssl_cert_existe; then
            aputs_success "Certificado instalado en ${SSL_DIR}"
            ssl_cert_mostrar_info
        else
            aputs_warning "No hay certificado generado aun"
            echo ""
        fi

        echo "  1) Generar nuevo certificado autofirmado"
        echo "  2) Ver informacion del certificado"
        echo "  3) Verificar herramientas SSL"
        echo "  4) Eliminar certificado actual"
        echo "  0) Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1)
                echo ""
                if ssl_cert_existe; then
                    read -rp "  Ya existe un certificado. Sobreescribir? [s/N]: " conf
                    [[ "$conf" =~ ^[sS]$ ]] || { pause; continue; }
                fi
                ssl_cert_generar
                pause
                ;;
            2)
                echo ""
                ssl_cert_mostrar_info
                pause
                ;;
            3)
                echo ""
                ssl_verificar_prereqs
                pause
                ;;
            4)
                echo ""
                if ssl_cert_existe; then
                    read -rp "  Confirmar eliminacion del certificado? [s/N]: " conf
                    if [[ "$conf" =~ ^[sS]$ ]]; then
                        rm -f "${SSL_CERT}" "${SSL_KEY}"
                        aputs_success "Certificado eliminado"
                    else
                        aputs_info "Operacion cancelada"
                    fi
                else
                    aputs_warning "No hay certificado que eliminar"
                fi
                pause
                ;;
            0) return ;;
            *) aputs_error "Opcion invalida"; sleep 1 ;;
        esac
    done
}
