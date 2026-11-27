@echo off
rem Interactive AI relay: asks for project, goal and roles, then runs the agents in Herdr.
rem   relay overnight [-Until 08:00 ^| -Until done] [-MaxCycles 10 ^| 0]
rem                     switch the relay running in this project to overnight mode (again: new limits)
rem   relay switch executor=claude:sonnet@high[,tester=haiku] [-SwitchScope run]
rem                     change agent/model/effort for the running relay's next stage (or the rest of the run)
rem   relay switch clear  drop earlier switches
rem   relay explain [T-037[,T-038]]
rem                     show which agent, model and effort each role would get, and why (starts nothing)
if /i "%~1"=="overnight" (
  shift
  goto :overnight
)
if /i "%~1"=="switch" goto :switch
if /i "%~1"=="explain" goto :explain
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.agents\protocol\ai-relay.ps1" %*
exit /b %errorlevel%

:overnight
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.agents\protocol\ai-relay.ps1" -MakeOvernight %1 %2 %3 %4 %5 %6
exit /b %errorlevel%

:switch
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.agents\protocol\ai-relay.ps1" -Switch "%~2" %3 %4 %5 %6
exit /b %errorlevel%

:explain
if "%~2"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.agents\protocol\ai-relay.ps1" -Explain %3 %4 %5 %6
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.agents\protocol\ai-relay.ps1" -Explain -Tasks "%~2" %3 %4 %5 %6
)
exit /b %errorlevel%
