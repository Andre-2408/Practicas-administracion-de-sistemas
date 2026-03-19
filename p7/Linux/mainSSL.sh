#!/bin/bash
#
# mainSSL.sh -- Orquestador principal Practica 7
#
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly P5_DIR="$(cd "${SCRIPT_DIR}/../P5" && pwd)"
readonly P6_DIR="$(cd "${SCRIPT_DIR}/../P6" && pwd)"
readonly SSL_DIR_LIB="${SCRIPT_DIR}"

# ------------------------------------------------------------
# Verificar rootpw
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo ""
    echo "  [ERROR] Este script requiere privilegios de root."
    echo "  Ejecute: sudo bash ${BASH_SOURCE[0]}"
    echo ""
    exit 1
fi

# ------------------------------------------------------------
# Verificar estructura de archivos
# ------------------------------------------------------------

_verificar_estructura() {
    local errores=0

    for dir in "${P5_DIR}" "${P6_DIR}" "${SSL_DIR_LIB}"; do
        if [[ ! -d "${dir}" ]]; then
            echo "  [ERROR] Directorio no encontrado: ${dir}"
            errores=$(( errores + 1 ))
        fi
    done

    # Archivos obligatorios (sin ellos no hay menu)
    local archivos_req=(
        "${P5_DIR}/main_ftp.sh"
        "${P6_DIR}/main_http.sh"
        "${SSL_DIR_LIB}/utilsSSL.sh"
    )

    for archivo in "${archivos_req[@]}"; do
        if [[ ! -f "${archivo}" ]]; then
            echo "  [ERROR] Archivo no encontrado: ${archivo}"
            errores=$(( errores + 1 ))
        fi
    done

    # Archivos SSL opcionales (advertencia si no estan)
    local archivos_ssl=(
        "${SSL_DIR_LIB}/certSSL.sh"
        "${SSL_DIR_LIB}/FTP-SSL.sh"
        "${SSL_DIR_LIB}/HTTP-SSL.sh"
        "${SSL_DIR_LIB}/verifySSL.sh"
        "${SSL_DIR_LIB}/repoHTTP.sh"
    )

    for archivo in "${archivos_ssl[@]}"; do
        if [[ ! -f "${archivo}" ]]; then
            echo "  [AVISO] Modulo SSL no encontrado: ${archivo}"
        fi
    done

    if [[ "$errores" -gt 0 ]]; then
        echo ""
        echo "  Verifique que las Practicas 5, 6 y 7 estan en:"
        echo "  ~/scripts/{P5,P6,P7}"
        echo ""
        exit 1
    fi
}

# ------------------------------------------------------------
# Cargar modulos
# ------------------------------------------------------------

_cargar_modulos() {
    source "${SSL_DIR_LIB}/utilsSSL.sh"

    local modulos_ssl=(
        "${SSL_DIR_LIB}/certSSL.sh"
        "${SSL_DIR_LIB}/FTP-SSL.sh"
        "${SSL_DIR_LIB}/HTTP-SSL.sh"
        "${SSL_DIR_LIB}/verifySSL.sh"
        "${SSL_DIR_LIB}/repoHTTP.sh"
        "${SSL_DIR_LIB}/installFTP.sh"
    )
    for mod in "${modulos_ssl[@]}"; do
        [[ -f "$mod" ]] && source "$mod"
    done
}

# ------------------------------------------------------------
# Indicadores de estado
# ------------------------------------------------------------

_icono_estado() {
    local condicion="$1"
    if [[ "$condicion" == "ok" ]]; then
        echo "[*]"
    else
        echo "[ ]"
    fi
}

_estado_ftp() {
    rpm -q vsftpd &>/dev/null && systemctl is-active --quiet vsftpd 2>/dev/null \
        && echo "ok" || echo "no"
}

_estado_ftps() {
    grep -q "^ssl_enable=YES" "${SSL_CONF_VSFTPD}" 2>/dev/null \
        && echo "ok" || echo "no"
}

