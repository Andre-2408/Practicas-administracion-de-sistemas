#!/bin/bash
#
# repoHTTP.sh -- Gestion del repositorio FTP de paquetes HTTP
#

[[ -n "${_REPO_HTTP_LOADED:-}" ]] && return 0
readonly _REPO_HTTP_LOADED=1

# ------------------------------------------------------------
# Crear estructura del repositorio
# ------------------------------------------------------------

ssl_repo_crear_estructura() {
    aputs_info "Creando estructura de directorios del repositorio..."
    echo ""

    local dirs=(
        "${SSL_REPO_APACHE}"
        "${SSL_REPO_NGINX}"
        "${SSL_REPO_TOMCAT}"
    )

    for dir in "${dirs[@]}"; do
        if mkdir -p "$dir" 2>/dev/null; then
            aputs_success "Creado: ${dir}"
        else
            aputs_error "No se pudo crear: ${dir}"
            return 1
        fi
    done

    chown root:root "${SSL_FTP_CHROOT}" 2>/dev/null || true
    chmod 755 "${SSL_FTP_CHROOT}" 2>/dev/null || true
    chown -R "${SSL_FTP_USER}:${SSL_FTP_USER}" "${SSL_REPO_ROOT}" 2>/dev/null || true
    chmod -R 755 "${SSL_REPO_ROOT}" 2>/dev/null || true

    if command -v restorecon &>/dev/null; then
        restorecon -Rv "${SSL_FTP_ROOT}" &>/dev/null
        aputs_success "Contexto SELinux aplicado"
    fi

    echo ""
    aputs_success "Estructura del repositorio creada en ${SSL_REPO_ROOT}"
    printf "  %-14s %s\n" "Chroot:"  "${SSL_FTP_CHROOT}  (root:root 755)"
    printf "  %-14s %s\n" "Repo:"    "${SSL_REPO_ROOT}   (${SSL_FTP_USER}:${SSL_FTP_USER} 755)"
    printf "  %-14s %s\n" "Apache:"  "${SSL_REPO_APACHE}"
    printf "  %-14s %s\n" "Nginx:"   "${SSL_REPO_NGINX}"
    printf "  %-14s %s\n" "Tomcat:"  "${SSL_REPO_TOMCAT}"
    echo ""
    aputs_info "Acceso FTP:  ftp://${SSL_FTP_IP}  usuario: ${SSL_FTP_USER}"
    aputs_info "Navegar a:   /repositorio/http/Linux/{Apache,Nginx,Tomcat}"
    echo ""
}

# ------------------------------------------------------------
# Listar contenido del repositorio
# ------------------------------------------------------------

ssl_repo_listar() {
    echo ""
    aputs_info "Contenido actual del repositorio:"
    echo ""

    local total=0
    for subdir in Apache Nginx Tomcat; do
        local dir="${SSL_REPO_LINUX}/${subdir}"
        local cnt=0
        if [[ -d "$dir" ]]; then
            cnt=$(find "$dir" -name "*.rpm" 2>/dev/null | wc -l)
        fi
        printf "  %-10s %d RPM(s)\n" "${subdir}:" "$cnt"

        # Mostrar versiones descargadas
        if [[ -d "$dir" && "$cnt" -gt 0 ]]; then
            find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while read -r vdir; do
                local vcnt
                vcnt=$(find "$vdir" -name "*.rpm" 2>/dev/null | wc -l)
                printf "             %-14s %d RPM(s)\n" "$(basename "$vdir"):" "$vcnt"
            done
        fi

        total=$(( total + cnt ))
    done

    echo ""
    printf "  %-10s %d RPM(s) en total\n" "Total:" "$total"
    echo ""
    printf "  %-14s ftp://%s  usuario: %s\n" "Acceso FTP:" "${SSL_FTP_IP}" "${SSL_FTP_USER}"
    printf "  %-14s /repositorio/http/Linux/{Apache,Nginx,Tomcat}/{version}/\n" "Ruta FTP:"
    echo ""
}

# ------------------------------------------------------------
# Consultar versiones disponibles en DNF
# ------------------------------------------------------------

_repo_listar_versiones_dnf() {
    local paquete="$1"

    dnf list --showduplicates "$paquete" 2>/dev/null \
        | awk '/^('"$paquete"')/ {print $2}' \
        | sed 's/^[0-9]*://' \
        | sort -V \
        | uniq
}

