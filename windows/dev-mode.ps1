<#
.SYNOPSIS
開発モードと通常モードを切り替える。

.DESCRIPTION
Dev    : 常駐アプリを終了し、WSL のファイルキャッシュを破棄してから VS Code を起動する。
Normal : Dev で終了した常駐アプリを、スタートメニューの登録から起動し直す。
Install: このスクリプトを指す「Dev Mode」「Normal Mode」ショートカットをスタートメニューへ作る。

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File dev-mode.ps1 -Mode Dev -Path /home/issei/dotfiles
#>
param(
    [ValidateSet('Dev', 'Normal', 'Install')]
    [string]$Mode = 'Dev',
    # Dev で開く WSL 内のパス。省略時は VS Code が前回のウィンドウを復元する。
    [string]$Path
)

$ErrorActionPreference = 'Stop'

# 開発中に WSL へメモリを回すため終了するアプリ。
# Process は終了するプロセス名、StartName は再起動に使う Get-StartApps の表示名。
$apps = @(
    @{ Process = @('Discord'); StartName = 'Discord' },
    @{ Process = @('Notion'); StartName = 'Notion' },
    @{ Process = @('ChatGPT'); StartName = 'ChatGPT' },
    @{ Process = @('lghub', 'lghub_agent', 'lghub_system_tray'); StartName = 'Logitech G HUB' }
)

function Get-DefaultDistro {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $id = (Get-ItemProperty $lxss).DefaultDistribution
    (Get-ItemProperty (Join-Path $lxss $id)).DistributionName
}

function Stop-ResidentApps {
    foreach ($app in $apps) {
        $running = Get-Process -Name $app.Process -ErrorAction SilentlyContinue
        if (-not $running) { continue }
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "終了: $($app.StartName)"
    }
}

function Start-ResidentApps {
    $startApps = Get-StartApps
    foreach ($app in $apps) {
        if (Get-Process -Name $app.Process -ErrorAction SilentlyContinue) { continue }
        $entry = $startApps | Where-Object Name -eq $app.StartName | Select-Object -First 1
        if (-not $entry) {
            Write-Warning "スタートメニューに見つかりません: $($app.StartName)"
            continue
        }
        Start-Process "shell:AppsFolder\$($entry.AppID)"
        Write-Host "起動: $($app.StartName)"
    }
}

function Clear-WslPageCache {
    # dropCache の自動返却はアイドル待ちになるため、開発開始時に明示的に返却する。
    & wsl.exe -u root -e sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
    Write-Host 'WSL のファイルキャッシュを破棄しました。'
}

function Install-Shortcuts {
    $programs = [Environment]::GetFolderPath('Programs')
    $shell = New-Object -ComObject WScript.Shell
    foreach ($name in 'Dev', 'Normal') {
        $lnkPath = Join-Path $programs "$name Mode.lnk"
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = (Get-Command powershell.exe).Source
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $name"
        $lnk.WorkingDirectory = $env:USERPROFILE
        $lnk.Save()
        Write-Host "作成: $lnkPath"
    }
}

switch ($Mode) {
    'Dev' {
        Stop-ResidentApps
        Clear-WslPageCache
        if ($Path) {
            & code --remote "wsl+$(Get-DefaultDistro)" $Path
        } else {
            & code
        }
    }
    'Normal' { Start-ResidentApps }
    'Install' { Install-Shortcuts }
}
