$ErrorActionPreference = "Stop"

$Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:ConfigPath = Join-Path $Script:Root "config.json"
$Script:PreviousMetricsSnapshot = $null

function Get-ConfigValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) { return $DefaultValue }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
    return $property.Value
}

function Read-BridgeConfig {
    if (-not (Test-Path -LiteralPath $Script:ConfigPath)) {
        throw "config.json not found. Copy config.example.json to config.json and fill in the values."
    }

    return Get-Content -Raw -LiteralPath $Script:ConfigPath | ConvertFrom-Json
}

function Protect-Secrets {
    param(
        [string]$Message,
        [object]$Config
    )

    $safe = [string]$Message
    $sub = Get-ConfigValue $Config "subTraffic"
    $vps = Get-ConfigValue $Config "vpsTraffic"
    $secrets = @(
        (Get-ConfigValue $sub "subscribeUrl" ""),
        (Get-ConfigValue $vps "basicAuthPassword" ""),
        (Get-ConfigValue $vps "bwhApiKey" "")
    )

    foreach ($secret in $secrets) {
        if (-not [string]::IsNullOrWhiteSpace([string]$secret)) {
            $safe = $safe.Replace([string]$secret, "******")
        }
    }
    return $safe
}

function New-ErrorPayload {
    param(
        [string]$Message,
        [string]$Kind
    )

    if ($Kind -eq "sub") {
        return [ordered]@{
            ok = $false
            status = $Message
            traffic = $Message
            expire = $Message
            traffic_color = "2"
            expire_color = "2"
        }
    }

    return [ordered]@{
        ok = $false
        status = $Message
        download_rate = $Message
        upload_rate = $Message
        bwh_usage = $Message
        bwh_reset = $Message
        tcp_inuse = $Message
        tcp_established = $Message
        node_color = "2"
        bwh_color = "2"
    }
}

function Invoke-BridgeWebRequest {
    param(
        [string]$Url,
        [hashtable]$Headers,
        [int]$TimeoutSeconds = 5
    )

    if ($null -eq $Headers) { $Headers = @{} }
    if (-not $Headers.ContainsKey("User-Agent")) {
        $Headers["User-Agent"] = "LiteMonitorBridge/1.0"
    }

    return Invoke-WebRequest -Uri $Url -Method Get -Headers $Headers -TimeoutSec $TimeoutSeconds -UseBasicParsing
}

function Get-HeaderValue {
    param(
        [object]$Headers,
        [string]$Name
    )

    if ($null -eq $Headers) { return "" }
    foreach ($key in $Headers.Keys) {
        if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            $value = $Headers[$key]
            if ($value -is [array]) { return ($value -join ",") }
            return [string]$value
        }
    }
    return ""
}

function ConvertTo-UInt64Invariant {
    param([object]$Value)

    if ($null -eq $Value) { return [uint64]0 }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return [uint64]0 }

    $number = [double]::Parse(
        $text,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if ($number -lt 0) { return [uint64]0 }
    return [uint64][System.Math]::Round($number)
}

function Format-ByteCount {
    param([double]$Bytes)

    $units = @("B", "KB", "MB", "GB", "TB", "PB")
    $value = [double]$Bytes
    if ($value -lt 0) { $value = 0.0 }
    $index = 0
    while ($value -ge 1024 -and $index + 1 -lt $units.Count) {
        $value = $value / 1024
        $index++
    }

    $format = if ($index -eq 0) { "{0:F0}{1}" } else { "{0:F2}{1}" }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $format, $value, $units[$index])
}

function Format-CompactByteCount {
    param([double]$Bytes)

    $units = @("B", "KB", "MB", "GB", "TB", "PB")
    $value = [double]$Bytes
    if ($value -lt 0) { $value = 0.0 }
    $index = 0
    while ($value -ge 1024 -and $index + 1 -lt $units.Count) {
        $value = $value / 1024
        $index++
    }

    return ([uint64][System.Math]::Floor($value)).ToString([System.Globalization.CultureInfo]::InvariantCulture) + $units[$index]
}

function Format-Gigabytes {
    param([double]$Bytes)

    $gb = $Bytes / 1024 / 1024 / 1024
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:F2}GB", $gb)
}

function Format-BytesPerSecond {
    param([double]$BytesPerSecond)

    $nonNegative = [double]$BytesPerSecond
    if ($nonNegative -lt 0) { $nonNegative = 0.0 }
    $rounded = [System.Math]::Round($nonNegative)
    return (Format-ByteCount $rounded) + "/s"
}

