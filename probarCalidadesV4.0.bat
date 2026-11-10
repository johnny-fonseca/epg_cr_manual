@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Buscador de Calidades HLS v3.0

:: ================================================================
::  Buscador de Calidades HLS v3.0
::  Uso:  buscador_hls.bat [/v] [/full|/fast] [/k] [/ref URL] [URL]
::  Sin argumentos pide los datos de forma interactiva.
:: ================================================================

if /i "%~1"=="/?" goto :help
if /i "%~1"=="-h" goto :help
if /i "%~1"=="--help" goto :help

:: ================================================================
::  DEPENDENCIAS
:: ================================================================
where curl.exe >nul 2>&1
if errorlevel 1 (
    echo.
    echo  [ERROR] curl.exe no encontrado.
    echo          Requiere Windows 10 1803 o superior, o instalar curl.
    goto :fin
)

:: ================================================================
::  CONFIGURACION
:: ================================================================
set "QS=2160 1440 1080 720 576 540 480 432 360 288 240 144"
set "NAMES=source src hd sd high medium low mobile"
set "ALTTAILS=playlist.m3u8 index.m3u8 master.m3u8 manifest.m3u8 chunklist.m3u8 stream.m3u8 main.m3u8 live.m3u8 hls.m3u8"
set "UA=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
set "TMO=10"
set "CTMO=5"
set "FOUND=0"
set "PROBED=0"
set "MASTERS=0"
set "VERBOSE=0"
set "INSECURE=0"
set "MODE="
set "REF="
set "URL="

if not defined TEMP set "TEMP=%~dp0"
set "TMPF=%TEMP%\hls_%RANDOM%%RANDOM%.tmp"
set "RESF=%~dp0hls_resultados.txt"
(type nul >"%RESF%") 2>nul
if not exist "%RESF%" set "RESF=%TEMP%\hls_resultados.txt"
(type nul >"%RESF%") 2>nul

:: ================================================================
::  ARGUMENTOS
:: ================================================================
:args
if "%~1"=="" goto :argsdone
set "A=%~1"
if /i "!A!"=="/v"    (set "VERBOSE=1" & goto :argnext)
if /i "!A!"=="/full" (set "MODE=2" & goto :argnext)
if /i "!A!"=="/fast" (set "MODE=1" & goto :argnext)
if /i "!A!"=="/k"    (set "INSECURE=1" & goto :argnext)
if /i "!A!"=="/ref"  (set "REF=%~2" & shift & goto :argnext)
if "!A:~0,1!"=="/" (
    echo  [WARN] Opcion desconocida ignorada: !A!
    goto :argnext
)
if not defined URL set "URL=!A!"
:argnext
shift
goto :args
:argsdone

:: ================================================================
::  ENTRADA
:: ================================================================
set "FROMARG=0"
if defined URL set "FROMARG=1"

if "!FROMARG!"=="0" (
    echo.
    set /p "URL=Pega la URL del stream: "
)

if not defined URL (
    echo.
    echo  [ERROR] URL vacia.
    goto :fin
)

:: Limpiar comillas y espacios
set "URL=!URL:"=!"
set "URL=!URL: =!"
if not defined URL (
    echo.
    echo  [ERROR] URL vacia.
    goto :fin
)

:: Validar protocolo sin usar echo ni pipes ^(seguro con & en la URL^)
set "OKP=0"
if /i "!URL:~0,7!"=="http://"  set "OKP=1"
if /i "!URL:~0,8!"=="https://" set "OKP=1"
if "!OKP!"=="0" (
    echo.
    echo  [ERROR] La URL debe comenzar con http:// o https://
    goto :fin
)

if "!FROMARG!"=="0" (
    if not defined REF set /p "REF=Referer (Enter = ninguno): "
    if not defined MODE (
        echo.
        echo   [1] Rapido    sufijo con guion bajo, nombre de archivo detectado
        echo   [2] Completo  mas separadores, nombres de archivo y etiquetas
        choice /c 12 /n /m "  Elige modo 1 o 2: "
        if errorlevel 2 (set "MODE=2") else (set "MODE=1")
    )
)
if not defined MODE set "MODE=1"

