$ErrorActionPreference = 'Stop'

# Tests for generate-flclash-profile.ps1
# Focus: fail-closed validation, exact preservation of the rules block and
# every untouched top-level block, no accidental overwrite of the source or of
# an existing output file. Everything runs through Windows PowerShell 5.1.

$root = Split-Path -Parent $PSScriptRoot
$generator = Join-Path $root 'generate-flclash-profile.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Command powershell).Source }

$script:passes = 0
$script:failures = 0

function Pass([string]$Message) {
    $script:passes++
    Write-Output ("PASS: " + $Message)
}

function Fail([string]$Message) {
    $script:failures++
    Write-Output ("FAIL: " + $Message)
}

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

function Assert-Equal([string]$Expected, [string]$Actual, [string]$Message) {
    if ($Expected -ceq $Actual) { Pass $Message } else { Fail ($Message + ' (values differ)') }
}

function New-TempDir {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('flclash-test-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir -Force)
    return $dir
}

function Write-TextFile([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-TextFile([string]$Path) {
    return [IO.File]::ReadAllText($Path)
}

function Get-FileHashText([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-BlockText([string]$Text, [string]$Name) {
    $matches = [regex]::Matches($Text, '(?m)^([^\s#][^:]*):')
    $startOffset = -1
    $endOffset = $Text.Length
    foreach ($m in $matches) {
        $blockName = $m.Groups[1].Value.Trim().Trim('"').Trim("'")
        if ($blockName -ceq $Name) {
            if ($startOffset -ge 0) { throw "duplicate top-level block: $Name" }
            $startOffset = $m.Index
            continue
        }
        if ($startOffset -ge 0) {
            $endOffset = $m.Index
            break
        }
    }
    if ($startOffset -lt 0) { return $null }
    return $Text.Substring($startOffset, $endOffset - $startOffset)
}

function Get-TopLevelNames([string]$Text) {
    $names = @()
    foreach ($m in [regex]::Matches($Text, '(?m)^([^\s#][^:]*):')) {
        $names += $m.Groups[1].Value.Trim().Trim('"').Trim("'")
    }
    return $names
}

function Invoke-Generator {
    param([string[]]$Arguments)

    foreach ($a in $Arguments) {
        if ($a -match '"') { throw 'test harness does not support embedded quotes' }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $generator + '" ' +
        (($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = [IO.Path]::GetTempPath()

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()

    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
        Output   = $stdout + $stderr
    }
}

$appLines = @(
    'mixed-port: 7890',
    'allow-lan: false',
    'mode: rule',
    'log-level: warning',
    'external-controller: "127.0.0.1:9090"',
    'secret: "s3cr3t-value-should-not-be-echoed"',
    'dns:',
    '  enable: true',
    '  nameserver:',
    '    - "https://doh.pub/dns-query"',
    'tun:',
    '  enable: true',
    '  device: "FlClash"',
    '  stack: "mixed"'
)

$proxyLines = @(
    'proxies:',
    '  - name: "old-node"',
    '    type: vless',
    '    server: "198.51.100.7"',
    '    port: 443',
    '    uuid: "22222222-2222-4222-8222-222222222222"'
)

$groupLines = @(
    'proxy-groups:',
    '  - name: "PROXY"',
    '    type: select',
    '    proxies:',
    '      - "old-node"',
    '      - "DIRECT"'
)

$defaultRules = @(
    '  - "DOMAIN-SUFFIX,example.com,PROXY"',
    '  - "DOMAIN,lan,DIRECT"',
    '  - "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"',
    '  - "AND,((DST-PORT,443),(NETWORK,UDP)),REJECT"',
    '  - "MATCH,PROXY"'
)

function New-Fixture {
    param(
        [string]$Path,
        [string[]]$RuleLines = $defaultRules,
        [string]$Newline = "`n",
        [bool]$IncludeRules = $true
    )
    $lines = @()
    $lines += $appLines
    $lines += $proxyLines
    $lines += $groupLines
    if ($IncludeRules) {
        $lines += 'rules:'
        $lines += $RuleLines
    }
    Write-TextFile $Path (($lines -join $Newline) + $Newline)
}

$validArgs = @(
    '-Server', '203.0.113.10',
    '-Port', '443',
    '-UUID', '11111111-1111-4111-8111-111111111111',
    '-PublicKey', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    '-ShortId', '01234567',
    '-ServerName', 'example.com'
)

function New-GeneratorArgs {
    param([string]$Source, [string]$Output, [string[]]$Extra = @(), [switch]$OmitOutput)
    $args = @('-SourceConfig', $Source) + $validArgs
    if (-not $OmitOutput) { $args += @('-OutputPath', $Output) }
    $args += $Extra
    return $args
}

# ---------------------------------------------------------------- case 1
# Happy path: rules preserved byte-for-byte, other blocks untouched, node replaced.
$dir = New-TempDir
$source = Join-Path $dir 'flclash.yaml'
$output = Join-Path $dir 'generated.yaml'
New-Fixture -Path $source
$sourceHashBefore = Get-FileHashText $source
$sourceText = Read-TextFile $source

$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $output)

Assert-Equal '0' ([string]$result.ExitCode) 'happy path: exit code is 0'
Assert-True (Test-Path -LiteralPath $output -PathType Leaf) 'happy path: output file was written'
if (Test-Path -LiteralPath $output -PathType Leaf) {
    $generatedText = Read-TextFile $output

    Assert-Equal (Get-BlockText $sourceText 'rules') (Get-BlockText $generatedText 'rules') 'happy path: rules block is byte-identical and in original order'

    $untouched = @('mixed-port', 'allow-lan', 'mode', 'log-level', 'external-controller', 'secret', 'dns', 'tun')
    $allPreserved = $true
    foreach ($name in $untouched) {
        if ((Get-BlockText $sourceText $name) -cne (Get-BlockText $generatedText $name)) { $allPreserved = $false }
    }
    Assert-True $allPreserved 'happy path: every untouched top-level block is byte-identical'

    $sourceNames = Get-TopLevelNames $sourceText
    $generatedNames = Get-TopLevelNames $generatedText
    Assert-Equal ($sourceNames -join ',') ($generatedNames -join ',') 'happy path: top-level block names and order unchanged'

    $proxyBlock = Get-BlockText $generatedText 'proxies'
    $expectedProxyFields = @(
        'type: vless',
        'server: "203.0.113.10"',
        'port: 443',
        'uuid: "11111111-1111-4111-8111-111111111111"',
        'network: tcp',
        'tls: true',
        'udp: true',
        'flow: xtls-rprx-vision',
        'client-fingerprint: chrome',
        'servername: "example.com"',
        'reality-opts:',
        'public-key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"',
        'short-id: "01234567"'
    )
    $missing = @($expectedProxyFields | Where-Object { $proxyBlock -notmatch [regex]::Escape($_) })
    Assert-True ($missing.Count -eq 0) ('happy path: proxy block carries every required field' + $(if ($missing.Count -gt 0) { ' (missing: ' + ($missing -join '; ') + ')' } else { '' }))
    Assert-True ($proxyBlock -notmatch 'old-node') 'happy path: old proxy entry removed'
    Assert-True ($proxyBlock -match 'name: "Personal-VPS"') 'happy path: node name written'

    $groupBlock = Get-BlockText $generatedText 'proxy-groups'
    Assert-True ($groupBlock -match 'name: "PROXY"') 'happy path: PROXY group kept'
    Assert-True ($groupBlock -match '"Personal-VPS"') 'happy path: PROXY group points at new node'
    Assert-True ($groupBlock -match 'DIRECT') 'happy path: PROXY group keeps DIRECT'

    $proxiesCount = ([regex]::Matches($generatedText, '(?m)^proxies:')).Count
    $groupsCount = ([regex]::Matches($generatedText, '(?m)^proxy-groups:')).Count
    Assert-True (($proxiesCount -eq 1) -and ($groupsCount -eq 1)) 'happy path: exactly one proxies and one proxy-groups block'
    $outputBytes = [IO.File]::ReadAllBytes($output)
    $hasBom = ($outputBytes.Length -ge 3 -and $outputBytes[0] -eq 0xEF -and $outputBytes[1] -eq 0xBB -and $outputBytes[2] -eq 0xBF)
    Assert-True (-not $hasBom) 'happy path: output has no BOM'
}
Assert-Equal $sourceHashBefore (Get-FileHashText $source) 'happy path: source config untouched'
Assert-True ($result.Output -match 'mixed-port' -and $result.Output -match 'dns' -and $result.Output -match 'tun') 'happy path: copied app sections are reported'
Assert-True ($result.Output -notmatch 's3cr3t-value-should-not-be-echoed') 'happy path: secret value is never printed'
Assert-True ($result.Output -match 'WARNING') 'happy path: controller/secret reuse is flagged'
Assert-True ($result.Output -match 'device/app specific') 'happy path: app-specific tun/dns reuse is flagged'

# ---------------------------------------------------------------- case 2
# CRLF sources keep CRLF; no mixed line endings are introduced.
$dir = New-TempDir
$source = Join-Path $dir 'crlf.yaml'
$output = Join-Path $dir 'crlf-out.yaml'
New-Fixture -Path $source -Newline "`r`n"
$sourceText = Read-TextFile $source
$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $output)
Assert-Equal '0' ([string]$result.ExitCode) 'crlf: exit code is 0'
if (Test-Path -LiteralPath $output) {
    $generatedText = Read-TextFile $output
    Assert-Equal (Get-BlockText $sourceText 'rules') (Get-BlockText $generatedText 'rules') 'crlf: rules block preserved exactly'
    Assert-True (-not [regex]::IsMatch($generatedText, '(?<!\r)\n')) 'crlf: output uses CRLF only'
}

# ---------------------------------------------------------------- case 3
# Large rule set keeps exact ordering.
$dir = New-TempDir
$source = Join-Path $dir 'large.yaml'
$output = Join-Path $dir 'large-out.yaml'
$bigRules = @()
for ($i = 0; $i -lt 300; $i++) {
    $action = @('PROXY', 'DIRECT', 'REJECT')[$i % 3]
    $bigRules += ('  - "DOMAIN-SUFFIX,r{0:D4}.example.com,{1}"' -f $i, $action)
}
$bigRules += '  - "GEOIP,CN,DIRECT,no-resolve"'
$bigRules += '  - "MATCH,PROXY"'
New-Fixture -Path $source -RuleLines $bigRules
$sourceText = Read-TextFile $source
$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $output)
Assert-Equal '0' ([string]$result.ExitCode) 'large rule set: exit code is 0'
if (Test-Path -LiteralPath $output) {
    $generatedText = Read-TextFile $output
    Assert-Equal (Get-BlockText $sourceText 'rules') (Get-BlockText $generatedText 'rules') 'large rule set: 302 rules preserved exactly and in order'
    $firstRule = (Get-BlockText $generatedText 'rules') -match 'r0000\.example\.com,PROXY'
    $lastRule = (Get-BlockText $generatedText 'rules') -match 'MATCH,PROXY'
    Assert-True ($firstRule -and $lastRule) 'large rule set: first and last rules still in place'
}

# ---------------------------------------------------------------- case 4
# Fail-closed validation: every rejected input must exit non-zero and write nothing.
function Assert-Rejects {
    param(
        [string]$Name,
        [string]$RuleLinesText,
        [string[]]$ExtraArgs = @(),
        [string]$ExpectInOutput = ''
    )
    $dir = New-TempDir
    $source = Join-Path $dir 'src.yaml'
    $output = Join-Path $dir 'out.yaml'
    if ($null -ne $RuleLinesText) {
        Write-TextFile $source $RuleLinesText
    } else {
        New-Fixture -Path $source
    }
    $before = Get-FileHashText $source
    $result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $output -Extra $ExtraArgs)

    Assert-True ($result.ExitCode -ne 0) ($Name + ': rejected with non-zero exit')
    Assert-True (-not (Test-Path -LiteralPath $output)) ($Name + ': no output file written')
    Assert-Equal $before (Get-FileHashText $source) ($Name + ': source config untouched')
    if ($ExpectInOutput -ne '') {
        Assert-True ($result.Output -match [regex]::Escape($ExpectInOutput)) ($Name + ': error names the offending value')
    }
}

function Join-Lines([string[]]$Lines) { return (($Lines -join "`n") + "`n") }

$badRulesPass = $appLines + $proxyLines + $groupLines + @(
    'rules:',
    '  - "DOMAIN-SUFFIX,example.com,PROXY"',
    '  - "DOMAIN-SUFFIX,corp.example.com,PASS"',
    '  - "MATCH,PROXY"'
)
Assert-Rejects -Name 'unknown action PASS' -RuleLinesText (Join-Lines $badRulesPass) -ExpectInOutput 'PASS'

$badRulesCustomGroup = $appLines + $proxyLines + $groupLines + @(
    'rules:',
    '  - "DOMAIN-SUFFIX,example.com,PROXY"',
    '  - "DOMAIN-SUFFIX,intranet.example.com,MyGroup"',
    '  - "MATCH,PROXY"'
)
Assert-Rejects -Name 'unknown action custom group' -RuleLinesText (Join-Lines $badRulesCustomGroup) -ExpectInOutput 'MyGroup'

$badRulesRejectDrop = $appLines + $proxyLines + $groupLines + @(
    'rules:',
    '  - "DOMAIN-SUFFIX,example.com,PROXY"',
    '  - "MATCH,REJECT-DROP"'
)
Assert-Rejects -Name 'unknown action REJECT-DROP' -RuleLinesText (Join-Lines $badRulesRejectDrop) -ExpectInOutput 'REJECT-DROP'

$badRulesSubRule = $appLines + $proxyLines + $groupLines + @(
    'rules:',
    '  - "DOMAIN-SUFFIX,example.com,PROXY"',
    '  - "SUB-RULE,(NETWORK,UDP),sub1"',
    '  - "MATCH,PROXY"'
)
Assert-Rejects -Name 'SUB-RULE rejected' -RuleLinesText (Join-Lines $badRulesSubRule) -ExpectInOutput 'SUB-RULE'

$badRulesMapping = $appLines + $proxyLines + $groupLines + @(
    'rules:',
    '  - "DOMAIN-SUFFIX,example.com,PROXY"',
    '  nested-key: value',
    '  - "MATCH,PROXY"'
)
Assert-Rejects -Name 'non-list entry inside rules' -RuleLinesText (Join-Lines $badRulesMapping)

$badRulesNoProxy = $appLines + $proxyLines + $groupLines + @(
    'rules:',
    '  - "DOMAIN,lan,DIRECT"',
    '  - "MATCH,DIRECT"'
)
Assert-Rejects -Name 'no PROXY rule' -RuleLinesText (Join-Lines $badRulesNoProxy) -ExpectInOutput 'PROXY'

$badRulesEmpty = $appLines + $proxyLines + $groupLines + @('rules:')
Assert-Rejects -Name 'empty rules block' -RuleLinesText (Join-Lines $badRulesEmpty) -ExpectInOutput 'rules'

$noRulesBlock = $appLines + $proxyLines + $groupLines
Assert-Rejects -Name 'missing rules block' -RuleLinesText (Join-Lines $noRulesBlock) -ExpectInOutput 'rules'

Assert-Rejects -Name 'invalid UUID' -RuleLinesText $null -ExtraArgs @('-UUID', 'not-a-uuid') -ExpectInOutput 'UUID'
Assert-Rejects -Name 'UUID without RFC variant' -RuleLinesText $null -ExtraArgs @('-UUID', '11111111-1111-1111-1111-111111111111') -ExpectInOutput 'UUID'
Assert-Rejects -Name 'odd-length ShortId' -RuleLinesText $null -ExtraArgs @('-ShortId', 'abc') -ExpectInOutput 'ShortId'
Assert-Rejects -Name 'non-hex ShortId' -RuleLinesText $null -ExtraArgs @('-ShortId', 'zz') -ExpectInOutput 'ShortId'
Assert-Rejects -Name 'oversized ShortId' -RuleLinesText $null -ExtraArgs @('-ShortId', '00112233445566778899') -ExpectInOutput 'ShortId'
Assert-Rejects -Name 'short PublicKey' -RuleLinesText $null -ExtraArgs @('-PublicKey', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA') -ExpectInOutput 'PublicKey'
Assert-Rejects -Name 'public key with padding' -RuleLinesText $null -ExtraArgs @('-PublicKey', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=') -ExpectInOutput 'PublicKey'
Assert-Rejects -Name 'port out of range' -RuleLinesText $null -ExtraArgs @('-Port', '0') -ExpectInOutput 'Port'
Assert-Rejects -Name 'port too large' -RuleLinesText $null -ExtraArgs @('-Port', '70000') -ExpectInOutput 'Port'
Assert-Rejects -Name 'empty server name' -RuleLinesText $null -ExtraArgs @('-ServerName', '  ') -ExpectInOutput 'ServerName'
Assert-Rejects -Name 'invalid server name' -RuleLinesText $null -ExtraArgs @('-ServerName', 'bad name') -ExpectInOutput 'ServerName'
Assert-Rejects -Name 'node name collides with policy' -RuleLinesText $null -ExtraArgs @('-NodeName', 'DIRECT') -ExpectInOutput 'NodeName'

# ---------------------------------------------------------------- case 5
# Refuse to overwrite the source config.
$dir = New-TempDir
$source = Join-Path $dir 'source.yaml'
New-Fixture -Path $source
$before = Get-FileHashText $source
$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $source)
Assert-True ($result.ExitCode -ne 0) 'same source and output: rejected'
Assert-Equal $before (Get-FileHashText $source) 'same source and output: source file untouched'
Assert-True ($result.Output -match 'source\.yaml') 'same source and output: error names the path'

$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $source -Extra @('-Force'))
Assert-True ($result.ExitCode -ne 0) 'same source and output: rejected even with -Force'
Assert-Equal $before (Get-FileHashText $source) 'same source and output: source file untouched with -Force'

# ---------------------------------------------------------------- case 6
# Existing output is not overwritten unless -Force is explicit.
$dir = New-TempDir
$source = Join-Path $dir 'source.yaml'
$output = Join-Path $dir 'existing.yaml'
New-Fixture -Path $source
Write-TextFile $output 'sentinel-content'
$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $output)
Assert-True ($result.ExitCode -ne 0) 'existing output: rejected without -Force'
Assert-Equal 'sentinel-content' (Read-TextFile $output) 'existing output: previous content preserved'

$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $output -Extra @('-Force'))
Assert-Equal '0' ([string]$result.ExitCode) 'existing output: -Force allows the write'
if (Test-Path -LiteralPath $output) {
    $written = Read-TextFile $output
    Assert-True ($written -notmatch 'sentinel-content') 'existing output: -Force replaced the old content'
    Assert-True ($written -match 'server: "203\.0\.113\.10"') 'existing output: -Force wrote the new node'
}

# ---------------------------------------------------------------- case 7
# Default output path lands next to the source and is protected the same way.
$dir = New-TempDir
$source = Join-Path $dir 'default.yaml'
New-Fixture -Path $source
$defaultOutput = Join-Path $dir 'xray-personal.yaml'
$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output '' -OmitOutput)
Assert-Equal '0' ([string]$result.ExitCode) 'default output: exit code is 0'
Assert-True (Test-Path -LiteralPath $defaultOutput -PathType Leaf) 'default output: xray-personal.yaml created next to source'

