@echo off
setlocal EnableDelayedExpansion

set LPP_REPO=yeicebear/Luapp
set LPP_DIR=%USERPROFILE%\.lpp
set LPP_BIN=%LPP_DIR%\bin
set LPP_LIB=%LPP_DIR%\lib
set LPP_TMP=%TEMP%\lpp_install_%RANDOM%

echo.
echo =================================
echo        LPP INSTALLER
echo =================================
echo installing to %LPP_DIR%
echo.

mkdir "%LPP_TMP%" 2>nul

echo detecting architecture...
if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
 set LPP_ARCH=arm64
) else (
 set LPP_ARCH=x86_64
)
echo arch: %LPP_ARCH%

winget --version >nul 2>&1
if errorlevel 1 (
 echo winget not found
 echo install "App Installer" from Microsoft Store
 goto fail
)

echo checking for gcc...

where gcc >nul 2>&1
if errorlevel 1 (

 if exist C:\msys64\mingw64\bin\gcc.exe (
  set PATH=C:\msys64\mingw64\bin;C:\msys64\usr\bin;!PATH!
 ) else (

  echo installing MSYS2...
  winget install --id MSYS2.MSYS2 -e --accept-source-agreements --accept-package-agreements
  if errorlevel 1 goto fail

  echo waiting for MSYS2...
  :waitmsys
  if not exist C:\msys64\usr\bin\bash.exe (
   timeout /t 2 >nul
   goto waitmsys
  )

  set PATH=C:\msys64\mingw64\bin;C:\msys64\usr\bin;!PATH!

  echo initializing MSYS2...
  C:\msys64\usr\bin\bash.exe -lc "pacman -Sy --noconfirm"

  echo installing gcc...
  C:\msys64\usr\bin\bash.exe -lc "pacman -S --noconfirm mingw-w64-x86_64-gcc"
 )
) else (
 echo gcc found
)

where curl >nul 2>&1
if errorlevel 1 (
 echo curl not found
 goto fail
)

set LPP_URL=https://github.com/%LPP_REPO%/releases/latest/download/lpp-windows-%LPP_ARCH%.zip

echo downloading lpp...
curl -L --fail --show-error "%LPP_URL%" -o "%LPP_TMP%\lpp.zip"
if errorlevel 1 goto fail

echo extracting...
mkdir "%LPP_TMP%\out" 2>nul
powershell -NoProfile -Command "Expand-Archive '%LPP_TMP%\lpp.zip' '%LPP_TMP%\out' -Force"
if errorlevel 1 goto fail

if not exist "%LPP_TMP%\out\lpp.exe" goto fail

echo installing files...

mkdir "%LPP_BIN%" 2>nul
mkdir "%LPP_LIB%" 2>nul

copy /Y "%LPP_TMP%\out\lpp.exe" "%LPP_BIN%" >nul
copy /Y "%LPP_TMP%\out\qbe.exe" "%LPP_BIN%" >nul
copy /Y "%LPP_TMP%\out\runtime.c" "%LPP_LIB%" >nul
copy /Y "%LPP_TMP%\out\stdlib.c" "%LPP_LIB%" >nul
copy /Y "%LPP_TMP%\out\gamelib.c" "%LPP_LIB%" >nul

for /f "tokens=2,*" %%A in ('reg query HKCU\Environment /v PATH 2^>nul') do set CURRENT_PATH=%%B

echo !CURRENT_PATH! | findstr /i "%LPP_BIN%" >nul
if errorlevel 1 (
 set NEWPATH=%LPP_BIN%;C:\msys64\mingw64\bin;C:\msys64\usr\bin;!CURRENT_PATH!
 reg add HKCU\Environment /v PATH /t REG_EXPAND_SZ /d "!NEWPATH!" /f >nul
 echo PATH updated
) else (
 echo PATH already configured
)

echo verifying install...
"%LPP_BIN%\lpp.exe" --version

rmdir /s /q "%LPP_TMP%" 2>nul

echo.
echo =================================
echo   LPP INSTALLED SUCCESSFULLY
echo =================================
echo restart terminal then run:
echo   lpp --help
echo   lpp myfile.lpp --run
echo.

goto end

:fail
echo.
echo installation failed
echo temp files at %LPP_TMP%
rmdir /s /q "%LPP_TMP%" 2>nul
exit /b 1

:end
endlocal
