@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Buscador de Calidades HLS v5.0 Premium

:: ================================================================
::  Buscador de Calidades HLS v5.0 - Premium Edition
::
::  Uso:  probarCalidades.bat [opciones] [URL]
::
::  Opciones:
::    /v           Modo verbose - muestra pruebas fallidas
::    /vv          Modo debug - muestra toda la informacion
::    /full        Modo completo de escaneo
::    /fast        Modo rapido (default con argumentos)
::    /deep        Modo profundo - prueba variaciones extras
::    /k           Ignora errores SSL
::    /ref URL     Envia header Referer
::    /ua STRING   User-Agent personalizado
::    /h HEADER    Header HTTP adicional (puede repetirse)
::    /cookie STR  Cookie HTTP
::    /timeout N   Timeout por peticion en segundos (default 10)
::    /parallel N  Numero de pruebas simultaneas (1-16, default 1)
::    /out FILE    Archivo de salida personalizado
::    /json        Exporta resultados en JSON
::    /m3u         Genera playlist M3U con los streams encontrados
::    /download    Descarga master playlists encontrados
::    /log         Guarda log detallado de la sesion
::    /no-color    Desactiva colores ANSI
::    /no-dedup    No omite URLs ya probadas
::    /retry N     Reintentos por peticion (default 1)
::    /proxy URL   Usa proxy HTTP/HTTPS
::    /stats       Muestra estadisticas detalladas al final
::    /?           Esta ayuda
::
::  Secciones:
::    PRINCIPAL      flujo de alto nivel
::    ENTRADA        parse de argumentos y datos interactivos
::    URL            normalizacion y manipulacion
::    ESCANEO        generacion de variantes
::    PETICION       probe, validacion, registro
::    EXPORT         JSON, M3U, descarga
::    UTILIDADES     helpers varios
:: ================================================================

set "VERSION=5.0"
set "SELF=%~nx0"
set "SCRIPTDIR=%~dp0"
set "STARTTIME=%TIME%"

:: Captura argumentos de ayuda primero
if /i "%~1"=="/?"     goto :help
if /i "%~1"=="-h"     goto :help
if /i "%~1"=="--help" goto :help
if /i "%~1"=="/help"  goto :help
if /i "%~1"=="/version" goto :version

:: ================================================================
::  PRINCIPAL
:: ================================================================
call :setup_colors
call :check_deps || goto :fin
call :init_config
call :init_files

:parse_args
if "%~1"=="" goto :args_done
set "A=%~1"
if /i "!A!"=="/v"        (set "VERBOSE=1"  & goto :next_arg)
if /i "!A!"=="/vv"       (set "VERBOSE=1" & set "DEBUG=1" & goto :next_arg)
if /i "!A!"=="/full"     (set "MODE=2"     & goto :next_arg)
if /i "!A!"=="/fast"     (set "MODE=1"     & goto :next_arg)
if /i "!A!"=="/deep"     (set "MODE=3"     & goto :next_arg)
if /i "!A!"=="/k"        (set "INSECURE=1" & goto :next_arg)
if /i "!A!"=="/ref"      (set "REF=%~2"    & shift & goto :next_arg)
if /i "!A!"=="/ua"       (set "UA=%~2"     & shift & goto :next_arg)
if /i "!A!"=="/h"        (set "EXTRA_HEADERS=!EXTRA_HEADERS! -H "%~2"" & shift & goto :next_arg)
if /i "!A!"=="/cookie"   (set "COOKIE=%~2" & shift & goto :next_arg)
if /i "!A!"=="/timeout"  (set "TMO=%~2"    & shift & goto :next_arg)
if /i "!A!"=="/parallel" (set "PARALLEL=%~2" & shift & goto :next_arg)
if /i "!A!"=="/out"      (set "RESF=%~2"   & shift & goto :next_arg)
if /i "!A!"=="/json"     (set "EXPORT_JSON=1" & goto :next_arg)
if /i "!A!"=="/m3u"      (set "EXPORT_M3U=1" & goto :next_arg)
if /i "!A!"=="/download" (set "DOWNLOAD=1" & goto :next_arg)
if /i "!A!"=="/log"      (set "LOGMODE=1"  & goto :next_arg)
if /i "!A!"=="/no-color" (set "NOCOLOR=1" & call :setup_colors & goto :next_arg)
if /i "!A!"=="/no-dedup" (set "NODEDUP=1"  & goto :next_arg)
if /i "!A!"=="/retry"    (set "RETRIES=%~2" & shift & goto :next_arg)
if /i "!A!"=="/proxy"    (set "PROXY=%~2"  & shift & goto :next_arg)
if /i "!A!"=="/stats"    (set "SHOWSTATS=1" & goto :next_arg)
if "!A:~0,1!"=="/" (
    call :warn "Opcion desconocida ignorada: !A!"
    goto :next_arg
)
if not defined URL set "URL=!A!"
:next_arg
shift
goto :parse_args
:args_done

