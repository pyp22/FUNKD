#Requires -Version 3.0
<#
.SYNOPSIS
    Verification cote client Windows qu'AdGuard Home est actif sur le routeur OpenWrt.
    Aucune installation requise. Fonctionne sur tout Windows avec PowerShell 3.0+.

.USAGE
    powershell -ExecutionPolicy Bypass -File test-adguardhome-client.ps1
    powershell -ExecutionPolicy Bypass -File test-adguardhome-client.ps1 192.168.3.254
#>

param(
    [string]$Router = ""
)

# --- Affichage ----------------------------------------------------------------
function Write-Hdr  { param($m) Write-Host "`n== $m ==" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "[+] $m"    -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[!] $m"    -ForegroundColor Yellow }
function Write-Hint { param($m) Write-Host "    -> $m" -ForegroundColor Gray }
function Write-Err  { param($m) Write-Host "[X] $m"    -ForegroundColor Red; exit 1 }

# --- Verification des dependances ---------------------------------------------
Write-Hdr "Verification des dependances"

if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Err "PowerShell 3.0+ requis (version actuelle : $($PSVersionTable.PSVersion))"
}
Write-Ok "PowerShell $($PSVersionTable.PSVersion) detecte"

try {
    [void][System.Net.Sockets.UdpClient]
    [void][System.Net.Sockets.TcpClient]
    Write-Ok "Classes .NET Sockets disponibles"
} catch {
    Write-Err "Classes .NET System.Net.Sockets introuvables"
}

# --- Detection de la passerelle -----------------------------------------------
function Get-Gateway {
    try {
        $gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop |
               Sort-Object RouteMetric |
               Select-Object -First 1).NextHop
        if ($gw -and $gw -ne "0.0.0.0") { return $gw }
    } catch {}
    try {
        $lines = & route print 0.0.0.0 2>$null
        foreach ($line in $lines) {
            $parts = $line.Trim() -split '\s+'
            if ($parts.Count -ge 3 -and $parts[0] -eq "0.0.0.0") {
                return $parts[2]
            }
        }
    } catch {}
    return $null
}

# --- Requete DNS (Resolve-DnsName natif PS5, fallback UDP) --------------------
function Invoke-DnsQuery {
    param([string]$Hostname, [string]$Server, [int]$Port = 53, [int]$TimeoutMs = 5000)

    # Methode 1 : Resolve-DnsName (PS5+, utilise le resolveur Windows natif)
    try {
        $r = Resolve-DnsName -Name $Hostname -Server $Server -Type A -ErrorAction Stop |
             Where-Object { $_.Type -eq "A" } |
             Select-Object -First 1
        if ($r) { return $r.IPAddress }
    } catch {}

    # Methode 2 : fallback UDP brut
    try {
        $tid = Get-Random -Minimum 0 -Maximum 65535
        $header = [byte[]](
            ($tid -shr 8) -band 0xFF, $tid -band 0xFF,
            0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        )
        $qname = New-Object System.Collections.Generic.List[byte]
        foreach ($part in $Hostname.TrimEnd('.').Split('.')) {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($part)
            $qname.Add([byte]$bytes.Length)
            $qname.AddRange($bytes)
        }
        $qname.Add(0)
        $question = $qname.ToArray() + [byte[]](0x00, 0x01, 0x00, 0x01)
        $packet   = $header + $question

        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Server, $Port)
        [void]$udp.Send($packet, $packet.Length)
        $ep   = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $data = $udp.Receive([ref]$ep)
        $udp.Close()

        if ($data.Length -lt 12) { return $null }
        $ancount = ($data[4] -shl 8) -bor $data[5]
        if ($ancount -eq 0) { return $null }

        $pos = 12
        while ($pos -lt $data.Length) {
            if ($data[$pos] -eq 0)                  { $pos += 1; break }
            if (($data[$pos] -band 0xC0) -eq 0xC0) { $pos += 2; break }
            $pos += $data[$pos] + 1
        }
        $pos += 4

        for ($i = 0; $i -lt $ancount; $i++) {
            if ($pos -ge $data.Length) { break }
            if (($data[$pos] -band 0xC0) -eq 0xC0) { $pos += 2 }
            else {
                while ($pos -lt $data.Length -and $data[$pos] -ne 0) {
                    $pos += $data[$pos] + 1
                }
                $pos += 1
            }
            if ($pos + 10 -gt $data.Length) { break }
            $rtype = ($data[$pos]   -shl 8) -bor $data[$pos+1]
            $rdlen = ($data[$pos+8] -shl 8) -bor $data[$pos+9]
            $pos  += 10
            if ($rtype -eq 1 -and $rdlen -eq 4 -and ($pos + 4) -le $data.Length) {
                return "$($data[$pos]).$($data[$pos+1]).$($data[$pos+2]).$($data[$pos+3])"
            }
            $pos += $rdlen
        }
    } catch {}
    return $null
}

# --- Test TCP (port ouvert) ---------------------------------------------------
function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 3000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar  = $tcp.BeginConnect($HostName, $Port, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        $tcp.Close()
        return $ok
    } catch { return $false }
}

