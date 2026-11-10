<#
.SYNOPSIS
    Sube a GitHub el EPG manual y la lista de canales de forma segura.

.DESCRIPTION
    Valida el entorno (Git, repositorio, remoto, rama, identidad), comprueba el
    contenido de los archivos (XML bien formado, M3U coherente, tamanos), crea un
    commit solo con esos archivos, integra los cambios del remoto si hace falta y
    sube con reintentos. Al final verifica que el remoto quedo en el mismo commit.

    Si un push anterior fallo, el commit pendiente se sube en la siguiente
    ejecucion aunque los archivos no hayan cambiado.

.PARAMETER Remoto
    Nombre del remoto. Por defecto: origin.

.PARAMETER Rama
    Rama a publicar. Por defecto: la rama actual. Si se indica otra, se cambia a
    ella (nunca se recrea ni se mueve una rama existente).

.PARAMETER Archivos
    Archivos a publicar (relativos a la carpeta del script).

.PARAMETER Mensaje
    Texto base del commit. Se le agrega la fecha y un resumen de los archivos.

.PARAMETER ArchivoLog
    Si se indica, ademas de la pantalla se escribe un log con marcas de tiempo.

.PARAMETER Reintentos
    Intentos ante fallos de red (1 a 10). Por defecto: 3.

.PARAMETER EsperaSegundos
    Espera base entre reintentos; se multiplica por el numero de intento.

.PARAMETER Simular
    No modifica nada: valida y muestra lo que se haria.

.PARAMETER SinSubir
    Crea el commit pero no hace push.

.PARAMETER SinSincronizar
    No consulta ni integra los cambios del remoto antes de subir.

.PARAMETER SinValidar
    Omite la validacion de contenido (XML/M3U). Las comprobaciones de existencia
    y tamano se mantienen.

.PARAMETER PreferirLocal
    Si al integrar cambios del remoto hay conflictos en los mismos archivos, gana
    la version local (rebase -X theirs). Sin este modificador se aborta con error.

.PARAMETER SinPrompt
    Nunca pide credenciales ni abre ventanas. Para tareas programadas.

.NOTES
    Codigos de salida:
       0  Correcto (o no habia nada que subir)
       1  Error no clasificado
      30  Git no esta disponible
      31  La carpeta no es un repositorio Git utilizable
      32  El remoto indicado no existe
      33  Rama invalida o HEAD desacoplado
      34  Faltan archivos, estan en uso o su contenido no es valido
      35  Identidad de Git (user.name / user.email) sin configurar
      36  Repositorio bloqueado o con una operacion sin terminar
      37  Conflicto al integrar los cambios del remoto
      38  El push fallo (rechazado, bloqueado o error desconocido)
      39  Ya hay otra instancia del script en ejecucion
      40  Sin acceso al remoto (red o autenticacion)
#>
[CmdletBinding()]
param(
    [string]$Remoto = 'origin',
    [string]$Rama = '',
    [string[]]$Archivos = @('epg_manual_cr.xml', 'tv_cr.m3u'),
    [string]$Mensaje = 'Actualizar EPG y lista de canales',
    [string]$ArchivoLog = '',
    [ValidateRange(1, 10)][int]$Reintentos = 3,
    [ValidateRange(0, 300)][int]$EsperaSegundos = 5,
    [switch]$Simular,
    [switch]$SinSubir,
    [switch]$SinSincronizar,
    [switch]$SinValidar,
    [switch]$PreferirLocal,
    [switch]$SinPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  Estado global y constantes
# ---------------------------------------------------------------------------
$script:Inicio       = Get-Date
$script:CodigoSalida = 0
$script:Bloqueo      = $null
$script:LogPs        = $ArchivoLog
$script:Paso         = 0
$script:Dir          = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:Dir)) {
    $script:Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$LIMITE_AVISO = 50MB     # GitHub avisa a partir de 50 MB
$LIMITE_MAXIMO = 100MB   # GitHub rechaza archivos de mas de 100 MB

# ---------------------------------------------------------------------------
#  Utilidades de salida y errores
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Texto = '',
        [string]$Nivel = 'INFO'
    )
    $color = 'White'
    $prefijo = ''
    switch ($Nivel) {
        'TITULO'  { $color = 'Cyan' }
        'PASO'    { $color = 'Cyan' }
        'OK'      { $color = 'Green' }
        'WARN'    { $color = 'Yellow'; $prefijo = 'ADVERTENCIA: ' }
        'ERROR'   { $color = 'Red'; $prefijo = 'ERROR: ' }
        'DETALLE' { $color = 'DarkGray' }
    }
    Write-Host ($prefijo + $Texto) -ForegroundColor $color

    if ($script:LogPs -ne '' -and $Texto -ne '') {
        try {
            $linea = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Texto
            Add-Content -LiteralPath $script:LogPs -Value $linea -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            $script:LogPs = ''
            Write-Host 'ADVERTENCIA: no se pudo escribir en el archivo de log; se continua sin el.' -ForegroundColor Yellow
        }
    }
}

