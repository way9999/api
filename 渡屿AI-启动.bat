@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions EnableDelayedExpansion
title DuYu AI - Launch

echo.
echo   ========================================
echo        DuYu AI Gateway
echo        One-Click Launch + Tunnel
echo   ========================================
echo.

cd /d "%~dp0"

set "GATEWAY_HOST=127.0.0.1"
set "GATEWAY_PORT=3080"
set "API_PORT=3000"
set "DASHBOARD_PORT=9005"
set "PYTHON_CMD=python"
set "TUNNEL_TARGET=http://%GATEWAY_HOST%:%GATEWAY_PORT%"
set "GATEWAY_PID_FILE=%TEMP%\duyu_chat_gateway.pid"
set "GATEWAY_LOG=%TEMP%\duyu_chat_gateway.log"
set "MAX_WAIT=60"

echo [1/5] Starting base services (mysql, redis, new-api)...
docker compose -f docker-compose.yml up -d mysql redis new-api 2>nul
if errorlevel 1 (
    echo       [!] Failed to start base services
    pause
    exit /b 1
)

echo [2/5] Starting reverse services...
docker compose -f docker-compose.reverse.yml up -d resin 2>nul
REM Wait a moment for resin to be ready (other services depend on it)
timeout /t 3 /nobreak >nul
docker compose -f docker-compose.reverse.yml up -d codex-proxy gpt-register gpt-manager cliproxyapi 2>nul

echo [3/5] Waiting for services...

REM --- Wait for New API ---
set /a RETRY=0
:wait_api
curl -s http://localhost:%API_PORT%/api/status >nul 2>&1
if not errorlevel 1 (
    echo       [OK] New API ready
    goto api_ok
)
set /a RETRY+=1
if !RETRY! GEQ %MAX_WAIT% (
    echo       [!] New API not ready after %MAX_WAIT%s, continuing anyway...
    goto api_ok
)
timeout /t 1 /nobreak >nul
goto wait_api
:api_ok

REM --- Wait for Dashboard ---
set /a RETRY=0
:wait_dash
curl -s http://localhost:%DASHBOARD_PORT%/api/status >nul 2>&1
if not errorlevel 1 (
    echo       [OK] Dashboard ready
    goto dash_ok
)
set /a RETRY+=1
if !RETRY! GEQ %MAX_WAIT% (
    echo       [!] Dashboard not ready after %MAX_WAIT%s, continuing anyway...
    goto dash_ok
)
timeout /t 1 /nobreak >nul
goto wait_dash
:dash_ok

REM --- Wait for Codex Proxy ---
set /a RETRY=0
:wait_codex
curl -s http://localhost:9006/__codex_proxy_health >nul 2>&1
if not errorlevel 1 (
    echo       [OK] Codex Proxy ready
    goto codex_ok
)
set /a RETRY+=1
if !RETRY! GEQ 30 (
    echo       [!] Codex Proxy not ready after 30s, continuing anyway...
    goto codex_ok
)
timeout /t 1 /nobreak >nul
goto wait_codex
:codex_ok

REM --- Show status of all reverse services ---
echo.
echo       Service status:
for %%S in (resin codex-proxy gpt-register gpt-manager cliproxyapi) do (
    for /f "tokens=*" %%R in ('docker ps --filter "name=%%S" --format "{{.Status}}" 2^>nul') do (
        echo         %%S: %%R
    )
)
echo.

echo [4/5] Starting local chat gateway...
taskkill /fi "WINDOWTITLE eq DuYu Chat Gateway" /f >nul 2>&1
del "%GATEWAY_PID_FILE%" >nul 2>&1
del "%GATEWAY_LOG%" >nul 2>&1
start "DuYu Chat Gateway" /b cmd /c "%PYTHON_CMD% scripts\chat_gateway.py --host %GATEWAY_HOST% --port %GATEWAY_PORT% --backend-host 127.0.0.1 --backend-port %API_PORT% 1>"%GATEWAY_LOG%" 2>&1"

set /a GATEWAY_RETRY=0
:wait_gateway
curl -s http://%GATEWAY_HOST%:%GATEWAY_PORT%/__chat_gateway_health >nul 2>&1
if not errorlevel 1 goto gateway_ok
set /a GATEWAY_RETRY+=1
if !GATEWAY_RETRY! GEQ 20 goto gateway_fail
timeout /t 1 /nobreak >nul
goto wait_gateway

