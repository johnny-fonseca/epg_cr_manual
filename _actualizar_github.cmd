@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Actualizacion de GitHub

rem ==========================================================================
rem  ACTUALIZAR GITHUB - Lanzador robusto
rem
rem  Lanza _actualizar_github.ps1 (mismo directorio) despues de validar el
rem  entorno: PowerShell, Git, repositorio, remoto, bloqueos y conexion.
rem
rem  Uso:  _actualizar_github.cmd [/nopause] [/nolog] [/live] [/nonet]
rem                                [/dry] [/nopush] [/nosync] [/preferlocal]
rem                                [/novalidate] [/help]
rem
rem  Codigos de salida propios:
rem     0  Correcto
rem    10  No se encontro PowerShell
rem    11  No se encontro _actualizar_github.ps1
rem    12  Git no esta instalado o no esta en PATH
rem    13  La carpeta no es un repositorio Git
rem    14  El repositorio no tiene ningun remoto configurado
rem    15  Sin conexion con el remoto
rem    16  Bloqueo de Git: existe index.lock
rem    17  Hay un merge, rebase o cherry-pick sin terminar
rem    20  No se pudo acceder a la carpeta del script
rem
rem  Codigos devueltos por _actualizar_github.ps1:
rem     1  Error no clasificado
rem    30  Git no esta disponible para PowerShell
rem    31  La carpeta no es un repositorio Git utilizable
rem    32  El remoto indicado no existe
rem    33  Rama invalida o HEAD desacoplado
rem    34  Faltan archivos, estan en uso o su contenido no es valido
rem    35  user.name / user.email de Git sin configurar
rem    36  Repositorio bloqueado o con una operacion sin terminar
rem    37  Conflicto al integrar los cambios del remoto
rem    38  El push fallo (rechazado, bloqueado o error desconocido)
rem    39  Ya hay otra actualizacion en ejecucion
rem    40  Sin acceso al remoto (red o autenticacion)
rem ==========================================================================

rem ---------- Configuracion (ajustable) ----------
set "BASE_DIR=%~dp0"
set "SELF=%~nx0"
set "PS_SCRIPT=%BASE_DIR%_actualizar_github.ps1"
set "LOG_DIR=%BASE_DIR%logs"
set "LOG_KEEP=30"
set "NET_RETRIES=3"
set "NET_WAIT=3"

rem ---------- Estado interno ----------
set "NOPAUSE=0"
set "NOLOG=0"
set "LIVE=1"
set "NONET=0"
set "LOG_FILE="
set "PUSHED="
set "EXITCODE=0"
set "ATTEMPT=0"
set "REMOTE_NAME="
set "TS="
set "PS_ARGS="
set "PS_EXTRA="
set "RC=0"

rem ---------- Lectura de argumentos ----------
:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="/nopause" set "NOPAUSE=1" & goto :next_arg
if /i "%~1"=="/nolog"   set "NOLOG=1"   & goto :next_arg
if /i "%~1"=="/live"    set "LIVE=1"    & goto :next_arg
if /i "%~1"=="/nonet"   set "NONET=1"   & goto :next_arg
if /i "%~1"=="/dry"         set "PS_ARGS=%PS_ARGS% -Simular"        & goto :next_arg
if /i "%~1"=="/nopush"      set "PS_ARGS=%PS_ARGS% -SinSubir"       & goto :next_arg
if /i "%~1"=="/nosync"      set "PS_ARGS=%PS_ARGS% -SinSincronizar" & goto :next_arg
if /i "%~1"=="/preferlocal" set "PS_ARGS=%PS_ARGS% -PreferirLocal"  & goto :next_arg
if /i "%~1"=="/novalidate"  set "PS_ARGS=%PS_ARGS% -SinValidar"     & goto :next_arg
if /i "%~1"=="/help"    goto :show_help
if /i "%~1"=="/?"       goto :show_help
echo ADVERTENCIA: argumento desconocido: %~1
:next_arg
shift
goto :parse_args
:args_done

echo ============================================================
echo   ACTUALIZACION DE GITHUB
echo ============================================================
echo.

rem ---------- 1. Carpeta de trabajo (soporta rutas UNC) ----------
pushd "%BASE_DIR%" 2>nul
if errorlevel 1 goto :err_cwd
set "PUSHED=1"

rem ---------- 1b. Confianza temporal para Git ----------
rem Git puede ejecutar este script con una cuenta distinta al propietario de la
rem carpeta. Estas variables solo viven durante este proceso (setlocal).
set "GIT_CONFIG_COUNT=1"
set "GIT_CONFIG_KEY_0=safe.directory"
set "GIT_CONFIG_VALUE_0=%CD%"
call :log "safe.directory temporal: %CD%"

