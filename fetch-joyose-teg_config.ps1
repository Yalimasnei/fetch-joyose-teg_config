<#
.SYNOPSIS
Pull Xiaomi Joyose TEG cloud scheduling config.

.EXAMPLE
.\fetch-joyose-teg_config.ps1 -UseAdb

.EXAMPLE
.\fetch-joyose-teg_config.ps1 -Device myron -MiuiRegion CN -Incremental OS3.0.306.0.WPMCNXM

.EXAMPLE
.\fetch-joyose-teg_config.ps1 -Server intl -Device duchamp -MiuiRegion US -Locale en_US -NoFetch
#>

[CmdletBinding()]
param(
    [ValidateSet("cn", "intl", "india", "russia", "staging")]
    [string]$Server = "cn",

    [string]$BaseUrl,
    [string]$OutDir = ".",

    [switch]$UseAdb,
    [switch]$NoFetch,
    [switch]$Pretty,
    [switch]$IncludeEmptyIds,
    [switch]$KeepDebugFiles,

    [string]$PackageName = "com.xiaomi.joyose",
    [int]$AppVersion = 490,
    [string]$VersionName = "2.4.90",
    [long]$LocalVersion = 0,
    [string]$Channel,

    [string]$Device = "myron",
    [string]$MiuiRegion = "CN",
    [string]$Locale = "zh_CN",
    [string]$Incremental = "OS3.0.306.0.WPMCNXM",
    [string]$MiuiVersionName = "V816",
    [string]$BuildType = "stable",
    [string]$AndroidRelease = "16",
    [string]$IHash,
    [string]$Uid
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Test-Text {
    param([object]$Value)
    return ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value))
}

function Select-FirstText {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Values)
    foreach ($value in $Values) {
        if (Test-Text $value) {
            return ([string]$value).Trim()
        }
    }
    return $null
}

function Get-AdbProp {
    param([string]$Name)

    $adb = Get-Command adb -ErrorAction SilentlyContinue
    if (-not $adb) {
        throw "adb not found. Install Android platform-tools or run without -UseAdb and pass device fields manually."
    }

    $output = & $adb.Source shell getprop $Name 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return (($output -join "`n") -replace "`r", "").Trim()
}

function Convert-LocaleName {
    param([string]$Value)
    if (-not (Test-Text $Value)) {
        return $null
    }

    $normalized = $Value.Trim().Replace("-", "_")
    $parts = $normalized.Split("_")
    if ($parts.Count -ge 2) {
        return ("{0}_{1}" -f $parts[0].ToLowerInvariant(), $parts[1].ToUpperInvariant())
    }

    return $normalized
}

function Normalize-Region {
    param([string]$Value)
    if (-not (Test-Text $Value)) {
        return $null
    }
    return $Value.Trim().ToUpperInvariant()
}

function Get-DefaultRegion {
    param([string]$ServerName)
    switch ($ServerName) {
        "india" { return "IN" }
        "russia" { return "RU" }
        "intl" { return "US" }
        default { return "CN" }
    }
}

function Get-DefaultLocale {
    param([string]$Region)
    switch ($Region) {
        "CN" { return "zh_CN" }
        "IN" { return "en_IN" }
        "RU" { return "ru_RU" }
        default { return "en_US" }
    }
}

function Infer-BuildType {
    param([string]$IncrementalVersion)
    if (-not (Test-Text $IncrementalVersion)) {
        return $null
    }

    if ($IncrementalVersion -match "(?i)alpha") {
        return "alpha"
    }
    if ($IncrementalVersion -match "(?i)(dev|weekly|development)") {
        return "development"
    }
    return "stable"
}

