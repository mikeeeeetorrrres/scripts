#!/bin/zsh
# mac_audit.sh (v2) - Reporte macOS: batería, discos, usuarios, FileVault, MDM, cifrado, OS, errores, apps + periféricos
# Recomendado ejecutar con sudo.

OUT=""
ERR_RANGE="24h"
INTERACTIVE_TESTS=0
INCLUDE_PKGUTIL=1   # 1=incluye lista de paquetes Apple (puede ser MUY larga). Cambia a 0 si lo quieres corto.

show_help() {
  cat << 'EOT'
Uso:
  ./mac_audit.sh [--output /ruta/reporte.txt] [--errors 24h] [--tests] [--no-pkgs]

Opciones:
  -o, --output    Ruta completa del archivo de salida (.txt)
  -e, --errors    Rango de logs para errores (ej: 6h, 24h, 48h, 7d)
  -t, --tests     Pruebas guiadas (S/N/NA) de periféricos/puertos
  --no-pkgs       No listar paquetes (pkgutil) para que el reporte pese menos
  -h, --help      Ayuda
EOT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) OUT="${2:-}"; shift 2 ;;
    -e|--errors) ERR_RANGE="${2:-24h}"; shift 2 ;;
    -t|--tests) INTERACTIVE_TESTS=1; shift 1 ;;
    --no-pkgs) INCLUDE_PKGUTIL=0; shift 1 ;;
    -h|--help) show_help; exit 0 ;;
    *) echo "Argumento no reconocido: $1"; show_help; exit 1 ;;
  esac
done

TS="$(date '+%Y-%m-%d_%H%M%S')"
[[ -z "$OUT" ]] && OUT="$HOME/Desktop/Mac_Audit_${TS}.txt"

mkdir -p "$(dirname "$OUT")" 2>/dev/null
: > "$OUT" || { echo "No puedo escribir en: $OUT"; exit 1; }

write(){ print -r -- "$*" >> "$OUT"; }
section(){
  write ""
  write "============================================================"
  write "$1"
  write "============================================================"
}
run(){
  local label="$1"; shift
  write ""
  write "--- $label"
  local out
  out="$("$@" 2>&1)"
  [[ -n "$out" ]] && write "$out" || write "(sin salida)"
}
prompt_bool(){
  local q="$1"
  local ans=""
  while true; do
    echo -n "$q (s/n/na): "
    read -r ans
    ans="${ans:l}"
    if [[ "$ans" == "s" || "$ans" == "si" ]]; then
      write "$q: SI"; break
    elif [[ "$ans" == "n" || "$ans" == "no" ]]; then
      write "$q: NO"; break
    elif [[ "$ans" == "na" ]]; then
      write "$q: N/A"; break
    else
      echo "Respuesta inválida. Usa: s / n / na"
    fi
  done
}

write "REPORTE DE AUDITORÍA macOS (v2)"
write "Generado: $(date)"
write "Usuario actual: $(whoami)"
write "Ejecución como root: $([[ $EUID -eq 0 ]] && echo 'SI' || echo 'NO (recomendado sudo)')"
write "Salida: $OUT"
write "Pruebas guiadas (--tests): $([[ $INTERACTIVE_TESTS -eq 1 ]] && echo 'SI' || echo 'NO')"
write "Rango errores (--errors): $ERR_RANGE"

# 1) Sistema
section "1) Sistema (OS / Hardware básico)"
run "macOS (sw_vers)" sw_vers
run "Kernel (uname -a)" uname -a
run "Software (system_profiler SPSoftwareDataType)" system_profiler SPSoftwareDataType
run "Hardware (system_profiler SPHardwareDataType)" system_profiler SPHardwareDataType

# 2) Batería
section "2) Batería"
run "Estado rápido (pmset -g batt)" pmset -g batt
run "Detalle (system_profiler SPPowerDataType)" system_profiler SPPowerDataType

# 3) Discos / SMART / Cifrado
section "3) Discos (Info / SMART / APFS / Cifrado)"
run "Listado de discos (diskutil list)" diskutil list
run "Info del volumen raíz / (diskutil info /)" diskutil info /
run "APFS (diskutil apfs list)" diskutil apfs list

write ""
write "--- SMART / Salud del almacenamiento (system_profiler)"
# NVMe / SATA (según el equipo, alguno aplica)
system_profiler SPNVMeDataType 2>/dev/null >> "$OUT" || true
system_profiler SPSerialATADataType 2>/dev/null >> "$OUT" || true
system_profiler SPStorageDataType 2>/dev/null >> "$OUT" || true