:: Opciones de curl
set COPT=-s -L -m !TMO! --connect-timeout !CTMO! --max-redirs 5 --max-filesize 5000000 -A "!UA!"
if defined REF set COPT=!COPT! -e "!REF!"
if "!INSECURE!"=="1" set COPT=!COPT! -k

:: ================================================================
::  NORMALIZAR URL  ->  HEAD (directorio), TAIL (archivo), QUERY
:: ================================================================
call :cutat URL "#" FRAG
call :cutat URL "?" QUERY

set "ISDIR=0"
:trimslash
if "!URL:~-1!"=="/" (
    set "URL=!URL:~0,-1!"
    set "ISDIR=1"
    goto :trimslash
)

:: URL solo con host (sin ruta)
set "REST=!URL:*://=!"
if "!REST:/=!"=="!REST!" set "ISDIR=1"

set "TAIL="
set "EXT="
if "!ISDIR!"=="0" (
    for %%A in ("!URL!") do (
        set "TAIL=%%~nxA"
        set "EXT=%%~xA"
    )
    if not defined EXT set "ISDIR=1"
)

if "!ISDIR!"=="1" goto :dirmode
call :strlen TAIL TLEN
set /a CUT=TLEN+1
set "HEAD=!URL:~0,-%CUT%!"
goto :headdone
:dirmode
set "HEAD=!URL!"
set "TAIL=playlist.m3u8"
:headdone

:: Guardar la URL original tal cual
set "HEAD0=!HEAD!"
set "TAIL0=!TAIL!"

:: chunklist -> playlist
if /i "!TAIL:~0,9!"=="chunklist" set "TAIL=playlist.m3u8"

:: Quitar sufijo de calidad del directorio ^(_720p, -720, /720p, etc.^)
set "STRIPPED=0"
for %%S in (_ - /) do (
    for %%Q in (!QS!) do (
        call :trysuffix "%%S%%Qp"
        call :trysuffix "%%S%%Q"
    )
)

if "!MODE!"=="2" (set "MODETXT=Completo") else (set "MODETXT=Rapido")

echo.
echo  Base     : !HEAD!
echo  Archivo  : !TAIL!
if defined QUERY echo  Query    : detectada, se anexa a cada prueba
if defined REF   echo  Referer  : !REF!
echo  Modo     : !MODETXT!    Timeout: %TMO%s por peticion
echo  Leyenda  : MASTER = lista maestra, LIVE / VOD = lista de medios, * = cifrado
echo.
echo  Escaneando...
echo  --------------------------------------------------------------

call :gettime T0

:: ================================================================
::  1) URL ORIGINAL Y URL BASE
:: ================================================================
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
    echo   [ERROR] Sin respuesta del servidor. Revisa conexion, URL o timeout.
    goto :summary
)

:: ================================================================
::  2) NOMBRES DE ARCHIVO  ^(solo modo completo^)
:: ================================================================
set "TAILLIST=!TAIL!"
if "!BASEHIT!"=="0" if "!ORIGHIT!"=="1" set "TAILLIST=!TAIL0!"
if "!BASEHIT!"=="1" goto :scanstart
if "!ORIGHIT!"=="1" goto :scanstart
if "!MODE!"=="1" goto :scanstart

echo   [..]  Base sin respuesta valida, probando nombres de archivo alternativos
for %%T in (!ALTTAILS!) do (
    if /i not "%%T"=="!TAIL!" (
        if "!BASEHIT!"=="0" (
            set "PU=!HEAD!/%%T"
            call :probe "archivo"
            if "!HIT!"=="1" (
                set "BASEHIT=1"
                set "TAIL=%%T"
                set "TAILLIST=%%T"
            )
        )
    )
)
if "!BASEHIT!"=="0" (
    set "TAILLIST=!TAIL!"
    for %%T in (playlist.m3u8 index.m3u8 master.m3u8 chunklist.m3u8) do (
        if /i not "%%T"=="!TAIL!" set "TAILLIST=!TAILLIST! %%T"
    )
)

:: ================================================================
::  3) VARIANTES DE CALIDAD
:: ================================================================
:scanstart
set "SEPS=_"
if "!MODE!"=="2" set "SEPS=_ - /"

