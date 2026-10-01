@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
chcp 866 >nul
title DNS Switcher

rem === Проверка прав администратора ===
fltmc >nul 2>&1
if errorlevel 1 (
    echo Требуются права администратора. Перезапуск с повышением прав...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "BACKUP=dns_backup.txt"
set "ADAPTERFILE=adapter.txt"
set "PROFDIR=profiles"

rem === Загрузка сохранённого индекса адаптера ===
set "IFINDEX="
if exist "%ADAPTERFILE%" (
    for /f "usebackq delims=" %%A in ("%ADAPTERFILE%") do if not defined IFINDEX set "IFINDEX=%%A"
)

rem === Проверка, существует ли сохранённый индекс ===
if defined IFINDEX (
    powershell -NoProfile -Command "if (Get-NetAdapter -InterfaceIndex %IFINDEX% -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
    if errorlevel 1 set "IFINDEX="
)

rem === Автоопределение адаптера (по шлюзу, иначе первый активный) ===
if not defined IFINDEX (
    powershell -NoProfile -Command "$c=Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1; if($c){$c.InterfaceIndex}else{$a=Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1; if($a){$a.InterfaceIndex}else{(Get-NetAdapter | Select-Object -First 1).InterfaceIndex}}" > "%TEMP%\ifidx.tmp"
    for /f "usebackq delims=" %%A in ("%TEMP%\ifidx.tmp") do if not defined IFINDEX set "IFINDEX=%%A"
    del "%TEMP%\ifidx.tmp" 2>nul
    if not defined IFINDEX set "IFINDEX=1"
    echo(!IFINDEX!> "%ADAPTERFILE%"
)

rem === Команда применения DNS (значения через переменные окружения) ===
set "APPLY_CMD=$idx=[int]$env:IFINDEX; $d1=$env:DNS1; $d2=$env:DNS2; $doh=$env:DOH; try { if ($d1) { $s=@($d1); if ($d2) { $s+=$d2 }; Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $s -ErrorAction Stop } else { Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -ErrorAction Stop }; $all=Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue; if ($all) { foreach ($a in $all) { Remove-DnsClientDohServerAddress -ServerAddress $a.ServerAddress -ErrorAction SilentlyContinue } }; if ($doh -and $d1) { Add-DnsClientDohServerAddress -ServerAddress $d1 -DohTemplate $doh -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction SilentlyContinue; if ($d2) { Add-DnsClientDohServerAddress -ServerAddress $d2 -DohTemplate $doh -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction SilentlyContinue } }; Clear-DnsClientCache -ErrorAction SilentlyContinue; Write-Host 'DONE' } catch { Write-Host 'ERROR:'; Write-Host $_.Exception.Message }"

:menu
rem === Имя адаптера для отображения ===
set "IFLABEL="
powershell -NoProfile -Command "if(Get-NetAdapter -InterfaceIndex %IFINDEX% -ErrorAction SilentlyContinue){(Get-NetAdapter -InterfaceIndex %IFINDEX%).Name | Out-File -FilePath '%TEMP%\ifname.tmp' -Encoding OEM}"
if exist "%TEMP%\ifname.tmp" (
    for /f "usebackq delims=" %%A in ("%TEMP%\ifname.tmp") do if not defined IFLABEL set "IFLABEL=%%A"
    del "%TEMP%\ifname.tmp" 2>nul
)
if not defined IFLABEL set "IFLABEL=(адаптер не найден)"

rem === Список конфигураций ===
set /a pcount=0
if exist "%PROFDIR%\*.txt" (
    for /f "delims=" %%F in ('dir /b /o:n "%PROFDIR%\*.txt"') do (
        set /a pcount+=1
        set "prof_!pcount!=%%F"
    )
)

cls
echo ==============================================
echo                DNS SWITCHER
echo ==============================================
echo  Адаптер [!IFINDEX!]: !IFLABEL!
echo ----------------------------------------------
echo   1. Сохранить текущие DNS в файл
echo   2. Восстановить DNS из файла
echo   3. DNS Xbox   (111.88.96.50 / 111.88.96.51)
echo   4. DNS Google (8.8.8.8 / 8.8.4.4)
echo   5. Сменить сетевой адаптер
echo   6. Создать свою конфигурацию
echo   7. Удалить конфигурацию
echo ----------------------------------------------
echo  Ваши конфигурации:
if !pcount! equ 0 (
    echo   (нет)
) else (
    for /l %%I in (1,1,!pcount!) do (
        set "PROFILEFILE=%PROFDIR%\!prof_%%I!"
        call :getname
        set /a pnum=7+%%I
        echo   !pnum!. !NAME!
    )
)
echo ----------------------------------------------
echo   0. Выход
echo ----------------------------------------------
set "choice="
set /p "choice=Ваш выбор: "

if not defined choice goto menu
if "%choice%"=="0" exit /b
if "%choice%"=="1" goto save
if "%choice%"=="2" goto restore
if "%choice%"=="3" goto xbox
if "%choice%"=="4" goto google
if "%choice%"=="5" goto chooseadapter
if "%choice%"=="6" goto createprofile
if "%choice%"=="7" goto deleteprofile

rem === Выбор своей конфигурации (кнопки 8, 9, ...) ===
set "cnum="
set /a cnum=!choice! 2>nul
set "selprofile="
if defined cnum (
    set /a maxp=7+!pcount!
    if !cnum! gtr 7 if !cnum! leq !maxp! (
        set /a pidx=!cnum!-7
        for %%Z in (!pidx!) do set "selprofile=!prof_%%Z!"
    )
)
if defined selprofile (
    set "PROFILEFILE=%PROFDIR%\!selprofile!"
    call :loadprofile
    if not "!PINDEX!"=="" (
        set "IFINDEX=!PINDEX!"
        echo(!IFINDEX!> "%ADAPTERFILE%"
    )
    goto apply
)
goto menu

rem ============ ПРИМЕНЕНИЕ DNS ============
:apply
echo.
echo Применяю DNS к адаптеру (индекс %IFINDEX%) ...
if not defined DNS1 set "DNS1="
if not defined DNS2 set "DNS2="
if not defined DOH set "DOH="
powershell -NoProfile -Command "%APPLY_CMD%"
echo.
echo Текущие DNS-серверы:
powershell -NoProfile -Command "$a=(Get-DnsClientServerAddress -InterfaceIndex %IFINDEX% -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses; if($a){$a -join ', '}else{'DHCP'}"
echo.
pause
goto menu

rem ============ 1. СОХРАНЕНИЕ ============
:save
echo Сохранение текущих DNS в %BACKUP% ...
powershell -NoProfile -Command "$d=(Get-DnsClientServerAddress -InterfaceIndex %IFINDEX% -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses; $dhcp=(Get-NetIPInterface -InterfaceIndex %IFINDEX% -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp; if($dhcp -eq 'Enabled'){'DHCP' | Out-File -FilePath '%BACKUP%' -Encoding ascii}else{$d | Out-File -FilePath '%BACKUP%' -Encoding ascii}"
echo Готово. Файл создан: %cd%\%BACKUP%
echo.
pause
goto menu

rem ============ 2. ВОССТАНОВЛЕНИЕ ============
:restore
if not exist "%BACKUP%" (
    echo Файл %BACKUP% не найден! Сначала выполните пункт 1.
    pause
    goto menu
)
set "DNS1="
set "DNS2="
set "DOH="
set /a n=0
for /f "usebackq delims=" %%A in ("%BACKUP%") do (
    set /a n+=1
    if !n! equ 1 set "DNS1=%%A"
    if !n! equ 2 set "DNS2=%%A"
)
if /i "!DNS1!"=="DHCP" (
    set "DNS1="
    set "DNS2="
)
echo Восстанавливаю DNS из %BACKUP% ...
goto apply

rem ============ 3. XBOX ============
:xbox
set "DNS1=111.88.96.50"
set "DNS2=111.88.96.51"
set "DOH=https://xbox-dns.ru/dns-query"
goto apply

rem ============ 4. GOOGLE ============
:google
set "DNS1=8.8.8.8"
set "DNS2=8.8.4.4"
set "DOH=https://dns.google/dns-query"
goto apply

rem ============ 5. СМЕНА АДАПТЕРА ============
:chooseadapter
cls
echo === Смена сетевого адаптера ===
echo.
powershell -NoProfile -Command "Get-NetAdapter | ForEach-Object { '{0}|{1}|{2}' -f $_.InterfaceIndex, $_.Name, $_.Status } | Out-File -FilePath '%TEMP%\adapters.tmp' -Encoding OEM"
set /a acnt=0
if exist "%TEMP%\adapters.tmp" (
    for /f "usebackq tokens=1,* delims=|" %%A in ("%TEMP%\adapters.tmp") do (
        set /a acnt+=1
        set "adp_idx_!acnt!=%%A"
        set "adp_nm_!acnt!=%%B"
        echo   !acnt!. [%%A] %%B
    )
    del "%TEMP%\adapters.tmp" 2>nul
)
echo   0. Назад
echo.
set "asel="
set /p "asel=Номер адаптера: "
set "anum="
set /a anum=!asel! 2>nul
set "selidx="
if defined anum (
    for %%Z in (!anum!) do set "selidx=!adp_idx_%%Z!"
)
if defined selidx (
    set "IFINDEX=!selidx!"
    echo(!IFINDEX!> "%ADAPTERFILE%"
    echo Выбран адаптер с индексом !IFINDEX!.
) else (
    echo Отмена или неверный номер.
)
pause
goto menu

rem ============ 6. СОЗДАНИЕ КОНФИГУРАЦИИ ============
:createprofile
cls
echo === Создание своей конфигурации ===
echo.
set "PNAME="
set /p "PNAME=Название (например: Cloudflare): "
if not defined PNAME (
    echo Отменено.
    pause
    goto menu
)
set "DNS1="
set /p "DNS1=Предпочтительный DNS (обязательно): "
if not defined DNS1 (
    echo DNS обязателен. Отменено.
    pause
    goto menu
)
set "DNS2="
set /p "DNS2=Дополнительный DNS (Enter - пропустить): "
set "DOH="
set /p "DOH=DoH шаблон (Enter - пропустить): "
set "PINDEX=!IFINDEX!"
echo.
echo Адаптер для конфигурации: !PINDEX! (текущий).
echo Чтобы задать другой адаптер, сначала смените его в меню (п.5), затем создайте конфигурацию.
echo.

set /a nxt=0
:findnext
set /a nxt+=1
if !nxt! lss 10 (set "NPAD=0!nxt!") else (set "NPAD=!nxt!")
if exist "%PROFDIR%\profile_!NPAD!.txt" goto findnext
if not exist "%PROFDIR%" mkdir "%PROFDIR%"
set "PFILE=%PROFDIR%\profile_!NPAD!.txt"

set "FDNS2=!DNS2!"
if "!FDNS2!"=="" set "FDNS2=-"
set "FDOH=!DOH!"
if "!FDOH!"=="" set "FDOH=-"
set "FPINDEX=!PINDEX!"
if "!FPINDEX!"=="" set "FPINDEX=-"

> "!PFILE!" echo(!PNAME!
>> "!PFILE!" echo(!DNS1!
>> "!PFILE!" echo(!FDNS2!
>> "!PFILE!" echo(!FDOH!
>> "!PFILE!" echo(!FPINDEX!

echo.
echo Конфигурация сохранена: !PNAME!
echo   Файл: !PFILE!
echo   DNS: !DNS1! / !DNS2!
echo   DoH: !DOH!
echo   Адаптер (индекс): !PINDEX!
echo.
pause
goto menu

rem ============ 7. УДАЛЕНИЕ КОНФИГУРАЦИИ ============
:deleteprofile
cls
set /a pcount=0
if exist "%PROFDIR%\*.txt" (
    for /f "delims=" %%F in ('dir /b /o:n "%PROFDIR%\*.txt"') do (
        set /a pcount+=1
        set "prof_!pcount!=%%F"
    )
)
if !pcount! equ 0 (
    echo Нет сохранённых конфигураций.
    pause
    goto menu
)
echo === Удаление конфигурации ===
echo.
for /l %%I in (1,1,!pcount!) do (
    set "PROFILEFILE=%PROFDIR%\!prof_%%I!"
    call :getname
    echo   %%I. !NAME!
)
echo   0. Назад
echo.
set "dsel="
set /p "dsel=Номер для удаления: "
set "dnum="
set /a dnum=!dsel! 2>nul
set "dfile="
if defined dnum (
    for %%Z in (!dnum!) do set "dfile=!prof_%%Z!"
)
if defined dfile (
    set "DFULL=%PROFDIR%\!dfile!"
    del "!DFULL!"
    echo Удалено: !DFULL!
) else (
    echo Отмена или неверный номер.
)
pause
goto menu

rem ============ ВСПОМОГАТЕЛЬНЫЕ ============
:getname
set "NAME="
for /f "usebackq delims=" %%A in ("%PROFILEFILE%") do if not defined NAME set "NAME=%%A"
goto :eof

:loadprofile
set "NAME="
set "DNS1="
set "DNS2="
set "DOH="
set "PINDEX="
set /a ln=0
for /f "usebackq delims=" %%A in ("%PROFILEFILE%") do (
    set /a ln+=1
    if !ln! equ 1 set "NAME=%%A"
    if !ln! equ 2 set "DNS1=%%A"
    if !ln! equ 3 set "DNS2=%%A"
    if !ln! equ 4 set "DOH=%%A"
    if !ln! equ 5 set "PINDEX=%%A"
)
if "!DNS2!"=="-" set "DNS2="
if "!DOH!"=="-" set "DOH="
if "!PINDEX!"=="-" set "PINDEX="
goto :eof
