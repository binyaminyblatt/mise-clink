@echo off
setlocal

@REM To use the original mise, you can run the following command:
@REM mise.exe <args>
@REM i.e. appending '.exe' to the command.

if not defined CLINK_DIR (
    echo Environment variable 'CLINK_DIR' is not set.
    echo Refer to the https://github.com/binyaminyblatt/mise-clink#installation and set the 'CLINK_DIR' before running.
    exit /b 1
)

set "mise_exe=mise.exe"
set "mise_lua=%~dp0mise.lua"
call "%CLINK_DIR%\clink.bat" lua "%mise_lua%" "%mise_exe%" %*
call :end %ERRORLEVEL%
goto :eof

:end
endlocal & exit /b %~1