function Write-Paso {
    param([string]$Texto)
    $script:Paso++
    Write-Log ''
    Write-Log ('[{0}] {1}' -f $script:Paso, $Texto) 'PASO'
}

# Lanza un error con codigo de salida propio y una ayuda opcional.
function Stop-Script {
    param(
        [Parameter(Mandatory)][int]$Codigo,
        [Parameter(Mandatory)][string]$Texto,
        [string]$Ayuda = ''
    )
    $ex = New-Object -TypeName System.Exception -ArgumentList $Texto
    $ex.Data['ExitCode'] = $Codigo
    $ex.Data['Ayuda'] = $Ayuda
    throw $ex
}

# Oculta usuario y token incrustados en URLs (https://usuario:token@host/...).
function Hide-Credenciales {
    param([string]$Texto)
    return ($Texto -replace '(?<=://)[^/@\s]+@', '***@')
}

function Format-Tamano {
    param([long]$Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} bytes' -f $Bytes)
}

# ---------------------------------------------------------------------------
#  Git
# ---------------------------------------------------------------------------

# Clasifica el texto de error de Git para decidir si tiene sentido reintentar.
function Get-TipoFalloGit {
    param([string]$Texto)
    if ($Texto -match '(?i)GH00\d|protected branch|pre-receive hook declined|exceeds github|file size limit|large files detected') { return 'bloqueado' }
    if ($Texto -match '(?i)authentication failed|could not read (username|password)|terminal prompts disabled|invalid username or password|permission denied|access denied|repository not found|returned error: 40[134]|password authentication was removed|bad credentials') { return 'auth' }
    if ($Texto -match '(?i)non-fast-forward|\[rejected\]|fetch first|updates were rejected|tip of your current branch is behind') { return 'rechazado' }
    if ($Texto -match '(?i)could not resolve host|timed out|timeout|connection (was )?(reset|refused|closed)|early eof|rpc failed|remote end hung up|network is unreachable|failed to connect|unable to access|\bssl\b|schannel|\btls\b|http/2|gnutls|operation too slow|transfer closed') { return 'red' }
    return 'desconocido'
}

# Ejecuta git capturando salida y codigo. Nunca deja que stderr (que Git usa
# para mensajes normales) se convierta en una excepcion de PowerShell.
function Invoke-Git {
    param(
        [Parameter(Mandatory)][string[]]$Argumentos,
        [switch]$PermitirFallo
    )
    # La confianza se aplica solo a esta invocacion; no modifica la
    # configuracion global ni la del repositorio. Esto permite ejecutar el
    # script aunque la cuenta actual no sea la propietaria de la carpeta.
    $argumentosGit = @('-c', ('safe.directory={0}' -f $script:Dir)) + $Argumentos
    Write-Verbose ('git ' + (Hide-Credenciales ($argumentosGit -join ' ')))

    $previo = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $salida = & git @argumentosGit 2>&1
        $codigo = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previo
    }

    $lineas = @()
    if ($null -ne $salida) {
        foreach ($item in @($salida)) {
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                $lineas += $item.ToString()
            }
            else {
                $lineas += [string]$item
            }
        }
    }

    $texto = $lineas -join "`n"
    $tipo = ''
    if ($codigo -ne 0) { $tipo = Get-TipoFalloGit $texto }

    $resultado = [pscustomobject]@{
        Ok     = ($codigo -eq 0)
        Codigo = $codigo
        Lineas = $lineas
        Texto  = $texto
        Tipo   = $tipo
    }

    if ($codigo -ne 0 -and -not $PermitirFallo) {
        $ultima = @($lineas | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1)
        $detalle = ''
        if ($ultima.Count -gt 0) { $detalle = ' -> ' + (Hide-Credenciales $ultima[0]) }
        Stop-Script 1 ('El comando git fallo (codigo {0}): git {1}{2}' -f $codigo, (Hide-Credenciales ($argumentosGit -join ' ')), $detalle)
    }
    return $resultado
}

# Igual que Invoke-Git -PermitirFallo, pero reintenta con espera creciente
# cuando el fallo parece ser de red.
function Invoke-GitConReintentos {
    param(
        [Parameter(Mandatory)][string[]]$Argumentos,
        [Parameter(Mandatory)][string]$Descripcion,
        [int]$Maximo = 3,
        [int]$Espera = 5
    )
    $intento = 0
    while ($true) {
        $intento++
        $r = Invoke-Git $Argumentos -PermitirFallo
        if ($r.Ok -or $r.Tipo -ne 'red' -or $intento -ge $Maximo) { return $r }
        $pausa = $Espera * $intento
        Write-Log ('{0}: sin respuesta (intento {1} de {2}). Reintentando en {3} s...' -f $Descripcion, $intento, $Maximo, $pausa) 'WARN'
        Start-Sleep -Seconds $pausa
    }
}