for %%Q in (!QS!) do (
    for %%S in (!SEPS!) do call :scanq "%%S" "%%Q"
)

if "!MODE!"=="2" (
    for %%N in (!NAMES!) do (
        for %%S in (!SEPS!) do call :tryone "%%S" "%%N"
    )
)

:: ================================================================
::  RESUMEN
:: ================================================================
:summary
call :gettime T1
set /a EL=T1-T0
if !EL! lss 0 set /a EL+=8640000
set /a ELS=EL/100

echo  --------------------------------------------------------------
if "!FOUND!"=="0" goto :nofound

echo   Validas: !FOUND!    Masters: !MASTERS!    Peticiones: !PROBED!    Tiempo: !ELS!s
echo   Lista guardada en: !RESF!
set "FIRSTURL="
set /p "FIRSTURL=" <"%RESF%"
echo.
echo   Ejemplo con la primera URL valida:
echo     ffmpeg -i "!FIRSTURL!" -c copy salida.mp4
echo.
choice /c CN /n /m "  Copiar todas las URLs al portapapeles? [C]opiar / [N]o: "
if errorlevel 2 goto :cleanup
type "%RESF%" | clip
echo   Copiadas.
goto :cleanup

:nofound
echo   No se encontro ninguna lista HLS valida. Peticiones: !PROBED!
echo.
echo   Sugerencias:
echo    - Verifica que el stream este activo y que la URL sea correcta.
echo    - Prueba el modo completo:  %~nx0 /full URL
echo    - Si el servidor exige Referer:  %~nx0 /ref https://sitio.com URL
echo    - Los tokens de la URL suelen ser validos solo para una ruta.
echo    - Usa /v para ver el codigo HTTP de cada prueba.

:cleanup
if exist "%TMPF%" del "%TMPF%" >nul 2>&1
goto :fin

:: ================================================================
::  SUBRUTINAS
:: ================================================================

:: ---- Ayuda ----------------------------------------------------
:help
echo.
echo  Buscador de Calidades HLS v3.0
echo.
echo  Uso:  %~nx0 [opciones] [URL]
echo.
echo    /v         Muestra tambien las pruebas fallidas
echo    /full      Modo completo: mas separadores, nombres de archivo y etiquetas
echo    /fast      Modo rapido
echo    /k         Ignora errores de certificado SSL
echo    /ref URL   Envia la cabecera Referer
echo    /?         Esta ayuda
echo.
echo  Con la URL entre comillas si contiene el caracter ampersand.
goto :fin

:: ---- probar variante con etiqueta, probando "720p" y luego "720" ----
:scanq
call :tryone "%~1" "%~2p"
if "!HIT!"=="1" exit /b
call :tryone "%~1" "%~2"
exit /b

:: ---- probar HEAD + sep + etiqueta + / + cada nombre de archivo ----
:tryone
set "HIT=0"
for %%T in (!TAILLIST!) do (
    if "!HIT!"=="0" (
        set "PU=!HEAD!%~1%~2/%%T"
        call :probe "%~1%~2"
    )
)
exit /b

:: ---- peticion + validacion de contenido ----
:probe
set /a PROBED+=1
title Buscador HLS - peticion !PROBED! - validas !FOUND!
set "HIT=0"
set "CODE=000"
set "LABEL=%~1"
if exist "%TMPF%" del "%TMPF%" >nul 2>&1

for /f %%A in ('curl.exe !COPT! -o "%TMPF%" -w "%%{http_code}" "!PU!!QUERY!" 2^>nul') do set "CODE=%%A"

if not "!CODE!"=="200" if not "!CODE!"=="206" goto :probe_fail

:: Debe ser realmente una lista m3u8 ^(evita falsos positivos tipo soft-404^)
findstr /c:"#EXTM3U" "%TMPF%" >nul 2>&1
if errorlevel 1 goto :probe_soft

