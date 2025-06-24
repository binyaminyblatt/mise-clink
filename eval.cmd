@echo off
@REM Used to evaluate commands (similar to eval in bash). Example usage:
@REM - eval mise activate pwsh
@REM - eval mise deactivate
@REM - eval mise shell

FOR /F "usebackq delims=" %%A IN (`^"%*^"`) DO (
    CALL %%A
)
