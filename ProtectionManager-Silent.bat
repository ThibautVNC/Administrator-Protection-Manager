@echo off
setlocal EnableExtensions

REM ============================================================
REM  Administrator Protection Manager - SILENT
REM  For unattended / GPO startup-script rollout. No GUI, no prompts.
REM  by Thibaut VNC
REM
REM  Usage:
REM    ProtectionManager-Silent.bat            -> disable Admin Protection (default)
REM    ProtectionManager-Silent.bat /disable   -> same as default
REM    ProtectionManager-Silent.bat /restore   -> re-enable Admin Protection
REM    ProtectionManager-Silent.bat /notask    -> disable but skip the startup fail-safe task
REM
REM  Exit codes: 0 = applied OK, 1 = a step failed (see log).
REM  A reboot is required for the change to take effect.
REM ============================================================

set "REGKEY=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
set "REGNAME=TypeOfAdminApprovalMode"
set "TASKNAME=DisableAdminProtection_Startup"
set "LOGDIR=%ProgramData%\ProtectionManager"
set "LOGFILE=%LOGDIR%\ProtectionManager.log"
set "BACKUPDIR=%LOGDIR%\backups"

REM --- Parse argument ---
set "MODE=disable"
set "WANT=1"
set "DOTASK=1"
if /I "%~1"=="/restore" set "MODE=restore"
if /I "%~1"=="/restore" set "WANT=2"
if /I "%~1"=="/restore" set "DOTASK=0"
if /I "%~1"=="/notask"  set "DOTASK=0"

if not exist "%LOGDIR%"    md "%LOGDIR%"    >nul 2>&1
if not exist "%BACKUPDIR%" md "%BACKUPDIR%" >nul 2>&1

REM --- Timestamp (locale-independent via wmic) ---
set "STAMP=unknown"
for /f %%a in ('wmic os get LocalDateTime ^| find "."') do set "DT=%%a"
if defined DT set "STAMP=%DT:~0,8%_%DT:~8,6%"

call :log "============================================================"
call :log "ProtectionManager-Silent started. mode=%MODE% target=%REGNAME%=%WANT% task=%DOTASK%"

REM --- Must be admin/SYSTEM ---
net session >nul 2>&1
if errorlevel 1 (
    call :log "ERROR: not elevated. Run as administrator or SYSTEM (GPO startup script)."
    endlocal & exit /b 1
)

set "FAILED=0"

REM --- Pre-change state ---
set "CUR="
for /f "tokens=3" %%v in ('reg query "%REGKEY%" /v "%REGNAME%" 2^>nul ^| find "%REGNAME%"') do set "CUR=%%v"
if defined CUR (call :log "Pre-check: %REGNAME% currently = %CUR%.") else (call :log "Pre-check: %REGNAME% not present.")
schtasks /query /tn "%TASKNAME%" >nul 2>&1
if errorlevel 1 (call :log "Pre-check: task %TASKNAME% not present.") else (call :log "Pre-check: task %TASKNAME% present.")

REM --- Backup registry key ---
set "BKP=%BACKUPDIR%\PoliciesSystem_%STAMP%.reg"
reg export "%REGKEY%" "%BKP%" /y >nul 2>&1
if errorlevel 1 (set "FAILED=1" & call :log "WARNING: registry backup failed.") else (call :log "Registry backup saved: %BKP%")

REM --- Apply local security policy via secedit ---
set "INF=%TEMP%\apm_%STAMP%.inf"
set "SDB=%TEMP%\apm_%STAMP%.sdb"
> "%INF%" echo [Unicode]
>> "%INF%" echo Unicode=yes
>> "%INF%" echo [Version]
>> "%INF%" echo signature="$CHICAGO$"
>> "%INF%" echo Revision=1
>> "%INF%" echo [Registry Values]
>> "%INF%" echo MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\TypeOfAdminApprovalMode=4,%WANT%
secedit /configure /db "%SDB%" /cfg "%INF%" /areas SECURITYPOLICY /quiet >nul 2>&1
if errorlevel 1 (set "FAILED=1" & call :log "secedit returned an error (may be blocked by a management policy).") else (call :log "Local security policy set (secedit OK).")
del /q "%INF%" "%SDB%" >nul 2>&1

REM --- Apply registry value directly ---
reg add "%REGKEY%" /v "%REGNAME%" /t REG_DWORD /d %WANT% /f >nul 2>&1
if errorlevel 1 (set "FAILED=1" & call :log "reg add failed.") else (call :log "Registry value %REGNAME% = %WANT% set.")

REM --- Startup fail-safe task ---
if "%MODE%"=="restore" goto :restore_task
if "%DOTASK%"=="1" goto :create_task
call :log "Startup fail-safe task skipped (/notask)."
goto :finish

:create_task
schtasks /create /tn "%TASKNAME%" /ru SYSTEM /sc ONSTART /rl HIGHEST /f /tr "reg add \"%REGKEY%\" /v %REGNAME% /t REG_DWORD /d 1 /f" >nul 2>&1
if errorlevel 1 (set "FAILED=1" & call :log "Could not create task %TASKNAME%.") else (call :log "Task %TASKNAME% registered (SYSTEM, at startup).")
goto :finish

:restore_task
schtasks /query /tn "%TASKNAME%" >nul 2>&1
if errorlevel 1 (call :log "No task to remove." & goto :finish)
schtasks /delete /tn "%TASKNAME%" /f >nul 2>&1
if errorlevel 1 (set "FAILED=1" & call :log "Could not remove task %TASKNAME%.") else (call :log "Task %TASKNAME% removed.")
goto :finish

:finish
if "%FAILED%"=="0" (
    call :log "DONE: all steps succeeded. Reboot required to apply."
    endlocal & exit /b 0
)
call :log "DONE WITH WARNINGS: one or more steps failed. See entries above."
endlocal & exit /b 1

:log
echo [%date% %time%] %~1>> "%LOGFILE%"
exit /b 0
