<#
  Instalador da memoria compartilhada do ufba.app (Windows PowerShell 5.1+, sem dependencias, sem administrador).

  Normalmente voce o recebe pelo bootstrap (irm https://ufba.app/install.ps1 | iex), que confere o SHA-256 antes de
  executar. Para rodar na mao: baixe, leia, confira o hash publicado no release e execute.

    ufba-memory.ps1 [-DryRun] [-Yes] [-Root <pasta>[,<pasta>]] [-ComputerName <nome>] [-Uninstall]

  -DryRun / -WhatIf  mostra o plano e nao escreve nada.
  -Yes               aceita todos os agentes encontrados e nao pergunta nada (em modo perfil exige -Root).
  -Root              pasta onde ficam os repositorios da ufba.app (so no modo perfil).
  -Uninstall         remove so o que este instalador instalou.

  O modo (fresh ou profile) NAO se escolhe: e detectado. A chave do computador nunca vai em argumento, variavel de
  ambiente persistente, log, arquivo de estado ou saida: entra por stdin ou no ambiente so do processo filho.

  Variaveis de TESTE (so valem com UFBA_INSTALLER_TEST=1; sem ela sao ignoradas com aviso): UFBA_API_URL,
  UFBA_MEMORY_URL, UFBA_POLL_SCALE_MS. UFBA_NO_BROWSER=1 nao abre o navegador.

  Tudo roda dentro de Invoke-UfbaMemory, chamada na ultima linha: um download truncado nao executa nada.
#>
param(
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$WhatIf,
    [switch]$Yes,
    [string[]]$Root = @(),
    [string]$ComputerName = ''
)

function Invoke-UfbaMemory {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $InstallerVersion = '1.0.1'
    $PinnedApi = 'https://api.ufba.app'
    $PinnedMemory = 'https://memory.ufba.app'
    $dry = [bool]($DryRun -or $WhatIf)
    $testMode = ($env:UFBA_INSTALLER_TEST -eq '1')

    # ---------- util ----------
    function Say([string]$m) { Write-Host $m }
    function Warn([string]$m) { Write-Host "Aviso: $m" }
    function Stop-Planned([string]$m) { Write-Host ''; Write-Host $m; Write-Host ''; Write-Host 'Nada foi alterado nesta maquina.'; return 3 }
    function Fail([string]$m) { throw "ufba-memory: erro: $m" }

    # TLS 1.2+ no Windows PowerShell 5.1 (o padrao dele pode ser TLS 1.0).
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    # ---------- URLs: fixas em producao; overrides so em teste ----------
    $api = $PinnedApi; $mem = $PinnedMemory
    foreach ($n in 'UFBA_API_URL', 'UFBA_MEMORY_URL') {
        $v = [Environment]::GetEnvironmentVariable($n)
        if (-not $v) { continue }
        if (-not $testMode) { Warn "$n ignorada (so vale com UFBA_INSTALLER_TEST=1); usando as URLs oficiais."; continue }
        if ($v -notmatch '^(https://|http://127\.0\.0\.1[:/])') { Fail "$n precisa ser https:// (ou http://127.0.0.1 em teste)." }
        if ($n -eq 'UFBA_API_URL') { $api = $v.TrimEnd('/') } else { $mem = $v.TrimEnd('/') }
    }
    $mcpUrl = "$api/mcp"
    $scaleMs = 1000
    if ($testMode -and $env:UFBA_POLL_SCALE_MS) { $scaleMs = [int]$env:UFBA_POLL_SCALE_MS }
    function Wait-Seconds([double]$s) { Start-Sleep -Milliseconds ([int]($s * $scaleMs)) }
    function Test-AllowedUrl([string]$u) {
        if ($u -like 'https://*') { return $true }
        return ($testMode -and $u -like 'http://127.0.0.1*')
    }

    # ---------- pastas ----------
    $userHome = $env:USERPROFILE
    if (-not $userHome) { Fail 'USERPROFILE nao esta definido.' }
    $localApp = $env:LOCALAPPDATA
    if (-not $localApp) { Fail 'LOCALAPPDATA nao esta definido.' }
    $stateDir = Join-Path $userHome '.ufba'
    $stateFile = Join-Path $stateDir 'computer.json'
    $dataDir = Join-Path $localApp 'ai-memory'
    $binDir = Join-Path (Join-Path $localApp 'Programs') 'ai-memory'
    $binExe = Join-Path $binDir 'ai-memory.exe'

    # ---------- rede ----------
    function Send-Http([string]$Method, [string]$Url, $Headers = @{}, $Body = $null, [string]$ContentType = $null) {
        if (-not (Test-AllowedUrl $Url)) { Fail "URL recusada (so https): $Url" }
        $p = @{ UseBasicParsing = $true; Method = $Method; Uri = $Url; TimeoutSec = 30; Headers = $Headers }
        if ($null -ne $Body) { $p.Body = $Body }
        if ($ContentType) { $p.ContentType = $ContentType }
        try {
            $r = Invoke-WebRequest @p
            return @{ Status = [int]$r.StatusCode; Body = [string]$r.Content }
        } catch {
            $resp = $_.Exception.Response
            if (-not $resp) { return @{ Status = 0; Body = '' } }
            $text = ''
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $text = $_.ErrorDetails.Message }
            else { try { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $text = $sr.ReadToEnd(); $sr.Close() } catch { } }
            return @{ Status = [int]$resp.StatusCode; Body = $text }
        }
    }
    function ConvertFrom-JsonSafe([string]$t) { try { return ($t | ConvertFrom-Json) } catch { return $null } }
    function Get-ApiMessage($r) {
        $j = ConvertFrom-JsonSafe $r.Body
        if ($j) {
            if ($j.message) { return [string]$j.message }
            if ($j.error_description) { return [string]$j.error_description }
            if ($j.error) { return [string]$j.error }
        }
        if ($r.Status -eq 0) { return 'sem resposta do servidor (verifique a conexao)' }
        return "resposta HTTP $($r.Status)"
    }
    function Get-FileSha256([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }

    # ---------- processos filhos (a chave so entra por stdin ou no ambiente do filho) ----------
    function Invoke-Native([string]$Exe, [string[]]$Arguments, $Stdin = $null, [hashtable]$EnvMap = @{}, [string]$Redact = $null) {
        $saved = @{}
        $oldEap = $ErrorActionPreference
        try {
            foreach ($k in $EnvMap.Keys) {
                $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
                [Environment]::SetEnvironmentVariable($k, $EnvMap[$k], 'Process')
            }
            $ErrorActionPreference = 'Continue'
            $global:LASTEXITCODE = 0
            if ($null -ne $Stdin) { $out = $Stdin | & $Exe @Arguments 2>&1 | Out-String }
            else { $out = & $Exe @Arguments 2>&1 | Out-String }
            $code = $global:LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldEap
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
        }
        if ($Redact) { $out = $out.Replace($Redact, '***') }
        return @{ Code = $code; Out = $out }
    }

    # ---------- perguntas ----------
    function Read-Answer([string]$prompt) {
        try { return (Read-Host $prompt) } catch { Fail 'preciso de uma resposta, mas nao ha terminal interativo. Rode de novo com -Yes (e -Root, no modo perfil).' }
    }
    function Confirm-Item([string]$prompt) {
        if ($Yes) { return $true }
        $a = Read-Answer "$prompt [S/n]"
        return ($a -eq '' -or $a -match '^(s|sim|y|yes)$')
    }

    # ---------- estado (~/.ufba/computer.json, SEM segredo) ----------
    function Read-State {
        if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
        try { return (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json) } catch { return $null }
    }
    function Write-State($obj) {
        if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }
        $json = ConvertTo-Json -InputObject $obj -Depth 6
        [IO.File]::WriteAllText($stateFile, $json, (New-Object Text.UTF8Encoding($false)))
    }

    # ---------- PATH do usuario (so no modo fresh) ----------
    function Edit-UserPath([string]$dir, [bool]$add) {
        if ($testMode) { Say "(teste) PATH do usuario nao alterado."; return }
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        try {
            $cur = [string]$k.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
            $parts = @($cur -split ';' | Where-Object { $_ })
            $want = $dir.TrimEnd('\')
            $kept = @($parts | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ne $want })
            $has = ($kept.Count -ne $parts.Count)
            if ($add -and -not $has) { $kept = $kept + $dir } elseif ($add) { return } elseif (-not $has) { return }
            $k.SetValue('Path', ($kept -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
        } finally { $k.Close() }
    }

    # ---------- agentes (lista fechada, sem varrer disco) ----------
    function Test-AimHooks([string]$configDir) {
        $f = Join-Path $configDir 'settings.json'
        if (-not (Test-Path -LiteralPath $f)) { return $false }
        $t = Get-Content -LiteralPath $f -Raw
        return ($t -match 'ai-memory' -and $t -match '--event')
    }
    function Get-ClaudeTargets {
        $list = @()
        $claudeCmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $defEnv = $null
        $defDir = $env:CLAUDE_CONFIG_DIR
        if ($defDir) { $defEnv = $defDir } else { $defDir = Join-Path $userHome '.claude' }
        if ((Test-Path -LiteralPath $defDir) -or $claudeCmd) {
            $list += [pscustomobject]@{ Label = 'Claude Code'; Dir = $defDir; EnvDir = $defEnv; Kind = 'claude-code' }
        }
        $acc = Join-Path (Join-Path $userHome '.maestri-local') 'accounts'
        if (Test-Path -LiteralPath $acc) {
            foreach ($d in (Get-ChildItem -LiteralPath $acc -Directory | Sort-Object Name)) {
                $list += [pscustomobject]@{ Label = "Maestri: $($d.Name)"; Dir = $d.FullName; EnvDir = $d.FullName; Kind = 'claude-code' }
            }
        }
        return $list
    }
    function Get-TargetEnv($t, [hashtable]$extra = @{}) {
        $m = @{} + $extra
        if ($t.EnvDir) { $m['CLAUDE_CONFIG_DIR'] = $t.EnvDir }
        return $m
    }

    # =====================================================================
    # DESINSTALAR
    # =====================================================================
    if ($Uninstall) {
        $st = Read-State
        if (-not $st) { Say 'Nada para desinstalar: nao ha ~/.ufba/computer.json (este computador nao foi conectado por este instalador).'; return 0 }
        $mode = [string]$st.install_mode
        $aimPath = if ($st.ai_memory_exe -and (Test-Path -LiteralPath $st.ai_memory_exe)) { [string]$st.ai_memory_exe } else { $null }
        if (-not $aimPath) { $c = Get-Command ai-memory -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { $aimPath = $c.Source } }
        $claudeCmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $dd = if ($st.data_dir) { [string]$st.data_dir } else { $dataDir }
        $targets = @($st.targets)
        Say "Desinstalar (modo de instalacao: $mode)"
        Say '  - registro do MCP "ufba" em cada conta conectada'
        if ($mode -eq 'fresh') { Say '  - hooks do ai-memory nessas contas, a chave gravada, o programa ai-memory e a entrada no PATH (foram instalados por nos)' }
        else { Say '  - perfil "ufba" do ai-memory (os hooks e o servidor padrao da pessoa NAO sao tocados)' }
        Say '  - ~/.ufba/computer.json'
        if ($dry) { Say ''; Say 'Simulacao (-DryRun): nada foi alterado.'; return 0 }
        foreach ($t in $targets) {
            $envm = @{}; if ($t.env_dir) { $envm['CLAUDE_CONFIG_DIR'] = [string]$t.env_dir }
            if ($claudeCmd) {
                $r = Invoke-Native $claudeCmd.Source @('mcp', 'remove', '--scope', 'user', 'ufba') $null $envm
                if ($r.Code -eq 0) { Say "MCP removido: $($t.label)" } else { Warn "nao consegui remover o MCP em $($t.label) (talvez ja nao exista)." }
            } else { Warn "comando claude nao encontrado: remova o MCP ufba de $($t.label) na mao (claude mcp remove --scope user ufba)." }
            if ($mode -eq 'fresh' -and $aimPath) {
                $r = Invoke-Native $aimPath @('--data-dir', $dd, 'uninstall', '--only', 'hooks', '--apply', '--yes') $null $envm
                if ($r.Code -eq 0) { Say "Hooks removidos: $($t.label)" } else { Warn "nao consegui remover os hooks em $($t.label): $($r.Out.Trim())" }
            }
        }
        if ($mode -eq 'profile') {
            if ($aimPath) {
                $r = Invoke-Native $aimPath @('--data-dir', $dd, 'server', 'remove', 'ufba')
                if ($r.Code -eq 0) { Say 'Perfil "ufba" removido do ai-memory.' } else { Warn 'nao consegui remover o perfil "ufba".' }
            } else { Warn 'ai-memory nao encontrado: remova o perfil na mao (ai-memory server remove ufba).' }
        } else {
            foreach ($n in 'auth-token', 'auth-header') {
                $p = Join-Path $dd $n
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
            }
            if ($st.ai_memory_installed_by_ufba -and $st.ai_memory_dir -and (Test-Path -LiteralPath $st.ai_memory_dir)) {
                Remove-Item -LiteralPath ([string]$st.ai_memory_dir) -Recurse -Force
                Edit-UserPath ([string]$st.ai_memory_dir) $false
                Say 'Programa ai-memory removido.'
            }
        }
        Remove-Item -LiteralPath $stateFile -Force
        if ((Test-Path -LiteralPath $stateDir) -and -not (Get-ChildItem -LiteralPath $stateDir -Force)) { Remove-Item -LiteralPath $stateDir -Force }
        Say ''
        Say 'Pronto. A chave deste computador continua valida no servidor ate voce revoga-la:'
        Say 'abra a ufba.app, va em "Computadores conectados" e remova este computador.'
        Say "Os dados que ja estao no servidor nao sao apagados. A pasta de dados local ($dd) foi mantida."
        return 0
    }

    # =====================================================================
    # INSTALAR
    # =====================================================================
    Say "ufba.app: instalador da memoria compartilhada ($InstallerVersion)"
    if ($dry) { Say '*** SIMULACAO (-DryRun): nada sera escrito nesta maquina. ***' }

    # ---- 1. pre-checagem ----
    $osName = 'windows'
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    if (-not $arch -and [Environment]::Is64BitOperatingSystem) { $arch = 'AMD64' }
    if ($arch -ne 'AMD64' -and $arch -ne 'ARM64') { return (Stop-Planned "Arquitetura sem build do ai-memory para Windows: $arch.") }
    if ($arch -eq 'ARM64') { Say 'Windows ARM64: o ai-memory usa o build x86_64 (emulado).' }
    $platKey = 'windows-x64'

    $r = Send-Http GET "$api/memory/install-manifest"
    if ($r.Status -ne 200) { Fail "nao consegui obter o manifesto de instalacao em $api ($(Get-ApiMessage $r))." }
    $manifest = ConvertFrom-JsonSafe $r.Body
    if (-not $manifest -or $manifest.schema -ne 1 -or -not $manifest.aiMemory -or -not $manifest.installer) { Fail 'manifesto de instalacao invalido (schema diferente de 1).' }
    $r2 = Send-Http GET "$mem/identity"
    if ($r2.Status -eq 0) { Fail "nao consegui falar com o servidor de memoria ($mem)." }

    # ---- manifesto: versao minima do instalador e hash deste proprio arquivo ----
    if ([version]$InstallerVersion -lt [version][string]$manifest.installer.minVersion) {
        Fail "este instalador ($InstallerVersion) e antigo demais (minimo $($manifest.installer.minVersion)). Baixe o atual em https://ufba.app/instalar."
    }
    # Hash deste instalador: do proprio arquivo; ou, quando o bootstrap o roda em memoria, o hash que ELE ja conferiu.
    $self = $PSCommandPath
    if ($self -and (Test-Path -LiteralPath $self)) { $selfHash = Get-FileSha256 $self }
    elseif ($env:UFBA_INSTALLER_SHA256 -match '^[0-9a-f]{64}$') { $selfHash = $env:UFBA_INSTALLER_SHA256 }
    else { Fail 'nao consegui conferir o hash deste instalador; use o bootstrap (irm https://ufba.app/install.ps1 | iex) ou baixe o arquivo e rode como arquivo.' }
    $expectSelf = [string]$manifest.installer.files.'install.ps1'
    if ($selfHash -ne $expectSelf.ToLowerInvariant()) {
        Fail 'o hash deste instalador nao confere com o manifesto da ufba.app. Nada foi instalado. Baixe de novo o instalador oficial.'
    }
    $aimVersion = [string]$manifest.aiMemory.version
    $art = $manifest.aiMemory.artifacts.$platKey
    if (-not $art -or -not $art.url -or -not $art.sha256) { Fail "o manifesto nao traz o ai-memory para $platKey." }
    if (-not (Test-AllowedUrl ([string]$art.url))) { Fail 'URL do ai-memory no manifesto nao e https.' }

    # ---- deteccao do modo (3) ----
    $state = Read-State
    $targetsAll = @(Get-ClaudeTargets)
    $aim = $null
    $cmdAim = Get-Command ai-memory -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmdAim) { $aim = $cmdAim.Source } elseif (Test-Path -LiteralPath $binExe) { $aim = $binExe }
    $signals = @()
    if ($cmdAim) { $signals += 'ai-memory no PATH' }
    if (Test-Path -LiteralPath $binExe) { $signals += "programa em $binDir" }
    if (Test-Path -LiteralPath $dataDir) { $signals += "pasta de dados $dataDir" }
    if (Test-Path -LiteralPath (Join-Path $dataDir 'servers.toml')) { $signals += 'servers.toml' }
    foreach ($t in $targetsAll) { if (Test-AimHooks $t.Dir) { $signals += "hooks do ai-memory em $($t.Label)" } }
    $mode = if ($state -and ($state.install_mode -eq 'fresh' -or $state.install_mode -eq 'profile')) { [string]$state.install_mode } elseif ($signals.Count -gt 0) { 'profile' } else { 'fresh' }
    Say ''
    if ($mode -eq 'fresh') { Say ('Modo: fresh (nao ha ai-memory nesta maquina: vou instalar a versao ' + $aimVersion + ' e a ufba.app sera o servidor padrao).') }
    else { Say 'Modo: profile (ja existe ai-memory aqui: o servidor padrao, a chave e o modo de captura dele NAO serao tocados; so registro o perfil "ufba").' }
    if ($signals.Count -gt 0) { Say ('  sinais: ' + ($signals -join '; ')) }

    # ---- profile: pre-condicoes (param ANTES de qualquer escrita ou login) ----
    $existingProfiles = @()
    if ($mode -eq 'profile') {
        if (-not $aim) { return (Stop-Planned ("Encontrei sinais de um ai-memory existente (" + ($signals -join '; ') + "), mas nao achei o programa no PATH nem em $binDir.`nNao vou instalar outro por cima. Coloque o ai-memory $aimVersion no PATH (ou reinstale o seu) e rode de novo.")) }
        $vr = Invoke-Native $aim @('--version')
        if ($vr.Code -ne 0 -or $vr.Out -notmatch '(\d+\.\d+\.\d+)') { return (Stop-Planned "Nao consegui ler a versao do ai-memory em $aim.") }
        $have = [version]$Matches[1]
        if ($have -lt [version]$aimVersion) {
            return (Stop-Planned ("O seu ai-memory e a versao $have, mais antiga que a $aimVersion que a ufba.app exige para o modo perfil.`nUma versao antiga ignora o perfil e mandaria a captura para o seu servidor padrao.`nEste instalador nunca atualiza o ai-memory de ninguem: atualize o seu por conta propria (ai-memory upgrade, ou baixe a $aimVersion em github.com/akitaonrails/ai-memory) e rode de novo.`nPrograma encontrado: $aim"))
        }
        $sl = Invoke-Native $aim @('--data-dir', $dataDir, 'server', 'list', '--json')
        if ($sl.Code -eq 0) { $existingProfiles = @([regex]::Matches($sl.Out, '"name"\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) }
    }

    # ---- 4. agentes ----
    $targets = @()
    Say ''
    if ($targetsAll.Count -eq 0) { return (Stop-Planned 'Nao encontrei nenhum agente compativel (Claude Code ou contas do Maestri). Instale o Claude Code e rode de novo.') }
    Say 'Agentes encontrados:'
    $skippedNoHooks = $false
    foreach ($t in $targetsAll) {
        $hooks = Test-AimHooks $t.Dir
        if ($mode -eq 'profile' -and -not $hooks) {
            Say "  - $($t.Label): SEM hooks do ai-memory; vou pular (veja as opcoes abaixo)."
            $skippedNoHooks = $true
            continue
        }
        if (Confirm-Item "  Conectar $($t.Label) ($($t.Dir))?") { $targets += $t } else { Say "  (pulado: $($t.Label))" }
    }
    if ($skippedNoHooks) {
        Say ''
        Say 'Para conectar um agente sem hooks, instale os hooks do ai-memory (este instalador nunca roda install-hooks no modo perfil) e rode este instalador de novo:'
        Say "  1. (recomendada) so nos repos da ufba: dentro de cada repo do ufba-app rode 'ai-memory install-hooks --agent claude-code --scope project --apply'. Os hooks valem so naquele repo."
        Say "  2. global, so com marcador: 'ai-memory install-hooks --agent claude-code --apply --capture-mode allowlist'. ATENCAO: o modo allowlist vale tambem para o seu servidor pessoal; repos sem .ai-memory.toml deixam de capturar."
        Say "  (conta do Maestri na opcao 2: rode com a variavel CLAUDE_CONFIG_DIR apontando para a pasta da conta.)"
    }
    foreach ($o in @('.codex', '.gemini', '.cursor')) {
        if (Test-Path -LiteralPath (Join-Path $userHome $o)) { Say "  - $o encontrado, mas nao conectado: esse agente usa scripts que nao roteiam perfil de servidor." }
    }
    if ($targets.Count -eq 0) {
        if ($mode -eq 'profile') { return (Stop-Planned 'Nenhum agente com hooks do ai-memory foi selecionado. O modo perfil so conecta agentes que ja tem os hooks do ai-memory: instale-os por uma das opcoes acima e rode de novo.') }
        return (Stop-Planned 'Nenhum agente selecionado.')
    }

    # ---- roots (profile) ----
    $roots = @()
    if ($mode -eq 'profile') {
        foreach ($rr in $Root) {
            foreach ($one in ($rr -split ',')) {
                if (-not $one.Trim()) { continue }
                $full = [IO.Path]::GetFullPath($one.Trim())
                if (-not (Test-Path -LiteralPath $full -PathType Container)) { Fail "a pasta de -Root nao existe: $full" }
                $roots += $full
            }
        }
        $already = ($existingProfiles -contains 'ufba')
        if ($roots.Count -eq 0 -and -not $already) {
            if ($Yes) { Fail 'em -Yes o modo perfil exige -Root <pasta onde ficam os repositorios da ufba.app>.' }
            Say ''
            Say 'Um repositorio so pode escolher o perfil "ufba" se estiver dentro de uma pasta que voce autorizar.'
            $a = Read-Answer 'Pasta onde ficam (ou ficarao) os repositorios da ufba.app'
            if (-not $a.Trim()) { Fail 'preciso de uma pasta para o perfil.' }
            $full = [IO.Path]::GetFullPath($a.Trim())
            if (-not (Test-Path -LiteralPath $full -PathType Container)) { Fail "a pasta nao existe: $full" }
            $roots += $full
        }
        if ($roots.Count -eq 0 -and $already) { Say 'Perfil "ufba" ja existe: mantenho as pastas (roots) que ele ja tem.' }
        $others = @($existingProfiles | Where-Object { $_ -ne 'ufba' })
        if ($others.Count -gt 0 -and $roots.Count -eq 0 -and -not $already) { Fail 'ha mais de um perfil: -Root e obrigatorio.' }
    } elseif ($Root.Count -gt 0) { Warn '-Root so vale no modo perfil; ignorado.' }

    $name = if ($ComputerName) { $ComputerName } elseif ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'computador' }

    # ---- plano ----
    Say ''
    Say 'Plano (o que vai mudar nesta maquina):'
    if ($mode -eq 'fresh') {
        Say "  - instalar o ai-memory $aimVersion em $binDir (sha256 conferido contra o manifesto) e coloca-lo no PATH do usuario"
        Say "  - pasta de dados do ai-memory: $dataDir"
        Say ('  - gravar os hooks do ai-memory (servidor padrao = ufba.app, captura so em repositorios com marcador) em: ' + (($targets | ForEach-Object { $_.Label }) -join ', '))
    } else {
        Say ("  - registrar o perfil de servidor 'ufba' no ai-memory existente (dados em $dataDir)" + $(if ($roots.Count) { ", roots: " + ($roots -join ', ') } else { '' }))
        Say '  - NAO mexer nos hooks, no servidor padrao nem no modo de captura'
    }
    Say ('  - registrar o MCP "ufba" (' + $mcpUrl + ') em: ' + (($targets | ForEach-Object { $_.Label }) -join ', '))
    Say "  - guardar o id deste computador em $stateFile (sem segredo)"
    Say '  - login de dispositivo: voce aprova na ufba.app; a chave deste computador fica so no ai-memory'
    if ($dry) { Say ''; Say 'Simulacao (-DryRun) concluida: nada foi alterado.'; return 0 }

    # ---- 2. binario (fresh) ----
    $installedBinary = $false
    if ($mode -eq 'fresh') {
        $needInstall = $true
        if (Test-Path -LiteralPath $binExe) {
            $vr = Invoke-Native $binExe @('--version')
            if ($vr.Code -eq 0 -and $vr.Out -match [regex]::Escape($aimVersion)) { $needInstall = $false; Say "ai-memory $aimVersion ja instalado."; if ($state -and $state.ai_memory_installed_by_ufba) { $installedBinary = $true } }
        }
        if ($needInstall) {
            Say "Baixando o ai-memory $aimVersion ..."
            $work = Join-Path ([IO.Path]::GetTempPath()) ('ufba-memory-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $work | Out-Null
            try {
                $zip = Join-Path $work 'ai-memory.zip'
                Invoke-WebRequest -UseBasicParsing -Uri ([string]$art.url) -OutFile $zip -TimeoutSec 300
                $got = Get-FileSha256 $zip
                if ($got -ne ([string]$art.sha256).ToLowerInvariant()) { Fail "o SHA-256 do ai-memory baixado ($got) nao confere com o manifesto. Nada foi instalado." }
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $za = [IO.Compression.ZipFile]::OpenRead($zip)
                try {
                    foreach ($e in $za.Entries) {
                        $n = $e.FullName
                        if ($n.StartsWith('/') -or $n.StartsWith('\') -or $n -match '^[A-Za-z]:' -or ($n -split '[\\/]') -contains '..') { Fail "o arquivo do ai-memory tem um caminho suspeito ($n). Nada foi instalado." }
                    }
                } finally { $za.Dispose() }
                $staged = Join-Path $work 'staged'
                Expand-Archive -LiteralPath $zip -DestinationPath $staged
                if (-not (Test-Path -LiteralPath (Join-Path $staged 'ai-memory.exe'))) { Fail 'o arquivo do ai-memory nao tem ai-memory.exe.' }
                $parent = Split-Path $binDir -Parent
                if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                $old = $null
                if (Test-Path -LiteralPath $binDir) { $old = "$binDir.old-" + [guid]::NewGuid().ToString('N').Substring(0, 8); Move-Item -LiteralPath $binDir -Destination $old }
                try { Move-Item -LiteralPath $staged -Destination $binDir } catch { if ($old) { Move-Item -LiteralPath $old -Destination $binDir }; throw }
                if ($old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
                $installedBinary = $true
            } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
            Edit-UserPath $binDir $true
            Say "ai-memory instalado em $binDir (reabra o terminal para ele aparecer no PATH)."
        }
        $aim = $binExe
        $vr = Invoke-Native $aim @('--version')
        if ($vr.Code -ne 0) { Fail 'o ai-memory instalado nao executa nesta maquina.' }
    }

    # ---- 3. login de dispositivo ----
    Say ''
    $r = Send-Http POST "$api/oauth/device_authorization" @{} @{ client_id = 'ufba-installer'; scope = 'memory:connect'; computer_name = $name; os = $osName } 'application/x-www-form-urlencoded'
    if ($r.Status -ne 200) { Fail "nao consegui iniciar o login de dispositivo: $(Get-ApiMessage $r)" }
    $dev = ConvertFrom-JsonSafe $r.Body
    if (-not $dev -or -not $dev.device_code -or -not $dev.user_code) { Fail 'resposta inesperada no login de dispositivo.' }
    Say 'Para autorizar este computador:'
    Say "  1. abra  $($dev.verification_uri)"
    Say "  2. confira que o codigo na tela e  $($dev.user_code)  (so aprove se ele apareceu AQUI agora)"
    $complete = [string]$dev.verification_uri_complete
    if ($env:UFBA_NO_BROWSER -ne '1' -and -not $testMode -and $complete -match '^https://([^/]+\.)?ufba\.app(/|$)') { try { Start-Process $complete } catch { } }
    $interval = [double]$dev.interval; if ($interval -lt 1) { $interval = 5 }
    $deadline = (Get-Date).AddSeconds([double]$dev.expires_in)
    $short = $null
    Say 'Aguardando a sua aprovacao ...'
    while ((Get-Date) -lt $deadline) {
        Wait-Seconds $interval
        $pr = Send-Http POST "$api/token" @{} @{ grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; device_code = [string]$dev.device_code; client_id = 'ufba-installer' } 'application/x-www-form-urlencoded'
        if ($pr.Status -eq 200) { $tj = ConvertFrom-JsonSafe $pr.Body; if ($tj -and $tj.access_token) { $short = [string]$tj.access_token; break } ; Fail 'resposta inesperada do token.' }
        if ($pr.Status -eq 0) { continue }
        $pj = ConvertFrom-JsonSafe $pr.Body
        $code = if ($pj) { [string]$pj.error } else { '' }
        switch ($code) {
            'authorization_pending' { continue }
            'slow_down' { $interval += 5; continue }
            'access_denied' { Write-Host ''; Write-Host 'A autorizacao foi negada na ufba.app. Nada foi instalado alem do programa (se era o modo fresh).'; return 4 }
            'expired_token' { Write-Host ''; Write-Host 'O codigo expirou. Rode o instalador de novo para ver um novo.'; return 4 }
            default { Fail "login de dispositivo falhou: $(Get-ApiMessage $pr)" }
        }
    }
    if (-not $short) { Write-Host ''; Write-Host 'O tempo para aprovar acabou. Rode o instalador de novo.'; return 4 }
    Say 'Autorizado.'

    # ---- POST /memory/computers (idempotente por computer_id) ----
    $computerId = if ($state -and $state.computer_id) { [string]$state.computer_id } else { $null }
    $agentNames = @('claude-code')
    $payload = @{ name = $name; os = $osName; agents = $agentNames; client_version = "ai-memory $aimVersion"; install_mode = $mode }
    if ($computerId) { $payload.computer_id = $computerId }
    $body = ConvertTo-Json -InputObject $payload -Depth 4
    $key = $null; $created = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $cr = Send-Http POST "$api/memory/computers" @{ Authorization = "Bearer $short" } ([Text.Encoding]::UTF8.GetBytes($body)) 'application/json'
        if ($cr.Status -eq 200) {
            $created = ConvertFrom-JsonSafe $cr.Body
            if ($created -and $created.key -and $created.computer_id) { break }
            $created = $null
        } elseif ($cr.Status -ne 0 -and $cr.Status -lt 500) { Fail "a ufba.app recusou o pedido: $(Get-ApiMessage $cr)" }
        if ($attempt -lt 3) { Warn 'a resposta se perdeu ou o servidor falhou; tentando de novo (com o mesmo id do computador, a chave e trocada com seguranca).'; Wait-Seconds (2 * $attempt) }
    }
    if (-not $created) { Fail 'nao consegui registrar o computador. Rode o instalador de novo em alguns minutos.' }
    $key = [string]$created.key
    $created.key = $null
    $computerId = [string]$created.computer_id
    $username = [string]$created.username
    if (([string]$created.memory_url).TrimEnd('/') -ne $mem) { Fail 'o endereco do servidor de memoria devolvido pela API nao e o esperado. Nada foi gravado.' }

    $stateObj = [ordered]@{
        schema = 1; computer_id = $computerId; name = $name; os = $osName; install_mode = $mode
        installer_version = $InstallerVersion; ai_memory_version = $aimVersion; ai_memory_exe = $aim
        ai_memory_dir = $(if ($mode -eq 'fresh') { $binDir } else { $null }); ai_memory_installed_by_ufba = $installedBinary
        data_dir = $dataDir; roots = @($roots); profile = $(if ($mode -eq 'profile') { 'ufba' } else { $null })
        targets = @(); mcp_url = $mcpUrl; updated_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-State $stateObj

    # ---- 5. gravar a chave ----
    $written = @()
    try {
        foreach ($t in $targets) {
            if ($mode -eq 'fresh') {
                $args2 = @('--data-dir', $dataDir, 'install-hooks', '--agent', 'claude-code', '--server-url', $mem, '--capture-mode', 'allowlist', '--as-user', $username, '--apply')
                $res = Invoke-Native $aim $args2 $null (Get-TargetEnv $t @{ AI_MEMORY_AUTH_TOKEN = $key }) $key
                if ($res.Code -ne 0) { Fail "install-hooks falhou em $($t.Label): $($res.Out.Trim())" }
            }
            $written += $t
        }
        if ($mode -eq 'profile') {
            $args2 = @('--data-dir', $dataDir, 'server', 'add', 'ufba', '--url', $mem)
            foreach ($rt in $roots) { $args2 += @('--root', $rt) }
            $args2 += '--auth-token-stdin'
            $res = Invoke-Native $aim $args2 $key @{} $key
            if ($res.Code -ne 0) { Fail "server add falhou: $($res.Out.Trim())" }
        }
    } catch {
        Write-Host ''
        Write-Host 'Nao consegui gravar a chave; por seguranca NAO confirmei o computador. Em ate 10 minutos a ufba.app revoga a chave sozinha.'
        Write-Host 'Corrija o problema e rode o instalador de novo (ele reaproveita o id deste computador).'
        throw
    } finally { $key = $null; $short2 = $null }
    Say 'Chave gravada no ai-memory (nao aparece em nenhum log).'

    # ---- confirmar (consome o token curto) ----
    $confirmed = $false
    for ($i = 1; $i -le 3 -and -not $confirmed; $i++) {
        $cf = Send-Http POST "$api/memory/computers/$computerId/confirm" @{ Authorization = "Bearer $short" }
        if ($cf.Status -eq 204 -or $cf.Status -eq 200) { $confirmed = $true } elseif ($cf.Status -ne 0 -and $cf.Status -lt 500) { Fail "a ufba.app nao confirmou o computador: $(Get-ApiMessage $cf)" } else { Wait-Seconds (2 * $i) }
    }
    if (-not $confirmed) { Fail 'a chave foi gravada, mas nao consegui confirmar com a ufba.app. Rode o instalador de novo (em ate 10 minutos a chave nao confirmada e revogada).' }
    $short = $null

    # ---- 7. MCP ----
    $claudeCmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $mcpOk = @(); $targetRecs = @()
    foreach ($t in $targets) {
        $targetRecs += [ordered]@{ label = $t.Label; kind = $t.Kind; config_dir = $t.Dir; env_dir = $t.EnvDir }
        if (-not $claudeCmd) { Warn "comando claude nao encontrado; em $($t.Label) rode: claude mcp add --transport http --scope user ufba $mcpUrl"; continue }
        $envm = Get-TargetEnv $t
        $g = Invoke-Native $claudeCmd.Source @('mcp', 'get', 'ufba') $null $envm
        if ($g.Code -eq 0) { Say "MCP ufba ja registrado: $($t.Label)"; $mcpOk += $t.Label; continue }
        $ad = Invoke-Native $claudeCmd.Source @('mcp', 'add', '--transport', 'http', '--scope', 'user', 'ufba', $mcpUrl) $null $envm
        if ($ad.Code -eq 0) { Say "MCP ufba registrado: $($t.Label)"; $mcpOk += $t.Label } else { Warn "nao consegui registrar o MCP em $($t.Label): $($ad.Out.Trim())" }
    }
    $stateObj.targets = @($targetRecs)
    $stateObj.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    Write-State $stateObj

    # ---- 9. auto-teste (so leitura; a chave ja nao esta mais em memoria, entao usa o que o ai-memory guardou) ----
    Say ''
    Say 'Verificando:'
    if ($mode -eq 'profile') {
        $sl = Invoke-Native $aim @('--data-dir', $dataDir, 'server', 'list', '--json')
        if ($sl.Code -eq 0 -and $sl.Out -match '"name"\s*:\s*"ufba"') { Say '  ok: o perfil "ufba" esta registrado.' } else { Warn 'o perfil "ufba" nao apareceu em "ai-memory server list".' }
        $selfRoot = if ($roots.Count) { $roots[0] } else { $null }
        if ($selfRoot) {
            $probe = Join-Path $selfRoot ('.ufba-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            try {
                New-Item -ItemType Directory -Path $probe | Out-Null
                [IO.File]::WriteAllText((Join-Path $probe '.ai-memory.toml'), "workspace = `"ufba-app`"`nproject = `"selftest`"`nserver = `"ufba`"`n")
                Push-Location -LiteralPath $probe
                try { $cc = Invoke-Native $aim @('--data-dir', $dataDir, 'hook', '--event', 'user-prompt-submit', '--agent', 'claude-code', '--check-capture') '{}' } finally { Pop-Location }
                if ($cc.Out -match '"server_resolution"\s*:\s*"marker"') { Say '  ok: um repositorio com marcador server = "ufba" dentro da pasta autorizada captura para a ufba.app.' }
                else { Warn 'o teste de captura nao devolveu server_resolution = marker (confira a pasta autorizada e rode: ai-memory hook --check-capture).' }
            } finally { Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } else {
        Say '  ok: hooks gravados (servidor padrao = ufba.app, captura so em repositorios com marcador).'
    }
    $idr = $null
    $keyFile = if ($mode -eq 'fresh') { Join-Path $dataDir 'auth-token' } else { Join-Path (Join-Path $dataDir 'auth-tokens') 'ufba' }
    if (Test-Path -LiteralPath $keyFile) {
        $k2 = (Get-Content -LiteralPath $keyFile -TotalCount 1)
        if ($k2) { $idr = Send-Http GET "$mem/identity" @{ Authorization = "Bearer $($k2.Trim())" }; $k2 = $null }
    }
    if ($idr -and $idr.Status -eq 200 -and $idr.Body -match [regex]::Escape($username)) { Say "  ok: o servidor de memoria reconhece este computador como a sua conta (user:$username)." }
    else { Warn 'nao consegui confirmar a identidade no servidor de memoria (/identity). Se algo falhar depois, rode o instalador de novo.' }

    # ---- 10. resumo ----
    Say ''
    Say '================ Resumo ================'
    Say "Modo: $mode    Computador: $name    Id: $computerId"
    if ($mode -eq 'fresh') { Say ("- ai-memory $aimVersion em $binDir; hooks gravados em: " + (($targets | ForEach-Object { $_.Label }) -join ', ')) }
    else { Say ('- perfil "ufba" registrado' + $(if ($roots.Count) { ' (roots: ' + ($roots -join ', ') + ')' } else { '' }) + '; seus hooks e servidor padrao ficaram como estavam') }
    Say ('- MCP "ufba" registrado em: ' + $(if ($mcpOk.Count) { $mcpOk -join ', ' } else { '(nenhuma conta)' }))
    Say "- id do computador (sem segredo): $stateFile"
    if ($mode -eq 'profile') {
        Say ''
        Say 'Para um repositorio capturar para a ufba.app, ponha na raiz dele (dentro da pasta autorizada) um .ai-memory.toml com:'
        Say '  workspace = "ufba-app"'
        Say '  project   = "<projeto>"'
        Say '  server    = "ufba"'
    }
    Say ''
    Say 'Para desfazer: rode este instalador com -Uninstall, e remova este computador em "Computadores conectados" na ufba.app (isso revoga a chave).'
    Say 'No Claude Code, rode /mcp e autentique o servidor "ufba" (login com Google @ufba.br).'
    return 0
}

$ufbaExit = Invoke-UfbaMemory
if ($ufbaExit -is [array]) { $ufbaExit = $ufbaExit[-1] }
# Como arquivo (-File) o codigo de saida vale; em memoria (bootstrap/iex) so seta $LASTEXITCODE, para nao fechar o terminal.
if ($ufbaExit -ne 0) { if ($PSCommandPath) { exit $ufbaExit } else { $global:LASTEXITCODE = $ufbaExit } }
