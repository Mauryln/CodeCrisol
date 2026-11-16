#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [uri]$BaseUrl,

    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.config/opencode/opencode.json'),

    [ValidatePattern('^[a-z0-9][a-z0-9_-]*$')]
    [string]$ProviderId = 'ipad',

    [string]$ModelId,

    [ValidateRange(2, 2147483647)]
    [int]$ContextLength,

    [ValidateRange(1, 2147483647)]
    [int]$OutputLimit,

    [switch]$SupportsTools,

    [ValidatePattern('^[a-zA-Z_][a-zA-Z0-9_]*$')]
    [string]$ApiKeyEnv,

    [switch]$WithoutSkills,

    [switch]$Launch
)

$ErrorActionPreference = 'Stop'

function ConvertTo-ConfigMap($Value) {
    if ($null -ne $Value -and $Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        $map = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $map[$property.Name] = ConvertTo-ConfigMap $property.Value
        }
        return $map
    }
    if ($Value -is [array]) {
        return ,@(foreach ($item in $Value) { ConvertTo-ConfigMap $item })
    }
    return $Value
}

function Read-ConfigMap([string]$Path) {
    ConvertTo-ConfigMap (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$isIPad = $ProviderId -eq 'ipad'
$ProviderId = $ProviderId.ToLowerInvariant()
if (!$BaseUrl.IsAbsoluteUri -or $BaseUrl.Scheme -notin @('http', 'https') -or
    $BaseUrl.UserInfo -or $BaseUrl.Query -or $BaseUrl.Fragment) {
    throw 'Usa una URL HTTP o HTTPS sin credenciales, parámetros de consulta ni fragmentos.'
}
if ($isIPad -and $BaseUrl.AbsolutePath.TrimEnd('/') -ne '/v1') {
    throw 'Usa la URL completa que muestra CodeCrisol, terminada en /v1.'
}
if ($isIPad) {
    foreach ($option in @('ModelId', 'ContextLength', 'OutputLimit', 'SupportsTools', 'ApiKeyEnv')) {
        if ($PSBoundParameters.ContainsKey($option)) {
            throw "Para usar -$option especifica un -ProviderId distinto de ipad."
        }
    }
    $ModelId = 'local'
}

$endpoint = $BaseUrl.AbsoluteUri.TrimEnd('/')
$example = Read-ConfigMap (Join-Path $PSScriptRoot 'opencode.example.jsonc')
$config = if (Test-Path -LiteralPath $ConfigPath) {
    Read-ConfigMap $ConfigPath
} else {
    @{ '$schema' = 'https://opencode.ai/config.json' }
}

$package = $example['providers']['ipad']['package']
$existingProvider = if ($config['providers']) { $config['providers'][$ProviderId] }
if (!$isIPad -and $existingProvider) {
    if ($existingProvider['package'] -ne $package) {
        throw "El proveedor '$ProviderId' ya existe con otro paquete. Usa otro -ProviderId."
    }
    $existingEndpoint = if ($existingProvider['settings']) { $existingProvider['settings']['baseURL'] }
    if ($existingEndpoint -and ([string]$existingEndpoint).TrimEnd('/') -cne $endpoint) {
        throw "El proveedor '$ProviderId' ya apunta a otra URL. Usa otro -ProviderId para añadir esta conexión."
    }
}

$request = @{ Uri = "$endpoint/models"; TimeoutSec = 10; MaximumRedirection = 0 }
if ($ApiKeyEnv) {
    if ($BaseUrl.Scheme -ne 'https' -and !$BaseUrl.IsLoopback) {
        throw 'Usa HTTPS para enviar una clave a un servidor fuera de este equipo.'
    }
    $apiKey = [Environment]::GetEnvironmentVariable($ApiKeyEnv)
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "La variable de entorno '$ApiKeyEnv' no está definida."
    }
    $request['Headers'] = @{ Authorization = "Bearer $apiKey" }
}
try {
    $response = Invoke-RestMethod @request
} catch {
    $status = if ($_.Exception.Response) { " (HTTP $([int]$_.Exception.Response.StatusCode))" } else { '' }
    throw "No se pudo consultar /models en '$ProviderId'$status. Revisa la URL, el servidor y la autenticación."
}
$models = @($response.data | Where-Object { ![string]::IsNullOrWhiteSpace([string]$_.id) })
if (!$ModelId -and $models.Count -eq 1) { $ModelId = [string]$models[0].id }
if (!$ModelId) { throw 'Indica -ModelId con el ID exacto que devuelve /models.' }
if ($ModelId -match '[#\x00-\x1F\x7F]') { throw 'El ID del modelo contiene caracteres no admitidos por OpenCode.' }
$model = $models | Where-Object id -CEQ $ModelId | Select-Object -First 1
$announcedContext = 0
if ($model) { [void][int]::TryParse([string]$model.context_length, [ref]$announcedContext) }
if ($isIPad -and (!$model -or $announcedContext -lt 1)) {
    throw 'El iPad no anuncia un modelo cargado con contexto disponible.'
}
if (!$model) { throw "El modelo '$ModelId' no aparece en /models." }

$context = if ($ContextLength) { $ContextLength } else { $announcedContext }
if ($context -lt 2) { throw 'Indica -ContextLength con el contexto efectivo configurado en el servidor.' }
$toolsEnabled = if ($PSBoundParameters.ContainsKey('SupportsTools')) { $SupportsTools.IsPresent } else { $model.supports_tools -eq $true }
if (!$isIPad -and !$toolsEnabled) {
    throw 'El perfil de programación requiere herramientas. Usa un modelo compatible y confirma con -SupportsTools si /models no indica esa capacidad.'
}
$output = if ($OutputLimit) { $OutputLimit } elseif ($toolsEnabled) {
    [math]::Min(4096, [math]::Max(256, [int]($context / 4)))
} else {
    [math]::Min(500, [math]::Max(64, [int]($context / 4)))
}
if ($OutputLimit -ge $context) { throw '-OutputLimit debe ser menor que el contexto.' }
$output = [math]::Min($context - 1, $output)

if (!$config['providers']) { $config['providers'] = @{} }
if (!$config['agents']) { $config['agents'] = @{} }
if (!$config['providers'][$ProviderId]) {
    $config['providers'][$ProviderId] = if ($isIPad) { $example['providers']['ipad'] } else {
        [ordered]@{ name = $ProviderId; package = $package }
    }
}
$provider = $config['providers'][$ProviderId]
if (!$provider['settings']) { $provider['settings'] = @{} }
$provider['settings']['baseURL'] = $endpoint
if ($ApiKeyEnv) { $provider['settings']['apiKey'] = "{env:$ApiKeyEnv}" }
if ($isIPad) {
    $provider['name'] = 'CodeCrisol (iPad)'
    if (!$provider['body']) { $provider['body'] = @{} }
    $provider['body']['crucible_opencode_text'] = $true
    if ($toolsEnabled) {
        [void]$provider['body'].Remove('tool_choice')
    } else {
        $provider['body']['tool_choice'] = 'none'
    }
}
if (!$provider['models']) { $provider['models'] = @{} }
if ($provider['models'].Keys -contains $ModelId -and $provider['models'].Keys -cnotcontains $ModelId) {
    throw "Ese ID solo difiere en mayúsculas de otro modelo registrado. Usa otro -ProviderId para añadirlo."
}
if (!$provider['models'][$ModelId]) { $provider['models'][$ModelId] = @{} }
$modelConfig = $provider['models'][$ModelId]
if (!$modelConfig['limit']) { $modelConfig['limit'] = @{} }
if (!$modelConfig['capabilities']) { $modelConfig['capabilities'] = @{} }

$modelConfig['capabilities']['tools'] = $toolsEnabled
$modelConfig['name'] = if ($model.display_name) { [string]$model.display_name } elseif ($isIPad) {
    'Modelo cargado en el iPad'
} else { $ModelId }
$modelConfig['capabilities']['input'] = @('text')
$modelConfig['capabilities']['output'] = @('text')
$modelConfig['limit']['context'] = $context
$modelConfig['limit']['output'] = $output
$modelReference = "$ProviderId/$ModelId"
$agentId = "$ProviderId-code"
$codingAgent = $example['agents']['ipad-code']
$codingAgent['model'] = $modelReference
if (!$isIPad) { $codingAgent['description'] = "Programación con herramientas de OpenCode · $ProviderId" }
$skillPath = Join-Path $PSScriptRoot 'Skills'
if ($toolsEnabled -and !$WithoutSkills) {
    if (!(Test-Path -LiteralPath $skillPath -PathType Container)) {
        throw "No se encuentra la carpeta de skills de CodeCrisol: $skillPath"
    }
    if ($skillPath -notin $config['skills']) {
        $config['skills'] = @($config['skills'] | Where-Object { $_ }) + $skillPath
    }
} else {
    $codingAgent['system'] = 'Ayuda con el proyecto actual. Usa las herramientas disponibles para actuar y comprueba sus resultados antes de afirmar que un cambio se realizó.'
    $codingAgent['permissions'] = @($codingAgent['permissions'] | Where-Object {
        $_['action'] -ne 'skill' -or $_['effect'] -ne 'allow'
    })
}
$config['agents'][$agentId] = $codingAgent
if ($isIPad -and !$config['agents']['ipad-chat']) { $config['agents']['ipad-chat'] = $example['agents']['ipad-chat'] }

$absolute = [IO.Path]::GetFullPath($ConfigPath)
$folder = [IO.Path]::GetDirectoryName($absolute)
[IO.Directory]::CreateDirectory($folder) | Out-Null
$temporary = Join-Path $folder ('.crucible-config-' + [guid]::NewGuid().ToString('N') + '.tmp')
$backup = "$temporary.bak"
try {
    [IO.File]::WriteAllText($temporary, ($config | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
    if ([IO.File]::Exists($absolute)) { [IO.File]::Replace($temporary, $absolute, $backup) }
    else { [IO.File]::Move($temporary, $absolute) }
} finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
}

if (!$toolsEnabled) { $agentId = 'ipad-chat' }
Write-Host "$modelReference | $endpoint | contexto $context | salida $output | herramientas $toolsEnabled | agente $agentId"
if ($Launch) {
    $previousConfig = $env:OPENCODE_CONFIG
    try {
        $env:OPENCODE_CONFIG = $absolute
        & opencode mini --standalone --agent $agentId --model $modelReference
    } finally {
        $env:OPENCODE_CONFIG = $previousConfig
    }
    exit $LASTEXITCODE
}
