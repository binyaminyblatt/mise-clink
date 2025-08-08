# Mise-Clink

A way to use [**mise**](https://github.com/jdx/mise) in `cmd.exe` using [**Clink**](https://github.com/chrisant996/clink). As of June 2025, there's no support for `cmd.exe` in **mise**, hence this comes into play.

## Installation

The easiest way to install it for use with your Clink is:

1. Make sure you have [git](https://www.git-scm.com/downloads) installed.
2. Clone this repo into a local directory via <code>git clone https://github.com/binyaminyblatt/mise-clink <em>local_directory</em></code>.
3. Tell Clink to load scripts from the repo via <code>clink installscripts <em>absolute/path/to/local_directory</em></code>.
4. Start a new session of Clink.
5. Ensure environment variable `CLINK_DIR` points to the clink directory containing `clink.bat`, `clink_*.exe`. The env var may be unset when using clink, installed by a package manager.

Get updates using `git pull` and normal git workflow.

## Usage Completions

You can use mise shell completions that have been extended using [**cuc**](https://github.com/IMXEren/cuc). It should generate `mise.usage.lua` in the same directory as `mise.lua`.

```cmd
> mise completion clink
...
```

## Settings

There are some settings that you can configure using:

```cmd
@REM Get info on all settings
clink set -i mise.*

@REM Set the setting to value
clink set <setting> <value>

@REM Clear the setting's value to use the default one
clink set <setting> clear
```