rem ---------- 2. PowerShell ----------
where powershell.exe >nul 2>&1
if not errorlevel 1 goto :ps_ok
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PATH=%SystemRoot%\System32\WindowsPowerShell\v1.0;%PATH%" & goto :ps_ok
goto :err_ps
:ps_ok

rem ---------- 3. Script de PowerShell ----------
if not exist "%PS_SCRIPT%" goto :err_noscript

rem ---------- 4. Marca de tiempo y archivo de log ----------
for /f "usebackq delims=" %%T in (`powershell.exe -NoLogo -NoProfile -NonInteractive -Command "Get-Date -Format yyyyMMdd_HHmmss"`) do set "TS=%%T"
if not defined TS set "TS=%RANDOM%%RANDOM%"

if "%NOLOG%"=="1" goto :log_ready
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
if not exist "%LOG_DIR%" goto :log_ready
set "LOG_FILE=%LOG_DIR%\actualizacion_%TS%.log"
type nul > "%LOG_FILE%" 2>nul
if not exist "%LOG_FILE%" set "LOG_FILE="
if not defined LOG_FILE goto :log_ready
rem Rotacion: conserva solo los LOG_KEEP logs mas recientes
for /f "skip=%LOG_KEEP% delims=" %%F in ('dir /b /o-d "%LOG_DIR%\actualizacion_*.log" 2^>nul') do del /q "%LOG_DIR%\%%F" >nul 2>&1
:log_ready

call :log "==== Inicio de actualizacion ===="
call :log "Carpeta: %CD%"
call :log "Usuario: %USERNAME%  Equipo: %COMPUTERNAME%"
if defined PS_ARGS call :log "Opciones para PowerShell:%PS_ARGS%"
if not defined LOG_FILE if "%NOLOG%"=="0" call :log "ADVERTENCIA: no se pudo crear el log, se continua sin el."

rem ---------- 5. Git ----------
where git.exe >nul 2>&1
if not errorlevel 1 goto :git_ok
set "GIT_TRY=%ProgramFiles%\Git\cmd"
if exist "%GIT_TRY%\git.exe" goto :git_alt
set "GIT_TRY=%LocalAppData%\Programs\Git\cmd"
if exist "%GIT_TRY%\git.exe" goto :git_alt
set "GIT_TRY=%ProgramFiles(x86)%\Git\cmd"
if exist "%GIT_TRY%\git.exe" goto :git_alt
goto :err_git
:git_alt
set "PATH=%GIT_TRY%;%PATH%"
call :log "Git encontrado fuera del PATH, se agrego temporalmente."
:git_ok
for /f "delims=" %%V in ('git --version 2^>nul') do call :log "%%V"

rem ---------- 6. Repositorio ----------
git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 goto :err_repo

set "GIT_DIR_PATH="
for /f "delims=" %%G in ('git rev-parse --git-dir 2^>nul') do set "GIT_DIR_PATH=%%G"
if not defined GIT_DIR_PATH goto :repo_state_ok
set "GIT_DIR_PATH=%GIT_DIR_PATH:/=\%"
if exist "%GIT_DIR_PATH%\index.lock"        goto :err_lock
if exist "%GIT_DIR_PATH%\rebase-merge"      goto :err_busy
if exist "%GIT_DIR_PATH%\rebase-apply"      goto :err_busy
if exist "%GIT_DIR_PATH%\MERGE_HEAD"        goto :err_busy
if exist "%GIT_DIR_PATH%\CHERRY_PICK_HEAD"  goto :err_busy
:repo_state_ok

rem ---------- 7. Remoto ----------
for /f "delims=" %%R in ('git remote 2^>nul') do if not defined REMOTE_NAME set "REMOTE_NAME=%%R"
if not defined REMOTE_NAME goto :err_remote
git config --get remote.origin.url >nul 2>&1
if not errorlevel 1 set "REMOTE_NAME=origin"
call :log "Remoto: %REMOTE_NAME%"

rem ---------- 8. Informacion de diagnostico ----------
set "BRANCH="
for /f "delims=" %%B in ('git rev-parse --abbrev-ref HEAD 2^>nul') do set "BRANCH=%%B"
if defined BRANCH call :log "Rama actual: %BRANCH%"
if /i "%BRANCH%"=="HEAD" call :log "ADVERTENCIA: HEAD desacoplado, no hay rama activa. La actualizacion se detendra."

set "GIT_USER="
for /f "delims=" %%U in ('git config user.name 2^>nul') do set "GIT_USER=%%U"
if not defined GIT_USER call :log "ADVERTENCIA: user.name de Git no esta configurado."
set "GIT_MAIL="
for /f "delims=" %%M in ('git config user.email 2^>nul') do set "GIT_MAIL=%%M"
if not defined GIT_MAIL call :log "ADVERTENCIA: user.email de Git no esta configurado."

