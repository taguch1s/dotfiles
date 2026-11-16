<#
.SYNOPSIS
WSL の dev ディストリで Claude が作業中・SSH 接続中の間だけ Windows のアイドルスリープを止める。

.DESCRIPTION
dev ディストリは interop 無効のため、WSL 側の awake-keeper は判定結果を ~/.cache/awake/state に書くだけ。
このスクリプトは Windows 側で常駐し、state が新しく (StaleSeconds 以内) かつ中身が空でない間
SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) を保持する。それ以外は解除し、通常どおりスリープさせる。
dev が停止中は \\wsl.localhost に触れない (触るとディストリが起動してしまうため)。

Run      : 常駐ループ (スタートアップから -WindowStyle Hidden で起動される)
Install  : %LOCALAPPDATA%\awake-watcher にコピーし、スタートアップにショートカットを作って起動する
Uninstall: ショートカットを消し、常駐プロセスを止める
Status   : 現在の判定を表示する

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File \\wsl.localhost\dev\home\issei\dotfiles-main\windows\awake-watcher.ps1 -Mode Install
#>
param(
    [ValidateSet('Run', 'Install', 'Uninstall', 'Status')]
    [string]$Mode = 'Run',
    [string]$Distro = 'dev',
    [string]$User = 'issei',
    [int]$IntervalSeconds = 30,
    [int]$StaleSeconds = 180
)

$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'awake-watcher'
$installedScript = Join-Path $installDir 'awake-watcher.ps1'
$logFile = Join-Path $installDir 'awake-watcher.log'
$shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Awake-Watcher.lnk'
$stateFile = "\\wsl.localhost\$Distro\home\$User\.cache\awake\state"

function Get-AwakeReason {
    $env:WSL_UTF8 = '1'
    $running = & wsl.exe --list --running --quiet 2>$null
    if (-not ($running | Where-Object { $_.Trim() -eq $Distro })) { return '' }
    try {
        $item = Get-Item -LiteralPath $stateFile
        if (((Get-Date) - $item.LastWriteTime).TotalSeconds -gt $StaleSeconds) { return '' }
        return ([IO.File]::ReadAllText($stateFile)).Trim()
    } catch {
        return ''
    }
}

function Write-Log([string]$message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $message
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) { Move-Item $logFile "$logFile.old" -Force }
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    } catch {}
}

switch ($Mode) {
    'Status' {
        $reason = Get-AwakeReason
        if ($reason) { "抑止中: $reason" } else { 'idle (スリープ可)' }
        $proc = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -like '*awake-watcher.ps1*-Mode Run*' }
        if ($proc) { "watcher 常駐中 (PID $($proc.ProcessId -join ', '))" } else { 'watcher は動いていません' }
        if (Test-Path $logFile) { Get-Content $logFile -Tail 5 }
    }
    'Install' {
        New-Item -ItemType Directory -Force $installDir | Out-Null
        Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript -Force
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($shortcut)
        $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installedScript`" -Mode Run"
        $lnk.WindowStyle = 7  # 最小化
        $lnk.Save()
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -like '*awake-watcher.ps1*-Mode Run*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Start-Process -FilePath $lnk.TargetPath -ArgumentList $lnk.Arguments -WindowStyle Hidden
        "インストールしました: $installedScript"
        "スタートアップ: $shortcut"
    }
    'Uninstall' {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -like '*awake-watcher.ps1*-Mode Run*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Remove-Item -LiteralPath $shortcut -ErrorAction SilentlyContinue
        'アンインストールしました'
    }
    'Run' {
        Add-Type -Namespace Awake -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
'@
        $ES_CONTINUOUS = [uint32]'0x80000000'
        $ES_SYSTEM_REQUIRED = [uint32]'0x00000001'
        # ES_CONTINUOUS の状態はスレッド単位で保持されるため、同じスレッドで呼び続ける
        $prev = $null
        Write-Log 'start'
        try {
            while ($true) {
                $reason = Get-AwakeReason
                if ($reason) {
                    [void][Awake.Native]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
                } else {
                    [void][Awake.Native]::SetThreadExecutionState($ES_CONTINUOUS)
                }
                if ($reason -ne $prev) {
                    Write-Log ("state: {0}" -f $(if ($reason) { $reason } else { 'idle' }))
                    $prev = $reason
                }
                Start-Sleep -Seconds $IntervalSeconds
            }
        } finally {
            [void][Awake.Native]::SetThreadExecutionState($ES_CONTINUOUS)
            Write-Log 'stop'
        }
    }
}