set /a FOUND+=1
set "HIT=1"
>>"%RESF%" echo(!PU!!QUERY!

set "KP=LIVE"
findstr /c:"#EXT-X-STREAM-INF" "%TMPF%" >nul 2>&1 && set "KP=MASTER"
if not "!KP!"=="MASTER" (
    findstr /c:"#EXT-X-ENDLIST" "%TMPF%" >nul 2>&1 && set "KP=VOD"
)
set "ISMASTER=0"
if "!KP!"=="MASTER" set "ISMASTER=1"
findstr /c:"#EXT-X-KEY:METHOD=AES" "%TMPF%" >nul 2>&1 && set "KP=!KP!*"

set "KP=!KP!       "
set "KP=!KP:~0,7!"
set "LP=!LABEL!            "
set "LP=!LP:~0,10!"
echo   [OK]  !KP! !LP! !PU!!QUERY!

if "!ISMASTER!"=="1" call :listmaster
exit /b

:probe_fail
if "!VERBOSE!"=="1" echo   [--]  HTTP !CODE!  !LABEL!  !PU!
exit /b

:probe_soft
if "!VERBOSE!"=="1" echo   [??]  HTTP !CODE! pero no es una lista m3u8  !LABEL!  !PU!
exit /b

:: ---- listar renditions de un master playlist ----
:listmaster
set /a MASTERS+=1
set "EXPECT=0"
set "RV=?"
set "BV=?"
for /f "usebackq delims=" %%L in ("%TMPF%") do (
    set "LN=%%L"
    if "!LN:~0,18!"=="#EXT-X-STREAM-INF:" (
        set "ATTR=!LN!"
        call :getattr RV RESOLUTION
        call :getattr BV BANDWIDTH
        set "EXPECT=1"
    ) else if "!EXPECT!"=="1" (
        if not "!LN:~0,1!"=="#" (
            set "KB=?"
            if not "!BV!"=="?" set /a KB=BV/1000
            echo           +-- !RV!   !KB! kbps   !LN!
            set "EXPECT=0"
        )
    )
)
exit /b

:: ---- extraer atributo de una linea EXT-X-STREAM-INF ----
:getattr
set "%~1=?"
set "GA_T=!ATTR:AVERAGE-BANDWIDTH=AVGBW!"
set "GA_U=!GA_T:*%~2==!"
if "!GA_U!"=="!GA_T!" exit /b
set "GA_U=!GA_U:"=!"
if not defined GA_U exit /b
for /f "delims=," %%X in ("!GA_U!") do set "%~1=%%X"
exit /b

:: ---- quitar sufijo de calidad del final de HEAD ----
:trysuffix
if "!STRIPPED!"=="1" exit /b
set "SFX=%~1"
call :strlen SFX SLEN
set "TL=!HEAD:~-%SLEN%!"
if /i not "!TL!"=="!SFX!" exit /b
call :strlen HEAD HLEN
set /a KEEP=HLEN-SLEN
set "HEAD=!HEAD:~0,%KEEP%!"
set "STRIPPED=1"
exit /b

:: ---- cortar variable en la primera aparicion de un caracter ----
::      cutat VAR "caracter" VARRESTO   ->  VAR = antes, VARRESTO = caracter + resto
:cutat
set "%~3="
set "CA_T=!%~1!"
if "!CA_T:%~2=!"=="!CA_T!" exit /b
set "%~3=!CA_T:*%~2=%~2!"
call :strlen %~3 CA_L
set "%~1=!CA_T:~0,-%CA_L%!"
exit /b

:: ---- longitud de cadena ----
:strlen
set "SL_S=!%~1!"
set "SL_N=0"
if not defined SL_S goto :strlen_done
for %%P in (1024 512 256 128 64 32 16 8 4 2 1) do (
    if not "!SL_S:~%%P,1!"=="" (
        set /a SL_N+=%%P
        set "SL_S=!SL_S:~%%P!"
    )
)
set /a SL_N+=1
:strlen_done
set "%~2=!SL_N!"
exit /b

:: ---- hora actual en centesimas de segundo ----
:gettime
set "T_=%TIME: =0%"
set /a "%~1=(1!T_:~0,2!-100)*360000+(1!T_:~3,2!-100)*6000+(1!T_:~6,2!-100)*100+(1!T_:~9,2!-100)"
exit /b

:fin
echo.
pause
exit /b