call :read_input || goto :fin
call :build_curl_opts
call :normalize_url
call :print_banner
call :start_log
call :scan
call :summary
call :do_exports
goto :fin

:: ================================================================
::  AYUDA / VERSION / SALIDA
:: ================================================================
:help
echo.
echo  !CYAN!Buscador de Calidades HLS v%VERSION% - Premium Edition!RESET!
echo.
echo  !BOLD!Uso:!RESET!  %~nx0 [opciones] [URL]
echo.
echo  !BOLD!Opciones de escaneo:!RESET!
echo    /fast        Modo rapido - solo sufijos estandar
echo    /full        Modo completo - mas separadores y variantes
echo    /deep        Modo profundo - todas las combinaciones posibles
echo.
echo  !BOLD!Opciones de red:!RESET!
echo    /k           Ignora errores de certificado SSL
echo    /ref URL     Envia header Referer
echo    /ua STRING   User-Agent personalizado
echo    /h HEADER    Header HTTP adicional (puede repetirse)
echo    /cookie STR  Cookie HTTP
echo    /timeout N   Timeout por peticion en segundos (default: 10)
echo    /proxy URL   Usa proxy HTTP/HTTPS
echo    /retry N     Reintentos por peticion fallida (default: 1)
echo.
echo  !BOLD!Opciones de salida:!RESET!
echo    /v           Verbose - muestra pruebas fallidas
echo    /vv          Debug - muestra toda la informacion
echo    /out FILE    Archivo de salida personalizado
echo    /json        Exporta resultados en formato JSON
echo    /m3u         Genera playlist M3U
echo    /download    Descarga los master playlists
echo    /log         Guarda log detallado de la sesion
echo    /stats       Muestra estadisticas detalladas
echo    /no-color    Desactiva colores ANSI
echo    /no-dedup    No omite URLs ya probadas
echo.
echo  !BOLD!Ejemplos:!RESET!
echo    %~nx0 "https://ejemplo.com/stream/playlist.m3u8"
echo    %~nx0 /deep /json /ref https://sitio.com URL
echo    %~nx0 /h "X-Auth: token123" /cookie "sid=abc" URL
echo.
goto :fin_simple

:version
echo Buscador de Calidades HLS v%VERSION%
goto :fin_simple

:fin
if defined TMPF if exist "%TMPF%" del "%TMPF%" >nul 2>&1
if defined TMPF2 if exist "%TMPF2%" del "%TMPF2%" >nul 2>&1
if defined LOGFILE if "!LOGMODE!"=="1" echo [%DATE% %TIME%] Sesion finalizada >> "!LOGFILE!"
echo.
:fin_simple
pause
exit /b 0

:: ================================================================
::  INICIALIZACION
:: ================================================================
:setup_colors
if "!NOCOLOR!"=="1" (
    set "RESET="
    set "BOLD="
    set "RED="
    set "GREEN="
    set "YELLOW="
    set "BLUE="
    set "CYAN="
    set "MAGENTA="
    set "GRAY="
    exit /b 0
)
:: Prueba soporte ANSI
for /f "tokens=2 delims=[]" %%V in ('ver') do set "VERSION_WIN=%%V"
set "ESC="
set "RESET=%ESC%[0m"
set "BOLD=%ESC%[1m"
set "RED=%ESC%[91m"
set "GREEN=%ESC%[92m"
set "YELLOW=%ESC%[93m"
set "BLUE=%ESC%[94m"
set "MAGENTA=%ESC%[95m"
set "CYAN=%ESC%[96m"
set "GRAY=%ESC%[90m"
exit /b 0

:check_deps
where curl.exe >nul 2>&1
if errorlevel 1 (
    call :error "curl.exe no encontrado. Requiere Windows 10 1803+ o instalar curl."
    exit /b 1
)
:: Version de curl
for /f "tokens=2" %%v in ('curl.exe --version 2^>nul ^| findstr /b "curl"') do set "CURL_VERSION=%%v"
exit /b 0