function Format-DateText {
    param([long]$UnixSeconds)

    if ($UnixSeconds -le 0) { return "Unknown" }
    return [System.DateTimeOffset]::FromUnixTimeSeconds($UnixSeconds).LocalDateTime.ToString("yyyy-MM-dd")
}

function Get-ExpiryColor {
    param([long]$UnixSeconds)

    if ($UnixSeconds -le 0) { return "1" }
    $expires = [System.DateTimeOffset]::FromUnixTimeSeconds($UnixSeconds).LocalDateTime
    $days = ($expires - [System.DateTime]::Now).TotalDays
    if ($days -le 7) { return "2" }
    if ($days -le 30) { return "1" }
    return "0"
}

function Get-RatioColor {
    param(
        [double]$Used,
        [double]$Total
    )

    if ($Total -le 0) { return "0" }
    $ratio = $Used / $Total
    if ($ratio -ge 0.9) { return "2" }
    if ($ratio -ge 0.75) { return "1" }
    return "0"
}

function Get-SubTrafficPayload {
    $config = Read-BridgeConfig
    try {
        $sub = Get-ConfigValue $config "subTraffic"
        $url = [string](Get-ConfigValue $sub "subscribeUrl" "")
        if ([string]::IsNullOrWhiteSpace($url)) {
            return New-ErrorPayload "Subscription URL missing" "sub"
        }

        $timeout = [int](Get-ConfigValue $sub "timeoutSeconds" 10)
        $userAgent = [string](Get-ConfigValue $sub "userAgent" "ClashforWindows/0.20.39")
        $response = Invoke-BridgeWebRequest -Url $url -Headers @{ "User-Agent" = $userAgent } -TimeoutSeconds $timeout
        $header = Get-HeaderValue $response.Headers "subscription-userinfo"
        if ([string]::IsNullOrWhiteSpace($header)) {
            return New-ErrorPayload "subscription-userinfo missing" "sub"
        }

        $values = @{}
        foreach ($match in [regex]::Matches($header, "(?i)(upload|download|total|expire)\s*=\s*(\d+)")) {
            $values[$match.Groups[1].Value.ToLowerInvariant()] = $match.Groups[2].Value
        }

        $upload = ConvertTo-UInt64Invariant $values["upload"]
        $download = ConvertTo-UInt64Invariant $values["download"]
        $total = ConvertTo-UInt64Invariant $values["total"]
        $expire = [long](ConvertTo-UInt64Invariant $values["expire"])
        $used = $upload + $download

        return [ordered]@{
            ok = $true
            status = "OK"
            traffic = (Format-Gigabytes $used) + "/" + (Format-Gigabytes $total)
            expire = Format-DateText $expire
            used_bytes = $used
            total_bytes = $total
            expire_timestamp = $expire
            traffic_color = Get-RatioColor $used $total
            expire_color = Get-ExpiryColor $expire
        }
    }
    catch {
        return New-ErrorPayload (Protect-Secrets $_.Exception.Message $config) "sub"
    }
}

function Get-LabelValue {
    param(
        [string]$Labels,
        [string]$Name
    )

    $match = [regex]::Match($Labels, [regex]::Escape($Name) + '="([^"]*)"')
    if ($match.Success) { return $match.Groups[1].Value }
    return ""
}

function Test-PreferredDevice {
    param([string]$DeviceName)

    if ([string]::IsNullOrWhiteSpace($DeviceName)) { return $false }
    $lower = $DeviceName.ToLowerInvariant()
    if ($lower -eq "lo") { return $false }

    $excludedPrefixes = @("docker", "veth", "br-", "virbr", "cali", "flannel", "tun", "tap", "wg", "dummy")
    foreach ($prefix in $excludedPrefixes) {
        if ($lower.StartsWith($prefix)) { return $false }
    }
    return $true
}

function Get-OrCreateCounter {
    param(
        [System.Collections.Specialized.OrderedDictionary]$Counters,
        [string]$DeviceName
    )

    if (-not $Counters.Contains($DeviceName)) {
        $Counters[$DeviceName] = [ordered]@{
            hasReceive = $false
            hasTransmit = $false
            receiveBytesTotal = [uint64]0
            transmitBytesTotal = [uint64]0
        }
    }
    return $Counters[$DeviceName]
}

