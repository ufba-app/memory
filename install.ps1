# Bootstrap de https://memory.ufba.app/install.ps1  (irm https://memory.ufba.app/install.ps1 | iex)
#
# Este arquivo so faz tres coisas: baixa o instalador VERSIONADO e IMUTAVEL do release do GitHub (ufba-app/memory),
# confere o SHA-256 embutido aqui e o executa. Os marcadores @@...@@ abaixo sao trocados pelo CI (tools/build-release.mjs)
# a cada release; no git eles ficam como placeholder e o bootstrap RECUSA rodar assim.
# O instalador roda em memoria (sem salvar .ps1), entao a ExecutionPolicy padrao do Windows nao atrapalha.
# Argumentos: & ([scriptblock]::Create((irm https://memory.ufba.app/install.ps1))) -Yes -Root C:\dev\ufba
# Tudo fica dentro de Install-UfbaMemory, chamada na ultima linha: um download truncado nao executa nada.

function Install-UfbaMemory {
    $ErrorActionPreference = 'Stop'
    $version = '@@INSTALLER_VERSION@@'
    $expected = '@@INSTALLER_SHA256@@'
    $base = 'https://github.com/ufba-app/memory/releases/download'
    $test = ($env:UFBA_INSTALLER_TEST -eq '1')
    if ($test -and $env:UFBA_RELEASE_BASE) { $base = $env:UFBA_RELEASE_BASE.TrimEnd('/') }
    if ($version -like '*@@*' -or $expected -like '*@@*') { throw 'ufba: este bootstrap e um modelo (placeholder) e nao pode ser executado; use o de https://memory.ufba.app/install.ps1' }
    if ($expected -notmatch '^[0-9a-f]{64}$') { throw 'ufba: hash embutido invalido' }
    if (-not ($base -like 'https://*' -or ($test -and $base -like 'http://127.0.0.1*'))) { throw 'ufba: so aceito https' }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    try { $bytes = (New-Object Net.WebClient).DownloadData("$base/installer-v$version/ufba-memory.ps1") }
    catch { throw 'ufba: nao consegui baixar o instalador' }
    $sha = [Security.Cryptography.SHA256]::Create()
    $got = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    if ($got -ne $expected) { throw "ufba: o hash do instalador NAO confere (esperado $expected, veio $got). Nada foi executado." }
    $text = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    $env:UFBA_INSTALLER_SHA256 = $got
    try { & ([scriptblock]::Create($text)) @args } finally { Remove-Item Env:\UFBA_INSTALLER_SHA256 -ErrorAction SilentlyContinue }
}

Install-UfbaMemory @args
