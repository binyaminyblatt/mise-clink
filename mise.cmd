@echo off
setlocal

@REM To use the original mise, you can run the following command:
@REM mise.exe <args>
@REM i.e. appending '.exe' to the command.

set "mise_exe=mise.exe"
set "mise_lua=%~dp0mise.lua"
call "%CLINK_DIR%\clink.bat" lua "%mise_lua%" "%mise_exe%" %*
call :end %ERRORLEVEL%
goto :eof

:end
endlocal & exit /b %~1
