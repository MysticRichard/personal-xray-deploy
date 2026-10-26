[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceConfig,

    [Parameter(Mandatory = $true)]
    [string]$Server,

    [int]$Port = 443,

    [Parameter(Mandatory = $true)]
    [string]$UUID,

    [Parameter(Mandatory = $true)]
    [string]$PublicKey,

    [Parameter(Mandatory = $true)]
    [string]$ShortId,

    [Parameter(Mandatory = $true)]
    [string]$ServerName,

    [string]$NodeName = 'Personal-VPS',

    [string]$OutputPath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$script:AllowedActions = @('DIRECT', 'PROXY', 'REJECT')
$script:ReservedPolicyNames = @('DIRECT', 'PROXY', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE', 'GLOBAL')
$script:NotableAppKeys = @(
    'mixed-port', 'allow-lan', 'external-controller', 'secret', 'authentication',
    'dns', 'tun', 'sniffer', 'profile', 'experimental', 'listeners', 'hosts'
)
$script:SensitiveKeys = @('external-controller', 'secret', 'authentication')
$script:AppSpecificKeys = @('tun', 'dns', 'sniffer', 'profile', 'experimental')

function Quote-Yaml([string]$Value) {
    $escaped = $Value.Replace([string][char]92, ([string][char]92 + [string][char]92))
    $escaped = $escaped.Replace([string][char]34, ([string][char]92 + [string][char]34))
    return ([string][char]34 + $escaped + [string][char]34)
}

function Assert-NonEmpty([string]$Name, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name must not be empty" }
}

function Assert-NoControlChars([string]$Name, [string]$Value) {
    if ($Value -match '[\x00-\x1F\x7F]') { throw "$Name must not contain control characters" }
}

function Assert-HostName([string]$Name, [string]$Value) {
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($Value, [ref]$ip)) { return }
    if ($Value.Length -gt 253) { throw "$Name is too long" }
    $pattern = '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
    if ($Value -notmatch $pattern) { throw "$Name is not a valid IP address or hostname: $Value" }
}

function Assert-Uuid([string]$Value) {
    $pattern = '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$'
    if ($Value -notmatch $pattern) {
        throw "UUID is not a valid RFC 4122 UUID (expected xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx): $Value"
    }
}

function Assert-RealityPublicKey([string]$Value) {
    if ($Value -notmatch '^[A-Za-z0-9_-]{43}$') {
        throw 'PublicKey must be the base64url form of a 32-byte REALITY public key (43 characters, no padding)'
    }
    $padded = $Value.Replace('-', '+').Replace('_', '/') + '='
    try {
        $bytes = [Convert]::FromBase64String($padded)
    } catch {
        throw 'PublicKey is not valid base64url'
    }
    if ($bytes.Length -ne 32) { throw 'PublicKey does not decode to 32 bytes' }
}

function Assert-ShortId([string]$Value) {
    if ($Value -notmatch '^([0-9A-Fa-f]{2}){1,8}$') {
        throw "ShortId must be 2 to 16 hexadecimal characters (even length): $Value"
    }
}

function Get-BlockName([string]$Line) {
    $name = ($Line -split ':', 2)[0].Trim()
    return $name.Trim('"').Trim("'")
}

function Get-TopLevelBlocks([string[]]$Lines) {
    $starts = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^(?!-)[^\s#][^:]*:') { $starts.Add($i) }
    }
    $blocks = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $starts.Count; $i++) {
        $start = $starts[$i]
        $end = $Lines.Count
        if (($i + 1) -lt $starts.Count) { $end = $starts[$i + 1] }
        $blocks.Add([pscustomobject]@{
            Name  = Get-BlockName $Lines[$start]
            Start = $start
            End   = $end
        })
    }
    return $blocks.ToArray()
}

function Get-TopLevelBlockInfo([string[]]$Lines, [string]$Name) {
    $found = @(Get-TopLevelBlocks $Lines | Where-Object { $_.Name -ceq $Name })
    if ($found.Count -eq 0) { throw "Top-level section not found: $Name" }
    if ($found.Count -gt 1) { throw "Top-level section appears more than once: $Name" }
    return $found[0]
}

function Get-TopLevelBlock([string[]]$Lines, [string]$Name) {
    $info = Get-TopLevelBlockInfo $Lines $Name
    return ,@($Lines[$info.Start..($info.End - 1)])
}

