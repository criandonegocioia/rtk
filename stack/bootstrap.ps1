<#
Stack global de IA para Claude Code: rtk + caveman (só skill) + claude-mem (local).
Uso: .\bootstrap.ps1 [-Check] [-DryRun] [-RegisterLogonTask]
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$DryRun,
    [switch]$RegisterLogonTask
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RtkVersion = 'v0.51.0'
$CavemanRef = 'v3.1.0'
$ClaudeMemVersion = '13.28.0'

$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$Settings = Join-Path $ClaudeDir 'settings.json'
$RtkBinDir = if ($env:RTK_INSTALL_DIR) { $env:RTK_INSTALL_DIR } else { Join-Path $env:USERPROFILE '.local\bin' }
$ClaudeMemDir = if ($env:CLAUDE_MEM_DATA_DIR) { $env:CLAUDE_MEM_DATA_DIR } else { Join-Path $env:USERPROFILE '.claude-mem' }
$StackHome = Join-Path $env:LOCALAPPDATA 'ia-stack'
$TaskName = 'IA-Stack-Bootstrap'

$env:Path = "$RtkBinDir;$env:Path"
# Sem isso o `rtk init` pode travar esperando resposta de telemetria num pseudo-TTY.
$env:RTK_TELEMETRY_DISABLED = '1'
$env:CLAUDE_MEM_ONLINE_OPTIN = 'false'