$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output '' -OmitOutput)
Assert-True ($result.ExitCode -ne 0) 'default output: second run refuses to clobber the existing file'

# ---------------------------------------------------------------- case 8
# A missing output directory must fail instead of creating it silently.
$dir = New-TempDir
$source = Join-Path $dir 'source.yaml'
New-Fixture -Path $source
$missingDirOutput = Join-Path (Join-Path $dir 'nope') 'out.yaml'
$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $missingDirOutput)
Assert-True ($result.ExitCode -ne 0) 'missing output directory: rejected'
Assert-True (-not (Test-Path -LiteralPath (Split-Path -Parent $missingDirOutput))) 'missing output directory: not created silently'

# ---------------------------------------------------------------- case 9
# Rule parsing edge cases that must still be accepted and preserved.
$dir = New-TempDir
$source = Join-Path $dir 'edge.yaml'
$output = Join-Path $dir 'edge-out.yaml'
$edgeRules = @(
    '  - DOMAIN-SUFFIX,unquoted.example.com,PROXY',
    "  - 'DOMAIN,single-quoted.example.com,DIRECT'",
    '  - "IP-CIDR6,2001:db8::/32,DIRECT,no-resolve"',
    '  - "IP-CIDR,192.0.2.0/24,PROXY,no-resolve"',
    '  - "PROCESS-NAME,steam.exe,DIRECT"',
    '  - "GEOIP,CN,DIRECT,no-resolve"',
    '  - "AND,((DST-PORT,443),(NETWORK,UDP)),REJECT"',
    '  - "MATCH,PROXY"'
)
New-Fixture -Path $source -RuleLines $edgeRules
$sourceText = Read-TextFile $source
$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $output)
Assert-Equal '0' ([string]$result.ExitCode) 'rule edge cases: accepted'
if (Test-Path -LiteralPath $output) {
    $generatedText = Read-TextFile $output
    Assert-Equal (Get-BlockText $sourceText 'rules') (Get-BlockText $generatedText 'rules') 'rule edge cases: quoting and nesting preserved exactly'
}

