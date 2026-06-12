@echo off
REM build_odocrypt_lib.bat - build odocrypt.dll (Windows/MSVC) from the repo's
REM upstream OdoCrypt sources, so lib\odo_node.py can validate shares natively.
REM Windows counterpart of build_odocrypt_lib.sh. Run from a normal cmd prompt;
REM it sets up the MSVC environment itself.
REM Output: tools\testnet\odocrypt.dll
setlocal
cd /d "%~dp0"

set "CRYPTO=..\..\upstream\odo-miner\src\crypto"
if not exist "%CRYPTO%\odocrypt.cpp" (
    echo upstream submodule missing - run: git submodule update --init
    exit /b 1
)

REM Locate Visual Studio via vswhere, fall back to the known install path.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VCVARS="
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSINSTALL=%%i"
)
if defined VSINSTALL set "VCVARS=%VSINSTALL%\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" set "VCVARS=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
    echo vcvars64.bat not found - is the C++ workload installed?
    exit /b 1
)

call "%VCVARS%" >nul
echo Building odocrypt.dll with MSVC ...
cl /nologo /O2 /EHsc /std:c++17 /I "%CRYPTO%" /LD ^
   odocrypt_wrapper.cpp "%CRYPTO%\odocrypt.cpp" "%CRYPTO%\KeccakP-800-reference.c" ^
   /Fe:odocrypt.dll
if errorlevel 1 (
    echo BUILD FAILED
    exit /b 1
)
del /q *.obj 2>nul
echo built: %cd%\odocrypt.dll