function Parse-MetricsBody {
    param(
        [string]$Body,
        [string]$PreferredDevice
    )

    $counters = New-Object System.Collections.Specialized.OrderedDictionary
    $tcpInUse = 0
    $tcpEstablished = 0
    $load1 = 0.0

    foreach ($rawLine in ($Body -split "`r?`n")) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }

        $match = [regex]::Match($line, '^node_network_receive_bytes_total\{([^}]*)\}\s+([0-9eE+\-.]+)')
        if ($match.Success) {
            $device = Get-LabelValue $match.Groups[1].Value "device"
            if (-not [string]::IsNullOrWhiteSpace($device)) {
                $counter = Get-OrCreateCounter $counters $device
                $counter["hasReceive"] = $true
                $counter["receiveBytesTotal"] = ConvertTo-UInt64Invariant $match.Groups[2].Value
            }
            continue
        }

        $match = [regex]::Match($line, '^node_network_transmit_bytes_total\{([^}]*)\}\s+([0-9eE+\-.]+)')
        if ($match.Success) {
            $device = Get-LabelValue $match.Groups[1].Value "device"
            if (-not [string]::IsNullOrWhiteSpace($device)) {
                $counter = Get-OrCreateCounter $counters $device
                $counter["hasTransmit"] = $true
                $counter["transmitBytesTotal"] = ConvertTo-UInt64Invariant $match.Groups[2].Value
            }
            continue
        }

        $match = [regex]::Match($line, '^node_sockstat_TCP_inuse\s+([0-9eE+\-.]+)')
        if ($match.Success) {
            $tcpInUse = [long](ConvertTo-UInt64Invariant $match.Groups[1].Value)
            continue
        }

        $match = [regex]::Match($line, '^node_netstat_Tcp_CurrEstab\s+([0-9eE+\-.]+)')
        if ($match.Success) {
            $tcpEstablished = [long](ConvertTo-UInt64Invariant $match.Groups[1].Value)
            continue
        }

        $match = [regex]::Match($line, '^node_load1\s+([0-9eE+\-.]+)')
        if ($match.Success) {
            $load1 = [double]::Parse($match.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }

    $selectedDevice = ""
    if (-not [string]::IsNullOrWhiteSpace($PreferredDevice) -and $counters.Contains($PreferredDevice)) {
        $candidate = $counters[$PreferredDevice]
        if ($candidate["hasReceive"] -and $candidate["hasTransmit"]) {
            $selectedDevice = $PreferredDevice
        }
    }

    if ([string]::IsNullOrWhiteSpace($selectedDevice)) {
        foreach ($device in $counters.Keys) {
            $candidate = $counters[$device]
            if ($candidate["hasReceive"] -and $candidate["hasTransmit"] -and (Test-PreferredDevice $device)) {
                $selectedDevice = $device
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($selectedDevice)) {
        foreach ($device in $counters.Keys) {
            $candidate = $counters[$device]
            if ($candidate["hasReceive"] -and $candidate["hasTransmit"]) {
                $selectedDevice = $device
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($selectedDevice)) {
        throw "No matching network device metrics"
    }

    $selected = $counters[$selectedDevice]
    return [pscustomobject]@{
        deviceName = $selectedDevice
        receiveBytesTotal = [uint64]$selected["receiveBytesTotal"]
        transmitBytesTotal = [uint64]$selected["transmitBytesTotal"]
        tcpInUse = [long]$tcpInUse
        tcpEstablished = [long]$tcpEstablished
        load1 = [double]$load1
        sampleTimeSeconds = [System.DateTimeOffset]::Now.ToUnixTimeSeconds()
    }
}

function Get-MetricsSnapshot {
    param([object]$VpsConfig)

    $metricsUrl = [string](Get-ConfigValue $VpsConfig "metricsUrl" "")
    if ([string]::IsNullOrWhiteSpace($metricsUrl)) { throw "MetricsUrl missing" }

    $headers = @{ "Accept" = "text/plain" }
    $user = [string](Get-ConfigValue $VpsConfig "basicAuthUser" "")
    $password = [string](Get-ConfigValue $VpsConfig "basicAuthPassword" "")
    if (-not [string]::IsNullOrEmpty($user) -or -not [string]::IsNullOrEmpty($password)) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($user + ":" + $password)
        $headers["Authorization"] = "Basic " + [System.Convert]::ToBase64String($bytes)
    }

    $timeout = [int](Get-ConfigValue $VpsConfig "timeoutSeconds" 5)
    $response = Invoke-BridgeWebRequest -Url $metricsUrl -Headers $headers -TimeoutSeconds $timeout
    $preferredDevice = [string](Get-ConfigValue $VpsConfig "networkDevice" "")
    return Parse-MetricsBody ([string]$response.Content) $preferredDevice
}

function Get-RateDisplay {
    param(
        [object]$Previous,
        [object]$Current
    )

    if ($null -eq $Previous -or $Previous.deviceName -ne $Current.deviceName -or $Current.sampleTimeSeconds -le $Previous.sampleTimeSeconds) {
        return @{ down = "Sampling"; up = "Sampling" }
    }

    $elapsed = [double]($Current.sampleTimeSeconds - $Previous.sampleTimeSeconds)
    if ($Current.receiveBytesTotal -lt $Previous.receiveBytesTotal -or $Current.transmitBytesTotal -lt $Previous.transmitBytesTotal) {
        return @{ down = "Counter reset"; up = "Counter reset" }
    }

    $downRate = ([double]($Current.receiveBytesTotal - $Previous.receiveBytesTotal)) / $elapsed
    $upRate = ([double]($Current.transmitBytesTotal - $Previous.transmitBytesTotal)) / $elapsed
    return @{
        down = Format-BytesPerSecond $downRate
        up = Format-BytesPerSecond $upRate
    }
}

function Build-UrlWithBwhQuery {
    param(
        [string]$BaseUrl,
        [string]$Veid,
        [string]$ApiKey
    )

    $separator = if ($BaseUrl.Contains("?")) { "&" } else { "?" }
    return $BaseUrl + $separator + "veid=" + [System.Uri]::EscapeDataString($Veid) + "&api_key=" + [System.Uri]::EscapeDataString($ApiKey)
}

function Get-BwhSnapshot {
    param([object]$VpsConfig)

    $veid = [string](Get-ConfigValue $VpsConfig "bwhVeid" "")
    $apiKey = [string](Get-ConfigValue $VpsConfig "bwhApiKey" "")
    $baseUrl = [string](Get-ConfigValue $VpsConfig "bwhServiceInfoUrl" "https://api.64clouds.com/v1/getServiceInfo")
    if ([string]::IsNullOrWhiteSpace($veid) -or [string]::IsNullOrWhiteSpace($apiKey)) {
        throw "BWH credentials missing"
    }

    $timeout = [int](Get-ConfigValue $VpsConfig "timeoutSeconds" 5)
    $url = Build-UrlWithBwhQuery $baseUrl $veid $apiKey
    $response = Invoke-BridgeWebRequest -Url $url -Headers @{ "Accept" = "application/json" } -TimeoutSeconds $timeout
    $json = ([string]$response.Content) | ConvertFrom-Json

    $error = ConvertTo-UInt64Invariant (Get-ConfigValue $json "error" 0)
    if ($error -ne 0) {
        $message = [string](Get-ConfigValue $json "message" ("BWH API error " + $error))
        throw $message
    }

    $planMonthlyData = ConvertTo-UInt64Invariant (Get-ConfigValue $json "plan_monthly_data" 0)
    $multiplier = ConvertTo-UInt64Invariant (Get-ConfigValue $json "monthly_data_multiplier" 1)
    if ($multiplier -gt 0) {
        $planMonthlyData = $planMonthlyData * $multiplier
    }

    return [pscustomobject]@{
        planName = [string](Get-ConfigValue $json "plan" "")
        usedBytes = ConvertTo-UInt64Invariant (Get-ConfigValue $json "data_counter" 0)
        totalBytes = $planMonthlyData
        nextResetSeconds = [long](ConvertTo-UInt64Invariant (Get-ConfigValue $json "data_next_reset" 0))
    }
}

function Get-VpsTrafficPayload {
    $config = Read-BridgeConfig
    $vps = Get-ConfigValue $config "vpsTraffic"
    $payload = [ordered]@{
        ok = $true
        status = "OK"
        download_rate = "Unknown"
        upload_rate = "Unknown"
        bwh_usage = "Unknown"
        bwh_reset = "Unknown"
        tcp_inuse = "Unknown"
        tcp_established = "Unknown"
        node_color = "0"
        bwh_color = "0"
        node_status = ""
        bwh_status = ""
    }

    try {
        $current = Get-MetricsSnapshot $vps
        $previous = $Script:PreviousMetricsSnapshot
        if ($null -eq $previous) {
            $Script:PreviousMetricsSnapshot = $current
            Start-Sleep -Seconds 2
            $previous = $current
            $current = Get-MetricsSnapshot $vps
        }

        $rates = Get-RateDisplay $previous $current
        $Script:PreviousMetricsSnapshot = $current

        $payload["download_rate"] = $rates.down
        $payload["upload_rate"] = $rates.up
        $payload["tcp_inuse"] = ([string]$current.tcpInUse)
        $payload["tcp_established"] = ([string]$current.tcpEstablished)
        $payload["node_status"] = "Device: $($current.deviceName); RX: $(Format-ByteCount $current.receiveBytesTotal); TX: $(Format-ByteCount $current.transmitBytesTotal); Load1: $([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F2}', $current.load1))"
    }
    catch {
        $message = Protect-Secrets $_.Exception.Message $config
        $payload["ok"] = $false
        $payload["status"] = $message
        $payload["download_rate"] = $message
        $payload["upload_rate"] = $message
        $payload["tcp_inuse"] = $message
        $payload["tcp_established"] = $message
        $payload["node_color"] = "2"
        $payload["node_status"] = $message
    }

    try {
        $bwh = Get-BwhSnapshot $vps
        $payload["bwh_usage"] = if ($bwh.totalBytes -eq 0) {
            Format-CompactByteCount $bwh.usedBytes
        } else {
            (Format-CompactByteCount $bwh.usedBytes) + "/" + (Format-CompactByteCount $bwh.totalBytes)
        }
        $payload["bwh_reset"] = Format-DateText $bwh.nextResetSeconds
        $payload["bwh_color"] = Get-RatioColor $bwh.usedBytes $bwh.totalBytes
        $payload["bwh_status"] = "Plan: $($bwh.planName); Reset: $($payload["bwh_reset"])"
    }
    catch {
        $message = Protect-Secrets $_.Exception.Message $config
        $payload["ok"] = $false
        $payload["status"] = $message
        $payload["bwh_usage"] = $message
        $payload["bwh_reset"] = $message
        $payload["bwh_color"] = "2"
        $payload["bwh_status"] = $message
    }

    return $payload
}

function Write-HttpJson {
    param(
        [System.IO.Stream]$Stream,
        [object]$Payload,
        [int]$StatusCode = 200
    )

    $statusText = if ($StatusCode -eq 200) { "OK" } elseif ($StatusCode -eq 404) { "Not Found" } else { "Error" }
    $json = $Payload | ConvertTo-Json -Depth 8 -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $header = "HTTP/1.1 $StatusCode $statusText`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nCache-Control: no-store`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
}

function Handle-Client {
    param([System.Net.Sockets.TcpClient]$Client)

    try {
        $Client.ReceiveTimeout = 5000
        $Client.SendTimeout = 5000
        $stream = $Client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
        $requestLine = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($requestLine)) { return }

        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line -or $line.Length -eq 0) { break }
        }

        $parts = $requestLine.Split(" ")
        $target = if ($parts.Length -ge 2) { $parts[1] } else { "/" }
        $uri = [System.Uri]("http://127.0.0.1" + $target)
        $path = $uri.AbsolutePath.TrimEnd("/")
        if ([string]::IsNullOrEmpty($path)) { $path = "/" }

        switch ($path.ToLowerInvariant()) {
            "/health" {
                Write-HttpJson $stream ([ordered]@{ ok = $true; status = "OK" })
            }
            "/subtraffic" {
                Write-HttpJson $stream (Get-SubTrafficPayload)
            }
            "/vps" {
                Write-HttpJson $stream (Get-VpsTrafficPayload)
            }
            default {
                Write-HttpJson $stream ([ordered]@{ ok = $false; status = "Not found" }) 404
            }
        }
    }
    catch {
        try {
            Write-HttpJson $Client.GetStream() ([ordered]@{ ok = $false; status = $_.Exception.Message }) 500
        }
        catch {}
    }
    finally {
        $Client.Close()
    }
}

$config = Read-BridgeConfig
$listen = Get-ConfigValue $config "listen"
$hostName = [string](Get-ConfigValue $listen "host" "127.0.0.1")
$port = [int](Get-ConfigValue $listen "port" 18786)
$address = [System.Net.IPAddress]::Parse($hostName)
$listener = New-Object System.Net.Sockets.TcpListener($address, $port)
$listener.Start()

Write-Host "LiteMonitor bridge listening on http://$hostName`:$port/"
Write-Host "Endpoints: /health, /subtraffic, /vps"

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        Handle-Client $client
    }
}
finally {
    $listener.Stop()
}