set "HAS_CHANGES="
for /f "delims=" %%S in ('git status --porcelain 2^>nul') do set "HAS_CHANGES=1"
if defined HAS_CHANGES call :log "Hay cambios locales pendientes."
if not defined HAS_CHANGES call :log "No hay cambios locales pendientes."

rem ---------- 9. Conexion con el remoto (con reintentos) ----------
if "%NONET%"=="1" goto :net_ok
call :log "Comprobando conexion con el remoto..."
set "GIT_TERMINAL_PROMPT=0"
set "GIT_HTTP_LOW_SPEED_LIMIT=1000"
set "GIT_HTTP_LOW_SPEED_TIME=15"
set "NET_TRY=0"
:net_loop
set /a NET_TRY+=1
git ls-remote --heads "%REMOTE_NAME%" >nul 2>&1
if not errorlevel 1 goto :net_pass
if %NET_TRY% GEQ %NET_RETRIES% goto :err_net
call :log "Sin respuesta del remoto. Reintento %NET_TRY% de %NET_RETRIES% en %NET_WAIT% s..."
set /a PING_N=NET_WAIT+1
ping -n %PING_N% 127.0.0.1 >nul
goto :net_loop
:net_pass
set "GIT_TERMINAL_PROMPT="
set "GIT_HTTP_LOW_SPEED_LIMIT="
set "GIT_HTTP_LOW_SPEED_TIME="
call :log "Conexion con el remoto correcta."
:net_ok

rem ---------- 10. Ejecucion del script de PowerShell ----------
:run
set /a ATTEMPT+=1
call :get_secs T_START
call :log "Ejecutando _actualizar_github.ps1, intento %ATTEMPT%..."
echo.
set "PS_EXTRA="
if "%NOPAUSE%"=="1" set "PS_EXTRA= -SinPrompt"
if not defined LOG_FILE goto :run_live
if "%LIVE%"=="1" goto :run_live

:run_capture
rem En captura la salida no se ve: un aviso de credenciales dejaria el proceso colgado.
set "PS_EXTRA= -SinPrompt"
set "OUT_FILE=%TEMP%\gh_update_%TS%_%ATTEMPT%.tmp"
echo Procesando... la salida se mostrara al terminar. Use /live para verla en tiempo real.
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Remoto "%REMOTE_NAME%"%PS_ARGS%%PS_EXTRA% >"%OUT_FILE%" 2>&1
set "RC=%ERRORLEVEL%"
type "%OUT_FILE%"
>>"%LOG_FILE%" echo ---------------- salida del script ----------------
>>"%LOG_FILE%" type "%OUT_FILE%"
>>"%LOG_FILE%" echo ----------------------------------------------------
del /q "%OUT_FILE%" >nul 2>&1
goto :run_done

:run_live
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Remoto "%REMOTE_NAME%"%PS_ARGS%%PS_EXTRA%
set "RC=%ERRORLEVEL%"
if defined LOG_FILE call :log "Modo en vivo: la salida del script no se guarda en el log."

:run_done
call :get_secs T_END
set /a DURATION=T_END-T_START
if %DURATION% LSS 0 set /a DURATION+=86400
call :log "Codigo de salida del script: %RC%   Duracion: %DURATION% s"
if "%RC%"=="0" goto :success

rem ---------- Fallo: reintento opcional ----------
call :log "ERROR: la actualizacion termino con errores. Codigo: %RC%"
call :explain %RC%
set "EXITCODE=%RC%"
if "%NOPAUSE%"=="1" goto :finish
echo.
choice /c SN /n /m "Desea reintentar? (S/N): "
if errorlevel 2 goto :finish
goto :run

:success
call :log "Actualizacion completada correctamente."
set "EXITCODE=0"
goto :finish

rem ---------- Cierre ----------
:finish
call :log "==== Fin, codigo de salida %EXITCODE% ===="
if defined LOG_FILE call :log "Log guardado en: %LOG_FILE%"
echo.
if "%NOPAUSE%"=="0" pause
if defined PUSHED popd
endlocal & exit /b %EXITCODE%