function Replace-TopLevelBlock([string[]]$Lines, [string]$Name, [string[]]$Replacement) {
    $info = Get-TopLevelBlockInfo $Lines $Name

    # Keep blank lines and comments that trail the replaced body so that
    # formatting between sections is not lost.
    $keepFrom = $info.End
    while ($keepFrom -gt ($info.Start + 1)) {
        $candidate = $Lines[$keepFrom - 1]
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.TrimStart().StartsWith('#')) {
            $keepFrom--
        } else {
            break
        }
    }

    $result = New-Object 'System.Collections.Generic.List[string]'
    if ($info.Start -gt 0) { $result.AddRange([string[]]$Lines[0..($info.Start - 1)]) }
    $result.AddRange($Replacement)
    if ($keepFrom -lt $Lines.Count) { $result.AddRange([string[]]$Lines[$keepFrom..($Lines.Count - 1)]) }
    return ,$result.ToArray()
}

function Split-RuleFields([string]$Rule) {
    $fields = New-Object 'System.Collections.Generic.List[string]'
    $current = New-Object System.Text.StringBuilder
    $depth = 0
    $quote = [char]0
    for ($i = 0; $i -lt $Rule.Length; $i++) {
        $c = $Rule[$i]
        if ($quote -ne [char]0) {
            if ($c -eq $quote) { $quote = [char]0 }
            [void]$current.Append($c)
            continue
        }
        if ($c -eq [char]34 -or $c -eq [char]39) {
            $quote = $c
            [void]$current.Append($c)
            continue
        }
        if ($c -eq [char]40) {
            $depth++
            [void]$current.Append($c)
            continue
        }
        if ($c -eq [char]41) {
            if ($depth -gt 0) { $depth-- }
            [void]$current.Append($c)
            continue
        }
        if ($c -eq [char]44 -and $depth -eq 0) {
            $fields.Add($current.ToString().Trim())
            [void]$current.Clear()
            continue
        }
        [void]$current.Append($c)
    }
    $fields.Add($current.ToString().Trim())
    return $fields.ToArray()
}

function Get-RuleText([string]$Line) {
    $text = $Line.Trim()
    if ($text -notmatch '^-\s+(.+)$') { throw "Unsupported rules entry: $Line" }
    $text = $Matches[1].Trim()

    if ($text.StartsWith('"')) {
        $builder = New-Object System.Text.StringBuilder
        $i = 1
        while ($i -lt $text.Length) {
            $c = $text[$i]
            if ($c -eq [char]92 -and ($i + 1) -lt $text.Length) {
                [void]$builder.Append($text[$i + 1])
                $i += 2
                continue
            }
            if ($c -eq [char]34) { return $builder.ToString() }
            [void]$builder.Append($c)
            $i++
        }
        throw "Unterminated double quote in rules entry: $Line"
    }

    if ($text.StartsWith("'")) {
        $builder = New-Object System.Text.StringBuilder
        $i = 1
        while ($i -lt $text.Length) {
            $c = $text[$i]
            if ($c -eq [char]39) {
                if (($i + 1) -lt $text.Length -and $text[$i + 1] -eq [char]39) {
                    [void]$builder.Append([char]39)
                    $i += 2
                    continue
                }
                return $builder.ToString()
            }
            [void]$builder.Append($c)
            $i++
        }
        throw "Unterminated single quote in rules entry: $Line"
    }

    $comment = $text.IndexOf(' #')
    if ($comment -ge 0) { $text = $text.Substring(0, $comment) }
    return $text.Trim()
}

function Get-RuleTarget([string]$RuleText, [int]$LineNumber) {
    $fields = Split-RuleFields $RuleText
    if ($fields.Count -lt 2) { throw "rules line $LineNumber is not a recognisable rule: $RuleText" }
    if ($fields[0].ToUpperInvariant() -eq 'SUB-RULE') {
        throw "rules line $LineNumber uses SUB-RULE; the generator cannot validate sub-rules, refusing to continue"
    }
    $last = $fields.Count - 1
    while ($last -gt 1 -and ($fields[$last] -ceq 'no-resolve' -or $fields[$last] -ceq 'src')) { $last-- }
    return $fields[$last]
}

