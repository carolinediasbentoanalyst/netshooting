<<<<<<< HEAD
<#
.SYNOPSIS
  Troubleshooting de rede para Windows Server 2016 a 2025 (PowerShell).

.DESCRIPTION
  Coleta informações de rede (IPv6 e IPv4), valida conectividade (ICMP/TRACEROUTE/DNS/TCP/PATHPING),
  exporta relatório. Gera TXT + JSON (e opcional ZIP). Não altera configurações.
  É interativo: mantém 3 valores padrões para testes, mas permite alterar IPs/Domínios.
  PATHPING roda via command line por até 4 minutos e exibe progresso ao usuário.
  O destino do PATHPING também é escolhido pelo usuário (padrão: 8.8.8.8).

.PARAMETER OutputDir
  Pasta de saída.

.PARAMETER Targets
  Alvos de teste (hosts/IPs).

.PARAMETER TcpPorts
  Portas TCP para testar em cada alvo (quando fizer sentido).

.PARAMETER DnsNames
  Nomes DNS para testar resolução.

.PARAMETER Zip
  Compacta os resultados ao final.

.EXAMPLE
  .\Network-Troubleshoot.ps1 -Zip

.EXAMPLE
  .\Network-Troubleshoot.ps1 -Targets @("10.0.0.1","dc01.contoso.local","8.8.8.8") -TcpPorts 53,88,135,389,445,3389
#>

[CmdletBinding()]
param(
  [string]$OutputDir = (Join-Path `
    ([Environment]::GetFolderPath('MyDocuments')) `
    ("netshooting_results_{0}" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))),

  [string[]]$Targets,
  [int[]]$TcpPorts = @(53, 80, 443, 3389),
  [string[]]$DnsNames,
  [switch]$Zip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# --------------------------
# Helpers
# --------------------------
function New-Folder {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-Log {
  param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
  )
  $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message

  # IMPORTANTE: não pode vazar output para o pipeline (senão quebra retornos de funções)
  $line | Tee-Object -FilePath $global:MainLog -Append | Out-Null
}

function Save-Text {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string]$Content
  )
  $Content | Out-File -FilePath $FilePath -Encoding UTF8 -Force
}

function Run-CmdToFile {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][object]$Args
  )

  try {
    if ($Args -is [string]) {
      Write-Log "Executando: $Exe $Args"
      $out = & $Exe $Args 2>&1 | Out-String
    } else {
      $argsText = ($Args | ForEach-Object { $_ }) -join " "
      Write-Log "Executando: $Exe $argsText"
      $out = & $Exe @Args 2>&1 | Out-String
    }
    Save-Text -FilePath $FilePath -Content $out
  } catch {
    Save-Text -FilePath $FilePath -Content ("Falha ao executar: {0} {1}`r`nErro: {2}" -f $Exe, ($Args -join " "), $_)
    Write-Log "Falha ao executar: $Exe :: $($_.Exception.Message)" "WARN"
  }
}
function Prompt-List {
  param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string[]]$Defaults,
    [string]$Hint = "Separe por vírgula. Enter para manter o padrão."
  )
  Write-Host ""
  Write-Host $Title -ForegroundColor Cyan
  Write-Host "Padrão: $($Defaults -join ', ')"
  Write-Host $Hint
  $raw = Read-Host "Novo valor (ou Enter)"
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Defaults }
  return ($raw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Prompt-Single {
  param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Default
  )
  Write-Host ""
  Write-Host $Title -ForegroundColor Cyan
  Write-Host "Padrão: $Default"
  $raw = Read-Host "Novo valor (ou Enter)"
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  return $raw.Trim()
}

function Get-NowStamp { "{0:yyyyMMdd_HHmmss}" -f (Get-Date) }

function Sanitize-Name([string]$s) {
  return ($s -replace '[\\/:*?"<>| ]','_')
}

function Test-TcpPort {
  param(
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][int]$Port
  )
  $result = [ordered]@{
    target = $Target
    port = $Port
    success = $false
    error = $null
    remoteAddress = $null
    tcpTestSucceeded = $null
  }

  try {
    # Captura em variável para não "printar" no console
    $tnc = Test-NetConnection -ComputerName $Target -Port $Port -InformationLevel Detailed -WarningAction SilentlyContinue
    $result.remoteAddress = $tnc.RemoteAddress
    $result.tcpTestSucceeded = $tnc.TcpTestSucceeded
    $result.success = [bool]$tnc.TcpTestSucceeded
  } catch {
    $result.error = $_.Exception.Message
  }
  [pscustomobject]$result
}