function Show-Salida {
    param($Resultado)
    foreach ($l in $Resultado.Lineas) {
        if ($l.Trim() -ne '') { Write-Log ('  git> ' + (Hide-Credenciales $l)) 'DETALLE' }
    }
}

# Localiza git; si no esta en PATH prueba las rutas de instalacion habituales.
function Find-Git {
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) { return $true }

    $candidatos = @()
    if ($env:ProgramFiles)        { $candidatos += (Join-Path $env:ProgramFiles 'Git\cmd') }
    if ($env:LOCALAPPDATA)        { $candidatos += (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd') }
    if (${env:ProgramFiles(x86)}) { $candidatos += (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd') }

    foreach ($c in $candidatos) {
        if (Test-Path -LiteralPath (Join-Path $c 'git.exe')) {
            $env:PATH = $c + [System.IO.Path]::PathSeparator + $env:PATH
            Write-Log 'Git encontrado fuera del PATH; se agrego temporalmente.' 'DETALLE'
            return $true
        }
    }
    return $false
}

# Commits locales sin subir (Adelante) y commits remotos sin traer (Atras).
function Get-AdelantoAtraso {
    param([string]$RemotoNombre, [string]$RamaNombre)
    $ref = "refs/remotes/$RemotoNombre/$RamaNombre"
    $r = Invoke-Git @('rev-parse', '--verify', '--quiet', $ref) -PermitirFallo
    if (-not $r.Ok) { return $null }
    $r = Invoke-Git @('rev-list', '--left-right', '--count', "HEAD...$ref") -PermitirFallo
    if (-not $r.Ok) { return $null }
    $p = @($r.Texto.Trim() -split '\s+')
    if ($p.Count -lt 2) { return $null }
    return [pscustomobject]@{ Adelante = [int]$p[0]; Atras = [int]$p[1] }
}

# Integra los cambios del remoto bajo los commits locales. Si hay conflicto
# deja el repositorio como estaba (rebase --abort) y falla con instrucciones.
function Invoke-Integracion {
    param([string]$RemotoNombre, [string]$RamaNombre, [bool]$GanaLocal)
    $parametros = @('rebase', '--autostash')
    if ($GanaLocal) { $parametros += @('-X', 'theirs') }
    $parametros += "refs/remotes/$RemotoNombre/$RamaNombre"

    if ($GanaLocal) {
        Write-Log 'Integrando cambios del remoto (rebase; ante conflictos gana la version local)...'
    }
    else {
        Write-Log 'Integrando cambios del remoto (rebase)...'
    }
    $r = Invoke-Git $parametros -PermitirFallo
    if (-not $r.Ok) {
        Show-Salida $r
        $null = Invoke-Git @('rebase', '--abort') -PermitirFallo
        Stop-Script 37 'Hay cambios en el remoto que entran en conflicto con los locales.' `
            'Se cancelo la integracion y todo quedo como estaba. Para que gane la version local use -PreferirLocal (en el .cmd: /preferlocal); si no, resuelva el conflicto a mano con git pull --rebase.'
    }
    if ($r.Texto -match 'resulted in conflicts') {
        Write-Log 'Al restaurar cambios locales sin commit hubo conflictos; estan guardados en git stash.' 'WARN'
    }
}

# ---------------------------------------------------------------------------
#  Validacion de archivos
# ---------------------------------------------------------------------------
function Test-ArchivoEnUso {
    param([string]$Ruta)
    try {
        $fs = [System.IO.File]::Open($Ruta, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $fs.Dispose()
        return $false
    }
    catch [System.IO.IOException] {
        return $true
    }
}

# XMLTV: comprueba que este bien formado (en streaming, sin cargarlo en memoria).
function Test-ContenidoXml {
    param([string]$Ruta, [string]$Nombre)

    $cfg = New-Object -TypeName System.Xml.XmlReaderSettings
    $cfg.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $flujo = $null
    $lector = $null
    $raiz = ''
    $canales = 0
    $programas = 0

    try {
        $flujo = [System.IO.File]::Open($Ruta, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $lector = [System.Xml.XmlReader]::Create($flujo, $cfg)
        while ($lector.Read()) {
            if ($lector.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if ($raiz -eq '') { $raiz = $lector.Name; continue }
            if ($lector.Depth -eq 1) {
                if ($lector.Name -eq 'channel') { $canales++ }
                elseif ($lector.Name -eq 'programme') { $programas++ }
            }
        }
    }
    catch [System.Xml.XmlException] {
        Stop-Script 34 ('El archivo {0} no es un XML valido: {1}' -f $Nombre, $_.Exception.Message) `
            'Corrija el archivo antes de subirlo (o use -SinValidar / /novalidate para omitir esta comprobacion).'
    }
    finally {
        if ($null -ne $lector) { $lector.Close() }
        if ($null -ne $flujo) { $flujo.Dispose() }
    }

    if ($raiz -ne 'tv') {
        Write-Log ("{0}: el elemento raiz es '{1}' y XMLTV espera 'tv'." -f $Nombre, $raiz) 'WARN'
    }
    if ($programas -eq 0) {
        Write-Log ('{0}: no contiene ningun elemento programme.' -f $Nombre) 'WARN'
    }
    return ('{0}: {1} canales, {2} programas' -f $Nombre, $canales, $programas)
}

# M3U: cabecera, numero de entradas y marcas de conflicto de Git.
function Test-ContenidoM3u {
    param([string]$Ruta, [string]$Nombre)

    $entradas = 0
    $buscandoCabecera = $true
    $tieneCabecera = $false
    $numLinea = 0

    foreach ($linea in [System.IO.File]::ReadLines($Ruta)) {
        $numLinea++
        if ($linea -match '^(<{7}|>{7})(\s|$)') {
            Stop-Script 34 ('{0}: contiene marcas de conflicto de Git en la linea {1}.' -f $Nombre, $numLinea) `
                'Resuelva el conflicto y vuelva a intentarlo.'
        }
        $t = $linea.Trim()
        if ($buscandoCabecera -and $t -ne '') {
            $buscandoCabecera = $false
            $tieneCabecera = $t.StartsWith('#EXTM3U')
        }
        if ($t.StartsWith('#EXTINF')) { $entradas++ }
    }

    if (-not $tieneCabecera) {
        Write-Log ('{0}: no empieza con la cabecera #EXTM3U.' -f $Nombre) 'WARN'
    }
    if ($entradas -eq 0) {
        Write-Log ('{0}: no contiene ninguna entrada #EXTINF.' -f $Nombre) 'WARN'
    }
    return ('{0}: {1} canales' -f $Nombre, $entradas)
}

# ---------------------------------------------------------------------------
#  Programa principal
# ---------------------------------------------------------------------------
function Invoke-Principal {
    Set-Location -LiteralPath $script:Dir

    # Normaliza -Archivos (con -File llega como un unico texto "a,b").
    $lista = @()
    foreach ($a in @($Archivos)) {
        foreach ($p in ($a -split '[,;]')) {
            $t = $p.Trim().Trim('"')
            if ($t -ne '') { $lista += $t }
        }
    }
    $lista = @($lista | Select-Object -Unique)
    if ($lista.Count -eq 0) { Stop-Script 34 'No se indico ningun archivo para publicar.' }

    # Entorno: mensajes de Git en ingles (para clasificar errores), sin
    # cuelgues por conexiones atascadas y, si se pide, sin ninguna ventana.
    $env:LC_MESSAGES = 'C'
    $env:LANGUAGE = 'C'
    $env:GIT_HTTP_LOW_SPEED_LIMIT = '1000'
    $env:GIT_HTTP_LOW_SPEED_TIME = '30'
    if ($SinPrompt) {
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
    }

    Write-Log '=== Actualizacion de epg_cr_manual ===' 'TITULO'
    Write-Log "Carpeta: $script:Dir"
    $opciones = @()
    if ($Simular)        { $opciones += 'Simular' }
    if ($SinSubir)       { $opciones += 'SinSubir' }
    if ($SinSincronizar) { $opciones += 'SinSincronizar' }
    if ($SinValidar)     { $opciones += 'SinValidar' }
    if ($PreferirLocal)  { $opciones += 'PreferirLocal' }
    if ($SinPrompt)      { $opciones += 'SinPrompt' }
    if ($opciones.Count -gt 0) { Write-Log ('Opciones: ' + ($opciones -join ', ')) 'DETALLE' }
    if ($Simular) { Write-Log 'MODO SIMULACION: no se modificara nada.' 'WARN' }

    # ---- Git ----
    Write-Paso 'Comprobando Git'
    if (-not (Find-Git)) {
        Stop-Script 30 'Git no esta instalado o no esta disponible en PATH.' `
            'Instale Git for Windows desde https://git-scm.com/download/win y vuelva a intentarlo.'
    }
    Write-Log ((Invoke-Git @('--version')).Texto.Trim()) 'DETALLE'

    # ---- Repositorio ----
    Write-Paso 'Comprobando el repositorio'
    $r = Invoke-Git @('rev-parse', '--is-inside-work-tree') -PermitirFallo
    if (-not $r.Ok -or $r.Texto.Trim() -ne 'true') {
        $ayuda = 'Inicialice el repositorio con: git init'
        if ($r.Texto -match 'dubious ownership') {
            $ayuda = 'Ejecute una vez: git config --global --add safe.directory "' + ($script:Dir -replace '\\', '/') + '"'
        }
        Stop-Script 31 'No se encontro un repositorio Git utilizable en esta carpeta.' $ayuda
    }

    $gitDir = ''
    $r = Invoke-Git @('rev-parse', '--absolute-git-dir') -PermitirFallo
    if ($r.Ok) { $gitDir = $r.Texto.Trim() }
    if ($gitDir -eq '' -or -not (Test-Path -LiteralPath $gitDir -PathType Container)) {
        $r = Invoke-Git @('rev-parse', '--git-dir')
        $gitDir = $r.Texto.Trim()
        if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $script:Dir $gitDir }
    }

    # ---- Una sola instancia a la vez ----
    # El bloqueo es un archivo abierto en exclusiva: el sistema lo libera solo
    # si el proceso muere, asi que nunca queda "pegado".
    $rutaBloqueo = Join-Path $gitDir 'actualizar_github.lock'
    try {
        $script:Bloqueo = [System.IO.File]::Open($rutaBloqueo, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        # 32/33 = violacion de uso compartido: otra instancia tiene el bloqueo.
        $codigoWin = $_.Exception.HResult -band 0xFFFF
        if ($codigoWin -eq 32 -or $codigoWin -eq 33) {
            Stop-Script 39 'Ya hay otra actualizacion en ejecucion sobre este repositorio.' `
                'Espere a que termine. Si esta seguro de que no hay ninguna, reinicie el equipo o finalice el proceso git/powershell.'
        }
        Write-Log ('No se pudo crear el bloqueo de instancia: ' + $_.Exception.Message) 'WARN'
    }
    catch {
        Write-Log ('No se pudo crear el bloqueo de instancia: ' + $_.Exception.Message) 'WARN'
    }

    # ---- Estado del repositorio ----
    Write-Paso 'Comprobando el estado del repositorio'
    $bloqueoIndice = Join-Path $gitDir 'index.lock'
    if (Test-Path -LiteralPath $bloqueoIndice) {
        $edad = [int]((Get-Date) - (Get-Item -LiteralPath $bloqueoIndice).LastWriteTime).TotalMinutes
        Stop-Script 36 ('Existe un bloqueo de Git (index.lock, de hace {0} min): {1}' -f $edad, $bloqueoIndice) `
            'Otro proceso de Git podria estar en ejecucion. Si no es asi, borre ese archivo.'
    }
    $pendientes = [ordered]@{
        'rebase-merge'     = 'rebase'
        'rebase-apply'     = 'rebase/am'
        'MERGE_HEAD'       = 'merge'
        'CHERRY_PICK_HEAD' = 'cherry-pick'
        'REVERT_HEAD'      = 'revert'
    }
    foreach ($clave in $pendientes.Keys) {
        if (Test-Path -LiteralPath (Join-Path $gitDir $clave)) {
            Stop-Script 36 ('Hay una operacion sin terminar en el repositorio: {0}.' -f $pendientes[$clave]) `
                'Termine o cancele esa operacion (git merge --abort, git rebase --abort, git cherry-pick --abort) y vuelva a intentarlo.'
        }
    }
    $r = Invoke-Git @('ls-files', '--unmerged') -PermitirFallo
    if ($r.Ok -and $r.Texto.Trim() -ne '') {
        Stop-Script 36 'Hay archivos con conflictos sin resolver.' 'Resuelvalos y use git add antes de volver a ejecutar.'
    }
    Write-Log 'Repositorio en buen estado.'

    # ---- Remoto ----
    Write-Paso 'Comprobando el remoto'
    $r = Invoke-Git @('config', '--get', "remote.$Remoto.url") -PermitirFallo
    if (-not $r.Ok -or [string]::IsNullOrWhiteSpace($r.Texto)) {
        $disponibles = @((Invoke-Git @('remote') -PermitirFallo).Lineas | Where-Object { $_.Trim() -ne '' }) -join ', '
        $ayuda = "Configurelo con: git remote add $Remoto URL_DEL_REPOSITORIO"
        if ($disponibles -ne '') { $ayuda = "Remotos disponibles: $disponibles. Use -Remoto NOMBRE o $ayuda" }
        Stop-Script 32 "No existe el remoto '$Remoto'." $ayuda
    }
    $urlRemoto = Hide-Credenciales $r.Texto.Trim()
    Write-Log "Remoto: $Remoto ($urlRemoto)"

    # ---- Rama ----
    Write-Paso 'Comprobando la rama'
    $r = Invoke-Git @('symbolic-ref', '--short', '-q', 'HEAD') -PermitirFallo
    $ramaActual = ''
    if ($r.Ok) { $ramaActual = $r.Texto.Trim() }

    $ramaTrabajo = $ramaActual
    if ($Rama -eq '') {
        if ($ramaActual -eq '') {
            Stop-Script 33 'El repositorio esta en HEAD desacoplado (no hay rama activa).' `
                'Cambie a una rama con: git switch NOMBRE_DE_RAMA (o indique -Rama NOMBRE). No se cambia sola para no mover ramas existentes.'
        }
    }
    elseif ($Rama -ne $ramaActual) {
        if ($Simular) {
            Write-Log "Se cambiaria a la rama '$Rama' (simulacion: se sigue con '$ramaActual')." 'WARN'
        }
        else {
            Write-Log "Cambiando a la rama '$Rama'..."
            $r = Invoke-Git @('checkout', $Rama, '--') -PermitirFallo
            if (-not $r.Ok) {
                Show-Salida $r
                Stop-Script 33 "No se pudo cambiar a la rama '$Rama'." `
                    'Compruebe que existe (git branch -a) y que no hay cambios locales que lo impidan.'
            }
            $ramaTrabajo = $Rama
        }
    }
    Write-Log "Rama: $ramaTrabajo"

    # ---- Identidad ----
    Write-Paso 'Comprobando la identidad de Git'
    $r = Invoke-Git @('var', 'GIT_AUTHOR_IDENT') -PermitirFallo
    if ($r.Ok) {
        Write-Log ('Autor: ' + ($r.Texto.Trim() -replace '\s+\d+\s+[+-]\d{4}\s*$', ''))
    }
    elseif ($Simular) {
        Write-Log 'No hay identidad de Git configurada (user.name / user.email).' 'WARN'
    }
    else {
        Stop-Script 35 'Git no tiene configurado user.name y/o user.email.' `
            'Ejecute: git config --global user.name "Su Nombre"  y  git config --global user.email "correo@ejemplo.com"'
    }

    # ---- Archivos ----
    Write-Paso 'Comprobando los archivos'
    $faltan = @()
    foreach ($nombre in $lista) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:Dir $nombre) -PathType Leaf)) { $faltan += $nombre }
    }
    if ($faltan.Count -gt 0) {
        Stop-Script 34 ('Faltan archivos: ' + ($faltan -join ', ')) 'Genere los archivos antes de actualizar.'
    }

    $resumenes = @()
    foreach ($nombre in $lista) {
        $ruta = Join-Path $script:Dir $nombre
        $tam = (Get-Item -LiteralPath $ruta).Length

        if ($tam -eq 0) {
            Stop-Script 34 "El archivo $nombre esta vacio." 'Publicarlo borraria el contenido en GitHub. Regenere el archivo.'
        }
        if ($tam -ge $LIMITE_MAXIMO) {
            Stop-Script 34 ("El archivo $nombre pesa {0} y GitHub rechaza archivos de mas de 100 MB." -f (Format-Tamano $tam)) `
                'Reduzca el archivo o use Git LFS.'
        }
        if ($tam -ge $LIMITE_AVISO) {
            Write-Log ("$nombre pesa {0}; GitHub avisa a partir de 50 MB." -f (Format-Tamano $tam)) 'WARN'
        }
        if (Test-ArchivoEnUso $ruta) {
            Stop-Script 34 "El archivo $nombre esta siendo escrito por otro programa." 'Espere a que termine de generarse y vuelva a intentarlo.'
        }

        $resumen = ''
        if (-not $SinValidar) {
            $ext = [System.IO.Path]::GetExtension($nombre).ToLowerInvariant()
            if ($ext -eq '.xml') { $resumen = Test-ContenidoXml $ruta $nombre }
            elseif ($ext -eq '.m3u' -or $ext -eq '.m3u8') { $resumen = Test-ContenidoM3u $ruta $nombre }
        }
        if ($resumen -ne '') { $resumenes += $resumen }

        # Aviso si el archivo se encogio mucho respecto a la version publicada.
        $rutaGit = $nombre -replace '\\', '/'
        $previo = Invoke-Git @('cat-file', '-s', "HEAD:./$rutaGit") -PermitirFallo
        if ($previo.Ok -and $previo.Texto.Trim() -match '^\d+$') {
            $tamPrevio = [long]$previo.Texto.Trim()
            if ($tamPrevio -gt 0 -and $tam -lt ($tamPrevio * 0.5)) {
                Write-Log ('{0} se redujo de {1} a {2} respecto a la ultima version publicada.' -f $nombre, (Format-Tamano $tamPrevio), (Format-Tamano $tam)) 'WARN'
            }
        }

        if ($resumen -ne '') { Write-Log ('OK  ' + $resumen + (' ({0})' -f (Format-Tamano $tam))) }
        else { Write-Log ('OK  {0} ({1})' -f $nombre, (Format-Tamano $tam)) }
    }

    # ---- Conexion y estado del remoto ----
    $remotoTieneRama = $false
    if ($SinSincronizar) {
        Write-Paso 'Sincronizacion con el remoto omitida (-SinSincronizar)'
    }
    else {
        Write-Paso 'Comprobando la conexion con el remoto'
        $r = Invoke-GitConReintentos @('ls-remote', '--heads', $Remoto, $ramaTrabajo) 'Conexion con el remoto' $Reintentos $EsperaSegundos
        if (-not $r.Ok) {
            Show-Salida $r
            if ($r.Tipo -eq 'auth') {
                Stop-Script 40 'El remoto rechazo las credenciales o no se tiene permiso.' `
                    'Inicie sesion en GitHub (Git Credential Manager) o revise su token/clave SSH y los permisos sobre el repositorio.'
            }
            Stop-Script 40 'No hay conexion con el remoto.' 'Revise su conexion a Internet, VPN o proxy y vuelva a intentarlo.'
        }
        $remotoTieneRama = (@($r.Lineas | Where-Object { $_ -match '\srefs/heads/' }).Count -gt 0)

        if ($remotoTieneRama) {
            $refspec = "+refs/heads/${ramaTrabajo}:refs/remotes/$Remoto/${ramaTrabajo}"
            $r = Invoke-GitConReintentos @('fetch', '--quiet', $Remoto, $refspec) 'Descarga del remoto' $Reintentos $EsperaSegundos
            if (-not $r.Ok) {
                Show-Salida $r
                Stop-Script 40 'No se pudo descargar el estado del remoto.' 'Vuelva a intentarlo; si persiste, revise la conexion y las credenciales.'
            }
            Write-Log 'Estado del remoto actualizado.'
        }
        else {
            Write-Log "La rama '$ramaTrabajo' aun no existe en el remoto; se creara al subir." 'WARN'
        }
    }

    # ---- Commit ----
    Write-Paso 'Preparando el commit'
    $hayCambios = $false
    if ($Simular) {
        $r = Invoke-Git (@('status', '--porcelain', '--') + $lista) -PermitirFallo
        $cambiados = @($r.Lineas | Where-Object { $_.Trim() -ne '' })
        $hayCambios = ($cambiados.Count -gt 0)
        foreach ($c in $cambiados) { Write-Log ('  ' + $c) 'DETALLE' }
    }
    else {
        $r = Invoke-Git (@('add', '--') + $lista) -PermitirFallo
        if (-not $r.Ok) {
            Show-Salida $r
            Stop-Script 1 'git add fallo.' 'Compruebe que los archivos no esten excluidos por .gitignore.'
        }
        Show-Salida $r

        $r = Invoke-Git (@('diff', '--cached', '--quiet', '--') + $lista) -PermitirFallo
        if ($r.Codigo -gt 1) {
            Show-Salida $r
            Stop-Script 1 'git diff fallo al comparar los archivos.'
        }
        $hayCambios = ($r.Codigo -eq 1)
    }

    if (-not $hayCambios) {
        Write-Log 'No hay cambios nuevos en los archivos.' 'WARN'
    }
    elseif ($Simular) {
        Write-Log 'Se crearia un commit con los cambios anteriores.'
    }
    else {
        $fecha = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $textoCommit = "$Mensaje - $fecha"
        if ($resumenes.Count -gt 0) { $textoCommit += "`n`n" + ($resumenes -join "`n") }

        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($tmp, $textoCommit + "`n", (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
            # Con rutas, git commit incluye solo esos archivos aunque haya otros en el indice.
            $r = Invoke-Git (@('commit', '--quiet', '-F', $tmp, '--') + $lista) -PermitirFallo
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        if (-not $r.Ok) {
            Show-Salida $r
            Stop-Script 1 'No se pudo crear el commit.' 'Revise la identidad de Git y los hooks del repositorio (pre-commit).'
        }
        $corto = (Invoke-Git @('rev-parse', '--short', 'HEAD')).Texto.Trim()
        Write-Log "Commit creado: $corto" 'OK'
    }

    # ---- Que hay pendiente de subir ----
    $ab = $null
    # Si el remoto no tiene la rama, cualquier referencia local a ella esta
    # obsoleta: se sube todo el historial local.
    if ($SinSincronizar -or $remotoTieneRama) {
        $ab = Get-AdelantoAtraso $Remoto $ramaTrabajo
    }
    if ($null -eq $ab) {
        $r = Invoke-Git @('rev-list', '--count', 'HEAD') -PermitirFallo
        $total = 0
        if ($r.Ok -and $r.Texto.Trim() -match '^\d+$') { $total = [int]$r.Texto.Trim() }
        $ab = [pscustomobject]@{ Adelante = $total; Atras = 0 }
    }
    if ($ab.Atras -gt 0) {
        Write-Log ('El remoto tiene {0} commit(s) que no estan en local.' -f $ab.Atras) 'DETALLE'
    }

    $pendiente = $ab.Adelante
    if ($Simular -and $hayCambios) { $pendiente++ }

    if ($pendiente -eq 0) {
        Write-Log 'No hay cambios nuevos para subir.' 'WARN'
        return
    }
    Write-Log ('Commits pendientes de subir: {0}' -f $pendiente)

    if ($Simular) {
        Write-Log "Simulacion terminada: se subirian los cambios a $Remoto/$ramaTrabajo." 'OK'
        return
    }
    if ($SinSubir) {
        Write-Log 'Commit creado localmente; no se sube por -SinSubir.' 'OK'
        return
    }

    # ---- Integrar y subir ----
    $sincronizado = $false
    if (-not $SinSincronizar -and $ab.Atras -gt 0) {
        Write-Paso 'Integrando cambios del remoto'
        Invoke-Integracion $Remoto $ramaTrabajo ([bool]$PreferirLocal)
        $sincronizado = $true
    }

    Write-Paso "Subiendo cambios a $Remoto/$ramaTrabajo"
    $intento = 0
    while ($true) {
        $intento++
        $r = Invoke-Git @('push', '--set-upstream', $Remoto, $ramaTrabajo) -PermitirFallo
        if ($r.Ok) { Show-Salida $r; break }

        Show-Salida $r
        $reintentar = $false
        if ($r.Tipo -eq 'red' -and $intento -lt $Reintentos) {
            $pausa = $EsperaSegundos * $intento
            Write-Log ('Fallo de red al subir (intento {0} de {1}). Reintentando en {2} s...' -f $intento, $Reintentos, $pausa) 'WARN'
            Start-Sleep -Seconds $pausa
            $reintentar = $true
        }
        elseif ($r.Tipo -eq 'rechazado' -and -not $sincronizado -and -not $SinSincronizar) {
            Write-Log 'El remoto avanzo mientras tanto; se integran sus cambios y se reintenta.' 'WARN'
            $refspec = "+refs/heads/${ramaTrabajo}:refs/remotes/$Remoto/${ramaTrabajo}"
            $f = Invoke-GitConReintentos @('fetch', '--quiet', $Remoto, $refspec) 'Descarga del remoto' $Reintentos $EsperaSegundos
            if (-not $f.Ok) { Show-Salida $f; Stop-Script 40 'No se pudo descargar el estado del remoto.' }
            Invoke-Integracion $Remoto $ramaTrabajo ([bool]$PreferirLocal)
            $sincronizado = $true
            $reintentar = $true
        }

        if (-not $reintentar) {
            switch ($r.Tipo) {
                'auth' {
                    Stop-Script 40 'El remoto rechazo las credenciales o no se tiene permiso de escritura.' `
                        'Inicie sesion en GitHub (Git Credential Manager), revise su token/clave SSH y que tenga permisos de escritura en el repositorio.'
                }
                'red' {
                    Stop-Script 40 ('No se pudo subir tras {0} intentos por problemas de red.' -f $Reintentos) `
                        'El commit quedo guardado en local y se subira en la proxima ejecucion. Revise su conexion, VPN o proxy.'
                }
                'bloqueado' {
                    Stop-Script 38 'GitHub bloqueo el push (rama protegida, archivo demasiado grande o regla del repositorio).' `
                        'Lea el detalle de git mostrado arriba. El commit quedo guardado en local.'
                }
                'rechazado' {
                    Stop-Script 38 'El remoto rechazo el push porque tiene cambios que no estan en local.' `
                        'Ejecute sin -SinSincronizar para integrarlos automaticamente. El commit quedo guardado en local.'
                }
                default {
                    Stop-Script 38 'El push fallo por un motivo no reconocido.' `
                        'Lea el detalle de git mostrado arriba. El commit quedo guardado en local y se reintentara en la proxima ejecucion.'
                }
            }
        }
    }

    # ---- Verificacion ----
    Write-Paso 'Verificando la publicacion'
    $local = (Invoke-Git @('rev-parse', 'HEAD')).Texto.Trim()
    $v = Invoke-Git @('ls-remote', $Remoto, "refs/heads/$ramaTrabajo") -PermitirFallo
    $lineaRemota = @($v.Lineas | Where-Object { $_ -match 'refs/heads/' } | Select-Object -First 1)
    if ($v.Ok -and $lineaRemota.Count -gt 0) {
        $shaRemoto = ($lineaRemota[0] -split '\s+')[0]
        if ($shaRemoto -eq $local) {
            Write-Log ('Verificado: {0}/{1} esta en el commit {2}.' -f $Remoto, $ramaTrabajo, $local.Substring(0, 7)) 'OK'
        }
        else {
            Write-Log 'El remoto no esta en el mismo commit que el local; revise el repositorio en GitHub.' 'WARN'
        }
    }
    else {
        Write-Log 'No se pudo verificar el estado final del remoto.' 'WARN'
    }

    $segundos = [math]::Round(((Get-Date) - $script:Inicio).TotalSeconds, 1)
    Write-Log ''
    Write-Log ('Resumen: remoto {0}, rama {1}, commit {2}, {3} s.' -f $urlRemoto, $ramaTrabajo, $local.Substring(0, 7), $segundos)
    Write-Log 'Actualizacion completada correctamente.' 'OK'
}

try {
    Invoke-Principal
}
catch {
    $ex = $_.Exception
    $codigo = 1
    $texto = ''
    $ayuda = 'Revise la autenticacion, el remoto y el estado del repositorio en GitHub.'

    if ($ex.Data.Contains('ExitCode')) {
        $codigo = [int]$ex.Data['ExitCode']
        $texto = $ex.Message
        $ayuda = [string]$ex.Data['Ayuda']
    }
    else {
        $texto = 'Error inesperado (linea {0}): {1}' -f $_.InvocationInfo.ScriptLineNumber, $ex.Message
    }

    Write-Log ''
    Write-Log $texto 'ERROR'
    if ($ayuda -ne '') { Write-Log $ayuda 'WARN' }
    $script:CodigoSalida = $codigo
}
finally {
    if ($null -ne $script:Bloqueo) { $script:Bloqueo.Dispose() }
}

exit $script:CodigoSalida
