@echo off
rem Interactive AI relay: asks for project, goal and roles, then runs the agents in Herdr.
rem   relay overnight [-Until 08:00 ^| -Until done] [-MaxCycles 10 ^| 0]
rem                     switch the relay running in this project to overnight mode (again: new limits)
if /i "%~1"=="overnight" (
  shift
  goto :overnight
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.agents\protocol\ai-relay.ps1" %*
exit /b %errorlevel%

:overnight
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.agents\protocol\ai-relay.ps1" -MakeOvernight %1 %2 %3 %4 %5 %6
exit /b %errorlevel%