write ""
write "--- Info por discos físicos (diskutil info) + líneas SMART/Encryption/FileVault"
PHYS_DISKS="$(diskutil list physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+/ {print $1}')"
if [[ -z "$PHYS_DISKS" ]]; then
  # fallback
  PHYS_DISKS="$(diskutil list 2>/dev/null | awk '/^\/dev\/disk[0-9]+/ {print $1}' | sort -u)"
fi

for d in ${(f)PHYS_DISKS}; do
  write ""
  write ">> $d"
  diskutil info "$d" 2>&1 >> "$OUT"
  write "-- Extracto SMART/Encryption/FileVault:"
  diskutil info "$d" 2>/dev/null | egrep -i "SMART|Encrypted|Encryption|FileVault|APFS|Protocol|Internal|Solid State" >> "$OUT" || write "(sin extracto)"
done

# 4) Usuarios
section "4) Usuarios locales (admin vs estándar)"
write "Criterio: UID >= 501 y que no empiece con '_'"
USERS="$(dscl . list /Users UniqueID 2>/dev/null | awk '$2 >= 501 {print $1}' | grep -v '^_')"
if [[ -z "$USERS" ]]; then
  write "(No pude listar usuarios con dscl)"
else
  write ""
  write "Usuario | UID | Admin?"
  write "------------------------"
  for u in ${(f)USERS}; do
    uid="$(id -u "$u" 2>/dev/null || echo '?')"
    is_admin="NO"
    if dseditgroup -o checkmember -m "$u" admin 2>/dev/null | grep -qi "yes"; then
      is_admin="SI"
    fi
    write "$u | $uid | $is_admin"
  done
fi

# 5) FileVault
section "5) FileVault (Cifrado de disco)"
run "Estado (fdesetup status)" fdesetup status

write ""
write "--- Usuarios habilitados para FileVault (si es posible)"
if [[ $EUID -eq 0 ]]; then
  fdesetup list 2>&1 >> "$OUT" || write "(No se pudo ejecutar fdesetup list)"
else
  write "(Ejecuta con sudo para ver: fdesetup list)"
fi

# 6) MDM / Perfiles
section "6) MDM / Administración del dispositivo"
if command -v profiles >/dev/null 2>&1; then
  write "--- Enrollment (intento 1)"
  profiles status -type enrollment 2>&1 >> "$OUT" || write "(profiles status -type enrollment no disponible)"
  write ""
  write "--- Enrollment (intento 2)"
  profiles show -type enrollment 2>&1 >> "$OUT" || write "(profiles show -type enrollment no disponible)"
  write ""
  write "--- Perfiles instalados"
  profiles list 2>&1 >> "$OUT" || write "(profiles list no disponible)"
else
  write "(Comando 'profiles' no disponible en este macOS)"
fi

write ""
write "--- Indicadores comunes MDM (detección simple)"
[[ -x "/usr/local/jamf/bin/jamf" ]] && write "Jamf: DETECTADO (/usr/local/jamf/bin/jamf)" || write "Jamf: no detectado"
[[ -d "/Applications/Company Portal.app" ]] && write "Intune Company Portal: DETECTADO" || write "Intune Company Portal: no detectado"
[[ -d "/Applications/Jamf Connect.app" ]] && write "Jamf Connect: DETECTADO" || write "Jamf Connect: no detectado"

# 7) Periféricos / Puertos (detección)
section "7) Periféricos y puertos (detección)"
run "Cámaras (system_profiler SPCameraDataType)" system_profiler SPCameraDataType
run "Audio (system_profiler SPAudioDataType)" system_profiler SPAudioDataType
run "USB (system_profiler SPUSBDataType)" system_profiler SPUSBDataType
run "Thunderbolt (system_profiler SPThunderboltDataType)" system_profiler SPThunderboltDataType
run "Bluetooth (system_profiler SPBluetoothDataType)" system_profiler SPBluetoothDataType
run "Puertos de red (networksetup -listallhardwareports)" networksetup -listallhardwareports

write ""
write "--- Teclado/Trackpad (detección rápida ioreg, limitado)"
ioreg -l 2>/dev/null | egrep -i "Keyboard|Trackpad|Multitouch|EmbeddedKeyboard|EmbeddedTrackpad" | head -n 120 >> "$OUT" 2>/dev/null || write "(No se pudo extraer ioreg)"

