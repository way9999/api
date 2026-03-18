@echo off
chcp 65001 >nul 2>&1
title GPT Team Manager

echo ========================================
echo   GPT Team Manager - 一键启动
echo ========================================
echo.

cd /d "%~dp0"

echo [1/3] 启动服务...
docker compose -f docker-compose.yml up -d mysql redis new-api 2>nul
timeout /t 5 /nobreak >nul
docker compose -f docker-compose.reverse.yml up -d gpt-register resin 2>nul
timeout /t 3 /nobreak >nul

echo [2/3] 等待服务就绪...
:wait_loop
curl -s http://localhost:9005/api/status >nul 2>&1
if errorlevel 1 (
    timeout /t 2 /nobreak >nul
    goto wait_loop
)
echo       Dashboard 已就绪!

echo [3/3] 打开浏览器...
start http://localhost:9005

echo.
echo ========================================
echo   Dashboard: http://localhost:9005
echo   New API:   http://localhost:3000
echo ========================================
echo.
echo   使用方法:
echo   1. 在 Token 提取 区域输入邮箱
echo   2. 点击 发送验证码
echo   3. 去邮箱查看验证码并填入
echo   4. 点击 提取 Token
echo   5. 点击 添加到 new-api 渠道
echo   6. 立即可用!
echo.
echo   按任意键关闭此窗口...
pause >nul