_estado_repo() {
    local count
    count=$(find "${SSL_REPO_ROOT}" -name "*.rpm" 2>/dev/null | wc -l)
    [[ "$count" -gt 0 ]] && echo "ok" || echo "no"
}

_estado_http() {
    ( ssl_servicio_instalado httpd || ssl_servicio_instalado nginx || \
      ssl_servicio_instalado tomcat ) && echo "ok" || echo "no"
}

_estado_ssl_http() {
    local apache_ok=false nginx_ok=false tomcat_ok=false

    [[ -f "${SSL_CONF_APACHE_SSL}" ]] && apache_ok=true

    if grep -q "=== Practica7 SSL Nginx ===" "${SSL_CONF_NGINX}" 2>/dev/null; then
        nginx_ok=true
    fi

    local server_xml
    server_xml=$(SSL_CONF_TOMCAT 2>/dev/null)
    if [[ -f "$server_xml" ]] && grep -q "Practica7 SSL" "$server_xml" 2>/dev/null; then
        tomcat_ok=true
    fi

    if $apache_ok || $nginx_ok || $tomcat_ok; then
        echo "ok"
    else
        echo "no"
    fi
}

_estado_cert() {
    ssl_cert_existe && echo "ok" || echo "no"
}

# ------------------------------------------------------------
# Pasos del menu
# ------------------------------------------------------------

_paso_1_ftp() {
    clear
    ssl_mostrar_banner "Paso 1 -- Instalar y configurar FTP"

    aputs_info "Entrando al menu de instalacion FTP (Practica 5)..."
    echo ""
    pause

    if [[ -f "${P5_DIR}/main_ftp.sh" ]]; then
        bash "${P5_DIR}/main_ftp.sh"
    else
        aputs_error "main_ftp.sh no encontrado en ${P5_DIR}"
        pause
    fi
}

_paso_2_ftps() {
    clear
    ssl_mostrar_banner "Paso 2 -- Configurar FTPS/TLS (opcional)"

    if ! rpm -q vsftpd &>/dev/null; then
        aputs_error "vsftpd no esta instalado"
        aputs_info  "Ejecute primero el Paso 1 -- Instalar FTP"
        pause
        return
    fi

    echo ""
    echo "  Este paso configurara:"
    echo "    - Certificado SSL autofirmado (si no existe)"
    echo "    - TLS explicito en vsftpd (puerto 21)"
    echo ""
    read -rp "  Desea aplicar FTPS/TLS a vsftpd? [S/n]: " resp

    if [[ "$resp" =~ ^[nN]$ ]]; then
        aputs_info "FTPS omitido -- puede configurarlo despues desde el menu"
        pause
        return
    fi

    echo ""

    if ! ssl_cert_existe; then
        aputs_info "El certificado no existe -- generando..."
        echo ""
        ssl_cert_generar || { pause; return; }
        echo ""
    else
        aputs_info "Certificado ya existe -- reutilizando"
        ssl_cert_mostrar_info
        echo ""
    fi

    ssl_ftp_aplicar
    pause
}