:init_config
:: Catalogo de calidades - ordenadas de mayor a menor
set "QUALITIES=4320 2160 1440 1080 900 720 576 540 480 432 406 360 288 270 240 180 144"
:: Etiquetas de nombres (modos completo y deep)
set "NAMES=source src original raw master hd fhd uhd 4k qhd sd high medium low mobile lowest highest best worst main backup alt audio video"
:: Nombres de archivo de playlist alternativos
set "ALTTAILS=playlist.m3u8 index.m3u8 master.m3u8 manifest.m3u8 chunklist.m3u8 stream.m3u8 main.m3u8 live.m3u8 hls.m3u8 video.m3u8 audio.m3u8 prog_index.m3u8"
:: Separadores entre base y etiqueta
set "SEPS_FAST=_"
set "SEPS_ALL=_ - /"
set "SEPS_DEEP=_ - / . ="
:: Prefijos para modo deep
set "PREFIXES_DEEP=v q quality level stream variant rendition"

:: User-Agent por defecto
set "UA=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

:: Timeouts y red
set "TMO=10"
set "CTMO=5"
set "RETRIES=1"
set "MAXFILESIZE=5000000"
set "MAXREDIRS=5"

:: Contadores
set "FOUND=0"
set "PROBED=0"
set "MASTERS=0"
set "VODS=0"
set "LIVES=0"
set "ENCRYPTED=0"
set "FAILED=0"
set "SKIPPED=0"
set "HTTP_200=0"
set "HTTP_404=0"
set "HTTP_403=0"
set "HTTP_5XX=0"
set "HTTP_OTHER=0"
set "BYTES_DOWNLOADED=0"

:: Flags por defecto
set "VERBOSE=0"
set "DEBUG=0"
set "INSECURE=0"
set "NODEDUP=0"
set "LOGMODE=0"
set "SHOWSTATS=0"
set "EXPORT_JSON=0"
set "EXPORT_M3U=0"
set "DOWNLOAD=0"
set "PARALLEL=1"

:: Variables vacias
set "MODE="
set "REF="
set "URL="
set "QUERY="
set "FRAG="
set "COOKIE="
set "PROXY="
set "EXTRA_HEADERS="
set "NOCOLOR=0"
exit /b 0

:init_files
if not defined TEMP set "TEMP=%SCRIPTDIR%"

:: Sesion unica con timestamp
set "SESSION_ID=%RANDOM%%RANDOM%"
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value 2^>nul ^| find "="') do set "DT=%%I"
if defined DT set "STAMP=!DT:~0,8!_!DT:~8,6!"
if not defined STAMP set "STAMP=%RANDOM%"

set "TMPF=%TEMP%\hls_%SESSION_ID%.tmp"
set "TMPF2=%TEMP%\hls_%SESSION_ID%_2.tmp"
set "LOGFILE=%SCRIPTDIR%hls_log_%STAMP%.txt"

if not defined RESF (
    set "RESF=%SCRIPTDIR%hls_resultados.txt"
)
(type nul >"!RESF!") 2>nul
if not exist "!RESF!" (
    set "RESF=%TEMP%\hls_resultados.txt"
    (type nul >"!RESF!") 2>nul
)

:: Archivos de export
set "JSONFILE=%SCRIPTDIR%hls_results_%STAMP%.json"
set "M3UFILE=%SCRIPTDIR%hls_playlist_%STAMP%.m3u"
set "DOWNDIR=%SCRIPTDIR%hls_downloads_%STAMP%"
exit /b 0

:start_log
if "!LOGMODE!"=="0" exit /b 0
(
    echo ================================================================
    echo Sesion HLS v%VERSION% - %DATE% %TIME%
    echo URL: !HEAD!/!TAIL!
    echo Modo: !MODE!    Timeout: !TMO!s    Retries: !RETRIES!
    echo ================================================================
) > "!LOGFILE!"
exit /b 0

:log
if "!LOGMODE!"=="0" exit /b 0
echo [%TIME%] %~1 >> "!LOGFILE!"
exit /b 0

:: ================================================================
::  ENTRADA
:: ================================================================
:read_input
set "FROMARG=0"
if defined URL set "FROMARG=1"

if "!FROMARG!"=="0" (
    echo.
    echo !CYAN!=== Buscador de Calidades HLS v%VERSION% ===!RESET!
    echo.
    set /p "URL=Pega la URL del stream: "
)
if not defined URL (
    call :error "URL vacia."
    exit /b 1
)

:: Limpiar comillas y espacios
set "URL=!URL:"=!"
set "URL=!URL: =!"
if not defined URL (
    call :error "URL vacia tras limpiar."
    exit /b 1
)