rem ---------- Ayuda ----------
:show_help
echo.
echo Uso: %SELF% [opciones]
echo.
echo(  /nopause   No pausar al final ni preguntar por reintentos. Para tareas programadas.
echo(  /nolog     No crear archivo de log.
echo(  /live      Mostrar la salida del script en tiempo real (predeterminado). No se guarda en el log.
echo(  /nonet     Omitir la comprobacion de conexion con el remoto.
echo(  /dry       Simulacion: valida y muestra lo que se haria, sin cambiar nada.
echo(  /nopush    Crear el commit pero no subirlo.
echo(  /nosync    No consultar ni integrar los cambios del remoto antes de subir.
echo(  /preferlocal  Si hay conflicto con el remoto, gana la version local.
echo(  /novalidate   Omitir la validacion del contenido (XML y M3U).
echo(  /help      Mostrar esta ayuda.
echo.
echo Los logs se guardan en la carpeta logs, junto a este archivo.
echo Se conservan los %LOG_KEEP% mas recientes.
echo.
endlocal & exit /b 0

rem ---------- Errores ----------
:err_cwd
call :log "ERROR: no se pudo acceder a la carpeta del script."
set "EXITCODE=20"
goto :finish

:err_ps
call :log "ERROR: no se encontro Windows PowerShell, powershell.exe."
call :log "Verifique la instalacion de Windows o la variable PATH."
set "EXITCODE=10"
goto :finish

:err_noscript
call :log "ERROR: no se encontro el script: %PS_SCRIPT%"
call :log "Debe estar en la misma carpeta que este archivo."
set "EXITCODE=11"
goto :finish

:err_git
call :log "ERROR: Git no esta instalado o no esta en PATH."
call :log "Instale Git for Windows y vuelva a intentarlo."
set "EXITCODE=12"
goto :finish

:err_repo
call :log "ERROR: esta carpeta no es un repositorio Git, o Git no puede leerla."
call :log "Se aplico safe.directory temporalmente; revise la ruta y la propiedad de la carpeta."
set "EXITCODE=13"
goto :finish

:err_remote
call :log "ERROR: el repositorio no tiene ningun remoto configurado."
call :log "Agregue uno con: git remote add origin URL_DEL_REPOSITORIO"
set "EXITCODE=14"
goto :finish

:err_net
call :log "ERROR: no hay conexion con el remoto despues de %NET_RETRIES% intentos."
call :log "Revise su conexion a Internet, VPN, proxy o las credenciales de GitHub."
call :log "Use /nonet para omitir esta comprobacion."
set "EXITCODE=15"
goto :finish

:err_lock
call :log "ERROR: existe un bloqueo de Git: %GIT_DIR_PATH%\index.lock"
call :log "Otro proceso de Git podria estar en ejecucion. Si no es asi, borre ese archivo."
set "EXITCODE=16"
goto :finish

:err_busy
call :log "ERROR: hay un merge, rebase o cherry-pick sin terminar."
call :log "Termine o cancele esa operacion con git status y git merge --abort, git rebase --abort."
set "EXITCODE=17"
goto :finish

rem ==========================================================================
rem  SUBRUTINAS
rem ==========================================================================

rem :log "mensaje"  - escribe en pantalla y en el archivo de log, si existe
:log
setlocal EnableDelayedExpansion
set "MSG=%~1"
echo(!MSG!
if defined LOG_FILE >>"!LOG_FILE!" echo [!DATE! !TIME!] !MSG!
endlocal
exit /b 0

rem :explain CODIGO  - explica en el log el codigo de salida de PowerShell
:explain
if "%~1"=="30" call :log "Causa: Git no esta disponible para PowerShell."
if "%~1"=="31" call :log "Causa: la carpeta no es un repositorio Git utilizable."
if "%~1"=="32" call :log "Causa: el remoto indicado no existe en este repositorio."
if "%~1"=="33" call :log "Causa: rama invalida o HEAD desacoplado. Use git switch NOMBRE_DE_RAMA."
if "%~1"=="34" call :log "Causa: faltan archivos, estan en uso o su contenido no es valido. Vea el detalle arriba."
if "%~1"=="35" call :log "Causa: configure git config --global user.name y user.email."
if "%~1"=="36" call :log "Causa: repositorio bloqueado o con una operacion sin terminar."
if "%~1"=="37" call :log "Causa: conflicto con el remoto. Use /preferlocal para que gane su version."
if "%~1"=="38" call :log "Causa: el push fallo. El commit queda en local y se subira en la proxima ejecucion."
if "%~1"=="39" call :log "Causa: ya hay otra actualizacion en curso sobre este repositorio."
if "%~1"=="40" call :log "Causa: sin acceso al remoto (red, VPN, proxy o credenciales de GitHub)."
exit /b 0

rem :get_secs VARIABLE  - guarda en VARIABLE los segundos transcurridos del dia
:get_secs
set "_T=%TIME: =0%"
set /a "%~1=(1%_T:~0,2%-100)*3600+(1%_T:~3,2%-100)*60+(1%_T:~6,2%-100)"
exit /b 0