_paso_3_repo_estructura() {
    clear
    ssl_mostrar_banner "Paso 3 -- Repositorio FTP + usuario 'repo'"

    if ! rpm -q vsftpd &>/dev/null; then
        aputs_error "vsftpd no esta instalado"
        aputs_info  "Ejecute primero el Paso 1 -- Instalar FTP"
        pause
        return
    fi

    aputs_info "Creando estructura del repositorio FTP..."
    echo ""
    ssl_repo_crear_estructura || { pause; return; }

    echo ""
    draw_line
    echo ""

    aputs_info "Configurando usuario dedicado 'repo'..."
    echo ""

    local REPO_USER="repo"
    local REPO_CHROOT="${SSL_FTP_ROOT}/ftp_repo"
    local REPO_SUBDIR="${REPO_CHROOT}/repositorio"
    local REPO_REAL="${SSL_FTP_ROOT}/repositorio"

    if ! grep -qx "/sbin/nologin" /etc/shells 2>/dev/null; then
        echo "/sbin/nologin" >> /etc/shells
        aputs_success "Agregado /sbin/nologin a /etc/shells (fix PAM vsftpd)"
    else
        aputs_info "/sbin/nologin ya esta en /etc/shells"
    fi
    echo ""

    if id "${REPO_USER}" &>/dev/null; then
        aputs_info "El usuario '${REPO_USER}' ya existe"
    else
        aputs_info "Creando usuario '${REPO_USER}'..."
        useradd -r -M -d "${REPO_CHROOT}" -s /sbin/nologin "${REPO_USER}" 2>/dev/null

        if id "${REPO_USER}" &>/dev/null; then
            aputs_success "Usuario '${REPO_USER}' creado"
        else
            aputs_error "No se pudo crear el usuario '${REPO_USER}'"
            pause
            return
        fi
    fi

    aputs_info "Creando estructura de chroot en ${REPO_CHROOT}..."

    mkdir -p "${REPO_CHROOT}"
    chown root:root "${REPO_CHROOT}"
    chmod 755 "${REPO_CHROOT}"
    aputs_success "Raiz del chroot: ${REPO_CHROOT} (root:root 755)"

    mkdir -p "${REPO_SUBDIR}"
    chown root:ftp "${REPO_SUBDIR}"
    chmod 755 "${REPO_SUBDIR}"

    if mountpoint -q "${REPO_SUBDIR}" 2>/dev/null; then
        aputs_info "Bind mount ya activo en ${REPO_SUBDIR}"
    else
        if mount --bind "${REPO_REAL}" "${REPO_SUBDIR}" 2>/dev/null; then
            aputs_success "Bind mount: ${REPO_REAL} -> ${REPO_SUBDIR}"
        else
            aputs_warning "bind mount fallo -- enlace simbolico como alternativa"
            rmdir "${REPO_SUBDIR}" 2>/dev/null
            ln -sfn "${REPO_REAL}" "${REPO_SUBDIR}"
            aputs_success "Symlink creado: ${REPO_SUBDIR} -> ${REPO_REAL}"
        fi
    fi

    local FSTAB_ENTRY="${REPO_REAL}  ${REPO_SUBDIR}  none  bind  0 0"
    if ! grep -qF "${REPO_SUBDIR}" /etc/fstab 2>/dev/null; then
        echo "# Practica7 -- repositorio FTP (bind mount)" >> /etc/fstab
        echo "${FSTAB_ENTRY}" >> /etc/fstab
        aputs_success "Bind mount agregado a /etc/fstab (persistente)"
    else
        aputs_info "Entrada en /etc/fstab ya existe"
    fi
    echo ""

    if command -v restorecon &>/dev/null; then
        restorecon -Rv "${REPO_CHROOT}" &>/dev/null
        aputs_success "Contexto SELinux aplicado a ${REPO_CHROOT}"
    fi

    read -rsp "  Contrasena para el usuario '${REPO_USER}': " pass
    echo ""

    if [[ -z "${pass}" ]]; then
        pass="reprobados"
        aputs_warning "Contrasena vacia -- usando default: reprobados"
    fi

    echo "${REPO_USER}:${pass}" | chpasswd 2>/dev/null \
        && aputs_success "Contrasena configurada" \
        || aputs_warning "No se pudo configurar contrasena (chpasswd)"

    echo ""
    draw_line
    echo ""
    aputs_success "Paso 3 completado"
    printf "  %-22s %s\n" "Usuario FTP:"    "${REPO_USER}"
    printf "  %-22s %s\n" "Raiz chroot:"    "${REPO_CHROOT}  (root:root 755)"
    printf "  %-22s %s\n" "Repositorio:"    "${REPO_SUBDIR}  (bind -> ${REPO_REAL})"
    printf "  %-22s %s\n" "Acceso FTP:"     "ftp://${SSL_FTP_IP}  usuario: ${REPO_USER}"
    printf "  %-22s %s\n" "Navegar a:"      "/repositorio/http/Linux/{Apache,Nginx,Tomcat}"
    echo ""

    pause
}