# Rules with an inline comment marker must not confuse the action check.
$dir = New-TempDir
$source = Join-Path $dir 'src-flag.yaml'
$output = Join-Path $dir 'src-flag-out.yaml'
$srcFlagRules = @(
    '  - "IP-CIDR,198.51.100.0/24,DIRECT,src"',
    '  - "MATCH,PROXY"'
)
New-Fixture -Path $source -RuleLines $srcFlagRules
$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $output)
Assert-Equal '0' ([string]$result.ExitCode) 'src flag: trailing modifier is not treated as an action'

# ---------------------------------------------------------------- case 10
# Blank lines and comments that sit between sections survive, and duplicated
# top-level sections are rejected rather than silently merged.
$dir = New-TempDir
$source = Join-Path $dir 'spacing.yaml'
$output = Join-Path $dir 'spacing-out.yaml'
$spacingLines = @(
    'mixed-port: 7890',
    '',
    '# node list below',
    'proxies:',
    '  - name: "old-node"',
    '    type: vless',
    '',
    '# groups below',
    'proxy-groups:',
    '  - name: "PROXY"',
    '    type: select',
    '    proxies:',
    '      - "old-node"',
    '      - "DIRECT"',
    '',
    '# routing below',
    'rules:',
    '  - "DOMAIN-SUFFIX,example.com,PROXY"',
    '  - "MATCH,PROXY"'
)
Write-TextFile $source (Join-Lines $spacingLines)
$sourceText = Read-TextFile $source
$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $output)
Assert-Equal '0' ([string]$result.ExitCode) 'spacing: accepted'
if (Test-Path -LiteralPath $output) {
    $generatedText = Read-TextFile $output
    Assert-Equal (Get-BlockText $sourceText 'rules') (Get-BlockText $generatedText 'rules') 'spacing: rules still exact'
    Assert-True ($generatedText -match '# routing below') 'spacing: comment before rules survives'
    Assert-True ($generatedText -match '(?m)^# groups below\r?$') 'spacing: comment before proxy-groups survives'
    Assert-True ($generatedText -match '(?m)^# node list below\r?$') 'spacing: comment before proxies survives'
}