# --------------------------
# PathPing (com progresso, sem travar)
# --------------------------
function Invoke-PathPingWithProgress {
  param(
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][string]$OutFile,
    [int]$DurationSeconds = 240,
    [int]$ProgressEverySeconds = 5,
    [int]$TimeoutPerHopMs = 3000
  )

  New-Folder -Path (Split-Path -Parent $OutFile)

  Write-Log "PathPing: iniciando por $DurationSeconds s (target=$Target). OutFile=$OutFile"
  Write-Host ""
  Write-Host ("PathPing em execução por {0} minutos (destino: {1})..." -f ([Math]::Round($DurationSeconds/60,2)), $Target) -ForegroundColor Cyan

  # pathping não tem "duração total"; então limitamos por tempo e matamos o processo se necessário.
  $args = @("-w", "$TimeoutPerHopMs", $Target)

  $tempOut = Join-Path ([System.IO.Path]::GetTempPath()) ("pathping_stdout_{0}.txt" -f (Get-NowStamp))
  $tempErr = Join-Path ([System.IO.Path]::GetTempPath()) ("pathping_stderr_{0}.txt" -f (Get-NowStamp))

  # Garante limpeza anterior (se existir)
  Remove-Item -LiteralPath $tempOut, $tempErr -Force -ErrorAction SilentlyContinue

  $p = Start-Process -FilePath "pathping.exe" `
                     -ArgumentList $args `
                     -NoNewWindow `
                     -PassThru `
                     -RedirectStandardOutput $tempOut `
                     -RedirectStandardError $tempErr

  $sw = [Diagnostics.Stopwatch]::StartNew()

  while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $DurationSeconds) {
    Start-Sleep -Seconds $ProgressEverySeconds

    $elapsed = [int]$sw.Elapsed.TotalSeconds
    $mm = [int]($elapsed / 60)
    $ss = $elapsed % 60
    $totalMm = [int]($DurationSeconds / 60)
    $totalSs = $DurationSeconds % 60

    Write-Host ("  Executando... {0:00}:{1:00} / {2:00}:{3:00}" -f $mm,$ss,$totalMm,$totalSs)
  }

  $timedOut = $false
  if (-not $p.HasExited) {
    $timedOut = $true
    Write-Host "  Tempo limite atingido. Finalizando pathping..." -ForegroundColor Yellow
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
  }

  $sw.Stop()

  # Monta relatório final a partir dos arquivos redirecionados
  $stdoutText = ""
  $stderrText = ""
  try { if (Test-Path -LiteralPath $tempOut) { $stdoutText = Get-Content -LiteralPath $tempOut -Raw -ErrorAction SilentlyContinue } } catch {}
  try { if (Test-Path -LiteralPath $tempErr) { $stderrText = Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue } } catch {}

  $content = @()
  $content += "=== PATHPING ==="
  $content += ("Target: {0}" -f $Target)
  $content += ("Args: pathping.exe {0}" -f (($args | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join " "))
  $content += ("DurationSeconds (limit): {0}" -f $DurationSeconds)
  $content += ("TimedOut: {0}" -f $timedOut)
  $content += ("FinishedAt: {0}" -f (Get-Date).ToString("o"))
  $content += ""
  $content += "=== STDOUT ==="
  $content += $stdoutText
  $content += ""
  $content += "=== STDERR ==="
  $content += $stderrText

  Save-Text -FilePath $OutFile -Content ($content -join "`r`n")

  # Limpa temporários
  Remove-Item -LiteralPath $tempOut, $tempErr -Force -ErrorAction SilentlyContinue

  Write-Host "PathPing concluído. Relatório: $OutFile" -ForegroundColor Green

  return [pscustomobject]@{
    target = $Target
    executed = $true
    durationSeconds = $DurationSeconds
    timedOut = $timedOut
    outputFile = (Split-Path -Leaf $OutFile)
    usedArgs = "pathping.exe " + (($args | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join " ")
  }
}

# --------------------------
# Setup output
# --------------------------
New-Folder -Path $OutputDir
$SubDirs = @{
  Info  = (Join-Path $OutputDir "01_info")
  Tests = (Join-Path $OutputDir "02_tests")
  Dns   = (Join-Path $OutputDir "03_dns")
  Raw   = (Join-Path $OutputDir "99_raw")
}
$SubDirs.Values | ForEach-Object { New-Folder -Path $_ }

$global:MainLog = Join-Path $OutputDir "Network-Troubleshoot.log.txt"
Write-Log "Início do troubleshooting. OutputDir=$OutputDir"

# --------------------------
# Interactive defaults
# --------------------------
$defaultTargets  = @("8.8.8.8","1.1.1.1","www.microsoft.com")
$defaultDnsNames = @("google.com","microsoft.com","cloudflare.com")

if (-not $Targets -or $Targets.Count -eq 0) {
  $Targets = Prompt-List -Title "Alvos de teste (Targets)" -Defaults $defaultTargets
} else {
  Write-Log "Targets fornecidos por parâmetro: $($Targets -join ', ')"
}

if (-not $DnsNames -or $DnsNames.Count -eq 0) {
  $DnsNames = Prompt-List -Title "Nomes DNS para teste (DnsNames)" -Defaults $defaultDnsNames
} else {
  Write-Log "DnsNames fornecidos por parâmetro: $($DnsNames -join ', ')"
}

$PathPingTarget = Prompt-Single -Title "Destino para PathPing (rota/perda/latência). (Enter = 8.8.8.8)" -Default "8.8.8.8"

# --------------------------
# Report object
# --------------------------
$report = [ordered]@{
  meta = [ordered]@{
    startedAt = (Get-Date).ToString("o")
    computerName = $env:COMPUTERNAME
    user = "$env:USERDOMAIN\$env:USERNAME"
    psVersion = $PSVersionTable.PSVersion.ToString()
    os = $null
  }
  networkInfo = [ordered]@{}
  tests = [ordered]@{
    icmp = @()
    traceroute = @()
    dns = @()
    tcp = @()
    pathping = $null
  }
  errors = @()
}

# --------------------------
# Collect OS
# --------------------------
try {
  $os = Get-CimInstance -ClassName Win32_OperatingSystem
  $report.meta.os = [ordered]@{
    caption = $os.Caption
    version = $os.Version
    buildNumber = $os.BuildNumber
    lastBootUpTime = $os.LastBootUpTime
  }
} catch {
  $report.errors += "Falha ao obter Win32_OperatingSystem: $($_.Exception.Message)"
  Write-Log "Falha ao obter OS via CIM: $($_.Exception.Message)" "WARN"
}

# --------------------------
# Raw snapshots
# --------------------------
# IPv4
Run-CmdToFile -FilePath (Join-Path $SubDirs.Raw "netsh_ipv4_show_addresses.txt") -Exe "netsh" -Args @("interface","ipv4","show","addresses")
Run-CmdToFile -FilePath (Join-Path $SubDirs.Raw "netsh_ipv4_show_dnsservers.txt") -Exe "netsh" -Args @("interface","ipv4","show","dnsservers")
Run-CmdToFile -FilePath (Join-Path $SubDirs.Raw "netsh_ipv4_show_route.txt") -Exe "netsh" -Args @("interface","ipv4","show","route")

# IPv6
Run-CmdToFile -FilePath (Join-Path $SubDirs.Raw "netsh_ipv6_show_addresses.txt") -Exe "netsh" -Args @("interface","ipv6","show","addresses")
Run-CmdToFile -FilePath (Join-Path $SubDirs.Raw "netsh_ipv6_show_dnsservers.txt") -Exe "netsh" -Args @("interface","ipv6","show","dnsservers")
Run-CmdToFile -FilePath (Join-Path $SubDirs.Raw "netsh_ipv6_show_route.txt") -Exe "netsh" -Args @("interface","ipv6","show","route")

# --------------------------
# Structured network info
# --------------------------
try {
  $adapters = Get-NetAdapter -ErrorAction Stop | Sort-Object -Property ifIndex
  $ipcfg    = Get-NetIPConfiguration -ErrorAction Stop | Sort-Object -Property InterfaceIndex
  $ipaddr   = Get-NetIPAddress -ErrorAction Stop | Sort-Object -Property InterfaceIndex, AddressFamily
  $routes   = Get-NetRoute -ErrorAction SilentlyContinue | Sort-Object -Property InterfaceIndex, DestinationPrefix
  $dnsSrv   = Get-DnsClientServerAddress -ErrorAction SilentlyContinue | Sort-Object -Property InterfaceIndex, AddressFamily

  $report.networkInfo.adapters = $adapters | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress, ifIndex
  $report.networkInfo.ipConfiguration = $ipcfg | Select-Object InterfaceAlias, InterfaceIndex, IPv4Address, IPv6Address, IPv4DefaultGateway, IPv6DefaultGateway, DNSServer
  $report.networkInfo.ipAddresses = $ipaddr | Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, IPAddress, PrefixLength, Type, ValidLifetime, PreferredLifetime
  $report.networkInfo.routes = $routes | Select-Object InterfaceIndex, InterfaceAlias, DestinationPrefix, NextHop, RouteMetric, Protocol
  $report.networkInfo.dnsServers = $dnsSrv | Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, ServerAddresses

  ($adapters | Format-Table -AutoSize | Out-String) | Out-File (Join-Path $SubDirs.Info "adapters.txt") -Encoding UTF8
  ($ipcfg    | Format-List | Out-String) | Out-File (Join-Path $SubDirs.Info "ipconfiguration.txt") -Encoding UTF8
  ($ipaddr   | Format-Table -AutoSize | Out-String) | Out-File (Join-Path $SubDirs.Info "ipaddresses.txt") -Encoding UTF8
  ($routes   | Select-Object -First 500 | Format-Table -AutoSize | Out-String) | Out-File (Join-Path $SubDirs.Info "routes_first500.txt") -Encoding UTF8
  ($dnsSrv   | Format-List | Out-String) | Out-File (Join-Path $SubDirs.Info "dnsservers.txt") -Encoding UTF8
} catch {
  $report.errors += "Falha ao coletar info de rede: $($_.Exception.Message)"
  Write-Log "Falha ao coletar info de rede: $($_.Exception.Message)" "WARN"
}

# --------------------------
# Tests: ICMP + Traceroute
# --------------------------
foreach ($t in $Targets) {
  $tTrim = $t.Trim()
  if (-not $tTrim) { continue }

  Write-Log "Testes ICMP para: $tTrim"
  $icmpObj = [ordered]@{
    target = $tTrim
    success = $false
    details = $null
    error = $null
  }

  try {
    $p = Test-Connection -ComputerName $tTrim -Count 4 -ErrorAction Stop
    $icmpObj.success = $true
    $icmpObj.details = $p | Select-Object Address, IPV4Address, IPV6Address, ResponseTime, StatusCode
    ($p | Format-Table -AutoSize | Out-String) | Out-File (Join-Path $SubDirs.Tests ("icmp_{0}.txt" -f (Sanitize-Name $tTrim))) -Encoding UTF8
  } catch {
    $icmpObj.error = $_.Exception.Message
    Save-Text -FilePath (Join-Path $SubDirs.Tests ("icmp_{0}.txt" -f (Sanitize-Name $tTrim))) -Content ("Falha no ICMP: {0}" -f $_.Exception.Message)
    Write-Log "ICMP falhou para $tTrim : $($_.Exception.Message)" "WARN"
  }
  $report.tests.icmp += [pscustomobject]$icmpObj

  Write-Log "Traceroute para: $tTrim"
  $trFile = Join-Path $SubDirs.Tests ("tracert_{0}.txt" -f (Sanitize-Name $tTrim))
  Run-CmdToFile -FilePath $trFile -Exe "tracert" -Args @("-d","-w","2000","-h","30",$tTrim)

  $report.tests.traceroute += [pscustomobject]@{
    target = $tTrim
    outputFile = (Split-Path -Leaf $trFile)
  }
}

# --------------------------
# Tests: DNS
# --------------------------
foreach ($name in $DnsNames) {
  $nTrim = $name.Trim()
  if (-not $nTrim) { continue }

  Write-Log "DNS Resolve-DnsName para: $nTrim"
  $dnsObj = [ordered]@{
    name = $nTrim
    success = $false
    answers = $null
    error = $null
  }

  try {
    $ans = Resolve-DnsName -Name $nTrim -ErrorAction Stop
    $dnsObj.success = $true
    $dnsObj.answers = $ans | Select-Object Name, Type, TTL, Section, IPAddress, NameHost
    ($ans | Format-Table -AutoSize | Out-String) | Out-File (Join-Path $SubDirs.Dns ("dns_{0}.txt" -f (Sanitize-Name $nTrim))) -Encoding UTF8
  } catch {
    $dnsObj.error = $_.Exception.Message
    Save-Text -FilePath (Join-Path $SubDirs.Dns ("dns_{0}.txt" -f (Sanitize-Name $nTrim))) -Content ("Falha no DNS: {0}" -f $_.Exception.Message)
    Write-Log "DNS falhou para $nTrim : $($_.Exception.Message)" "WARN"
  }

  $report.tests.dns += [pscustomobject]$dnsObj
}

# --------------------------
# Tests: TCP ports
# --------------------------
foreach ($t in $Targets) {
  $tTrim = $t.Trim()
  if (-not $tTrim) { continue }

  foreach ($p in $TcpPorts) {
    Write-Log "TCP Test-NetConnection: $tTrim : $p"
    $tcpRes = Test-TcpPort -Target $tTrim -Port $p
    $report.tests.tcp += $tcpRes

    $tcpLine = "{0} {1}:{2} success={3} remoteAddress={4} tcpTestSucceeded={5} error={6}" -f `
      (Get-Date).ToString("s"), $tcpRes.target, $tcpRes.port, $tcpRes.success, $tcpRes.remoteAddress, $tcpRes.tcpTestSucceeded, $tcpRes.error
    $tcpLine | Out-File (Join-Path $SubDirs.Tests "tcp_tests.txt") -Encoding UTF8 -Append
  }
}

