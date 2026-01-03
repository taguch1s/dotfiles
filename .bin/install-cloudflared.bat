@echo off
:: Delete sqlite3 DB storing cache of VSCode SSH folder

echo Starting setting cloudflared process...

:: Start local scope
setlocal
:: Set UTF-8 code page
chcp 65001 >nul

:: Set environment variables
set home_dir=%USERPROFILE%
set aria2_url=https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip
set cloudflare_url=https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe
set filename=aria2.zip
set dest_dir=aria2

:: Check if exists
if exist "%home_dir%\.ssh\cloudflared.exe" (
    echo Already exists: "%home_dir%\.ssh\cloudflared.exe"
    pause
    exit /b
) else (
    echo OK, File not found: %dest_dir%
)

echo Downloading aria2 ...
curl -L -o %filename% %aria2_url%

echo Unzipping %filename%...
powershell -command "Expand-Archive -Path '%filename%' -DestinationPath '%dest_dir%'"

:: Delete the file
del "%filename%" >nul 2>&1
if %errorlevel% equ 0 (
    echo File deleted: %filename%
) else (
    echo Failed to delete file.
    exit /b
)

:: Move the file
for /r "%dest_dir%" %%f in (aria2c.exe) do (
    copy "%%f" "%dest_dir%\aria2c.exe" >nul 2>&1
)
if %errorlevel% equ 0 (
    echo File moved: %dest_dir%\aria2c.exe
) else (
    echo Failed to move file.
    exit /b
)

:: exe aria2c.exe
%dest_dir%\aria2c.exe -d %home_dir%\.ssh -x 16 -s 16 -k 1M -o cloudflared.exe %cloudflare_url%
if %errorlevel% equ 0 (
    echo Successed download
) else (
    echo Failed to download.
    exit /b
)

:: Delete the folder
rmdir /S /Q "%dest_dir%"
if %errorlevel% equ 0 (
    echo File deleted: %dest_dir%
) else (
    echo Failed to delete file.
    exit /b
)
echo Done!

:: End local scope
endlocal

echo Process completed.
pause