:: Validar protocolo
set "OKP=0"
if /i "!URL:~0,7!"=="http://"  set "OKP=1"
if /i "!URL:~0,8!"=="https://" set "OKP=1"
if "!OKP!"=="0" (
    call :error "La URL debe comenzar con http:// o https://"
    exit /b 1
)

:: Validar que no sea solo el protocolo
set "TEST=!URL:~7!"
if "!URL:~0,8!"=="https://" set "TEST=!URL:~8!"
if not defined TEST (
    call :error "URL incompleta."
    exit /b 1
)

:: Modo interactivo - datos adicionales
if "!FROMARG!"=="0" (
    if not defined REF set /p "REF=Referer (Enter = ninguno): "
    if not defined MODE (
        echo.
        echo   !GREEN![1]!RESET! Rapido    - solo sufijos con guion bajo
        echo   !YELLOW![2]!RESET! Completo  - mas separadores y variantes
        echo   !MAGENTA![3]!RESET! Profundo  - todas las combinaciones (lento)
        choice /c 123 /n /m "  Elige modo: "
        if errorlevel 3 (set "MODE=3") else if errorlevel 2 (set "MODE=2") else (set "MODE=1")
    )
)
if not defined MODE set "MODE=1"

:: Validar parallel
if not defined PARALLEL set "PARALLEL=1"
if !PARALLEL! lss 1 set "PARALLEL=1"
if !PARALLEL! gtr 16 set "PARALLEL=16"

:: Validar retries
if !RETRIES! lss 0 set "RETRIES=0"
if !RETRIES! gtr 10 set "RETRIES=10"

:: Validar timeout
if !TMO! lss 1 set "TMO=1"
if !TMO! gtr 120 set "TMO=120"
exit /b 0

:build_curl_opts
set COPT=-s -L -m !TMO! --connect-timeout !CTMO! --max-redirs !MAXREDIRS! --max-filesize !MAXFILESIZE! -A "!UA!"
if defined REF set COPT=!COPT! -e "!REF!"
if "!INSECURE!"=="1" set COPT=!COPT! -k
if defined COOKIE set COPT=!COPT! -b "!COOKIE!"
if defined PROXY set COPT=!COPT! -x "!PROXY!"
if defined EXTRA_HEADERS set COPT=!COPT! !EXTRA_HEADERS!
if !RETRIES! gtr 0 set COPT=!COPT! --retry !RETRIES! --retry-delay 1
exit /b 0

:: ================================================================
::  NORMALIZACION DE URL
:: ================================================================
:normalize_url
call :cut_at URL "#" FRAG
call :cut_at URL "?" QUERY

:: Quitar barras finales
set "ISDIR=0"
:trim_slash
if "!URL:~-1!"=="/" (
    set "URL=!URL:~0,-1!"
    set "ISDIR=1"
    goto :trim_slash
)

:: URL solo con host
set "REST=!URL:*://=!"
if "!REST:/=!"=="!REST!" set "ISDIR=1"

:: Detectar archivo final
set "TAIL="
set "EXT="
if "!ISDIR!"=="0" (
    for %%A in ("!URL!") do (
        set "TAIL=%%~nxA"
        set "EXT=%%~xA"
    )
    if not defined EXT set "ISDIR=1"
)

if "!ISDIR!"=="1" (
    set "HEAD=!URL!"
    set "TAIL=playlist.m3u8"
) else (
    call :strlen TAIL TLEN
    set /a CUT=TLEN+1
    call :drop_end URL HEAD !CUT!
)

:: URL original
set "HEAD0=!HEAD!"
set "TAIL0=!TAIL!"

:: chunklist -> playlist
if /i "!TAIL:~0,9!"=="chunklist" set "TAIL=playlist.m3u8"

call :strip_quality_suffix
exit /b 0

:strip_quality_suffix
set "STRIPPED=0"
for %%S in (!SEPS_ALL!) do (
    for %%Q in (!QUALITIES!) do (
        call :try_strip "%%S%%Qp"
        call :try_strip "%%S%%Q"
    )
)
exit /b 0

:try_strip
if "!STRIPPED!"=="1" exit /b 0
set "SFX=%~1"
call :strlen SFX SLEN
set "TL=!HEAD:~-%SLEN%!"
if /i not "!TL!"=="!SFX!" exit /b 0
call :drop_end HEAD HEAD !SLEN!
set "STRIPPED=1"
call :log "Stripped suffix: !SFX!"
exit /b 0