$dir = New-TempDir
$source = Join-Path $dir 'dupe.yaml'
$output = Join-Path $dir 'dupe-out.yaml'
$dupeLines = $appLines + $proxyLines + @(
    'proxy-groups:',
    '  - name: "PROXY"',
    '    type: select',
    '    proxies:',
    '      - "old-node"',
    'proxy-groups:',
    '  - name: "OTHER"',
    '    type: select',
    '    proxies:',
    '      - "DIRECT"',
    'rules:',
    '  - "MATCH,PROXY"'
)
Write-TextFile $source (Join-Lines $dupeLines)
$before = Get-FileHashText $source
$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $output)
Assert-True ($result.ExitCode -ne 0) 'duplicate section: rejected'
Assert-True (-not (Test-Path -LiteralPath $output)) 'duplicate section: no output written'
Assert-Equal $before (Get-FileHashText $source) 'duplicate section: source untouched'

# Missing proxies / proxy-groups sections must fail closed.
$dir = New-TempDir
$source = Join-Path $dir 'no-groups.yaml'
$output = Join-Path $dir 'no-groups-out.yaml'
Write-TextFile $source (Join-Lines ($appLines + $proxyLines + @('rules:', '  - "MATCH,PROXY"')))
$result = Invoke-Generator (New-GeneratorArgs -Source $source -Output $output)
Assert-True ($result.ExitCode -ne 0) 'missing proxy-groups: rejected'
Assert-True (-not (Test-Path -LiteralPath $output)) 'missing proxy-groups: no output written'

# ---------------------------------------------------------------- summary
Write-Output ''
Write-Output ("PASSED: " + $script:passes + "  FAILED: " + $script:failures)
if ($script:failures -gt 0) { throw ($script:failures.ToString() + ' assertions failed') }
Write-Output 'ALL PASS'