function Get-RulesInfo([string[]]$RulesBlock, [int]$RulesStartLine) {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 1; $i -lt $RulesBlock.Count; $i++) {
        $line = $RulesBlock[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.TrimStart().StartsWith('#')) { continue }
        if ($line -notmatch '^\s*-\s+(.+)$') {
            throw "rules line $($RulesStartLine + $i + 1) is not a list entry: $line"
        }
        $entries.Add([pscustomobject]@{
            Number = $RulesStartLine + $i + 1
            Text   = Get-RuleText $line
        })
    }
    if ($entries.Count -eq 0) { throw 'rules section is empty, refusing to generate' }

    $actions = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        $target = Get-RuleTarget $entry.Text $entry.Number
        if ($script:AllowedActions -cnotcontains $target) {
            throw "rules line $($entry.Number) ends in unsupported action '$target'; only DIRECT, PROXY and REJECT are allowed, refusing to generate"
        }
        if ($seen.Add($target)) { $actions.Add($target) }
    }
    if (-not $seen.Contains('PROXY')) {
        throw 'Source config has no PROXY rule; refusing to change routing behaviour'
    }

    return [pscustomobject]@{
        Count   = $entries.Count
        Actions = $actions.ToArray()
    }
}

function Assert-RulesPreserved([string[]]$Before, [string[]]$After) {
    $beforeRules = Get-TopLevelBlock $Before 'rules'
    $afterRules = Get-TopLevelBlock $After 'rules'
    if ($beforeRules.Count -ne $afterRules.Count) { throw 'rules section line count changed; refusing to write output' }
    for ($i = 0; $i -lt $beforeRules.Count; $i++) {
        if ($beforeRules[$i] -cne $afterRules[$i]) {
            throw "rules section line $($i + 1) changed; refusing to write output"
        }
    }
}

function Assert-OtherBlocksPreserved([string[]]$Before, [string[]]$After, [string[]]$Replaced) {
    $beforeBlocks = Get-TopLevelBlocks $Before
    $afterBlocks = Get-TopLevelBlocks $After
    if ($beforeBlocks.Count -ne $afterBlocks.Count) { throw 'Top-level section count changed; refusing to write output' }
    for ($i = 0; $i -lt $beforeBlocks.Count; $i++) {
        $beforeBlock = $beforeBlocks[$i]
        $afterBlock = $afterBlocks[$i]
        if ($beforeBlock.Name -cne $afterBlock.Name) { throw 'Top-level section order changed; refusing to write output' }
        if ($Replaced -contains $beforeBlock.Name) { continue }
        $beforeText = $Before[$beforeBlock.Start..($beforeBlock.End - 1)] -join "`n"
        $afterText = $After[$afterBlock.Start..($afterBlock.End - 1)] -join "`n"
        if ($beforeText -cne $afterText) {
            throw "Top-level section '$($beforeBlock.Name)' was not preserved verbatim; refusing to write output"
        }
    }
}

function Get-FullPath([string]$Path) {
    try {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    } catch {
        return [IO.Path]::GetFullPath($Path)
    }
}

function Test-SamePath([string]$Left, [string]$Right) {
    return [StringComparer]::OrdinalIgnoreCase.Equals((Get-FullPath $Left), (Get-FullPath $Right))
}