# ------------------------------------------------------------
# Descargar una version especifica
# ------------------------------------------------------------

_repo_descargar_version() {
    local paquete="$1" version="$2" destdir="$3"

    mkdir -p "$destdir"

    aputs_info "Descargando ${paquete}-${version}..."

    if dnf download --resolve --destdir="$destdir" "${paquete}-${version}" &>/dev/null 2>&1; then
        local cnt
        cnt=$(find "$destdir" -name "*.rpm" | wc -l)
        aputs_success "${cnt} RPM(s) en ${destdir}"

        # SHA256SUMS por version
        local sumsfile="${destdir}/SHA256SUMS"
        : > "$sumsfile"
        find "$destdir" -name "*.rpm" | while read -r rpm; do
            sha256sum "$rpm" >> "$sumsfile"
        done
        aputs_success "SHA256SUMS generado"
        return 0
    else
        aputs_error "No se pudo descargar ${paquete}-${version}"
        rmdir "$destdir" 2>/dev/null
        return 1
    fi
}

# ------------------------------------------------------------
# Menu de seleccion de versiones para un servicio
# ------------------------------------------------------------

_repo_menu_versiones() {
    local nombre="$1"   # Apache / Nginx / Tomcat
    local paquete="$2"  # httpd / nginx / tomcat
    local basedir="$3"  # SSL_REPO_APACHE / etc.

    while true; do
        clear
        ssl_mostrar_banner "Repositorio -- ${nombre}"

        aputs_info "Consultando versiones disponibles en DNF..."
        echo ""

        # Cargar versiones en array
        local versiones=()
        while IFS= read -r v; do
            [[ -n "$v" ]] && versiones+=("$v")
        done < <(_repo_listar_versiones_dnf "$paquete")

        if [[ ${#versiones[@]} -eq 0 ]]; then
            aputs_error "No se encontraron versiones de ${paquete} en los repos habilitados"
            aputs_info  "Verifique: dnf repolist"
            pause
            return
        fi

        echo "  Versiones disponibles:"
        echo ""
        local i=1
        for v in "${versiones[@]}"; do
            local vdir="${basedir}/${v}"
            local estado=""
            if [[ -d "$vdir" ]] && find "$vdir" -name "*.rpm" -quit 2>/dev/null | grep -q .; then
                estado="  [descargada]"
            fi
            printf "  %2d) %s%s\n" "$i" "$v" "$estado"
            i=$(( i + 1 ))
        done

        echo ""
        echo "  a) Descargar TODAS las versiones"
        echo "  0) Volver"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            0) return ;;
            a|A)
                echo ""
                for v in "${versiones[@]}"; do
                    local vdir="${basedir}/${v}"
                    draw_line
                    aputs_info "Version: ${v}"
                    _repo_descargar_version "$paquete" "$v" "$vdir"
                    echo ""
                done
                _repo_fix_permisos "$basedir"
                pause
                ;;
            *)
                if [[ "$op" =~ ^[0-9]+$ ]] && [[ "$op" -ge 1 && "$op" -le "${#versiones[@]}" ]]; then
                    local version_sel="${versiones[$((op-1))]}"
                    local vdir="${basedir}/${version_sel}"
                    echo ""
                    draw_line
                    _repo_descargar_version "$paquete" "$version_sel" "$vdir"
                    _repo_fix_permisos "$basedir"
                    pause
                else
                    aputs_error "Opcion invalida"
                    sleep 1
                fi
                ;;
        esac
    done
}

_repo_fix_permisos() {
    local dir="$1"
    chown -R "${SSL_FTP_USER}:${SSL_FTP_USER}" "$dir" 2>/dev/null || true
    chmod -R 755 "$dir" 2>/dev/null || true
    if command -v restorecon &>/dev/null; then
        restorecon -Rv "$dir" &>/dev/null
    fi
}

# ------------------------------------------------------------
# Descargar todos los servicios (version actual de cada uno)
# ------------------------------------------------------------