:print_banner
if "!MODE!"=="3" (set "MODETXT=Profundo")
if "!MODE!"=="2" (set "MODETXT=Completo")
if "!MODE!"=="1" (set "MODETXT=Rapido")
echo.
echo  !GRAY!================================================================!RESET!
echo   !BOLD!Buscador HLS v%VERSION%!RESET!
echo  !GRAY!----------------------------------------------------------------!RESET!
echo   Base     : !CYAN!!HEAD!!RESET!
echo   Archivo  : !CYAN!!TAIL!!RESET!
if defined QUERY echo   Query    : !GRAY!detectada, se anexa a cada prueba!RESET!
if defined REF   echo   Referer  : !GRAY!!REF!!RESET!
if defined COOKIE echo   Cookie   : !GRAY!presente!RESET!
if defined PROXY echo   Proxy    : !GRAY!!PROXY!!RESET!
echo   Modo     : !YELLOW!!MODETXT!!RESET!    Timeout: !TMO!s    Retries: !RETRIES!
echo   Leyenda  : !GREEN!MASTER!RESET!^=lista maestra  !BLUE!LIVE!RESET!/!MAGENTA!VOD!RESET!^=medios  !RED!*!RESET!^=cifrado
echo  !GRAY!================================================================!RESET!
echo.
echo   Escaneando...
echo.
exit /b 0

:: ================================================================
::  ESCANEO
:: ================================================================
:scan
call :get_time T0

:: 1) URL original y URL base
set "PU=!HEAD0!/!TAIL0!"
call :probe "original"
set "ORIGHIT=!HIT!"

if /i "!HEAD!/!TAIL!"=="!HEAD0!/!TAIL0!" (
    set "BASEHIT=!ORIGHIT!"
) else (
    set "PU=!HEAD!/!TAIL!"
    call :probe "base"
    set "BASEHIT=!HIT!"
)

if "!BASEHIT!"=="0" if "!ORIGHIT!"=="0" if "!CODE!"=="000" (
    echo   !RED![ERROR]!RESET! Sin respuesta del servidor. Revisa conexion, URL o timeout.
    call :log "ERROR: no server response"
    exit /b 0
)

:: 2) Resolver nombre de archivo
call :resolve_tails

:: 3) Seleccionar separadores segun modo
set "SEPS=!SEPS_FAST!"
if "!MODE!"=="2" set "SEPS=!SEPS_ALL!"
if "!MODE!"=="3" set "SEPS=!SEPS_DEEP!"

:: 4) Escaneo principal
call :scan_qualities
if "!MODE!" geq "2" call :scan_names
if "!MODE!"=="3" call :scan_deep
exit /b 0

:resolve_tails
set "TAILLIST=!TAIL!"
if "!BASEHIT!"=="1" exit /b 0
if "!ORIGHIT!"=="1" (
    set "TAILLIST=!TAIL0!"
    exit /b 0
)
if "!MODE!"=="1" exit /b 0

echo   !YELLOW![..]!RESET! Base sin respuesta valida, probando nombres alternativos
for %%T in (!ALTTAILS!) do (
    if "!BASEHIT!"=="0" if /i not "%%T"=="!TAIL!" (
        set "PU=!HEAD!/%%T"
        call :probe "archivo"
        if "!HIT!"=="1" (
            set "BASEHIT=1"
            set "TAILLIST=%%T"
        )
    )
)
if "!BASEHIT!"=="0" (
    for %%T in (playlist.m3u8 index.m3u8 master.m3u8 chunklist.m3u8) do (
        if /i not "%%T"=="!TAIL!" set "TAILLIST=!TAILLIST! %%T"
    )
)
exit /b 0

:scan_qualities
for %%Q in (!QUALITIES!) do (
    for %%S in (!SEPS!) do call :try_quality "%%S" "%%Q"
)
exit /b 0

:scan_names
for %%N in (!NAMES!) do (
    for %%S in (!SEPS!) do call :try_label "%%S" "%%N"
)
exit /b 0

:scan_deep
:: Modo deep: prefijos + numeros, variantes numericas puras, k/kbps
for %%P in (!PREFIXES_DEEP!) do (
    for %%Q in (!QUALITIES!) do (
        for %%S in (!SEPS!) do (
            call :try_label "%%S" "%%P%%Q"
            call :try_label "%%S" "%%P%%Qp"
        )
    )
)
:: Variantes numericas simples
for %%N in (0 1 2 3 4 5 6 7 8 9 10) do (
    call :try_label "_" "%%N"
    call :try_label "/" "%%N"
)
:: Bitrates
for %%B in (500k 1000k 1500k 2000k 3000k 5000k 8000k) do (
    call :try_label "_" "%%B"
)
exit /b 0