# 8) Apps instaladas (sin find/sort raro)
section "8) Apps instaladas (GUI) - /Applications, /System/Applications, ~/Applications"
app_info() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local name ver build bid
  name="$(basename "$app" .app)"
  ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
  bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
  [[ -z "$ver" ]] && ver="?"
  [[ -z "$build" ]] && build="?"
  [[ -z "$bid" ]] && bid="?"
  write "$name | v$ver (build $build) | $bid"
}

list_apps_dir() {
  local dir="$1"
  write ""
  write "--- Directorio: $dir"
  if [[ ! -d "$dir" ]]; then
    write "(No existe)"
    return
  fi

  local apps=("$dir"/*.app(N))
  if (( ${#apps} == 0 )); then
    write "(Sin .app en primer nivel)"
    return
  fi

  for app in $apps; do
    app_info "$app"
  done
}

list_apps_dir "/Applications"
list_apps_dir "/System/Applications"
list_apps_dir "$HOME/Applications"

# 9) Programas/paquetes CLI
section "9) Programas/paquetes (Brew / pkgutil)"
if command -v brew >/dev/null 2>&1; then
  run "Brew - versión" brew --version
  run "Brew - lista (brew list --versions)" brew list --versions
else
  write "(Homebrew no detectado)"
fi

if [[ $INCLUDE_PKGUTIL -eq 1 ]]; then
  write ""
  write "--- Paquetes instalados por Installer (pkgutil --pkgs) - puede ser MUY largo"
  pkgutil --pkgs 2>/dev/null >> "$OUT" || write "(No se pudo ejecutar pkgutil --pkgs)"
else
  write ""
  write "(Se omitió pkgutil por --no-pkgs)"
fi

# 10) Errores / Diagnósticos
section "10) Errores y diagnósticos (resumen)"
write "--- DiagnosticReports /Library (top 15)"
if [[ -d "/Library/Logs/DiagnosticReports" ]]; then
  ls -t /Library/Logs/DiagnosticReports 2>/dev/null | head -n 15 >> "$OUT" || write "(No se pudo listar)"
else
  write "(No existe /Library/Logs/DiagnosticReports)"
fi

write ""
write "--- DiagnosticReports ~/Library (top 15)"
if [[ -d "$HOME/Library/Logs/DiagnosticReports" ]]; then
  ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | head -n 15 >> "$OUT" || write "(No se pudo listar)"
else
  write "(No existe ~/Library/Logs/DiagnosticReports)"
fi

write ""
write "--- Previous shutdown cause (últimos 7 días, top 30)"
log show --style syslog --predicate 'eventMessage contains[c] "Previous shutdown cause"' --last 7d 2>/dev/null | tail -n 30 >> "$OUT" || write "(No se pudo leer log show)"

write ""
write "--- Extracto logs 'error'/'panic' (últimos $ERR_RANGE, últimas 200 líneas)"
log show --style syslog --predicate '(eventMessage contains[c] "error" OR eventMessage contains[c] "panic")' --last "$ERR_RANGE" 2>/dev/null | tail -n 200 >> "$OUT" || write "(No se pudo leer log show)"

# 11) Pruebas guiadas
if [[ $INTERACTIVE_TESTS -eq 1 ]]; then
  section "11) Pruebas guiadas (manual) - Periféricos y puertos"
  echo ""
  echo "== PRUEBAS GUIADAS =="
  echo "Responde s/n/na. (Usa Photo Booth/QuickTime si hace falta)"
  echo ""

  write "Nota: Confirmación manual del técnico."
  prompt_bool "Webcam: Photo Booth/FaceTime muestra imagen"
  prompt_bool "Micrófono: QuickTime (grabación) capta voz"
  prompt_bool "Bocinas: reproduce audio y suena claro"
  prompt_bool "Jack 3.5mm (si aplica): audífonos funcionan"
  prompt_bool "Teclado: teclas básicas OK (Shift/Cmd/Option/flechas/delete)"
  prompt_bool "Trackpad: click/right click/scroll/zoom OK"
  prompt_bool "USB puerto A/B (si aplica): detecta memoria/mouse"
  prompt_bool "USB-C/Thunderbolt (si aplica): detecta dock/carga"
  prompt_bool "HDMI (si aplica): detecta monitor externo"
  prompt_bool "Wi-Fi: se conecta y navega"
  prompt_bool "Bluetooth: empareja y mantiene conexión"

  write ""
  write "Observaciones del técnico:"
  echo -n "Observaciones (opcional, enter para saltar): "
  read -r OBS
  [[ -z "$OBS" ]] && OBS="(sin observaciones)"
  write "$OBS"
fi

section "12) Fin del reporte"
write "OK - Reporte generado en: $OUT"
echo "Listo. Reporte creado en: $OUT"
