## If mise.cmd is in a PATH directory then, invoking 'mise' from Powershell will result in calling 'mise.cmd',
## which is only compatible with cmd + clink. Hence, this 'mise.ps1' is here to override that behaviour.

$env:Path = $env:Path.Replace("$PSScriptRoot;", "")
& mise.exe $args