function ConvertTo-CompactJson {
    param([object]$Value)
    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    $builder = New-Object System.Text.StringBuilder
    $indent = 0
    $inString = $false
    $escaped = $false

    for ($i = 0; $i -lt $json.Length; $i++) {
        $char = $json[$i]

        if ($inString) {
            [void]$builder.Append($char)
            if ($escaped) {
                $escaped = $false
            } elseif ($char -eq '\') {
                $escaped = $true
            } elseif ($char -eq '"') {
                $inString = $false
            }
            continue
        }

        switch ($char) {
            '"' {
                $inString = $true
                [void]$builder.Append($char)
            }
            { $_ -eq '{' -or $_ -eq '[' } {
                $close = if ($char -eq '{') { '}' } else { ']' }
                $j = $i + 1
                while ($j -lt $json.Length -and [char]::IsWhiteSpace($json[$j])) { $j++ }
                if ($j -lt $json.Length -and $json[$j] -eq $close) {
                    [void]$builder.Append($char)
                    [void]$builder.Append($close)
                    $i = $j
                } else {
                    [void]$builder.Append($char)
                    $indent++
                    [void]$builder.Append("`r`n")
                    [void]$builder.Append((' ' * ($indent * 2)))
                }
            }
            { $_ -eq '}' -or $_ -eq ']' } {
                $indent--
                [void]$builder.Append("`r`n")
                [void]$builder.Append((' ' * ($indent * 2)))
                [void]$builder.Append($char)
            }
            ',' {
                [void]$builder.Append($char)
                [void]$builder.Append("`r`n")
                [void]$builder.Append((' ' * ($indent * 2)))
            }
            ':' {
                [void]$builder.Append(": ")
            }
            { [char]::IsWhiteSpace($_) } {
            }
            default {
                [void]$builder.Append($char)
            }
        }
    }

    return $builder.ToString()
}

function Encode-FormComponent {
    param([string]$Value)

    if ($null -eq $Value) {
        $Value = "null"
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $bytes) {
        $isAlphaNum = (
            ($byte -ge 0x30 -and $byte -le 0x39) -or
            ($byte -ge 0x41 -and $byte -le 0x5A) -or
            ($byte -ge 0x61 -and $byte -le 0x7A)
        )
        if ($isAlphaNum -or $byte -eq 0x2E -or $byte -eq 0x2D -or $byte -eq 0x2A -or $byte -eq 0x5F) {
            [void]$builder.Append([char]$byte)
        } elseif ($byte -eq 0x20) {
            [void]$builder.Append("+")
        } else {
            [void]$builder.Append("%")
            [void]$builder.Append($byte.ToString("X2"))
        }
    }
    return $builder.ToString()
}

function Get-TegSign {
    param(
        [System.Collections.IDictionary]$Params,
        [string]$SigningPackageName
    )

    [string[]]$keys = @($Params.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($keys, [System.StringComparer]::Ordinal)

    $parts = New-Object "System.Collections.Generic.List[string]"
    foreach ($key in $keys) {
        if ([string]::IsNullOrEmpty($key)) {
            continue
        }
        $value = $Params[$key]
        if ($null -eq $value) {
            $value = "null"
        }
        [void]$parts.Add(("{0}={1}" -f $key, [string]$value))
    }

    $raw = (($parts.ToArray()) -join "&") + "&" + $SigningPackageName
    $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($raw))
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($base64))
    } finally {
        $md5.Dispose()
    }

    $hex = New-Object System.Text.StringBuilder
    foreach ($byte in $hash) {
        [void]$hex.Append($byte.ToString("X2"))
    }

    return [pscustomobject]@{
        Raw    = $raw
        Base64 = $base64
        Sign   = $hex.ToString()
    }
}

function New-TegFormBody {
    param(
        [System.Collections.IDictionary]$Params,
        [string]$SigningPackageName
    )

    $pairs = New-Object "System.Collections.Generic.List[string]"
    [string[]]$keys = @($Params.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($keys, [System.StringComparer]::Ordinal)
    foreach ($key in $keys) {
        if ([string]::IsNullOrEmpty($key)) {
            continue
        }
        $value = $Params[$key]
        if ($null -eq $value) {
            $value = "null"
        }
        [void]$pairs.Add(("{0}={1}" -f (Encode-FormComponent $key), (Encode-FormComponent ([string]$value))))
    }

    $signature = Get-TegSign -Params $Params -SigningPackageName $SigningPackageName
    [void]$pairs.Add(("sign={0}" -f (Encode-FormComponent $signature.Sign)))

    return [pscustomobject]@{
        Body      = (($pairs.ToArray()) -join "&")
        Signature = $signature
    }
}

function Get-TegBaseUrl {
    param([string]$ServerName)
    switch ($ServerName) {
        "staging" { return "http://staging.mcc.inf.miui.com/" }
        "india" { return "https://mcc.india.inf.miui.com/" }
        "russia" { return "https://mcc.russia.inf.miui.com/" }
        "intl" { return "https://mcc.intl.inf.miui.com/" }
        default { return "https://mcc.inf.miui.com/" }
    }
}

function Save-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )
    Set-Content -LiteralPath $Path -Value (ConvertTo-CompactJson $Value) -Encoding UTF8
}

