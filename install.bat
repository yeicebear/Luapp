@echo off
setlocal EnableDelayedExpansion

:: lpp installer for Windows
:: uses winget to grab MSYS2/MinGW (gcc) and downloads lpp + QBE for Windows.
:: installs everything to %USERPROFILE%\.lpp\
:: adds it to your PATH permanently (current user only, no admin needed).
::
:: winget might pop a UAC prompt when installing MSYS2. that's normal, just click yes.
:: curl ships with Windows 10 1803+. you almost certainly have it. BUT STILL, reject windoop.

set LPP_REPO=yeicebear/Luapp
set LPP_DIR=%USERPROFILE%\.lpp
set LPP_BIN=%LPP_DIR%\bin
set LPP_LIB=%LPP_DIR%\lib
set LPP_TMP=%TEMP%\lpp_install_%RANDOM%

echo.
echo  lpp installer for Windows
echo  installing to %LPP_DIR%
echo.

mkdir "%LPP_TMP%" 2>nul

:: winget ships with Windows 11 and updated Windows 10.
:: if you don't have it, go get "App Installer" from the Microsoft Store.

where winget >nul 2>&1
if errorlevel 1 (
    echo  winget not found.
    echo  go to the Microsoft Store, search "App Installer", install it, then run this again.
    goto :fail
)


echo  checking for gcc...
where gcc >nul 2>&1
if errorlevel 1 (
    echo  gcc not found, installing MSYS2 + MinGW via winget...
    echo  this might ask for UAC. just say yes.
    winget install --id MSYS2.MSYS2 -e --accept-source-agreements --accept-package-agreements
    if errorlevel 1 (
        echo.
        echo  MSYS2 install failed. try it manually:
        echo    winget install MSYS2.MSYS2
        echo  then run this script again.
        goto :fail
    )
    set "PATH=C:\msys64\mingw64\bin;C:\msys64\usr\bin;!PATH!"
    echo  installing gcc toolchain inside MSYS2...
    C:\msys64\usr\bin\bash.exe -lc "pacman -S --noconfirm mingw-w64-x86_64-gcc"
    echo  done. if gcc is still missing after this script, restart your terminal.
) else (
    echo  gcc found, nice.
)


where curl >nul 2>&1
if errorlevel 1 (
    echo  curl not found. you need at least Windows 10 1803.
    goto :fail
)

:: grabs lpp-windows-x86_64.zip from the latest GitHub release.
:: the zip should contain: lpp.exe, qbe.exe, runtime.c, stdlib.c, gamelib.c

echo  downloading lpp...
set LPP_URL=https://github.com/%LPP_REPO%/releases/latest/download/lpp-windows-x86_64.zip

curl -fsSL "%LPP_URL%" -o "%LPP_TMP%\lpp.zip"
if errorlevel 1 (
    echo.
    echo  download failed. check your internet, or grab it manually at:
    echo    %LPP_URL%
    goto :fail
)

:: Expand-Archive is available on all modern Windows without any extra installs.

echo  unzipping...
powershell -NoProfile -Command "Expand-Archive -Path '%LPP_TMP%\lpp.zip' -DestinationPath '%LPP_TMP%\out' -Force"
if errorlevel 1 (
    echo  unzip failed. the zip might be corrupted, try downloading again.
    goto :fail
)


echo  installing files to %LPP_DIR%...
mkdir "%LPP_BIN%" 2>nul
mkdir "%LPP_LIB%" 2>nul

copy /Y "%LPP_TMP%\out\lpp.exe"     "%LPP_BIN%\lpp.exe"    >nul
copy /Y "%LPP_TMP%\out\qbe.exe"     "%LPP_BIN%\qbe.exe"    >nul
copy /Y "%LPP_TMP%\out\runtime.c"   "%LPP_LIB%\runtime.c"  >nul
copy /Y "%LPP_TMP%\out\stdlib.c"    "%LPP_LIB%\stdlib.c"   >nul
copy /Y "%LPP_TMP%\out\gamelib.c"   "%LPP_LIB%\gamelib.c"  >nul

if errorlevel 1 (
    echo  file copy failed. the zip is probably missing something.
    goto :fail
)

:: writes to HKCU\Environment so it persists for the current user.
:: no admin needed. takes effect in new terminal windows.

echo  adding to PATH...

for /f "tokens=2,*" %%A in ('reg query "HKCU\Environment" /v PATH 2^>nul') do set "CURRENT_PATH=%%B"

echo !CURRENT_PATH! | findstr /i /c:"%LPP_BIN%" >nul
if errorlevel 1 (
    setx PATH "%LPP_BIN%;C:\msys64\mingw64\bin;C:\msys64\usr\bin;!CURRENT_PATH!" >nul
    echo  added %LPP_BIN% and MinGW to PATH.
) else (
    echo  already in PATH, skipping.
)


echo.
echo  checking lpp works...
"%LPP_BIN%\lpp.exe" --version
if errorlevel 1 (
    echo  lpp ran but something looked wrong. try running it yourself after restarting your terminal.
)


rmdir /s /q "%LPP_TMP%" 2>nul

echo.
echo  =========================================
echo   lpp installed successfully!
echo  =========================================
echo.
echo  restart your terminal so PATH kicks in, then:
echo    lpp --help
echo    lpp myfile.lpp --run
echo.
echo  if gcc isn't found, you may need to open MSYS2 MinGW terminal once
echo  to let it finish setting up, or add C:\msys64\mingw64\bin to PATH manually.
echo.
goto :end

:fail
echo.
echo  install failed. temp files might be at: %LPP_TMP%
rmdir /s /q "%LPP_TMP%" 2>nul
exit /b 1

:end
endlocal