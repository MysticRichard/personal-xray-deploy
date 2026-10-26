$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path $env:TEMP ('xray-render-' + [guid]::NewGuid().ToString() + '.json')
$bash = 'C:\Program Files\Git\bin\bash.exe'
$env:SERVER_ADDRESS = '203.0.113.10'
$env:LISTEN_PORT = '18444'
$env:PUBLIC_PORT = '28443'
$env:REALITY_DEST = 'example.com:443'
$env:REALITY_SERVER_NAME = 'example.com'
$env:CLIENT_UUID = '11111111-1111-4111-8111-111111111111'
$env:PRIVATE_KEY = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
$env:PUBLIC_KEY = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
$env:SHORT_ID = '0123456789abcdef'
try {
    & $bash (Join-Path $root 'install-xray.sh') --render ($temp.Replace('\','/'))
    if ($LASTEXITCODE -ne 0) { throw 'Real script rendering failed' }
    $c = Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json
    if ($c.inbounds.Count -ne 1) { throw 'Unauthenticated extra listeners' }
    if ($c.inbounds[0].port -ne 18444) { throw 'Wrong internal listen port' }
    if ($c.routing.domainStrategy -ne 'IPOnDemand') { throw 'IP rules bypass domain targets' }
    if ('geoip:private' -notin $c.routing.rules[0].ip) { throw 'Private IP protection missing' }
    if ($c.inbounds[0].streamSettings.realitySettings.shortIds.Count -ne 1) { throw 'Unneeded extra short IDs' }
    if ($c.inbounds[0].streamSettings.network -ne 'tcp') { throw 'Server transport is not the tested FlClash combination' }
    Write-Output 'PASS: actual install script renders one authenticated listener with internal NAT port and IP rules'
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    'SERVER_ADDRESS','LISTEN_PORT','PUBLIC_PORT','REALITY_DEST','REALITY_SERVER_NAME','CLIENT_UUID','PRIVATE_KEY','PUBLIC_KEY','SHORT_ID' | ForEach-Object {
        Remove-Item "env:$_" -ErrorAction SilentlyContinue
    }
}
