param(
  [Parameter(Mandatory = $true)][string]$Installer,
  [Parameter(Mandatory = $true)][string]$OutputDirectory
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path
$work = Join-Path $env:RUNNER_TEMP ("tun-acceptance-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$xray = (Resolve-Path client/src-tauri/binaries/xray-x86_64-pc-windows-msvc.exe).Path
$server = $null
$fixture = $null
$client = $null
$installLocation = $null
$proof = [ordered]@{ tcp = $false; udp = $false; dns = $false; normalCleanup = $false; crashCleanup = $false }

function Assert-NoTunnel {
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  do {
    $cores = @(Get-Process -Name "sing-box" -ErrorAction SilentlyContinue)
    $routes = @(Get-NetRoute -InterfaceAlias "PrivateNetwork" -ErrorAction SilentlyContinue)
    if ($cores.Count -eq 0 -and $routes.Count -eq 0) { return }
    Start-Sleep -Milliseconds 300
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Tunnel process or routes remained after disconnect"
}

function Start-Tunnel([int]$HoldSeconds, [string]$Output) {
  $request = @{ schemaVersion = 1; operation = @{ method = "proxyConnect"; invitation = $script:invitation; proxyMode = "tun"; holdSeconds = $HoldSeconds } } | ConvertTo-Json -Depth 5 -Compress
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $script:binary
  $start.ArgumentList.Add("headless")
  $start.ArgumentList.Add("--output")
  $start.ArgumentList.Add($Output)
  $start.UseShellExecute = $false
  $start.RedirectStandardInput = $true
  $process = [Diagnostics.Process]::Start($start)
  $process.StandardInput.WriteLine($request)
  $process.StandardInput.Close()
  $deadline = [DateTime]::UtcNow.AddSeconds(45)
  do {
    if (Test-Path $Output) {
      try { $state = Get-Content $Output -Raw | ConvertFrom-Json } catch { $state = $null }
      if ($state -and $state.outcome.status -eq "error") { throw "Connect failed: $($state.outcome.code)" }
      if ($state -and $state.outcome.snapshot.phase -eq "connected") { return $process }
    }
    if ($process.HasExited) { throw "Connect exited before TUN became ready" }
    Start-Sleep -Milliseconds 250
  } while ([DateTime]::UtcNow -lt $deadline)
  $process.Kill($true)
  throw "TUN startup timed out"
}

try {
  $installed = Start-Process -FilePath $Installer -ArgumentList "/S" -PassThru -Wait
  if ($installed.ExitCode -ne 0) { throw "Installer failed" }
  $entry = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object DisplayName -eq "Private Network Connect" | Select-Object -First 1
  $installLocation = [Environment]::ExpandEnvironmentVariables(([string]$entry.InstallLocation).Trim().Trim([char]'"'))
  $binary = Join-Path $installLocation "reality-client.exe"
  if (-not (Test-Path $binary)) { throw "Installed client is missing" }
  if (-not (Test-Path (Join-Path $installLocation "sing-box.exe"))) { throw "Installer omitted TUN core" }
  & scripts/smoke/run-connect-headless.ps1 -Binary $binary
  $interface = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1 -ExpandProperty InterfaceAlias
  $keys = & $xray x25519
  $private = [regex]::Match(($keys -join "`n"), '(?m)^PrivateKey:\s*(\S+)').Groups[1].Value
  $public = [regex]::Match(($keys -join "`n"), '(?m)^(?:Password[^:]*|PublicKey):\s*(\S+)').Groups[1].Value
  if (-not $private -or -not $public) { throw "Cannot create ephemeral REALITY test keys" }
  $uuid = [guid]::NewGuid().ToString()
  $config = @{
    log = @{ loglevel = "warning" }
    inbounds = @(@{
      listen = "127.0.0.1"; port = 15443; protocol = "vless"
      settings = @{ clients = @(@{ id = $uuid; flow = "xtls-rprx-vision" }); decryption = "none" }
      streamSettings = @{ network = "raw"; security = "reality"; realitySettings = @{
        target = "www.microsoft.com:443"; serverNames = @("www.microsoft.com"); privateKey = $private; shortIds = @("12345678")
      } }
    })
    outbounds = @(
      @{ tag = "internet"; protocol = "freedom"; streamSettings = @{ sockopt = @{ interface = $interface } } },
      @{ tag = "fixture"; protocol = "freedom"; settings = @{ redirect = "127.0.0.1:15555" } }
    )
    routing = @{ rules = @(@{ type = "field"; ip = @("93.184.215.14/32"); outboundTag = "fixture" }) }
  }
  $serverConfig = Join-Path $work "server.json"
  $config | ConvertTo-Json -Depth 15 | Set-Content $serverConfig -Encoding utf8
  $server = Start-Process $xray -ArgumentList "run", "-config", $serverConfig -PassThru -RedirectStandardError (Join-Path $OutputDirectory "xray-stderr.log") -RedirectStandardOutput (Join-Path $OutputDirectory "xray-stdout.log")
  $fixture = Start-Process python -ArgumentList "scripts/smoke/windows-tun-fixture.py" -PassThru
  Start-Sleep -Seconds 2
  $invitation = "vless://${uuid}@127.0.0.1:15443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${public}&sid=12345678&type=tcp#Acceptance"
  $stateFile = Join-Path $work "connected.json"
  $client = Start-Tunnel 35 $stateFile
  if (-not (Get-NetRoute -InterfaceAlias "PrivateNetwork" -ErrorAction SilentlyContinue)) { throw "No TUN routes installed" }

  # These raw sockets do not use HTTP/SOCKS or Windows system proxy settings.
  $tcp = [Net.Sockets.TcpClient]::new()
  $task = $tcp.ConnectAsync("93.184.215.14", 15555)
  if (-not $task.Wait(10000)) { throw "Raw TCP over TUN timed out" }
  $reader = [IO.StreamReader]::new($tcp.GetStream())
  $tcp.ReceiveTimeout = 10000
  if ($reader.ReadLine() -ne "private-network-tun-tcp") { throw "TCP bypassed the test node" }
  $reader.Dispose(); $tcp.Dispose()
  $proof.tcp = $true

  $udp = [Net.Sockets.UdpClient]::new()
  $udp.Client.ReceiveTimeout = 10000
  $udp.Connect("93.184.215.14", 15555)
  $payload = [Text.Encoding]::UTF8.GetBytes("acceptance")
  [void]$udp.Send($payload, $payload.Length)
  $sender = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
  $response = [Text.Encoding]::UTF8.GetString($udp.Receive([ref]$sender))
  $udp.Dispose()
  if ($response -ne "private-network-tun-udp:acceptance") { throw "UDP bypassed the test node" }
  $proof.udp = $true

  Clear-DnsClientCache
  $answers = @(Resolve-DnsName "www.nexon.com" -Type A -DnsOnly -ErrorAction Stop | Where-Object IPAddress)
  if ($answers.Count -eq 0) { throw "Tunnel DNS resolution failed" }
  $proof.dns = $true
  if (-not $client.WaitForExit(60000)) { throw "Normal disconnect timed out" }
  if ($client.ExitCode -ne 0) { throw "Normal disconnect failed" }
  $final = Get-Content $stateFile -Raw | ConvertFrom-Json
  if ($final.outcome.snapshot.phase -ne "disconnected") { throw "Disconnect state incorrect" }
  Assert-NoTunnel
  $proof.normalCleanup = $true

  $client = Start-Tunnel 120 (Join-Path $work "crash.json")
  Stop-Process -Id $client.Id -Force
  Assert-NoTunnel
  $proof.crashCleanup = $true
  Resolve-DnsName "www.microsoft.com" -Type A -DnsOnly -ErrorAction Stop | Out-Null
  $proof | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory "results.json") -Encoding utf8
} finally {
  foreach ($process in @($client, $fixture, $server)) {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
  }
  if ($installLocation -and (Test-Path $installLocation)) {
    $uninstaller = Get-ChildItem $installLocation -Filter "uninstall*.exe" | Select-Object -First 1
    if ($uninstaller) { Start-Process $uninstaller.FullName -ArgumentList "/S" -Wait | Out-Null }
  }
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