:gateway_ok
echo       [OK] Chat gateway ready!  http://%GATEWAY_HOST%:%GATEWAY_PORT%

echo.
echo   [5/5] Select tunnel mode:
echo.
echo     1 - Cloudflare Tunnel  (free, random domain)
echo     2 - ngrok              (stable, ~7s latency)
echo     3 - No tunnel          (localhost only)
echo.
choice /c 123 /n /m "   Enter choice (1/2/3): "
set TUNNEL_MODE=%errorlevel%

set "TUNNEL_URL="

if %TUNNEL_MODE%==1 goto tunnel_cf
if %TUNNEL_MODE%==2 goto tunnel_ngrok
if %TUNNEL_MODE%==3 goto no_tunnel
goto no_tunnel

:gateway_fail
echo       [!] Chat gateway failed to start.
if exist "%GATEWAY_LOG%" (
    echo.
    echo       ---- gateway log ----
    type "%GATEWAY_LOG%"
    echo       ---------------------
)
pause
exit /b 1

:tunnel_cf
echo       Starting Cloudflare Tunnel -> %TUNNEL_TARGET%
del "%TEMP%\cf.log" >nul 2>&1
start /b cmd /c "cloudflared tunnel --url %TUNNEL_TARGET% 1>"%TEMP%\cf.log" 2>&1"
echo       Waiting for tunnel URL...
set /a RETRY=0
:wait_cf
if %RETRY% GEQ 30 goto show_result
timeout /t 1 /nobreak >nul
set /a RETRY+=1
for /f "delims=" %%U in ('findstr /r "https://.*trycloudflare.com" "%TEMP%\cf.log" 2^>nul') do (
    for %%W in (%%U) do (
        echo %%W | findstr "https://.*trycloudflare.com" >nul 2>&1 && set "TUNNEL_URL=%%W"
    )
)
if not defined TUNNEL_URL goto wait_cf
goto show_result

:tunnel_ngrok
echo       Starting ngrok -> %TUNNEL_TARGET%
del "%TEMP%\ngrok.log" >nul 2>&1
start /b cmd /c "ngrok http %GATEWAY_PORT% --log "%TEMP%\ngrok.log" --log-format json >nul 2>&1"
echo       Waiting for tunnel URL...
set /a RETRY=0
:wait_ngrok
if %RETRY% GEQ 20 goto show_result
timeout /t 1 /nobreak >nul
set /a RETRY+=1
for /f "delims=" %%U in ('curl -s http://127.0.0.1:4040/api/tunnels 2^>nul ^| python -c "import sys,json; d=json.load(sys.stdin); print(d['tunnels'][0]['public_url'])" 2^>nul') do (
    set "TUNNEL_URL=%%U"
)
if not defined TUNNEL_URL goto wait_ngrok
goto show_result

:no_tunnel
goto show_result

:show_result
start http://%GATEWAY_HOST%:%GATEWAY_PORT%

cls
echo.
echo   ========================================
echo        DuYu AI Gateway Started
echo   ========================================
echo.
echo   Local:
echo     Chat UI:    http://%GATEWAY_HOST%:%GATEWAY_PORT%/chat/
echo     Home:       http://%GATEWAY_HOST%:%GATEWAY_PORT%/
echo     Dashboard:  http://localhost:%DASHBOARD_PORT%
echo     API:        http://localhost:%API_PORT%
echo.
if defined TUNNEL_URL (
    echo   ----------------------------------------
    echo   Public URL:
    echo.
    echo     %TUNNEL_URL%
    echo.
    echo   ----------------------------------------
    echo.
    echo   Usage for others:
    echo     Home:      %TUNNEL_URL%/
    echo     Chat UI:   %TUNNEL_URL%/chat/
    echo     API Base:  %TUNNEL_URL%/v1
    echo     API Key:   Create token after logging in
) else (
    if %TUNNEL_MODE%==3 (
        echo   Running in local mode, no tunnel.
    ) else (
        echo   [!] Tunnel URL not detected.
        echo       Try running manually.
    )
)
echo.
echo   ========================================
echo   Press any key to stop and exit...
pause >nul

taskkill /fi "WINDOWTITLE eq DuYu Chat Gateway" /f >nul 2>&1
del "%GATEWAY_PID_FILE%" >nul 2>&1
taskkill /f /im ngrok.exe >nul 2>&1
taskkill /f /im cloudflared.exe >nul 2>&1
del "%TEMP%\ngrok.log" >nul 2>&1
del "%TEMP%\cf.log" >nul 2>&1