function Info($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "[aviso] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "[falha] $msg" -ForegroundColor Red }
function Has($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Invoke-Step {
    param([string]$Label, [scriptblock]$Action)
    if ($DryRun) { Write-Host "[dry-run] $Label"; return }
    $global:LASTEXITCODE = 0
    & $Action
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "falhou ($LASTEXITCODE): $Label" }
}

# Nas sondagens abaixo, stderr redirecionado de executável nativo vira erro fatal no PS 5.1 com 'Stop'.
function Get-RtkVersion {
    $ErrorActionPreference = 'Continue'
    if (-not (Has 'rtk')) { return $null }
    $raw = (& rtk --version 2>$null | Out-String).Trim()
    return ($raw -split '\s+')[1]
}

function Test-RtkIsTokenKiller {
    $ErrorActionPreference = 'Continue'
    if (-not (Has 'rtk')) { return $false }
    & rtk gain *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-PluginInstalled($Name, $MarketplaceDir) {
    $ErrorActionPreference = 'Continue'
    if (Has 'claude') {
        $list = (& claude plugin list 2>$null | Out-String)
        return ($list -match [regex]::Escape($Name))
    }
    return (Test-Path (Join-Path $ClaudeDir "plugins\marketplaces\$MarketplaceDir"))
}

function Test-SettingsMatch($Pattern) {
    if (-not (Test-Path $Settings)) { return $false }
    return [bool](Select-String -Path $Settings -Pattern $Pattern -Quiet)
}

function Test-ClaudeMemTelemetryOff {
    $file = Join-Path $ClaudeMemDir 'telemetry.json'
    if (-not (Test-Path $file)) { return $false }
    return [bool](Select-String -Path $file -Pattern '"enabled"\s*:\s*false' -Quiet)
}

function Install-Rtk {
    $want = $RtkVersion.TrimStart('v')
    if ((Get-RtkVersion) -eq $want -and (Test-RtkIsTokenKiller)) {
        Info "rtk $want já instalado"
    } else {
        Info "instalando rtk $want em $RtkBinDir (binário verificado por SHA-256)"
        Invoke-Step "baixar rtk $RtkVersion, conferir SHA-256 e copiar rtk.exe para $RtkBinDir" {
            $asset = 'rtk-x86_64-pc-windows-msvc.zip'
            $base = "https://github.com/rtk-ai/rtk/releases/download/$RtkVersion"
            $tmp = Join-Path $env:TEMP ("rtk-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $tmp | Out-Null
            try {
                $zip = Join-Path $tmp $asset
                $sums = Join-Path $tmp 'checksums.txt'
                Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $zip
                Invoke-WebRequest -UseBasicParsing -Uri "$base/checksums.txt" -OutFile $sums
                $line = Select-String -Path $sums -Pattern ("\s" + [regex]::Escape($asset) + '$') | Select-Object -First 1
                if (-not $line) { throw "checksum de $asset ausente em checksums.txt; instalação recusada" }
                $expected = ($line.Line -split '\s+')[0].ToLower()
                $actual = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLower()
                if ($expected -ne $actual) { throw "checksum não confere (esperado $expected, obtido $actual); instalação recusada" }
                Expand-Archive -Path $zip -DestinationPath $tmp -Force
                New-Item -ItemType Directory -Path $RtkBinDir -Force | Out-Null
                Copy-Item -Path (Join-Path $tmp 'rtk.exe') -Destination (Join-Path $RtkBinDir 'rtk.exe') -Force
            } finally {
                Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
            }
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            if (-not (($userPath -split ';') -contains $RtkBinDir)) {
                [Environment]::SetEnvironmentVariable('Path', "$RtkBinDir;$userPath", 'User')
                Info "$RtkBinDir adicionado ao PATH do usuário"
            }
        }
    }
    Invoke-Step 'rtk telemetry disable' { & rtk telemetry disable }
    # --hook-only: reescreve comandos sem injetar RTK.md no CLAUDE.md global (zero token de contexto).
    Invoke-Step 'rtk init -g --hook-only --auto-patch' { $null | & rtk init -g --hook-only --auto-patch }
}

function Install-Caveman {
    if (-not (Has 'claude')) {
        Warn "CLI 'claude' fora do PATH; caveman pulado. Instale com: npm i -g @anthropic-ai/claude-code"
        return
    }
    Info "instalando caveman $CavemanRef (só plugin/skill: sem proxy, sem MCP shrink, sem hooks avulsos)"
    # '--' entre aspas: sem elas o PowerShell consome o separador antes de chegar ao npx.
    Invoke-Step "npx caveman#$CavemanRef --only claude --minimal --non-interactive" {
        & npx.cmd -y "github:JuliusBrussee/caveman#$CavemanRef" '--' --only claude --minimal --non-interactive
    }
}

function Install-ClaudeMem {
    if (Test-PluginInstalled 'claude-mem' 'thedotmack') {
        Info 'claude-mem já instalado'
    } else {
        Info "instalando claude-mem $ClaudeMemVersion (provider=claude, sem nuvem cmem, memória nativa mantida)"
        # stdin redirecionado força o caminho não interativo, que mantém a auto-memória nativa ligada.
        Invoke-Step "npx claude-mem@$ClaudeMemVersion install --ide claude-code --provider claude" {
            $null | & npx.cmd -y "claude-mem@$ClaudeMemVersion" install --ide claude-code --provider claude
        }
    }
    if (-not (Test-ClaudeMemTelemetryOff)) {
        Invoke-Step "npx claude-mem@$ClaudeMemVersion telemetry disable" {
            $null | & npx.cmd -y "claude-mem@$ClaudeMemVersion" telemetry disable
        }
    }
}

function Test-Stack {
    $ok = $true

    if (Test-RtkIsTokenKiller) { Info "ok: rtk $(Get-RtkVersion)" }
    else { Fail "rtk ausente, ou é o 'Rust Type Kit' (projeto homônimo errado)"; $ok = $false }

    if (Test-SettingsMatch 'rtk.* hook claude') { Info "ok: hook do rtk registrado em $Settings" }
    else { Fail "hook 'rtk hook claude' ausente em $Settings"; $ok = $false }

    if (Test-PluginInstalled 'caveman' 'caveman') { Info 'ok: plugin caveman' }
    else { Fail 'plugin caveman não instalado'; $ok = $false }

    if (Test-PluginInstalled 'claude-mem' 'thedotmack') { Info 'ok: plugin claude-mem' }
    else { Fail 'plugin claude-mem não instalado'; $ok = $false }

    if (Test-SettingsMatch 'ANTHROPIC_BASE_URL|_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL') {
        Fail "settings.json redireciona a API (provável 'caveman enable'). Desfaça com: caveman disable --all"; $ok = $false
    } else { Info 'ok: chamadas de API vão direto para a Anthropic (sem proxy)' }
    if ($env:ANTHROPIC_BASE_URL) { Warn "ANTHROPIC_BASE_URL definido no ambiente: $env:ANTHROPIC_BASE_URL" }

    if (Test-SettingsMatch '"CLAUDE_CODE_DISABLE_AUTO_MEMORY"\s*:\s*"1"') {
        Fail "memória nativa do Claude Code desligada. Remova CLAUDE_CODE_DISABLE_AUTO_MEMORY do bloco env de $Settings"; $ok = $false
    } else { Info 'ok: memória nativa do Claude Code ligada' }

    if (Test-ClaudeMemTelemetryOff) { Info 'ok: telemetria do claude-mem desligada' }
    else { Fail 'telemetria do claude-mem não está desligada. Rode: npx claude-mem telemetry disable'; $ok = $false }

    return $ok
}

function Register-StackLogonTask {
    New-Item -ItemType Directory -Path $StackHome -Force | Out-Null
    $target = Join-Path $StackHome 'bootstrap.ps1'
    if ($PSCommandPath -ne $target) { Copy-Item -Path $PSCommandPath -Destination $target -Force }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -RunLevel Limited -Force | Out-Null
    Info "tarefa '$TaskName' registrada: roda a cada logon a partir de $target (log em $StackHome\bootstrap.log)"
}

if ($Check) {
    if (Test-Stack) { exit 0 } else { exit 1 }
}

if ($RegisterLogonTask) {
    if ($DryRun) { Write-Host "[dry-run] registrar tarefa agendada '$TaskName' no logon"; exit 0 }
    Register-StackLogonTask
    exit 0
}

if (-not $DryRun) {
    New-Item -ItemType Directory -Path $StackHome -Force | Out-Null
    Start-Transcript -Path (Join-Path $StackHome 'bootstrap.log') -Append | Out-Null
}

try {
    if (-not (Has 'npx.cmd')) { throw 'Node.js >= 20 é obrigatório (npx não encontrado)' }

    Install-Rtk
    Install-Caveman
    Install-ClaudeMem

    if ($DryRun) { Info 'dry-run concluído; nada foi alterado'; exit 0 }

    Info 'verificando...'
    if (Test-Stack) {
        Info 'stack pronto. Reinicie o Claude Code para carregar os hooks.'
    } else {
        Fail 'instalação terminou com pendências (acima)'
        exit 1
    }
} finally {
    if (-not $DryRun) { Stop-Transcript | Out-Null }
}