_paso_4_descargar_rpms() {
    clear
    ssl_mostrar_banner "Paso 4 -- Descargar RPMs al repositorio"

    if [[ ! -d "${SSL_REPO_ROOT}" ]]; then
        aputs_error "El repositorio no existe"
        aputs_info  "Ejecute primero el Paso 3 -- Crear repositorio"
        pause
        return
    fi

    while true; do
        clear
        ssl_mostrar_banner "Paso 4 -- Descargar RPMs"
        ssl_repo_listar

        echo "  1) Descargar todos (Apache + Nginx + Tomcat)"
        echo "  2) Descargar solo Apache (httpd)"
        echo "  3) Descargar solo Nginx"
        echo "  4) Descargar solo Tomcat"
        echo "  5) Verificar integridad (SHA256)"
        echo "  0) Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) ssl_repo_descargar_todos;               pause ;;
            2) ssl_repo_descargar_paquete "httpd";     pause ;;
            3) ssl_repo_descargar_paquete "nginx";     pause ;;
            4) ssl_repo_descargar_paquete "tomcat";    pause ;;
            5) ssl_repo_verificar_integridad;          pause ;;
            0) return ;;
            *) aputs_error "Opcion invalida"; sleep 1 ;;
        esac
    done
}

_paso_5_http() {
    while true; do
        clear
        ssl_mostrar_banner "Paso 5 -- Instalar y configurar HTTP"

        echo "  Como desea instalar los servicios HTTP?"
        echo ""

        # Indicar si hay RPMs en el repo local
        local rpm_count=0
        if [[ -d "${SSL_REPO_ROOT}" ]]; then
            rpm_count=$(find "${SSL_REPO_ROOT}" -name "*.rpm" 2>/dev/null | wc -l)
        fi

        if [[ "$rpm_count" -gt 0 ]]; then
            printf "  [*] Repositorio FTP local disponible (%d RPM(s))\n" "$rpm_count"
        else
            printf "  [ ] Repositorio FTP local vacio (ejecute Paso 4 primero)\n"
        fi

        echo ""
        echo "  1) Instalar desde repositorios del sistema  (Practica 6)"
        echo "  2) Instalar desde repositorio FTP propio"
        echo "  0) Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1)
                if [[ -f "${P6_DIR}/main_http.sh" ]]; then
                    bash "${P6_DIR}/main_http.sh"
                else
                    aputs_error "main_http.sh no encontrado en ${P6_DIR}"
                    pause
                fi
                ;;
            2)
                if [[ "$rpm_count" -eq 0 ]]; then
                    echo ""
                    aputs_warning "El repositorio FTP esta vacio"
                    aputs_info   "Ejecute el Paso 4 para descargar los RPMs primero"
                    pause
                else
                    ssl_instalar_desde_ftp
                fi
                ;;
            0) return ;;
            *) aputs_error "Opcion invalida"; sleep 1 ;;
        esac
    done
}

_paso_6_ssl_http() {
    clear
    ssl_mostrar_banner "Paso 6 -- Configurar SSL/HTTPS (opcional)"

    if ! ( ssl_servicio_instalado httpd || ssl_servicio_instalado nginx || \
           ssl_servicio_instalado tomcat ); then
        aputs_error "No hay servicios HTTP instalados"
        aputs_info  "Ejecute primero el Paso 5 -- Instalar HTTP"
        pause
        return
    fi

    echo ""
    echo "  Este paso configurara:"
    echo "    - Certificado SSL autofirmado (si no existe)"
    echo "    - HTTPS en los servicios HTTP instalados"
    echo "    - Redirect HTTP -> HTTPS"
    echo ""
    read -rp "  Desea aplicar SSL/HTTPS? [S/n]: " resp

    if [[ "$resp" =~ ^[nN]$ ]]; then
        aputs_info "SSL/HTTPS omitido -- puede configurarlo despues desde el menu"
        pause
        return
    fi

    echo ""

    if ! ssl_cert_existe; then
        aputs_info "El certificado no existe -- generando..."
        echo ""
        ssl_cert_generar || { pause; return; }
        echo ""
    else
        aputs_info "Certificado ya existe -- reutilizando"
        ssl_cert_mostrar_info
        echo ""
    fi

    ssl_http_aplicar_todos
    pause
}