# --------------------------
# Test: PathPing (4 minutos com progresso)
# --------------------------
$pathpingReportFile = Join-Path $SubDirs.Tests ("pathping_{0}_{1}.txt" -f (Sanitize-Name $PathPingTarget), (Get-NowStamp))

# Inicializa sempre (não quebra summary/json)
$report.tests.pathping = [pscustomobject]@{
  target = $PathPingTarget
  executed = $false
  durationSeconds = 240
  timedOut = $null
  outputFile = (Split-Path -Leaf $pathpingReportFile)
  usedArgs = $null
  note = "PathPing não executado."
}

try {
  $res = Invoke-PathPingWithProgress -Target $PathPingTarget -OutFile $pathpingReportFile -DurationSeconds 240 -ProgressEverySeconds 5 -TimeoutPerHopMs 3000
  $report.tests.pathping = $res
  $report.tests.pathping | Add-Member -NotePropertyName note -NotePropertyValue "Executado por até 4 minutos com progresso no console." -Force
} catch {
  $msg = "Falha no PathPing: $($_.Exception.Message)"
  Write-Log $msg "WARN"
  Save-Text -FilePath $pathpingReportFile -Content $msg
  $report.tests.pathping.note = $msg
}

# --------------------------
# Finalize: write summary TXT + JSON (+ ZIP optional)
# --------------------------
$summaryPath = Join-Path $OutputDir "Network-Troubleshoot.SUMMARY.txt"
$jsonPath    = Join-Path $OutputDir "Network-Troubleshoot.json"

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("=== Network Troubleshoot (Windows Server 2016-2025) ===")
[void]$sb.AppendLine("Started:  $($report.meta.startedAt)")
[void]$sb.AppendLine("Computer: $($report.meta.computerName)")
[void]$sb.AppendLine("User:     $($report.meta.user)")
if ($report.meta.os) {
  [void]$sb.AppendLine("OS:       $($report.meta.os.caption) ($($report.meta.os.version) build $($report.meta.os.buildNumber))")
}
[void]$sb.AppendLine("PS:       $($report.meta.psVersion)")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Targets:  $($Targets -join ', ')")
[void]$sb.AppendLine("TCPPorts: $($TcpPorts -join ', ')")
[void]$sb.AppendLine("DNSNames: $($DnsNames -join ', ')")
[void]$sb.AppendLine("PathPing: $PathPingTarget")
[void]$sb.AppendLine("")

