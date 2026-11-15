#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [uri]$BaseUrl,

    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.config/opencode/opencode.json'),

    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
$endpoint = $BaseUrl.AbsoluteUri.TrimEnd('/')
if ($BaseUrl.Scheme -notin @('http', 'https') -or $BaseUrl.AbsolutePath.TrimEnd('/') -ne '/v1') {
    throw 'Usa la URL completa que muestra CrucibleLLM, terminada en /v1.'
}

$response = Invoke-RestMethod -Uri "$endpoint/models" -TimeoutSec 10
$model = $response.data | Where-Object id -eq 'local' | Select-Object -First 1
if (!$model -or [int]$model.context_length -lt 1) {
    throw 'El iPad no anuncia un modelo cargado con contexto disponible.'
}

$example = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'opencode.example.jsonc') -Raw | ConvertFrom-Json -AsHashtable
$config = if (Test-Path -LiteralPath $ConfigPath) {
    Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
} else {
    @{ '$schema' = 'https://opencode.ai/config.json' }
}
if (!$config['providers']) { $config['providers'] = @{} }
if (!$config['agents']) { $config['agents'] = @{} }
if (!$config['providers']['ipad']) { $config['providers']['ipad'] = $example['providers']['ipad'] }
$provider = $config['providers']['ipad']
if (!$provider['settings']) { $provider['settings'] = @{} }
if (!$provider['body']) { $provider['body'] = @{} }
if (!$provider['models']) { $provider['models'] = @{} }
if (!$provider['models']['local']) { $provider['models']['local'] = $example['providers']['ipad']['models']['local'] }
$modelConfig = $provider['models']['local']
if (!$modelConfig['limit']) { $modelConfig['limit'] = @{} }
if (!$modelConfig['capabilities']) { $modelConfig['capabilities'] = @{} }

$supportsTools = $model.supports_tools -eq $true
$context = [int]$model.context_length
$output = if ($supportsTools) { [math]::Min(4096, [math]::Max(256, [int]($context / 4))) } else { [math]::Min(500, [math]::Max(64, [int]($context / 4))) }
$provider['settings']['baseURL'] = $endpoint
$provider['body']['crucible_opencode_text'] = $true
if ($supportsTools) {
    [void]$provider['body'].Remove('tool_choice')
} else {
    $provider['body']['tool_choice'] = 'none'
}
$modelConfig['capabilities']['tools'] = $supportsTools
$modelConfig['limit']['context'] = $context
$modelConfig['limit']['output'] = $output
$config['agents']['ipad-code'] = $example['agents']['ipad-code']
if (!$config['agents']['ipad-chat']) { $config['agents']['ipad-chat'] = $example['agents']['ipad-chat'] }

$absolute = [IO.Path]::GetFullPath($ConfigPath)
$folder = [IO.Path]::GetDirectoryName($absolute)
[IO.Directory]::CreateDirectory($folder) | Out-Null
$temporary = Join-Path $folder ('.crucible-config-' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText($temporary, ($config | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
    [IO.File]::Move($temporary, $absolute, $true)
} finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
}

Write-Host "ipad/local · $endpoint · contexto $context · salida $output · herramientas $supportsTools"
if ($Launch) {
    $agent = if ($supportsTools) { 'ipad-code' } else { 'ipad-chat' }
    & opencode mini --standalone --agent $agent --model ipad/local
    exit $LASTEXITCODE
}