function Write-Utf8Atomically([string]$Path, [string]$Content, [switch]$Overwrite) {
    $directory = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($directory)) { throw "Cannot determine output directory for: $Path" }
    $tempPath = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($tempPath, $Content, $utf8)
        if ($Overwrite -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Move-Item -LiteralPath $tempPath -Destination $Path -Force
        } else {
            [IO.File]::Move($tempPath, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

$Server = $Server.Trim()
$UUID = $UUID.Trim()
$PublicKey = $PublicKey.Trim()
$ShortId = $ShortId.Trim()
$ServerName = $ServerName.Trim()
$NodeName = $NodeName.Trim()

Assert-NonEmpty 'Server' $Server
Assert-NonEmpty 'UUID' $UUID
Assert-NonEmpty 'PublicKey' $PublicKey
Assert-NonEmpty 'ShortId' $ShortId
Assert-NonEmpty 'ServerName' $ServerName
Assert-NonEmpty 'NodeName' $NodeName

Assert-NoControlChars 'Server' $Server
Assert-NoControlChars 'ServerName' $ServerName
Assert-NoControlChars 'NodeName' $NodeName

if ($Port -lt 1 -or $Port -gt 65535) { throw "Port out of range: $Port" }
Assert-HostName 'Server' $Server
Assert-HostName 'ServerName' $ServerName
Assert-Uuid $UUID
Assert-RealityPublicKey $PublicKey
Assert-ShortId $ShortId
if ($script:ReservedPolicyNames -contains $NodeName.ToUpperInvariant()) {
    throw "NodeName collides with a reserved policy name: $NodeName"
}

if (-not (Test-Path -LiteralPath $SourceConfig -PathType Leaf)) { throw "Source config not found: $SourceConfig" }
$sourceFull = (Resolve-Path -LiteralPath $SourceConfig).Path
$sourceText = [IO.File]::ReadAllText($sourceFull)

$newline = "`n"
if ($sourceText.Contains("`r`n")) { $newline = "`r`n" }
if ($newline -eq "`r`n" -and [regex]::IsMatch($sourceText, '(?<!\r)\n')) {
    Write-Warning 'Source config mixes CRLF and LF; output will use CRLF'
}
$endsWithNewline = $sourceText.EndsWith("`n") -or $sourceText.EndsWith("`r")
$sourceLines = [regex]::Split($sourceText, "\r\n|\n|\r")
if ($endsWithNewline -and $sourceLines.Count -gt 1 -and $sourceLines[$sourceLines.Count - 1] -eq '') {
    $sourceLines = $sourceLines[0..($sourceLines.Count - 2)]
}

$rulesBlockInfo = Get-TopLevelBlockInfo $sourceLines 'rules'
$originalRules = Get-TopLevelBlock $sourceLines 'rules'
$rulesInfo = Get-RulesInfo $originalRules $rulesBlockInfo.Start

$node = @(
    'proxies:',
    "  - name: $(Quote-Yaml $NodeName)",
    '    type: vless',
    "    server: $(Quote-Yaml $Server)",
    "    port: $Port",
    "    uuid: $(Quote-Yaml $UUID)",
    '    network: tcp',
    '    tls: true',
    '    udp: true',
    '    flow: xtls-rprx-vision',
    '    client-fingerprint: chrome',
    "    servername: $(Quote-Yaml $ServerName)",
    '    reality-opts:',
    "      public-key: $(Quote-Yaml $PublicKey)",
    "      short-id: $(Quote-Yaml $ShortId)"
)

$groups = @(
    'proxy-groups:',
    '  - name: "PROXY"',
    '    type: select',
    '    proxies:',
    "      - $(Quote-Yaml $NodeName)",
    '      - DIRECT'
)

$generated = Replace-TopLevelBlock $sourceLines 'proxies' $node
$generated = Replace-TopLevelBlock $generated 'proxy-groups' $groups
Assert-RulesPreserved $sourceLines $generated
Assert-OtherBlocksPreserved $sourceLines $generated @('proxies', 'proxy-groups')

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Parent $sourceFull) 'xray-personal.yaml'
}
$outputFull = Get-FullPath $OutputPath

if (Test-SamePath $sourceFull $outputFull) {
    throw "Output path must differ from the source config; refusing to overwrite the original file: $outputFull"
}
if (Test-Path -LiteralPath $outputFull -PathType Container) {
    throw "Output path is a directory, not a file: $outputFull"
}
$outputDirectory = Split-Path -Parent $outputFull
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Output directory does not exist: $outputDirectory"
}
if ((Test-Path -LiteralPath $outputFull -PathType Leaf) -and -not $Force) {
    throw "Output file already exists: $outputFull; choose another -OutputPath or pass -Force to overwrite it"
}

$content = ($generated -join $newline)
if ($endsWithNewline) { $content += $newline }
Write-Utf8Atomically $outputFull $content -Overwrite:$Force

if ([IO.File]::ReadAllText($sourceFull) -cne $sourceText) {
    throw "Source config changed while generating; please check: $sourceFull"
}

$sourceBlocks = Get-TopLevelBlocks $sourceLines
$copiedKeys = @($sourceBlocks | Where-Object { $script:NotableAppKeys -contains $_.Name } | ForEach-Object { $_.Name })
$copiedSensitive = @($copiedKeys | Where-Object { $script:SensitiveKeys -contains $_ })
$copiedAppSpecific = @($copiedKeys | Where-Object { $script:AppSpecificKeys -contains $_ })

Write-Output "Generated: $outputFull"
Write-Output "Rules preserved: $($rulesInfo.Count) (content and order unchanged)"
Write-Output "Rule actions: $($rulesInfo.Actions -join ', ')"
Write-Output "New node: $NodeName"
if ($copiedKeys.Count -gt 0) {
    Write-Output "Copied app sections verbatim: $($copiedKeys -join ', ')"
}
if ($copiedAppSpecific.Count -gt 0) {
    Write-Output "NOTE: $($copiedAppSpecific -join ', ') came from the FlClash app config and are device/app specific; remove them if this profile is meant for another device."
}
if ($copiedSensitive.Count -gt 0) {
    Write-Output 'WARNING: output keeps controller/auth fields from the source config; do not share or commit it.'
}
Write-Output "Source config untouched: $sourceFull"
