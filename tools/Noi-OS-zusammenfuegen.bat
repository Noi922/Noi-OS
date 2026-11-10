@echo off
rem Noi OS: fuegt heruntergeladene Teile (.part00, .part01, ...) wieder zusammen.
rem Einfach in den Ordner mit den Teilen legen und doppelklicken.
chcp 65001 >nul
cd /d "%~dp0"
setlocal enabledelayedexpansion
echo.
echo  ==============================================
echo     Noi OS - Dateien zusammenfuegen
echo  ==============================================
echo.
set FOUND=0
for %%P in (*.part00) do (
    set FOUND=1
    set "ZIEL=%%~nP"
    if not exist "!ZIEL!.part01" (
        echo  [!] Fuer !ZIEL! fehlt noch die Datei .part01 - bitte auch herunterladen.
    ) else (
        echo  Erzeuge !ZIEL! ...
        copy /b /y "!ZIEL!.part*" "!ZIEL!" >nul
        if errorlevel 1 (
            echo  [!] Fehler beim Zusammenfuegen von !ZIEL!
        ) else (
            echo  [OK] !ZIEL! ist fertig.
        )
    )
    echo.
)
if "%FOUND%"=="0" (
    echo  Keine Teile gefunden.
    echo  Lege diese Datei in denselben Ordner wie die .part00- und .part01-Dateien.
    echo.
)
echo  Die .part-Dateien kannst du danach loeschen.
echo.
pause