ssl_repo_descargar_todos() {
    echo ""
    aputs_info "Descargando version actual de todos los servicios..."
    echo ""

    local ok=0 fail=0

    for entrada in "httpd:Apache:${SSL_REPO_APACHE}" "nginx:Nginx:${SSL_REPO_NGINX}" "tomcat:Tomcat:${SSL_REPO_TOMCAT}"; do
        local pkg="${entrada%%:*}"
        local resto="${entrada#*:}"
        local nombre="${resto%%:*}"
        local basedir="${resto##*:}"

        draw_line
        aputs_info "Consultando version actual de ${nombre} (${pkg})..."

        local version
        version=$(_repo_listar_versiones_dnf "$pkg" | tail -1)

        if [[ -z "$version" ]]; then
            aputs_error "${pkg} no encontrado en repos"
            fail=$(( fail + 1 ))
            echo ""
            continue
        fi

        aputs_info "Version: ${version}"
        echo ""

        local vdir="${basedir}/${version}"
        if _repo_descargar_version "$pkg" "$version" "$vdir"; then
            _repo_fix_permisos "$basedir"
            ok=$(( ok + 1 ))
        else
            fail=$(( fail + 1 ))
        fi
        echo ""
    done

    draw_line
    echo ""
    aputs_success "Descarga completada: ${ok} exitosa(s), ${fail} fallida(s)"
}

# ------------------------------------------------------------
# Verificar integridad SHA256
# ------------------------------------------------------------

ssl_repo_verificar_integridad() {
    echo ""
    aputs_info "Verificando integridad SHA256 de los RPMs..."
    echo ""

    local errores=0

    for subdir in Apache Nginx Tomcat; do
        local base="${SSL_REPO_LINUX}/${subdir}"
        [[ -d "$base" ]] || continue

        printf "  %s:\n" "$subdir"

        # Iterar subdirectorios de version
        local hay_versiones=false
        while IFS= read -r vdir; do
            hay_versiones=true
            local version
            version=$(basename "$vdir")
            local sumsfile="${vdir}/SHA256SUMS"

            printf "    Version %s:\n" "$version"

            if [[ ! -f "$sumsfile" ]]; then
                printf "      [--] Sin SHA256SUMS\n"
                continue
            fi

            while IFS= read -r linea; do
                local hash basename_rpm actual_path actual_hash
                hash="${linea%% *}"
                basename_rpm=$(basename "${linea##* }")
                actual_path="${vdir}/${basename_rpm}"

                if [[ ! -f "$actual_path" ]]; then
                    printf "      [NO] %s -- no encontrado\n" "$basename_rpm"
                    errores=$(( errores + 1 ))
                    continue
                fi

                actual_hash=$(sha256sum "$actual_path" | awk '{print $1}')
                if [[ "$actual_hash" == "$hash" ]]; then
                    printf "      [OK] %s\n" "$basename_rpm"
                else
                    printf "      [NO] %s -- hash no coincide\n" "$basename_rpm"
                    errores=$(( errores + 1 ))
                fi
            done < "$sumsfile"
        done < <(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

        if ! $hay_versiones; then
            printf "    [--] Sin versiones descargadas\n"
        fi
        echo ""
    done

    if [[ "$errores" -eq 0 ]]; then
        aputs_success "Todos los archivos son integros"
    else
        aputs_error "${errores} archivo(s) con problemas de integridad"
    fi
}

# ------------------------------------------------------------
# Menu del repositorio
# ------------------------------------------------------------

ssl_menu_repo() {
    while true; do
        clear
        ssl_mostrar_banner "Menu -- Repositorio FTP"
        ssl_repo_listar

        echo "  1) Crear estructura de directorios"
        echo "  2) Descargar version actual de todos"
        echo "  3) Apache  -- seleccionar version"
        echo "  4) Nginx   -- seleccionar version"
        echo "  5) Tomcat  -- seleccionar version"
        echo "  6) Verificar integridad SHA256"
        echo "  0) Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) echo ""; ssl_repo_crear_estructura;                                          pause ;;
            2) ssl_repo_descargar_todos;                                                    pause ;;
            3) _repo_menu_versiones "Apache" "httpd"  "${SSL_REPO_APACHE}" ;;
            4) _repo_menu_versiones "Nginx"  "nginx"  "${SSL_REPO_NGINX}"  ;;
            5) _repo_menu_versiones "Tomcat" "tomcat" "${SSL_REPO_TOMCAT}" ;;
            6) ssl_repo_verificar_integridad;                                               pause ;;
            0) return ;;
            *) aputs_error "Opcion invalida"; sleep 1 ;;
        esac
    done
}
