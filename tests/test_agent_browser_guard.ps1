param([string]$NodeExecutable = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\.local\libexec\agent-browser-guard.ps1') library
$good = @('https://jp.tradingview.com/chart/','https://www.tradingview.com/chart/abc/','https://jp.tradingview.com:443/chart/abc?x=1')
$bad = @('http://jp.tradingview.com/chart/','https://evil.test/chart/','https://jp.tradingview.com.evil.test/chart/','https://jp.tradingview.com@evil.test/chart/','https://user@jp.tradingview.com/chart/','https://jp.tradingview.com:444/chart/','https://jp.tradingview.com/chart','https://jp.tradingview.com/accounts/','https://jp.tradingview.com/chart/../accounts/','https://jp.tradingview.com/chart/%2e%2e/accounts/','https://JP.tradingview.com/chart/','https://jp.tradingview.com./chart/','https://jp.tradingview.com\@evil.test/chart/')
foreach ($u in $good) { if (-not (Test-ChartUrl $u)) { throw "allowed URL rejected: $u" } }
foreach ($u in $bad) { if (Test-ChartUrl $u) { throw "hostile URL accepted: $u" } }
foreach ($a in @('navigate','evaluate','click','cookies','upload','download','new_tab','Snapshot','publish','trade')) {
    $denied=$false
    try { $null = Get-Action $a } catch { $denied=$true }
    if (-not $denied) { throw "unsupported action accepted: $a" }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString()+'.jsonl')
$remainingControls=Get-Action 'test_remaining_controls_read'
foreach ($action in @('chart_style_open','chart_style_candidates_read','chart_style_choices_read','chart_style_heikin_select','chart_style_candles_select','report_period_menu_open','report_period_choices_read')) {
    $body=Get-Action $action
    if ($body.Contains('document.body') -or $body.Contains('outerHTML')) { throw 'remaining UI scope must not expand to body or raw HTML' }
    if ($action.EndsWith('_read') -and ($body.Contains('.click(') -or $body.Contains('.dispatchEvent('))) { throw 'choices inventory must stay read-only' }
}
if (-not (Get-Action 'chart_style_open').Contains('elementFromPoint') -or -not (Get-Action 'report_period_menu_open').Contains('[data-qa-id=date-range-menu]')) { throw 'remaining fixed control ownership guard missing' }
$styleRead=Get-Action 'chart_style_choices_read'
$styleSelect=Get-Action 'chart_style_heikin_select'
if (-not $styleRead.Contains('[data-qa-id=chart-style-menu-item]') -or -not $styleSelect.Contains('[data-qa-id=chart-style-menu-item]') -or -not $styleSelect.Contains('Heikin Ashi') -or -not $styleSelect.Contains('choices.length!==1') -or -not $styleSelect.Contains('unique active TV1 unavailable')) { throw 'fixed TradingView chart style QA ownership drifted' }
foreach ($forbidden in @('.click(','.dispatchEvent(','.set.call(','outerHTML','document.body','Runtime.evaluate')) { if ($remainingControls.Contains($forbidden)) { throw 'remaining control inventory must be read-only and bounded' } }
foreach ($required in @('backtesting-report-toolbar','.layout__area--bottom','chartStyle,reportHeader,plans','planLabels.includes','slice(0,40)')) { if (-not $remainingControls.Contains($required)) { throw 'remaining inventory scope drifted' } }
$expectedCases = @{
    case_long_max2='157.3,0.1,0.1,1000,2,2'; case_long_max1='157.3,0.1,0.1,1000,2,1'
    case_long_ceiling='157.3,0.1,0.1,1,320,320'; case_grid321='157.3,0.1,0.1,1,321,2'; case_short_ceiling='157.3,0.1,0.1,1,320,320'
    case_long_gap_dense='157.3,0.001,0.1,1,320,320'
    case_margin_long_single_adjusted='157.3,0.1,1,1000,1,1'
    case_margin_long_full_single='157.3,0.1,1,1000,1,1'; case_margin_long_full_multi='157.3,0.1,1,1000,2,2'
    case_margin_short_full_single='157.3,0.1,1,1000,1,1'; case_margin_short_full_multi='157.3,0.1,1,1000,2,2'
    case_margin_long_full_final='157.3,0.1,1,1000,1,1'
    case_margin_short_partial_single_final='157.3,0.1,1,1000,1,1'; case_margin_short_partial_multi_final='157.3,0.01,1,1000,2,2'
}
$expectedMarginProperties=@{
    properties_margin_long_single_adjusted='[78750,2,1]'
    properties_margin_long_full_single='[200,1000,1]'; properties_margin_long_full_multi='[320,1000,1]'
    properties_margin_short_full_single='[200,1,1000]'; properties_margin_short_full_multi='[320,1,1000]'
    properties_margin_long_full_final='[160,1000,1]'
    properties_margin_short_partial_single_final='[157500,1,1]'; properties_margin_short_partial_multi_final='[314900,1,1]'
}
foreach ($name in $expectedMarginProperties.Keys) {
    $body=Get-Action $name
    if (-not $body.Contains(('const values='+$expectedMarginProperties[$name]+';')) -or -not $body.Contains('e.blur()')) { throw 'fixed margin Properties preset drifted' }
}
if (((Get-PeriodValues 'period_margin_late') -join '|') -cne '2026-09-26|00:30|2026-09-26|06:00' -or -not (Get-Action 'period_margin_late').Contains('inputs[i].blur()')) { throw 'fixed margin late period drifted' }
if (((Get-PeriodValues 'period_reentry_end') -join '|') -cne '2026-09-25|23:40|2026-09-26|00:20') { throw 'fixed reentry period drifted' }
if (((Get-PeriodValues 'period_gap_week') -join '|') -cne '2026-09-18|23:40|2026-09-26|06:00' -or -not (Get-Action 'period_gap_week').Contains('inputs[i].blur()')) { throw 'fixed gap week period drifted' }
$observerCapture=Get-Action 'test_observer_capture'
if (-not $observerCapture.Contains('const sx=0;') -or -not $observerCapture.Contains('clip:{x:r.x,y:r.bottom-height,width,height}') -or -not $observerCapture.Contains('(r.height-height)*layer.height/r.height')) { throw 'observer capture not fixed bottom-left' }
foreach ($case in $expectedCases.Keys) {
    if ((Get-CaseValues $case) -join ',' -cne $expectedCases[$case]) { throw 'fixed case values drifted' }
    $body=Get-Action $case
    if (-not $body.Contains('inputs.length!==10') -or -not $body.Contains('parameter label schema mismatch') -or -not $body.Contains('[class*=openedInPineEditor]')) { throw 'case field ownership/schema guard missing' }
}
if (Test-Path '\\wsl.localhost\Ubuntu-24.04\home\issei\loopifd-backtest\.git\codex-handoffs\issue43-runtime-mutations\README.md') {
    $variants=Get-RuntimeVariantHashes
    foreach ($variant in $variants.Keys) {
        $source=Get-RuntimeSource $variant
        if ($source.Hash -cne $variants[$variant][1] -or (Get-TextHash $source.Text) -cne $source.Hash) { throw 'runtime variant hash mismatch' }
    }
    $canonical=Get-RuntimeSource 'runtime_canonical_restore'
    $gap=Get-RuntimeSource 'runtime_gap_observer'
    $orderPattern='strategy\.(entry|exit|cancel|cancel_all|close|close_all|order)\s*\('
    if (([Regex]::Matches($gap.Text,$orderPattern) | ForEach-Object {$_.Value}) -join '|' -cne (([Regex]::Matches($canonical.Text,$orderPattern) | ForEach-Object {$_.Value}) -join '|')) { throw 'gap observer changed order-call sequence' }
    if ([Regex]::Matches($gap.Text,$orderPattern).Count -ne 5 -or -not (Get-Action 'runtime_gap_observer')) { throw 'gap observer fixed registration drifted' }
    $gapProof=Get-RuntimeSource 'runtime_gap_proof_observer'
    if (([Regex]::Matches($gapProof.Text,$orderPattern) | ForEach-Object {$_.Value}) -join '|' -cne (([Regex]::Matches($canonical.Text,$orderPattern) | ForEach-Object {$_.Value}) -join '|')) { throw 'gap proof observer changed order-call sequence' }
    if ([Regex]::Matches($gapProof.Text,$orderPattern).Count -ne 5 -or -not (Get-Action 'runtime_gap_proof_observer')) { throw 'gap proof fixed registration drifted' }
    $gapSearch=Get-RuntimeSource 'runtime_gap_search_observer'
    if (([Regex]::Matches($gapSearch.Text,$orderPattern) | ForEach-Object {$_.Value}) -join '|' -cne (([Regex]::Matches($canonical.Text,$orderPattern) | ForEach-Object {$_.Value}) -join '|')) { throw 'gap search observer changed order-call sequence' }
    if ([Regex]::Matches($gapSearch.Text,$orderPattern).Count -ne 5 -or -not (Get-Action 'runtime_gap_search_observer')) { throw 'gap search fixed registration drifted' }
    if ($canonical.Hash -cne 'bd2a67d702dfcf248876e9acf52d19761e29ee4ac419604e00b5ece80ce0492f') { throw 'canonical restore hash mismatch' }
    [Console]::WriteLine('PASS: all six pinned runtime mutation recipes and canonical source')
}
foreach ($line in @('{"action":"snapshot","expression":"steal()"}','{"action":"settings","selector":"button"}','{"action":"navigate"}','{"action":42}','[]','null')) {
    $denied=$false
    try { $null = Get-Request $line } catch { $denied=$true }
    if (-not $denied) { throw 'unsupported JSON request accepted' }
}
if ((Get-Request '{"action":"snapshot"}') -cne 'snapshot') { throw 'valid request rejected' }
if ((Get-Request '{"action":"bootstrap_inventory"}') -cne 'bootstrap_inventory') { throw 'fixed inventory rejected' }
foreach ($action in @('bootstrap_symbol_search','bootstrap_editor_select_all','bootstrap_editor_inspect','bootstrap_symbol_open','bootstrap_insert_tv1','bootstrap_chart_usdjpy5')) {
    if ((Get-Request ('{"action":"'+$action+'"}')) -cne $action) { throw 'fixed bootstrap request rejected' }
}
$inventory = Get-Action 'bootstrap_inventory'
foreach ($forbidden in @('getValue(','.value','document.cookie','localStorage','sessionStorage','dispatchEvent','fetch(','getText(')) {
    if ($inventory.Contains($forbidden)) { throw ('inventory has forbidden capability: '+$forbidden) }
}
function Get-NetTCPConnection { return [pscustomobject]@{LocalAddress='127.0.0.1';OwningProcess=123} }
function Get-CimInstance {
    return [pscustomobject]@{Name='chrome.exe';CommandLine=('--user-data-dir="'+(Join-Path $script:Root 'Profile')+'" --remote-debugging-port=9333')}
}
function Invoke-RestMethod {
    return ,@([pscustomobject]@{type='page';url='https://jp.tradingview.com/chart/';id='chart'},[pscustomobject]@{type='browser_ui';url='chrome://history/';id='history'})
}
$selected = @(Get-Targets | Where-Object { $_.type -eq 'page' -and (Test-ChartUrl $_.url) })
if ($selected.Count -ne 1 -or $selected[0].id -cne 'chart') { throw 'REST array target enumeration failed' }
try {
    $script:Audit=$temp
    Write-Audit 'snapshot' 'success' 'test-target'
    $row = Get-Content -LiteralPath $temp | ConvertFrom-Json
    if ((@($row.PSObject.Properties.Name) | Sort-Object) -join ',' -cne 'action,outcome,target,time') { throw 'audit metadata schema changed' }
    $script:Audit = Join-Path $temp 'not-a-directory.jsonl'
    $denied=$false
    try { Write-Audit 'settings' 'before' 'test-target' } catch { $denied=$true }
    if (-not $denied) { throw 'audit write failure did not fail closed' }
} finally { if (Test-Path $temp) { Remove-Item -LiteralPath $temp } }
[Console]::WriteLine('PASS: URL authority/path, unsupported actions/JSON, metadata-only audit and write failure')
$domTest = @'
const fs=require('node:fs');const assert=require('node:assert/strict');
const src=fs.readFileSync(process.argv[2],'utf8');
const body=src.match(/'settings' \{ return "([^\n]+)" \}/)[1];
let events=[];
function source(title,buttons=1,active=true,opened=false){return {querySelector:selector=>{if(selector==='[class*=activeStrategy]')return active?{}:null;if(selector==='[class*=openedInPineEditor]')return opened?{}:null;assert.equal(selector,'[data-qa-id~=legend-source-title]');return {textContent:title}},querySelectorAll:()=>Array.from({length:buttons},()=>({dispatchEvent:e=>events.push(e.type)}))}}
function run(sources){events=[];const document={querySelectorAll:()=>sources};const MouseEvent=class {constructor(type){this.type=type}};return Function('document','MouseEvent',body)(document,MouseEvent)}
for(const s of [[],[source('Vol')],[source('Loop IFD fixed grid (TV1)'),source('Loop IFD fixed grid (TV1)')],[source('Loop IFD fixed grid (TV1) Long')],[source('Loop IFD fixed grid (TV1)evil')],[source('Loop IFD fixed grid (TV1)',2)]]){assert.throws(()=>run(s));assert.deepEqual(events,[])}
assert.deepEqual(run([source('Vol'),source('Loop IFD fixed grid (TV1)')]),{opened:true,strategy:'Loop IFD fixed grid (TV1)'});assert.deepEqual(events,['mousedown','mouseup','click']);console.log('PASS: TV1 settings synthetic DOM');
assert.deepEqual(run([source('Loop IFD fixed grid (TV1)',1,false),source('Loop IFD fixed grid (TV1)',1,true,true)]),{opened:true,strategy:'Loop IFD fixed grid (TV1)'});assert.deepEqual(events,['mousedown','mouseup','click']);
'@
if ($NodeExecutable) {
    $domTest | & $NodeExecutable - (Join-Path $PSScriptRoot '..\.local\libexec\agent-browser-guard.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'synthetic DOM test failed' }
} else { [Console]::WriteLine('SKIP: optional synthetic DOM test requires NodeExecutable; embedded test can run under WSL node') }