[void]$sb.AppendLine("== ICMP (Ping) ==")
foreach ($r in $report.tests.icmp) {
  [void]$sb.AppendLine(("{0} :: success={1} error={2}" -f $r.target, $r.success, $r.error))
}
[void]$sb.AppendLine("")

[void]$sb.AppendLine("== TCP Ports ==")
$grouped = $report.tests.tcp | Group-Object -Property target
foreach ($g in $grouped) {
  [void]$sb.AppendLine("-- {0} --" -f $g.Name)
  foreach ($tr in $g.Group | Sort-Object port) {
    [void]$sb.AppendLine(("  {0}: success={1} remote={2} error={3}" -f $tr.port, $tr.success, $tr.remoteAddress, $tr.error))
  }
}
[void]$sb.AppendLine("")

[void]$sb.AppendLine("== DNS Resolution ==")
foreach ($d in $report.tests.dns) {
  [void]$sb.AppendLine(("{0} :: success={1} error={2}" -f $d.name, $d.success, $d.error))
}
[void]$sb.AppendLine("")

[void]$sb.AppendLine("== PathPing ==")
try {
  if ($report.tests.pathping) {
    [void]$sb.AppendLine(("target={0} executed={1} timedOut={2} outputFile={3}" -f `
      $report.tests.pathping.target, $report.tests.pathping.executed, $report.tests.pathping.timedOut, $report.tests.pathping.outputFile))
    if ($report.tests.pathping.PSObject.Properties.Name -contains "note") {
      [void]$sb.AppendLine(("note={0}" -f $report.tests.pathping.note))
    }
  } else {
    [void]$sb.AppendLine("PathPing não foi executado.")
  }
} catch {
  [void]$sb.AppendLine("Falha ao escrever seção PathPing no SUMMARY: $($_.Exception.Message)")
}
[void]$sb.AppendLine("")

if ($report.errors.Count -gt 0) {
  [void]$sb.AppendLine("== Errors ==")
  $report.errors | ForEach-Object { [void]$sb.AppendLine($_) }
}

Save-Text -FilePath $summaryPath -Content $sb.ToString()

$report.meta.finishedAt = (Get-Date).ToString("o")
($report | ConvertTo-Json -Depth 12) | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Log "Relatórios gerados: SUMMARY=$summaryPath ; JSON=$jsonPath"

if ($Zip) {
  try {
    $zipPath = "$OutputDir.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
    Compress-Archive -Path (Join-Path $OutputDir "*") -DestinationPath $zipPath -Force
    Write-Log "ZIP gerado: $zipPath"
  } catch {
    Write-Log "Falha ao compactar ZIP: $($_.Exception.Message)" "WARN"
  }
}

Write-Log "Fim do troubleshooting."
Write-Host ""
Write-Host "Concluído. Arquivos em: $OutputDir" -ForegroundColor Green
Write-Host "Resumo:   $summaryPath"
Write-Host "JSON:     $jsonPath"
if ($Zip) { Write-Host "ZIP:      $OutputDir.zip" }
=======
<#
.SYNOPSIS
  Troubleshooting de rede para Windows Server 2016 a 2025 (PowerShell).

.DESCRIPTION
  Coleta informações de rede (IPv6 e IPv4), valida conectividade (ICMP/TRACEROUTE/DNS/TCP/PATHPING),
  exporta relatório. Gera TXT + JSON (e opcional ZIP). Não altera configurações.
  É interativo: mantém 3 valores padrões para testes, mas permite alterar IPs/Domínios.
  PATHPING roda via command line por até 4 minutos e exibe progresso ao usuário.
  O destino do PATHPING também é escolhido pelo usuário (padrão: 8.8.8.8).

.PARAMETER OutputDir
  Pasta de saída.

.PARAMETER Targets
  Alvos de teste (hosts/IPs).

.PARAMETER TcpPorts
  Portas TCP para testar em cada alvo (quando fizer sentido).

.PARAMETER DnsNames
  Nomes DNS para testar resolução.

.PARAMETER Zip
  Compacta os resultados ao final.

.EXAMPLE
  .\Network-Troubleshoot.ps1 -Zip

.EXAMPLE
  .\Network-Troubleshoot.ps1 -Targets @("10.0.0.1","dc01.contoso.local","8.8.8.8") -TcpPorts 53,88,135,389,445,3389
#>

[CmdletBinding()]
param(
  [string]$OutputDir = (Join-Path `
    ([Environment]::GetFolderPath('MyDocuments')) `
    ("netshooting_results_{0}" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))),

  [string[]]$Targets,
  [int[]]$TcpPorts = @(53, 80, 443, 3389),
  [string[]]$DnsNames,
  [switch]$Zip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# --------------------------
# Helpers
# --------------------------
function New-Folder {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-Log {
  param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
  )
  $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message

  # IMPORTANTE: não pode vazar output para o pipeline (senão quebra retornos de funções)
  $line | Tee-Object -FilePath $global:MainLog -Append | Out-Null
}

function Save-Text {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string]$Content
  )
  $Content | Out-File -FilePath $FilePath -Encoding UTF8 -Force
}

function Get-PublicIPToFile {
  param(
    [Parameter(Mandatory)][string]$FilePath
  )

  try {
    # ipify retorna o IP público em texto simples
    $ip = Invoke-RestMethod -Uri "https://api.ipify.org" -ErrorAction Stop
    $ipText = ($ip | Out-String).Trim()

    Save-Text -FilePath $FilePath -Content $ipText
    Write-Log "IP público detectado (ipify): $ipText. Salvo em: $FilePath"

    return $ipText
  } catch {
    $msg = "Falha ao obter IP público via ipify: $($_.Exception.Message)"
    Write-Log $msg "WARN"
    Save-Text -FilePath $FilePath -Content $msg
    return $null
  }
}

function Run-CmdToFile {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][object]$Args
  )

  try {
    if ($Args -is [string]) {
      Write-Log "Executando: $Exe $Args"
      $out = & $Exe $Args 2>&1 | Out-String
    } else {
      $argsText = ($Args | ForEach-Object { $_ }) -join " "
      Write-Log "Executando: $Exe $argsText"
      $out = & $Exe @Args 2>&1 | Out-String
    }
    Save-Text -FilePath $FilePath -Content $out
  } catch {
    Save-Text -FilePath $FilePath -Content ("Falha ao executar: {0} {1}`r`nErro: {2}" -f $Exe, ($Args -join " "), $_)
    Write-Log "Falha ao executar: $Exe :: $($_.Exception.Message)" "WARN"
  }
}
function Prompt-List {
  param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string[]]$Defaults,
    [string]$Hint = "Separe por vírgula. Enter para manter o padrão."
  )
  Write-Host ""
  Write-Host $Title -ForegroundColor Cyan
  Write-Host "Padrão: $($Defaults -join ', ')"
  Write-Host $Hint
  $raw = Read-Host "Novo valor (ou Enter)"
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Defaults }
  return ($raw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Prompt-Single {
  param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Default
  )
  Write-Host ""
  Write-Host $Title -ForegroundColor Cyan
  Write-Host "Padrão: $Default"
  $raw = Read-Host "Novo valor (ou Enter)"
  if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
  return $raw.Trim()
}

function Get-NowStamp { "{0:yyyyMMdd_HHmmss}" -f (Get-Date) }

function Sanitize-Name([string]$s) {
  return ($s -replace '[\\/:*?"<>| ]','_')
}

function Test-TcpPort {
  param(
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][int]$Port
  )
  $result = [ordered]@{
    target = $Target
    port = $Port
    success = $false
    error = $null
    remoteAddress = $null
    tcpTestSucceeded = $null
  }

  try {
    # Captura em variável para não "printar" no console
    $tnc = Test-NetConnection -ComputerName $Target -Port $Port -InformationLevel Detailed -WarningAction SilentlyContinue
    $result.remoteAddress = $tnc.RemoteAddress
    $result.tcpTestSucceeded = $tnc.TcpTestSucceeded
    $result.success = [bool]$tnc.TcpTestSucceeded
  } catch {
    $result.error = $_.Exception.Message
  }
  [pscustomobject]$result
}

# --------------------------
# PathPing (com progresso, sem travar)
# --------------------------
function Invoke-PathPingWithProgress {
  param(
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][string]$OutFile,
    [int]$DurationSeconds = 240,
    [int]$ProgressEverySeconds = 5,
    [int]$TimeoutPerHopMs = 3000
  )

  New-Folder -Path (Split-Path -Parent $OutFile)

  Write-Log "PathPing: iniciando por $DurationSeconds s (target=$Target). OutFile=$OutFile"
  Write-Host ""
  Write-Host ("PathPing em execução por {0} minutos (destino: {1})..." -f ([Math]::Round($DurationSeconds/60,2)), $Target) -ForegroundColor Cyan

  # pathping não tem "duração total"; então limitamos por tempo e matamos o processo se necessário.
  $args = @("-w", "$TimeoutPerHopMs", $Target)

  $tempOut = Join-Path ([System.IO.Path]::GetTempPath()) ("pathping_stdout_{0}.txt" -f (Get-NowStamp))
  $tempErr = Join-Path ([System.IO.Path]::GetTempPath()) ("pathping_stderr_{0}.txt" -f (Get-NowStamp))

  # Garante limpeza anterior (se existir)
  Remove-Item -LiteralPath $tempOut, $tempErr -Force -ErrorAction SilentlyContinue

  $p = Start-Process -FilePath "pathping.exe" `
                     -ArgumentList $args `
                     -NoNewWindow `
                     -PassThru `
                     -RedirectStandardOutput $tempOut `
                     -RedirectStandardError $tempErr

  $sw = [Diagnostics.Stopwatch]::StartNew()

  while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $DurationSeconds) {
    Start-Sleep -Seconds $ProgressEverySeconds

    $elapsed = [int]$sw.Elapsed.TotalSeconds
    $mm = [int]($elapsed / 60)
    $ss = $elapsed % 60
    $totalMm = [int]($DurationSeconds / 60)
    $totalSs = $DurationSeconds % 60

    Write-Host ("  Executando... {0:00}:{1:00} / {2:00}:{3:00}" -f $mm,$ss,$totalMm,$totalSs)
  }

  $timedOut = $false
  if (-not $p.HasExited) {
    $timedOut = $true
    Write-Host "  Tempo limite atingido. Finalizando pathping..." -ForegroundColor Yellow
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
  }

  $sw.Stop()

  # Monta relatório final a partir dos arquivos redirecionados
  $stdoutText = ""
  $stderrText = ""
  try { if (Test-Path -LiteralPath $tempOut) { $stdoutText = Get-Content -LiteralPath $tempOut -Raw -ErrorAction SilentlyContinue } } catch {}
  try { if (Test-Path -LiteralPath $tempErr) { $stderrText = Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue } } catch {}

  $content = @()
  $content += "=== PATHPING ==="
  $content += ("Target: {0}" -f $Target)
  $content += ("Args: pathping.exe {0}" -f (($args | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join " "))
  $content += ("DurationSeconds (limit): {0}" -f $DurationSeconds)
  $content += ("TimedOut: {0}" -f $timedOut)
  $content += ("FinishedAt: {0}" -f (Get-Date).ToString("o"))
  $content += ""
  $content += "=== STDOUT ==="
  $content += $stdoutText
  $content += ""
  $content += "=== STDERR ==="
  $content += $stderrText

  Save-Text -FilePath $OutFile -Content ($content -join "`r`n")

  # Limpa temporários
  Remove-Item -LiteralPath $tempOut, $tempErr -Force -ErrorAction SilentlyContinue

  Write-Host "PathPing concluído. Relatório: $OutFile" -ForegroundColor Green

  return [pscustomobject]@{
    target = $Target
    executed = $true
    durationSeconds = $DurationSeconds
    timedOut = $timedOut
    outputFile = (Split-Path -Leaf $OutFile)
    usedArgs = "pathping.exe " + (($args | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join " ")
  }
}

# --------------------------
# Setup output
# --------------------------
New-Folder -Path $OutputDir
$SubDirs = @{
  Info  = (Join-Path $OutputDir "01_info")
  Tests = (Join-Path $OutputDir "02_tests")
  Dns   = (Join-Path $OutputDir "03_dns")
  Raw   = (Join-Path $OutputDir "99_raw")
}
$SubDirs.Values | ForEach-Object { New-Folder -Path $_ }

$global:MainLog = Join-Path $OutputDir "Network-Troubleshoot.log.txt"
Write-Log "Início do troubleshooting. OutputDir=$OutputDir"

# --------------------------
# Interactive defaults
# --------------------------
$defaultTargets  = @("8.8.8.8","1.1.1.1","www.microsoft.com")
$defaultDnsNames = @("google.com","microsoft.com","cloudflare.com")

if (-not $Targets -or $Targets.Count -eq 0) {
  $Targets = Prompt-List -Title "Alvos de teste (Targets)" -Defaults $defaultTargets
} else {
  Write-Log "Targets fornecidos por parâmetro: $($Targets -join ', ')"
}

if (-not $DnsNames -or $DnsNames.Count -eq 0) {
  $DnsNames = Prompt-List -Title "Nomes DNS para teste (DnsNames)" -Defaults $defaultDnsNames
} else {
  Write-Log "DnsNames fornecidos por parâmetro: $($DnsNames -join ', ')"
}

$PathPingTarget = Prompt-Single -Title "Destino para PathPing (rota/perda/latência). (Enter = 8.8.8.8)" -Default "8.8.8.8"

# --------------------------
# Report object
# --------------------------
$report = [ordered]@{
  meta = [ordered]@{
    startedAt = (Get-Date).ToString("o")
    computerName = $env:COMPUTERNAME
    user = "$env:USERDOMAIN\$env:USERNAME"
    psVersion = $PSVersionTable.PSVersion.ToString()
    os = $null
  }
# --------------------------
# Public IP (ipify) -> salva em TXT
# --------------------------
$publicIpFile = Join-Path $SubDirs.Info "public_ip_ipify.txt"
$publicIp = Get-PublicIPToFile -FilePath $publicIpFile
$report.networkInfo.publicIp = $publicIp

  networkInfo = [ordered]@{}
  tests = [ordered]@{
    icmp = @()
    traceroute = @()
    dns = @()
    tcp = @()
    pathping = $null
  }
  errors = @()
}

# --------------------------
# Collect OS
# --------------------------
try {
  $os = Get-CimInstance -ClassName Win32_OperatingSystem
  $report.meta.os = [ordered]@{
    caption = $os.Caption
    version = $os.Version
    buildNumber = $os.BuildNumber
    lastBootUpTime = $os.LastBootUpTime
  }
} catch {
  $report.errors += "Falha ao obter Win32_OperatingSystem: $($_.Exception.Message)"
  Write-Log "Falha ao obter OS via CIM: $($_.Exception.Message)" "WARN"
}

# --------------------------
# Raw snapshots
# --------------------------
# IPv4
Run-CmdToFile -FilePath (Join-Path $SubDirs.Raw "netsh_ipv4_show_addresses.txt") -Exe "netsh" -Args @("interface","ipv4","show","addresses")
Run-CmdToFile -FilePath (Join-Path $SubDirs.Raw "netsh_ipv4_show_dnsservers.txt") -Exe "netsh" -Args @("interface","ipv4","show","dnsservers")
Run-CmdToFile -FilePath (Join-Path $SubDirs.Raw "netsh_ipv4_show_route.txt") -Exe "netsh" -Args @("interface","ipv4","show","route")

# IPv6
Run-CmdToFile -FilePath (Join-Path $SubDirs.Raw "netsh_ipv6_show_addresses.txt") -Exe "netsh" -Args @("interface","ipv6","show","addresses")
Run-CmdToFile -FilePath (Join-Path $SubDirs.Raw "netsh_ipv6_show_dnsservers.txt") -Exe "netsh" -Args @("interface","ipv6","show","dnsservers")
Run-CmdToFile -FilePath (Join-Path $SubDirs.Raw "netsh_ipv6_show_route.txt") -Exe "netsh" -Args @("interface","ipv6","show","route")

# --------------------------
# Structured network info
# --------------------------
try {
  $adapters = Get-NetAdapter -ErrorAction Stop | Sort-Object -Property ifIndex
  $ipcfg    = Get-NetIPConfiguration -ErrorAction Stop | Sort-Object -Property InterfaceIndex
  $ipaddr   = Get-NetIPAddress -ErrorAction Stop | Sort-Object -Property InterfaceIndex, AddressFamily
  $routes   = Get-NetRoute -ErrorAction SilentlyContinue | Sort-Object -Property InterfaceIndex, DestinationPrefix
  $dnsSrv   = Get-DnsClientServerAddress -ErrorAction SilentlyContinue | Sort-Object -Property InterfaceIndex, AddressFamily

  $report.networkInfo.adapters = $adapters | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress, ifIndex
  $report.networkInfo.ipConfiguration = $ipcfg | Select-Object InterfaceAlias, InterfaceIndex, IPv4Address, IPv6Address, IPv4DefaultGateway, IPv6DefaultGateway, DNSServer
  $report.networkInfo.ipAddresses = $ipaddr | Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, IPAddress, PrefixLength, Type, ValidLifetime, PreferredLifetime
  $report.networkInfo.routes = $routes | Select-Object InterfaceIndex, InterfaceAlias, DestinationPrefix, NextHop, RouteMetric, Protocol
  $report.networkInfo.dnsServers = $dnsSrv | Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, ServerAddresses

  ($adapters | Format-Table -AutoSize | Out-String) | Out-File (Join-Path $SubDirs.Info "adapters.txt") -Encoding UTF8
  ($ipcfg    | Format-List | Out-String) | Out-File (Join-Path $SubDirs.Info "ipconfiguration.txt") -Encoding UTF8
  ($ipaddr   | Format-Table -AutoSize | Out-String) | Out-File (Join-Path $SubDirs.Info "ipaddresses.txt") -Encoding UTF8
  ($routes   | Select-Object -First 500 | Format-Table -AutoSize | Out-String) | Out-File (Join-Path $SubDirs.Info "routes_first500.txt") -Encoding UTF8
  ($dnsSrv   | Format-List | Out-String) | Out-File (Join-Path $SubDirs.Info "dnsservers.txt") -Encoding UTF8
} catch {
  $report.errors += "Falha ao coletar info de rede: $($_.Exception.Message)"
  Write-Log "Falha ao coletar info de rede: $($_.Exception.Message)" "WARN"
}

# --------------------------
# Tests: ICMP + Traceroute
# --------------------------
foreach ($t in $Targets) {
  $tTrim = $t.Trim()
  if (-not $tTrim) { continue }

  Write-Log "Testes ICMP para: $tTrim"
  $icmpObj = [ordered]@{
    target = $tTrim
    success = $false
    details = $null
    error = $null
  }

  try {
    $p = Test-Connection -ComputerName $tTrim -Count 4 -ErrorAction Stop
    $icmpObj.success = $true
    $icmpObj.details = $p | Select-Object Address, IPV4Address, IPV6Address, ResponseTime, StatusCode
    ($p | Format-Table -AutoSize | Out-String) | Out-File (Join-Path $SubDirs.Tests ("icmp_{0}.txt" -f (Sanitize-Name $tTrim))) -Encoding UTF8
  } catch {
    $icmpObj.error = $_.Exception.Message
    Save-Text -FilePath (Join-Path $SubDirs.Tests ("icmp_{0}.txt" -f (Sanitize-Name $tTrim))) -Content ("Falha no ICMP: {0}" -f $_.Exception.Message)
    Write-Log "ICMP falhou para $tTrim : $($_.Exception.Message)" "WARN"
  }
  $report.tests.icmp += [pscustomobject]$icmpObj

  Write-Log "Traceroute para: $tTrim"
  $trFile = Join-Path $SubDirs.Tests ("tracert_{0}.txt" -f (Sanitize-Name $tTrim))
  Run-CmdToFile -FilePath $trFile -Exe "tracert" -Args @("-d","-w","2000","-h","30",$tTrim)

  $report.tests.traceroute += [pscustomobject]@{
    target = $tTrim
    outputFile = (Split-Path -Leaf $trFile)
  }
}

# --------------------------
# Tests: DNS
# --------------------------
foreach ($name in $DnsNames) {
  $nTrim = $name.Trim()
  if (-not $nTrim) { continue }

  Write-Log "DNS Resolve-DnsName para: $nTrim"
  $dnsObj = [ordered]@{
    name = $nTrim
    success = $false
    answers = $null
    error = $null
  }

  try {
    $ans = Resolve-DnsName -Name $nTrim -ErrorAction Stop
    $dnsObj.success = $true
    $dnsObj.answers = $ans | Select-Object Name, Type, TTL, Section, IPAddress, NameHost
    ($ans | Format-Table -AutoSize | Out-String) | Out-File (Join-Path $SubDirs.Dns ("dns_{0}.txt" -f (Sanitize-Name $nTrim))) -Encoding UTF8
  } catch {
    $dnsObj.error = $_.Exception.Message
    Save-Text -FilePath (Join-Path $SubDirs.Dns ("dns_{0}.txt" -f (Sanitize-Name $nTrim))) -Content ("Falha no DNS: {0}" -f $_.Exception.Message)
    Write-Log "DNS falhou para $nTrim : $($_.Exception.Message)" "WARN"
  }

  $report.tests.dns += [pscustomobject]$dnsObj
}

# --------------------------
# Tests: TCP ports
# --------------------------
foreach ($t in $Targets) {
  $tTrim = $t.Trim()
  if (-not $tTrim) { continue }

  foreach ($p in $TcpPorts) {
    Write-Log "TCP Test-NetConnection: $tTrim : $p"
    $tcpRes = Test-TcpPort -Target $tTrim -Port $p
    $report.tests.tcp += $tcpRes

    $tcpLine = "{0} {1}:{2} success={3} remoteAddress={4} tcpTestSucceeded={5} error={6}" -f `
      (Get-Date).ToString("s"), $tcpRes.target, $tcpRes.port, $tcpRes.success, $tcpRes.remoteAddress, $tcpRes.tcpTestSucceeded, $tcpRes.error
    $tcpLine | Out-File (Join-Path $SubDirs.Tests "tcp_tests.txt") -Encoding UTF8 -Append
  }
}

# --------------------------
# Test: PathPing (4 minutos com progresso)
# --------------------------
$pathpingReportFile = Join-Path $SubDirs.Tests ("pathping_{0}_{1}.txt" -f (Sanitize-Name $PathPingTarget), (Get-NowStamp))

# Inicializa sempre (não quebra summary/json)
$report.tests.pathping = [pscustomobject]@{
  target = $PathPingTarget
  executed = $false
  durationSeconds = 240
  timedOut = $null
  outputFile = (Split-Path -Leaf $pathpingReportFile)
  usedArgs = $null
  note = "PathPing não executado."
}

try {
  $res = Invoke-PathPingWithProgress -Target $PathPingTarget -OutFile $pathpingReportFile -DurationSeconds 240 -ProgressEverySeconds 5 -TimeoutPerHopMs 3000
  $report.tests.pathping = $res
  $report.tests.pathping | Add-Member -NotePropertyName note -NotePropertyValue "Executado por até 4 minutos com progresso no console." -Force
} catch {
  $msg = "Falha no PathPing: $($_.Exception.Message)"
  Write-Log $msg "WARN"
  Save-Text -FilePath $pathpingReportFile -Content $msg
  $report.tests.pathping.note = $msg
}

# --------------------------
# Finalize: write summary TXT + JSON (+ ZIP optional)
# --------------------------
$summaryPath = Join-Path $OutputDir "Network-Troubleshoot.SUMMARY.txt"
$jsonPath    = Join-Path $OutputDir "Network-Troubleshoot.json"

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("=== Network Troubleshoot (Windows Server 2016-2025) ===")
[void]$sb.AppendLine("Started:  $($report.meta.startedAt)")
[void]$sb.AppendLine("Computer: $($report.meta.computerName)")
[void]$sb.AppendLine("User:     $($report.meta.user)")
if ($report.meta.os) {
  [void]$sb.AppendLine("OS:       $($report.meta.os.caption) ($($report.meta.os.version) build $($report.meta.os.buildNumber))")
}
[void]$sb.AppendLine("PS:       $($report.meta.psVersion)")
[void]$sb.AppendLine("")
if ($report.networkInfo -and ($report.networkInfo.PSObject.Properties.Name -contains "publicIp") -and $report.networkInfo.publicIp) {
  [void]$sb.AppendLine("PublicIP: $($report.networkInfo.publicIp)")
}
[void]$sb.AppendLine("Targets:  $($Targets -join ', ')")
[void]$sb.AppendLine("TCPPorts: $($TcpPorts -join ', ')")
[void]$sb.AppendLine("DNSNames: $($DnsNames -join ', ')")
[void]$sb.AppendLine("PathPing: $PathPingTarget")
[void]$sb.AppendLine("")

[void]$sb.AppendLine("== ICMP (Ping) ==")
foreach ($r in $report.tests.icmp) {
  [void]$sb.AppendLine(("{0} :: success={1} error={2}" -f $r.target, $r.success, $r.error))
}
[void]$sb.AppendLine("")

[void]$sb.AppendLine("== TCP Ports ==")
$grouped = $report.tests.tcp | Group-Object -Property target
foreach ($g in $grouped) {
  [void]$sb.AppendLine("-- {0} --" -f $g.Name)
  foreach ($tr in $g.Group | Sort-Object port) {
    [void]$sb.AppendLine(("  {0}: success={1} remote={2} error={3}" -f $tr.port, $tr.success, $tr.remoteAddress, $tr.error))
  }
}
[void]$sb.AppendLine("")

[void]$sb.AppendLine("== DNS Resolution ==")
foreach ($d in $report.tests.dns) {
  [void]$sb.AppendLine(("{0} :: success={1} error={2}" -f $d.name, $d.success, $d.error))
}
[void]$sb.AppendLine("")

[void]$sb.AppendLine("== PathPing ==")
try {
  if ($report.tests.pathping) {
    [void]$sb.AppendLine(("target={0} executed={1} timedOut={2} outputFile={3}" -f `
      $report.tests.pathping.target, $report.tests.pathping.executed, $report.tests.pathping.timedOut, $report.tests.pathping.outputFile))
    if ($report.tests.pathping.PSObject.Properties.Name -contains "note") {
      [void]$sb.AppendLine(("note={0}" -f $report.tests.pathping.note))
    }
  } else {
    [void]$sb.AppendLine("PathPing não foi executado.")
  }
} catch {
  [void]$sb.AppendLine("Falha ao escrever seção PathPing no SUMMARY: $($_.Exception.Message)")
}
[void]$sb.AppendLine("")

if ($report.errors.Count -gt 0) {
  [void]$sb.AppendLine("== Errors ==")
  $report.errors | ForEach-Object { [void]$sb.AppendLine($_) }
}

Save-Text -FilePath $summaryPath -Content $sb.ToString()

$report.meta.finishedAt = (Get-Date).ToString("o")
($report | ConvertTo-Json -Depth 12) | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Log "Relatórios gerados: SUMMARY=$summaryPath ; JSON=$jsonPath"

if ($Zip) {
  try {
    $zipPath = "$OutputDir.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
    Compress-Archive -Path (Join-Path $OutputDir "*") -DestinationPath $zipPath -Force
    Write-Log "ZIP gerado: $zipPath"
  } catch {
    Write-Log "Falha ao compactar ZIP: $($_.Exception.Message)" "WARN"
  }
}

Write-Log "Fim do troubleshooting."
Write-Host ""
Write-Host "Concluído. Arquivos em: $OutputDir" -ForegroundColor Green
Write-Host "Resumo:   $summaryPath"
Write-Host "JSON:     $jsonPath"
if ($Zip) { Write-Host "ZIP:      $OutputDir.zip" }
>>>>>>> 954eae1 (adicionando função get IP publico)