function Invoke-TegPost {
    param(
        [string]$Uri,
        [string]$Body,
        [string]$BodyPath
    )

    try {
        $response = Invoke-WebRequest `
            -Uri $Uri `
            -Method Post `
            -Body $Body `
            -ContentType "application/x-www-form-urlencoded" `
            -UseBasicParsing `
            -TimeoutSec 30
        return $response.Content
    } catch {
        $webError = $_.Exception.Message
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if (-not $curl) {
            $curlError = "curl.exe not found"
        } else {
            Write-Warning "Invoke-WebRequest failed: $webError; retrying with curl.exe"
            $curlArgs = @(
                "-sS",
                "--tlsv1.2",
                "--ssl-no-revoke",
                "-X", "POST",
                "-H", "Content-Type: application/x-www-form-urlencoded",
                "--data-binary", "@$BodyPath",
                "--connect-timeout", "10",
                "--max-time", "30",
                $Uri
            )
            $oldErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $curlOutput = & $curl.Source @curlArgs 2>&1
                $curlExit = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $oldErrorActionPreference
            }
            if ($curlExit -eq 0) {
                return ($curlOutput -join "`n")
            }
            $curlError = $curlOutput -join "`n"
        }

        $pythonCandidates = @(
            (Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"),
            "python.exe"
        )
        $pythonExe = $null
        foreach ($candidate in $pythonCandidates) {
            if (Test-Path -LiteralPath $candidate) {
                $pythonExe = $candidate
                break
            }
            $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($cmd) {
                $pythonExe = $cmd.Source
                break
            }
        }

        if (-not $pythonExe) {
            throw "Invoke-WebRequest failed: $webError; curl.exe failed: $curlError; python.exe not found"
        }

        Write-Warning "curl.exe failed: $curlError; retrying with python urllib"
        $pythonCode = @'
import pathlib
import sys
import urllib.request

url = sys.argv[1]
body_path = pathlib.Path(sys.argv[2])
body = body_path.read_bytes()
request = urllib.request.Request(
    url,
    data=body,
    headers={'Content-Type': 'application/x-www-form-urlencoded'},
    method='POST',
)
with urllib.request.urlopen(request, timeout=30) as response:
    sys.stdout.buffer.write(response.read())
'@
        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $pythonOutput = & $pythonExe -c $pythonCode $Uri $BodyPath 2>&1
            $pythonExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        if ($pythonExit -ne 0) {
            throw "Invoke-WebRequest failed: $webError; curl.exe failed: $curlError; python urllib failed: $($pythonOutput -join "`n")"
        }
        return ($pythonOutput -join "`n")
    }
}

function Convert-JsonStringOrNull {
    param([string]$Text)
    if (-not (Test-Text $Text)) {
        return $null
    }
    try {
        return ($Text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Get-SafeFileName {
    param([string]$Value)
    if (-not (Test-Text $Value)) {
        return "unknown"
    }
    return ($Value -replace '[\\/:*?"<>|]', "_")
}

function Remove-GeneratedExtraFiles {
    param(
        [string]$OutRoot,
        [string[]]$KeepPaths
    )

    $keepNames = @{}
    foreach ($path in $KeepPaths) {
        if (Test-Text $path) {
            $keepNames[[IO.Path]::GetFileName($path).ToLowerInvariant()] = $true
        }
    }

    $generatedPatterns = @(
        '^teg_getData_(request|response|raw)\.json$',
        '^teg_getData_body\.txt$',
        '^rules\.json$',
        '^rule_.+\.(json|txt)$',
        '^module_.+_(merged|rules)\.json$',
        '^\[teg_config\.db\]\[.+\]\.json$',
        '^\[(booster_config|common_config)\]\.json$'
    )

    foreach ($file in Get-ChildItem -LiteralPath $OutRoot -File) {
        if ($keepNames.ContainsKey($file.Name.ToLowerInvariant())) {
            continue
        }
        foreach ($pattern in $generatedPatterns) {
            if ($file.Name -match $pattern) {
                Remove-Item -LiteralPath $file.FullName -Force
                break
            }
        }
    }
}

if ($UseAdb) {
    $Device = Select-FirstText $Device (Get-AdbProp "ro.product.device") (Get-AdbProp "ro.build.product")
    $MiuiRegion = Select-FirstText $MiuiRegion (Get-AdbProp "ro.miui.region") (Get-AdbProp "ro.miui.build.region")
    $Locale = Select-FirstText $Locale (Get-AdbProp "persist.sys.locale") (Get-AdbProp "ro.product.locale")
    $Incremental = Select-FirstText $Incremental (Get-AdbProp "ro.build.version.incremental")
    $MiuiVersionName = Select-FirstText $MiuiVersionName (Get-AdbProp "ro.miui.ui.version.name")
    $AndroidRelease = Select-FirstText $AndroidRelease (Get-AdbProp "ro.build.version.release")
}

$Device = Select-FirstText $Device "myron"
$MiuiRegion = Normalize-Region (Select-FirstText $MiuiRegion (Get-DefaultRegion $Server))
$Locale = Convert-LocaleName (Select-FirstText $Locale (Get-DefaultLocale $MiuiRegion))
$Incremental = Select-FirstText $Incremental "OS3.0.306.0.WPMCNXM"
$MiuiVersionName = Select-FirstText $MiuiVersionName "V816"
$AndroidRelease = Select-FirstText $AndroidRelease "16"
$BuildType = Select-FirstText $BuildType (Infer-BuildType $Incremental)
$Uid = Select-FirstText $Uid ([guid]::NewGuid().ToString())

if (-not (Test-Text $BaseUrl)) {
    $BaseUrl = Get-TegBaseUrl $Server
}
$url = $BaseUrl.TrimEnd("/") + "/cloud/app/getData"

$deviceInfo = [ordered]@{}
if ((Test-Text $IHash) -or $IncludeEmptyIds) { $deviceInfo["ihash"] = [string]$IHash }
if ((Test-Text $Uid) -or $IncludeEmptyIds) { $deviceInfo["uid"] = [string]$Uid }
if (Test-Text $Device) { $deviceInfo["d"] = $Device }
if (Test-Text $MiuiRegion) { $deviceInfo["r"] = $MiuiRegion }
if (Test-Text $Locale) { $deviceInfo["l"] = $Locale }
if (Test-Text $Incremental) { $deviceInfo["v"] = $Incremental }
if (Test-Text $MiuiVersionName) { $deviceInfo["bv"] = $MiuiVersionName }
if (Test-Text $BuildType) { $deviceInfo["t"] = $BuildType }
if (Test-Text $AndroidRelease) { $deviceInfo["av"] = $AndroidRelease }
$deviceInfo["p"] = "android"

$deviceInfoJson = ConvertTo-CompactJson $deviceInfo

$params = [ordered]@{
    packageName = $PackageName
    appVersion  = [string]$AppVersion
}
if (Test-Text $Channel) { $params["channel"] = $Channel }
if (Test-Text $VersionName) { $params["versionName"] = $VersionName }
if (Test-Text $deviceInfoJson) { $params["deviceInfo"] = $deviceInfoJson }
$params["version"] = [string]$LocalVersion

$form = New-TegFormBody -Params $params -SigningPackageName $PackageName

$outRoot = Join-Path $PSScriptRoot $OutDir
New-Item -ItemType Directory -Force -Path $outRoot | Out-Null

$requestInfo = [ordered]@{
    url        = $url
    method     = "POST"
    contentType = "application/x-www-form-urlencoded"
    server     = $Server
    params     = $params
    deviceInfo = $deviceInfo
    signRaw    = $form.Signature.Raw
    signBase64 = $form.Signature.Base64
    sign       = $form.Signature.Sign
    body       = $form.Body
}
Save-JsonFile -Path (Join-Path $outRoot "teg_getData_request.json") -Value $requestInfo
$bodyPath = Join-Path $outRoot "teg_getData_body.txt"
[System.IO.File]::WriteAllText($bodyPath, $form.Body, [System.Text.Encoding]::ASCII)

Write-Host "Joyose TEG getData"
Write-Host "  URL: $url"
Write-Host "  Device: $Device / region=$MiuiRegion / incremental=$Incremental"
Write-Host "  Sign: $($form.Signature.Sign)"
if ($KeepDebugFiles) {
    Write-Host "  Request saved: $(Join-Path $outRoot "teg_getData_request.json")"
    Write-Host "  Body saved: $bodyPath"
}

if ($NoFetch) {
    Write-Host "  NoFetch enabled; request body generated only."
    return
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # Older runtimes may not expose this knob; keep going with the platform default.
}

$responseContent = Invoke-TegPost -Uri $url -Body $form.Body -BodyPath $bodyPath

$rawPath = Join-Path $outRoot "teg_getData_raw.json"
Set-Content -LiteralPath $rawPath -Value $responseContent -Encoding UTF8
if ($KeepDebugFiles) {
    Write-Host "  Raw response saved: $rawPath"
}

$responseJson = $responseContent | ConvertFrom-Json -ErrorAction Stop
Save-JsonFile -Path (Join-Path $outRoot "teg_getData_response.json") -Value $responseJson

if ([int]$responseJson.code -ne 200) {
    Write-Warning "Server returned code=$($responseJson.code). Raw response was saved."
    return
}

$rules = @($responseJson.data.rules)
Save-JsonFile -Path (Join-Path $outRoot "rules.json") -Value $rules

$activeRules = @($rules | Where-Object { [int]$_.status -eq 1 })
foreach ($rule in $activeRules) {
    $module = Get-SafeFileName ([string]$rule.moduleKey)
    $ruleId = Get-SafeFileName ([string]$rule.ruleId)
    $version = Get-SafeFileName ([string]$rule.version)
    $contentText = [string]$rule.content
    $parsedContent = Convert-JsonStringOrNull $contentText

    if ($null -ne $parsedContent) {
        Save-JsonFile -Path (Join-Path $outRoot ("rule_{0}_{1}_v{2}.json" -f $module, $ruleId, $version)) -Value $parsedContent
    } else {
        Set-Content -LiteralPath (Join-Path $outRoot ("rule_{0}_{1}_v{2}.txt" -f $module, $ruleId, $version)) -Value $contentText -Encoding UTF8
    }
}

$outputModules = @("booster_config", "common_config")
$finalFiles = New-Object "System.Collections.Generic.List[string]"
$groups = $activeRules | Group-Object -Property moduleKey
foreach ($group in $groups) {
    $module = Get-SafeFileName ([string]$group.Name)
    $orderedRules = @($group.Group | Sort-Object -Property @{ Expression = { [long]$_.version }; Ascending = $true })
    $moduleRules = New-Object "System.Collections.Generic.List[object]"
    $merged = [ordered]@{}

    foreach ($rule in $orderedRules) {
        $contentText = [string]$rule.content
        $parsedContent = Convert-JsonStringOrNull $contentText
        [void]$moduleRules.Add([pscustomobject]@{
            status    = [int]$rule.status
            ruleId    = [long]$rule.ruleId
            version   = [long]$rule.version
            moduleKey = [string]$rule.moduleKey
            content   = $(if ($null -ne $parsedContent) { $parsedContent } else { $contentText })
        })

        if ($null -ne $parsedContent -and @($parsedContent.PSObject.Properties).Count -gt 0) {
            foreach ($prop in $parsedContent.PSObject.Properties) {
                $merged[$prop.Name] = $prop.Value
            }
        }
    }

    Save-JsonFile -Path (Join-Path $outRoot ("module_{0}_rules.json" -f $module)) -Value $moduleRules
    if ($merged.Count -gt 0) {
        Save-JsonFile -Path (Join-Path $outRoot ("module_{0}_merged.json" -f $module)) -Value $merged
        Save-JsonFile -Path (Join-Path $outRoot ("[teg_config.db][{0}].json" -f $module)) -Value $merged
        if ($outputModules -contains $module) {
            $finalPath = Join-Path $outRoot ("[{0}].json" -f $module)
            Save-JsonFile -Path $finalPath -Value $merged
            [void]$finalFiles.Add($finalPath)
        }
    }
}

$zipPath = $null
if ($finalFiles.Count -gt 0) {
    $zipName = "{0}-{1}-teg_config.zip" -f (Get-SafeFileName $Device), (Get-SafeFileName $Incremental)
    $zipPath = Join-Path $outRoot $zipName
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -LiteralPath $finalFiles.ToArray() -DestinationPath $zipPath -Force
}

if (-not $KeepDebugFiles) {
    Remove-GeneratedExtraFiles -OutRoot $outRoot -KeepPaths @($zipPath)
}

Write-Host "  maxVersion: $($responseJson.data.maxVersion)"
Write-Host "  rules: $($rules.Count), active: $($activeRules.Count)"
Write-Host "  Output dir: $outRoot"
if ($zipPath) {
    Write-Host "  Zip: $zipPath"
}