# --- Lecture du DNS configure -------------------------------------------------
function Get-ConfiguredDns {
    try {
        $addrs = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
                 Select-Object -ExpandProperty ServerAddresses |
                 Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
        return ($addrs | Select-Object -First 1)
    } catch {}
    try {
        $lines = & ipconfig /all 2>$null
        $inDns = $false
        foreach ($line in $lines) {
            if ($line -match 'DNS') { $inDns = $true }
            if ($inDns -and $line -match '(\d+\.\d+\.\d+\.\d+)') {
                return $Matches[1]
            }
        }
    } catch {}
    return $null
}

# --- Detection du routeur -----------------------------------------------------
if (-not $Router) { $Router = Get-Gateway }
if (-not $Router) {
    Write-Err "Impossible de detecter la passerelle.`n  Usage : .\test-adguardhome-client.ps1 192.168.3.254"
}

$results = @{}

Write-Hdr "Test AdGuard Home depuis ce client -- routeur $Router"

# -- Test 1 : DNS configure = routeur -----------------------------------------
Write-Hdr "Test 1 -- Serveur DNS configure"
$dnsCfg = Get-ConfiguredDns
if ($dnsCfg -eq $Router) {
    Write-Ok "DNS configure pointe vers le routeur : $dnsCfg"
    $results[1] = $true
} else {
    Write-Warn "DNS configure : $(if ($dnsCfg) { $dnsCfg } else { 'non detecte' }) (attendu : $Router)"
    Write-Hint "Le serveur DHCP n'a pas fourni l'IP du routeur comme DNS."
    Write-Hint "Sur le routeur : uci show dhcp | grep dhcp_option"
    $results[1] = $false
}

# -- Test 2 : resolution DNS directe via le routeur ---------------------------
Write-Hdr "Test 2 -- Requete DNS directe vers le routeur"
$res = Invoke-DnsQuery -Hostname "google.com" -Server $Router
if ($res) {
    Write-Ok "Routeur ${Router}:53 repond -- google.com -> $res"
    $results[2] = $true
} else {
    Write-Warn "Routeur ${Router}:53 ne repond pas aux requetes DNS"
    Write-Hint "Verifier sur le routeur : service adguardhome status"
    Write-Hint "Logs : logread -e AdGuardHome"
    $results[2] = $false
}

# -- Test 3 : resolution DNS par defaut ---------------------------------------
Write-Hdr "Test 3 -- Resolution DNS par defaut"
$dnsTarget = if ($dnsCfg) { $dnsCfg } else { $Router }
$resDef = Invoke-DnsQuery -Hostname "google.com" -Server $dnsTarget
if ($resDef) {
    Write-Ok "Resolution DNS par defaut fonctionnelle -- google.com -> $resDef"
    $results[3] = $true
} else {
    Write-Warn "Resolution DNS par defaut echoue"
    Write-Hint "Verifier la connectivite ou renouveler le bail DHCP : ipconfig /renew"
    $results[3] = $false
}

# -- Test 4 : DNAT -- bypass 8.8.8.8 doit etre intercepte --------------------
Write-Hdr "Test 4 -- Interception DNAT (bypass 8.8.8.8)"
$resBypass = Invoke-DnsQuery -Hostname "google.com" -Server "8.8.8.8"
if ($resBypass) {
    Write-Ok "Requete vers 8.8.8.8 interceptee -- google.com -> $resBypass"
    $results[4] = $true
} else {
    Write-Warn "Requete vers 8.8.8.8 non resolue -- regle DNAT absente ou inactive"
    Write-Hint "Sur le routeur : uci show firewall | grep -A8 Intercept-DNS"
    Write-Hint "Relancer : service firewall restart"
    $results[4] = $false
}

# -- Test 5 : interface web AdGuard accessible --------------------------------
Write-Hdr "Test 5 -- Interface web AdGuard Home"
if (Test-TcpPort -HostName $Router -Port 8080) {
    Write-Ok "Interface web accessible : http://${Router}:8080/"
    $results[5] = $true
} else {
    Write-Warn "Interface web non accessible sur ${Router}:8080"
    Write-Hint "Assistant initial : http://${Router}:3000/"
    Write-Hint "Sur le routeur : service adguardhome start"
    $results[5] = $false
}

# -- Synthese ------------------------------------------------------------------
$labels = @{
    1 = "DNS configure (DHCP -> routeur)"
    2 = "Routeur repond sur :53"
    3 = "Resolution DNS par defaut"
    4 = "DNAT actif (bypass 8.8.8.8 intercepte)"
    5 = "Interface web :8080 accessible"
}
$passed = ($results.Values | Where-Object { $_ }).Count
$failed = $results.Count - $passed

Write-Hdr "Synthese"
foreach ($n in 1..5) {
    $status = if ($results[$n]) { "OK" } else { "FAIL" }
    $color  = if ($results[$n]) { "Green" } else { "Yellow" }
    Write-Host ("  {0}. {1,-45} " -f $n, $labels[$n]) -NoNewline
    Write-Host $status -ForegroundColor $color
}
Write-Host ""

if ($failed -eq 0) {
    Write-Host "  OK AdGuard Home operationnel -- $passed/$($results.Count) tests reussis" -ForegroundColor Green
} else {
    Write-Host "  ATTENTION $failed/$($results.Count) tests en echec -- voir les details ci-dessus" -ForegroundColor Yellow
}

Write-Host "`n  Query Log : http://${Router}:8080/#logs`n"
exit $(if ($failed -eq 0) { 0 } else { 1 })