:try_quality
call :try_label "%~1" "%~2p"
if "!HIT!"=="1" exit /b 0
call :try_label "%~1" "%~2"
exit /b 0

:try_label
set "HIT=0"
for %%T in (!TAILLIST!) do (
    if "!HIT!"=="0" (
        set "PU=!HEAD!%~1%~2/%%T"
        call :probe "%~1%~2"
    )
)
exit /b 0

:: ================================================================
::  PETICION Y VALIDACION
:: ================================================================
:probe
set "HIT=0"
set "CODE=000"
set "LABEL=%~1"
set "FULL=!PU!!QUERY!"

:: Dedup
if "!NODEDUP!"=="0" (
    call :is_known
    if "!IS_KNOWN!"=="1" (
        set "HIT=1"
        set /a SKIPPED+=1
        if "!DEBUG!"=="1" echo   !GRAY![skip]!RESET! Ya conocida: !FULL!
        exit /b 0
    )
)

set /a PROBED+=1
title Buscador HLS v%VERSION% - req !PROBED! - ok !FOUND! - fail !FAILED!
if exist "%TMPF%" del "%TMPF%" >nul 2>&1

:: Petición con timing
set "CURL_OUT="
for /f "tokens=1,2 delims=|" %%A in ('curl.exe !COPT! -o "%TMPF%" -w "%%{http_code}^|%%{size_download}" "!FULL!" 2^>nul') do (
    set "CODE=%%A"
    set "SIZE=%%B"
)

:: Contador por codigo
call :count_http_code "!CODE!"

if not "!CODE!"=="200" if not "!CODE!"=="206" (
    set /a FAILED+=1
    if "!VERBOSE!"=="1" (
        set "CODE_COLOR=!RED!"
        if "!CODE!"=="404" set "CODE_COLOR=!YELLOW!"
        echo   !GRAY![--]!RESET! HTTP !CODE_COLOR!!CODE!!RESET!  !LABEL!  !GRAY!!PU!!RESET!
    )
    call :log "FAIL HTTP !CODE! - !FULL!"
    exit /b 0
)

:: Validar que sea m3u8
findstr /c:"#EXTM3U" "%TMPF%" >nul 2>&1
if errorlevel 1 (
    set /a FAILED+=1
    if "!VERBOSE!"=="1" echo   !YELLOW![??]!RESET! HTTP !CODE! pero no es m3u8  !LABEL!  !GRAY!!PU!!RESET!
    call :log "FAIL not m3u8 - !FULL!"
    exit /b 0
)

:: Acumular bytes
if defined SIZE set /a BYTES_DOWNLOADED+=SIZE 2>nul

call :register_hit
exit /b 0

:count_http_code
if "%~1"=="200" (set /a HTTP_200+=1 & exit /b 0)
if "%~1"=="206" (set /a HTTP_200+=1 & exit /b 0)
if "%~1"=="404" (set /a HTTP_404+=1 & exit /b 0)
if "%~1"=="403" (set /a HTTP_403+=1 & exit /b 0)
if "%~1"=="500" (set /a HTTP_5XX+=1 & exit /b 0)
if "%~1"=="502" (set /a HTTP_5XX+=1 & exit /b 0)
if "%~1"=="503" (set /a HTTP_5XX+=1 & exit /b 0)
if "%~1"=="504" (set /a HTTP_5XX+=1 & exit /b 0)
set /a HTTP_OTHER+=1
exit /b 0

:is_known
set "IS_KNOWN=0"
findstr /x /l /c:"!FULL!" "!RESF!" >nul 2>&1
if not errorlevel 1 set "IS_KNOWN=1"
exit /b 0