_paso_7_testing() {
    ssl_verify_todo
    pause
}

# ------------------------------------------------------------
# Menu principal
# ------------------------------------------------------------

_dibujar_menu() {
    clear

    local s1 s2 s3 s4 s5 s6 s_cert
    s1=$(_icono_estado "$(_estado_ftp)")
    s2=$(_icono_estado "$(_estado_ftps)")
    s3=$(_icono_estado "$(
        [[ -d "${SSL_REPO_ROOT}" ]] && echo "ok" || echo "no"
    )")
    s4=$(_icono_estado "$(_estado_repo)")
    s5=$(_icono_estado "$(_estado_http)")
    s6=$(_icono_estado "$(_estado_ssl_http)")
    s_cert=$(_icono_estado "$(_estado_cert)")

    echo ""
    echo "  =========================================================="
    echo "    Tarea 07 -- Infraestructura Segura FTP/HTTP"
    echo "  =========================================================="
    echo ""
    echo "  Certificado SSL: ${s_cert}"
    echo ""
    echo "  -- Fase FTP --------------------------------------------------"
    echo "  1) ${s1}  Instalar y configurar FTP"
    echo "  2) ${s2}  Configurar FTPS/TLS         (requiere paso 1)"
    echo ""
    echo "  -- Fase Repositorio ------------------------------------------"
    echo "  3) ${s3}  Crear repositorio + usuario 'repo'  (req. paso 1)"
    echo "  4) ${s4}  Descargar RPMs al repositorio        (req. paso 3)"
    echo ""
    echo "  -- Fase HTTP -------------------------------------------------"
    echo "  5) ${s5}  Instalar y configurar HTTP"
    echo "  6) ${s6}  Configurar SSL/HTTPS         (requiere paso 5)"
    echo ""
    echo "  -- Extras ----------------------------------------------------"
    echo "  7)      Testing general completo"
    echo "  f)      Menu completo FTP           (Practica 5)"
    echo "  h)      Menu completo HTTP          (Practica 6)"
    echo "  c)      Gestionar certificado SSL"
    echo "  r)      Menu repositorio FTP"
    echo ""
    echo "  0)      Salir"
    echo ""
}

main_menu() {
    while true; do
        _dibujar_menu

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) _paso_1_ftp              ;;
            2) _paso_2_ftps             ;;
            3) _paso_3_repo_estructura  ;;
            4) _paso_4_descargar_rpms   ;;
            5) _paso_5_http             ;;
            6) _paso_6_ssl_http         ;;
            7) _paso_7_testing          ;;

            f|F)
                if [[ -f "${P5_DIR}/main_ftp.sh" ]]; then
                    bash "${P5_DIR}/main_ftp.sh"
                else
                    aputs_error "main_ftp.sh no encontrado en ${P5_DIR}"
                    pause
                fi
                ;;
            h|H)
                if [[ -f "${P6_DIR}/main_http.sh" ]]; then
                    bash "${P6_DIR}/main_http.sh"
                else
                    aputs_error "main_http.sh no encontrado en ${P6_DIR}"
                    pause
                fi
                ;;
            c|C) ssl_menu_cert          ;;
            r|R) ssl_menu_repo          ;;

            0)
                echo ""
                aputs_info "Saliendo de la Practica 7..."
                echo ""
                exit 0
                ;;
            *)
                aputs_error "Opcion invalida"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------
# Punto de entrada
# ------------------------------------------------------------

_verificar_estructura
_cargar_modulos
main_menu
