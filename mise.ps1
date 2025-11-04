## If mise.cmd is in a PATH directory then, invoking 'mise' from Powershell will result in calling 'mise.cmd',
## which is only compatible with cmd + clink. Hence, this 'mise.ps1' is here to override that behaviour.

$env:Path = $env:Path.Replace("$PSScriptRoot;", "")
Remove-Item -ErrorAction SilentlyContinue -Path Env:\__MISE_CLINK_ACTIVATED
Remove-Item -ErrorAction SilentlyContinue -Path Env:\__MISE_CLINK_CMD_ACTIVATED
Remove-Item -ErrorAction SilentlyContinue -Path Env:\__MISE_CLINK_HOOK_ENV_ARGS
Remove-Item -ErrorAction SilentlyContinue -Path Env:\CLINK_PID
& mise.exe $args