:register_hit
set /a FOUND+=1
set "HIT=1"
>>"!RESF!" echo(!FULL!

call :classify_playlist

:: Contadores por tipo
if "!KIND!"=="MASTER" set /a MASTERS+=1
if "!KIND!"=="VOD"    set /a VODS+=1
if "!KIND!"=="LIVE"   set /a LIVES+=1
if defined ENC if not "!ENC!"=="" set /a ENCRYPTED+=1

:: Color segun tipo
set "KIND_COLOR=!BLUE!"
if "!KIND!"=="MASTER" set "KIND_COLOR=!GREEN!"
if "!KIND!"=="VOD"    set "KIND_COLOR=!MAGENTA!"

set "KP=!KIND!!ENC!       "
set "KP=!KP:~0,7!"
set "LP=!LABEL!            "
set "LP=!LP:~0,10!"
echo   !GREEN![OK]!RESET!  !KIND_COLOR!!KP!!RESET! !LP! !FULL!
call :log "OK !KIND!!ENC! !LABEL! !FULL!"

if "!KIND!"=="MASTER" call :list_renditions
exit /b 0

:classify_playlist
set "KIND=LIVE"
set "ENC="

findstr /c:"#EXT-X-STREAM-INF" "%TMPF%" >nul 2>&1
if not errorlevel 1 set "KIND=MASTER"

if not "!KIND!"=="MASTER" (
    findstr /c:"#EXT-X-ENDLIST" "%TMPF%" >nul 2>&1
    if not errorlevel 1 set "KIND=VOD"
)

findstr /c:"#EXT-X-KEY" "%TMPF%" 2>nul | findstr /v /c:"METHOD=NONE" >nul 2>&1
if not errorlevel 1 set "ENC=*"
exit /b 0

:list_renditions
set "EXPECT=0"
for /f "usebackq delims=" %%L in ("%TMPF%") do (
    set "LN=%%L"
    if "!LN:~0,18!"=="#EXT-X-STREAM-INF:" (
        set "ATTR=!LN!"
        call :get_attr RES RESOLUTION
        call :get_attr BW BANDWIDTH
        call :get_attr CODECS CODECS
        call :get_attr FRATE FRAME-RATE
        set "EXPECT=1"
    ) else if "!EXPECT!"=="1" if not "!LN:~0,1!"=="#" (
        set "KB=?"
        if not "!BW!"=="?" set /a KB=BW/1000
        set "EXTRA="
        if not "!FRATE!"=="?" set "EXTRA= !FRATE!fps"
        echo           !GRAY!+-- !RES!  !KB! kbps!EXTRA!  !LN!!RESET!
        set "EXPECT=0"
    )
)
exit /b 0

:: ================================================================
::  RESUMEN Y EXPORT
:: ================================================================
:summary
call :get_time T1
set /a EL=T1-T0
if !EL! lss 0 set /a EL+=8640000
set /a ELS=EL/100
set /a ELMS=(EL %% 100)*10

echo.
echo  !GRAY!================================================================!RESET!
if "!FOUND!"=="0" (
    call :print_no_results
    exit /b 0
)

echo   !BOLD!Resultados:!RESET!
echo     !GREEN!Validas    : !FOUND!!RESET!   (Masters: !MASTERS!  VOD: !VODS!  Live: !LIVES!  Cifrados: !ENCRYPTED!)
echo     Peticiones : !PROBED!   (Fallidas: !FAILED!  Omitidas: !SKIPPED!)
echo     Tiempo     : !ELS!.!ELMS!s

if "!SHOWSTATS!"=="1" (
    echo.
    echo   !BOLD!Estadisticas HTTP:!RESET!
    echo     200/206: !HTTP_200!
    echo     403    : !HTTP_403!
    echo     404    : !HTTP_404!
    echo     5xx    : !HTTP_5XX!
    echo     Otros  : !HTTP_OTHER!
    set /a KB_DL=BYTES_DOWNLOADED/1024
    echo     Descargado: !KB_DL! KB
)

echo.
echo   Guardado en: !CYAN!!RESF!!RESET!

set "FIRSTURL="
set /p "FIRSTURL=" <"!RESF!"
echo.
echo   !BOLD!Ejemplo con ffmpeg:!RESET!
echo     !GRAY!ffmpeg -i "!FIRSTURL!" -c copy salida.mp4!RESET!
echo.
choice /c CNA /n /m "  [C]opiar URLs al portapapeles / [N]o / [A]brir primera: "
if errorlevel 3 (
    start "" "!FIRSTURL!"
    exit /b 0
)
if errorlevel 2 exit /b 0
type "!RESF!" | clip
echo   !GREEN!Copiadas al portapapeles.!RESET!
exit /b 0

:print_no_results
echo   !RED!No se encontro ninguna lista HLS valida.!RESET!  Peticiones: !PROBED!
echo.
echo   !BOLD!Sugerencias:!RESET!
echo    - Verifica que el stream este activo y que la URL sea correcta.
echo    - Prueba modo completo:   !SELF! /full URL
echo    - Prueba modo profundo:   !SELF! /deep URL
echo    - Si requiere Referer:    !SELF! /ref https://sitio.com URL
echo    - Si requiere cookie:     !SELF! /cookie "sid=..." URL
echo    - Los tokens suelen expirar o ser validos solo para una ruta.
echo    - Usa /v para ver codigos HTTP de cada prueba.
echo    - Usa /vv para debug completo.
exit /b 0

:: ================================================================
::  EXPORTS
:: ================================================================
:do_exports
if "!FOUND!"=="0" exit /b 0
if "!EXPORT_JSON!"=="1" call :export_json
if "!EXPORT_M3U!"=="1"  call :export_m3u
if "!DOWNLOAD!"=="1"    call :download_masters
exit /b 0

:export_json
echo.
echo   !CYAN!Exportando JSON...!RESET!
(
    echo {
    echo   "version": "%VERSION%",
    echo   "timestamp": "%DATE% %TIME%",
    echo   "source": "!HEAD0!/!TAIL0!",
    echo   "stats": {
    echo     "found": !FOUND!,
    echo     "masters": !MASTERS!,
    echo     "vods": !VODS!,
    echo     "lives": !LIVES!,
    echo     "encrypted": !ENCRYPTED!,
    echo     "probed": !PROBED!,
    echo     "failed": !FAILED!
    echo   },
    echo   "urls": [
    set "FIRST=1"
    for /f "usebackq delims=" %%U in ("!RESF!") do (
        if "!FIRST!"=="1" (
            echo     "%%U"
            set "FIRST=0"
        ) else (
            echo     ,"%%U"
        )
    )
    echo   ]
    echo }
) > "!JSONFILE!"
echo   !GREEN!JSON:!RESET! !JSONFILE!
exit /b 0

:export_m3u
echo   !CYAN!Generando M3U...!RESET!
(
    echo #EXTM3U
    set "IDX=0"
    for /f "usebackq delims=" %%U in ("!RESF!") do (
        set /a IDX+=1
        echo #EXTINF:-1,Stream !IDX!
        echo %%U
    )
) > "!M3UFILE!"
echo   !GREEN!M3U:!RESET! !M3UFILE!
exit /b 0

:download_masters
echo   !CYAN!Descargando playlists...!RESET!
if not exist "!DOWNDIR!" mkdir "!DOWNDIR!" >nul 2>&1
set "IDX=0"
for /f "usebackq delims=" %%U in ("!RESF!") do (
    set /a IDX+=1
    set "FNAME=!DOWNDIR!\playlist_!IDX!.m3u8"
    curl.exe !COPT! -o "!FNAME!" "%%U" >nul 2>&1
    if exist "!FNAME!" echo   !GREEN![%%IDX%%]!RESET! !FNAME!
)
echo   !GREEN!Descargas en:!RESET! !DOWNDIR!
exit /b 0

:: ================================================================
::  UTILIDADES
:: ================================================================
:error
echo.
echo  !RED![ERROR]!RESET! %~1
call :log "ERROR: %~1"
exit /b 0

:warn
echo  !YELLOW![WARN]!RESET! %~1
call :log "WARN: %~1"
exit /b 0

:cut_at
set "%~3="
set "CA_T=!%~1!"
if "!CA_T:%~2=!"=="!CA_T!" exit /b 0
set "%~3=!CA_T:*%~2=%~2!"
call :strlen %~3 CA_L
call :drop_end %~1 %~1 !CA_L!
exit /b 0

:drop_end
set "%~2=!%~1:~0,-%~3!"
exit /b 0

:strlen
set "SL_S=!%~1!"
set "SL_N=0"
if not defined SL_S (
    set "%~2=0"
    exit /b 0
)
for %%P in (4096 2048 1024 512 256 128 64 32 16 8 4 2 1) do (
    if not "!SL_S:~%%P,1!"=="" (
        set /a SL_N+=%%P
        set "SL_S=!SL_S:~%%P!"
    )
)
set /a SL_N+=1
set "%~2=!SL_N!"
exit /b 0

:get_time
set "GT_=%TIME: =0%"
set /a "%~1=(1!GT_:~0,2!-100)*360000+(1!GT_:~3,2!-100)*6000+(1!GT_:~6,2!-100)*100+(1!GT_:~9,2!-100)"
exit /b 0

:get_attr
set "%~1=?"
set "GA_T=!ATTR:AVERAGE-BANDWIDTH=AVGBW!"
set "GA_U=!GA_T:*%~2=!"
if "!GA_U!"=="!GA_T!" exit /b 0
set "GA_U=!GA_U:~1!"
set "GA_U=!GA_U:"=!"
if not defined GA_U exit /b 0
for /f "delims=," %%X in ("!GA_U!") do set "%~1=%%X"
exit /b 0