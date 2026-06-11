@echo off
REM ===========================================================================
REM  start_fpga_miner.bat - OdoCrypt FPGA miner test bed (Windows)
REM
REM  Brings up a DigiByte node + the solo Stratum bridge and leaves them
REM  running, ready for the FPGA miner to connect on 127.0.0.1:3333.
REM
REM  Thin wrapper around run_testbed.py (all logic lives there, shared with
REM  the Linux demo). Replaces the older launcher that mined only 100 blocks
REM  and used a non-working server.py.
REM
REM  Usage:  start_fpga_miner.bat [1|2]      1=regtest (default), 2=testnet
REM ===========================================================================
setlocal
title OdoCrypt FPGA Miner Test Bed

REM ---- edit these paths if your layout differs ----
set "PYTHON=C:\Users\builder\AppData\Local\Python\pythoncore-3.14-64\python.exe"
set "DGB_BIN=C:\digibyte\bin"
set "ODOCRYPT_LIB=C:\digibyte\odocrypt.dll"
set "HARNESS=%~dp0"

set "MODE=%~1"
if not defined MODE (
    echo 1^) REGTEST  ^(local, instant blocks^)
    echo 2^) TESTNET  ^(public DigiByte testnet^)
    set /p MODE=Select mode [1]:
)
if "%MODE%"=="2" ( set "NET=testnet" ) else ( set "NET=regtest" )

"%PYTHON%" "%HARNESS%run_testbed.py" --net %NET% --dgb-bin "%DGB_BIN%" --odocrypt-lib "%ODOCRYPT_LIB%"

endlocal
