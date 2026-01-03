@echo off
:: Delete sqlite3 DB storing cache of VSCode SSH folder

echo Starting file check and backup process...

:: Start local scope
setlocal

:: Set UTF-8 code page
chcp 65001 >nul

set homeDir=%USERPROFILE%
set targetFile=%homeDir%\AppData\Roaming\Code\User\globalStorage\state.vscdb
set backupFile=%targetFile%.bak

if exist "%targetFile%" (
    :: Create a backup
    copy "%targetFile%" "%backupFile%" >nul 2>&1
    if %errorlevel% equ 0 (
        echo Backup created: %backupFile%
    ) else (
        echo Failed to create backup.
        goto end
    )

    :: Delete the file
    del "%targetFile%" >nul 2>&1
    if %errorlevel% equ 0 (
        echo File deleted: %targetFile%
    ) else (
        echo Failed to delete file.
        exit /b
    )
) else (
    echo File not found: %targetFile%
    exit /b
)
:end

echo Done!
:: End local scope
endlocal

echo Process completed.
pause
