---@diagnostic disable: undefined-field, undefined-global
-------------------------------------------------------------------------------------
-- mise.lua
-- This script is a Clink extension for managing the mise environment.
-- Requires to be used in conjunction with scripts:
--   - mise.cmd
--   - eval.cmd
-------------------------------------------------------------------------------------

local MISE_CLINK_ENABLED_DEFAULT = true
local MISE_CLINK_ENABLED
if settings then
    settings.add("mise.enabled", MISE_CLINK_ENABLED_DEFAULT, "Enable mise.lua script to run on Clink startup",
        "Although, the standalone script is run by clink if mise.cmd is in the PATH. " ..
        "Also, after enabling this setting, re-run the info command to see the all the settings.")
    MISE_CLINK_ENABLED = settings.get("mise.enabled")
    if not MISE_CLINK_ENABLED then
        return
    end
end

-- Adding this explicitly is necessary to run the standalone script
package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "modules/?.lua;" .. package.path
-- local inspect = require("inspect")
local standalone = not clink.argmatcher
local BASE_SHELL = "pwsh"
local CLINK_PID_KEY = "CLINK_PID"
local CLINK_PID = os.getenv(CLINK_PID_KEY) or os.getpid()
local EVAL_CMD_NAME = "eval.cmd"
local MISE_BIN_KEY = "__MISE_BIN"
local MISE_BIN = os.getenv(MISE_BIN_KEY)
local MISE_CLINK_AUTO_ACTIVATE
local MISE_CLINK_AUTO_ACTIVATE_ARGS
local MISE_CLINK_ASYNC_HOOK

local MISE_CMD_ACTIVATED_KEY = "__MISE_CLINK_CMD_ACTIVATED"
local MISE_ACTIVATED_KEY = "__MISE_CLINK_ACTIVATED"
local MISE_HOOK_ENV_ARGS_KEY = "__MISE_CLINK_HOOK_ENV_ARGS"
local MISE_CMD_TEMP_DIRS_SHOULD_DELETE_KEY = "__MISE_CLINK_CMD_TEMP_DIRS_SHOULD_DELETE"
local MISE_CMD_TEMP_DIRS_LAST_DELETED_KEY = "__MISE_CLINK_CMD_TEMP_DIRS_LAST_DELETED"

if not standalone then
    if not settings.add then
        print("mise.lua requires a newer version of Clink; please upgrade.")
    else
        settings.add("mise.auto_activate", true, "Auto activate mise on clink startup",
            "Otherwise, you'd need to run 'eval mise activate pwsh' manually.")
        settings.add("mise.auto_activate_args", "", "Line of args: mise activate " .. BASE_SHELL .. " <ARGS_LINE>")
        settings.add("mise.async_hook", false, "Asynchronously call hook-env from prompt hook",
            "Env changes may not be reflected immediately but allows instant prompt. Uses clink.promptcoroutine internally.")
        settings.add("mise.prompt_hook_priority", 0, "Priority of the mise prompt hook",
            "Lower number means higher priority (preferred). This setting is only used if async_hook is enabled.")
        MISE_CLINK_AUTO_ACTIVATE = settings.get("mise.auto_activate")
        MISE_CLINK_AUTO_ACTIVATE_ARGS = settings.get("mise.auto_activate_args")
        MISE_CLINK_ASYNC_HOOK = settings.get("mise.async_hook")
    end
end


--------------------------------------------------------------------------------
-- Utils: Utility functions for general operations
--------------------------------------------------------------------------------
function table.extend(t1, t2)
    for _, v in ipairs(t2) do
        table.insert(t1, v)
    end
end

function string.escape(s)
    return s:gsub("([%%%^%$%(%)%[%]%.*%+%-%?])", "%%%1")
end

function string.split(str, delimiter)
    local res, i = {}, 1
    while true do
        local a, b = str:find(delimiter, i, true)
        if not a then break end
        table.insert(res, str:sub(i, a - 1))
        i = b + 1
    end
    table.insert(res, str:sub(i))
    return res
end

function eprint(...)
    local args = { ... }
    io.stderr:write(table.concat(args, " "))
    io.stderr:write("\r\n")
end

function get_script_dir()
    local dir
    local info = debug.getinfo(1, "S")
    if info and info.source then
        dir = path.getdirectory(info.source:sub(2))
    end
    return dir or ""
end

--------------------------------------------------------------------------------
-- Replace the path to mise.exe if its a shim
--------------------------------------------------------------------------------
local function replace_shim_mise_exe(shim_mise_exe)
    return shim_mise_exe:gsub("scoop\\shims\\", "scoop\\apps\\mise\\current\\bin\\")
end

--------------------------------------------------------------------------------
-- Find the path to mise.exe using the "__MISE_BIN" env variable.
--------------------------------------------------------------------------------
local function find_mise_exe_from_mise_bin()
    local mise_bin = MISE_BIN and replace_shim_mise_exe(MISE_BIN)
    return (mise_bin and mise_bin ~= "") and mise_bin
end

--------------------------------------------------------------------------------
-- Find the path to mise.exe using the "where" command.
--------------------------------------------------------------------------------
local function find_mise_exe()
    local path = find_mise_exe_from_mise_bin()
    if path then
        return path
    end
    local fh, err = io.popen("where mise.exe 2>nul")
    assert(fh, "[ERROR]: 'where' command failed to execute: " .. (err or ""))
    path = fh:read("*l")
    fh:close()
    return path and replace_shim_mise_exe(path) or "mise.exe"
end

function load_mise_clink_config(path)
    local json = require("json")
    local fh, err = io.open(path, "r")
    if not fh and err then
        os.copy(path, path .. ".backup")
        return save_default_mise_clink_config(path)
    end
    assert(fh, "[ERROR]: failed to open: " .. path .. (err and " :" .. err or ""))
    local data = fh:read("*a")
    fh:close()
    local config = json.decode(data)
    return config
end

function save_mise_clink_config(path, config)
    local json = require("json")
    local data = json.encode(config)
    local fh, err = io.open(path, "w")
    assert(fh, "[ERROR]: failed to open: " .. path .. (err and " :" .. err or ""))
    fh:write(data)
    fh:flush()
    fh:close()
end

function default_mise_clink_config()
    local config = {
        mise_path = find_mise_exe(),
    }
    return config
end

function save_default_mise_clink_config(path)
    local config = default_mise_clink_config()
    save_mise_clink_config(path, config)
    return config
end

local mise_cmd_dir = get_script_dir()
local mise_clink_config_path = path.join(mise_cmd_dir, "mise.clink.json")
local mise_clink_config = load_mise_clink_config(mise_clink_config_path) -- TODO: Load config lazily i.e. load when getting any setting
local mise_path = find_mise_exe_from_mise_bin() or mise_clink_config.mise_path
if not mise_path or mise_path == "" then
    eprint("[ERROR]: mise.exe not found in PATH.")
    mise_path = "mise.exe"
end
local mise_exe_dir = path.getdirectory(mise_path)
local mise_shells = { bash = 1, elvish = 1, fish = 1, nu = 1, xonsh = 1, zsh = 1, pwsh = 1 }

local function mise_settings_get(setting)
    local cmd_line = mise_path .. " settings get " .. setting
    local fh = io.popen(cmd_line)
    assert(fh, "[ERROR]: failed to get setting " .. (setting or "(nil)"))
    local line = fh:read("*l")
    return line
end

local function get_temp_file(prefix, ext, path)
    if not prefix then
        prefix = CLINK_PID
    else
        prefix = CLINK_PID .. prefix
    end

    if not ext then
        ext = ".cmd"
    end
    if not path then
        path = os.getenv("TEMP") .. "\\mise-clink"
    end
    os.mkdir(path)
    local fh, fname = os.createtmpfile(prefix, ext, path)
    return fh, fname
end

local function delete_files_and_dirs_with(paths_t, threshold_hour, recursive, wait)
    if #paths_t == 0 then return end

    local paths_arr      = '"' .. table.concat(paths_t, '", "') .. '"'
    threshold_hour       = threshold_hour or 0
    local recursive_flag = recursive and "$true" or "$false"
    local param_vars     = string.format([[
        <# Array of paths to clean #>
        $paths = @(%s);
        $thresholdHour = %d;
        $recurse = @{ Recurse = %s };
    ]], paths_arr, threshold_hour, recursive_flag)
    local delete_ps1     = param_vars .. [[
    <# Remove files older than threshold #>
    Get-ChildItem -Path $paths -File @recurse
    | Where-Object { $_.LastWriteTime.AddHours($thresholdHour) -lt (Get-Date) }
    | Remove-Item -Force -ErrorAction SilentlyContinue;
    <# Remove empty directories recursively #>
    Get-ChildItem -Path $paths -Directory @recurse
    | Where-Object { -Not (Get-ChildItem $_.FullName @recurse -Force | Where-Object { -not $_.PSIsContainer }) }
    | Remove-Item -Force -ErrorAction SilentlyContinue;
]]

    local cmd_line       = [[powershell -NoLogo -NonInteractive -NoProfile -Command "]] ..
        delete_ps1:gsub('"', '\\"'):gsub("\r?\n", " ") .. '"'
    if wait then
        local fh, err = io.popen(cmd_line)
        assert(fh, "[ERROR]: failed to delete paths: " .. paths_arr .. (err and ("\n :" .. err) or ""))
        local output = fh:read("*a")
        local ok, _, code = fh:close()
        return ok, code, output
    else
        cmd_line = [[start "mise_clink_delete_paths" /b ]] .. cmd_line .. " >nul 2>nul"
        local ok, _, code = os.execute(cmd_line)
        return ok, code, nil
    end
end

--------------------------------------------------------------------------------
-- Prepend the mise command directory before the mise executable
-- directory in PATH.
--------------------------------------------------------------------------------
local function prepend_mise_cmd_before_mise_exe(path_env)
    local path = path_env or os.getenv("PATH")
    assert(path, "[ERROR]: %PATH% shouldn't be nil!")
    if path:match(string.format("%s;", mise_exe_dir:escape())) then
        path = path:gsub(string.format("%s;", mise_cmd_dir:escape()), "")
    end
    path = path:gsub(string.format("%s;", mise_exe_dir:escape()), string.format("%s;%s;", mise_cmd_dir, mise_exe_dir))
    if not path_env then os.setenv("PATH", path) end
    return path
end

--------------------------------------------------------------------------------
-- Parse environment variables from the line of PowerShell scripting language.
-- Extracts key-value pairs from line that start with "$env" or "Remove-Item".
--------------------------------------------------------------------------------
local function parse_env(line)
    if line:match("^%$[eE][nN][vV]") then
        local key, val = line:match("^%$[eE][nN][vV]:([%w_]+)%s*=%s*(.*)$")
        if key and val then
            -- Remove outer single quotes
            val = val:gsub("^\'", ""):gsub("\'$", "")
            val = val:gsub("\'?%+%[IO%.Path%]::PathSeparator%+", ";")
            val = val:gsub("%$[eE][nN][vV]:([%w_]+)", "%%%1%%")
            -- Handle escaped quotes or trailing backslashes
            val = val:gsub("\\'", "'"):gsub("\\\\", "\\")
            if key:upper() == "PATH" then
                val = prepend_mise_cmd_before_mise_exe(val)
            end
            return key, val
        end
    elseif line:match("^Remove%-Item") then
        local key = line:match("^Remove%-Item .- %-Path [eE][nN][vV]:[/\\](%S+)")
        if key then
            if key == "__MISE_WATCH" then key = "__MISE_SESSION" end
            return key, nil
        end
    end
end

--------------------------------------------------------------------------------
-- Set environment variable for the current process
--------------------------------------------------------------------------------
function set_env(key, val)
    if key then
        -- Ensuring val isn't something like "C:\path\to\dir1;C:\path\to\dir2;%PATH%"
        -- Because it needs to be expanded before using os.setenv
        if val then
            val = os.expandenv(val)
        end
        os.setenv(key, val)
    end
end

--------------------------------------------------------------------------------
-- Write environment variables to a file or stdout
--------------------------------------------------------------------------------
function write_env(key, val, env_fh)
    local fh = env_fh or io.stdout
    if key then
        local cmd = string.format('set "%s=%s"\r\n', key, val or "")
        fh:write(cmd)
    end
end

--------------------------------------------------------------------------------
-- Write line to a file or stdout
--------------------------------------------------------------------------------
function write_line(line, env_fh)
    local fh = env_fh or io.stdout
    if line then
        fh:write(line .. "\r\n")
    end
end

--------------------------------------------------------------------------------
-- Get the specified shell from the table of args
-- @param from_shell_flag: bool refers to whether the shell is a flag arg like
-- `--shell[=]pwsh`
-- @param shell_choices: table of shell names as keys and values as bool, to
-- choose from
-- @return shell: can be nil
-- @return found_shell_flag: bool refers to whether the shell was found from
-- the shell flag
--------------------------------------------------------------------------------
local function get_shell_from_args(args, from_shell_flag, shell_choices)
    shell_choices = shell_choices or mise_shells
    local shell, found_shell_flag
    for i, arg in ipairs(args) do
        if from_shell_flag then
            local shell_arg = string.match(arg, "^-s") or string.match(arg, "^--shell")
            if shell_arg then
                found_shell_flag = true
            end
            if shell_arg and string.match(arg, "=") then
                shell = string.gsub(arg, "^[^=]+=", "")
                break
            elseif shell_arg then
                shell = args[i + 1]
                break
            end
        elseif shell_choices[arg] then
            shell = arg
            break
        end
    end
    return shell, found_shell_flag
end

--------------------------------------------------------------------------------
-- Executes "mise hook-env <args>"
-- then set or write environment variables accordingly.
--------------------------------------------------------------------------------
local _hook_env_flags = {}
local function hook_env(args, env_fh, invoked_from_hook)
    if invoked_from_hook and not os.getenv(MISE_ACTIVATED_KEY) then return end

    local hook_args_line
    if type(args) == "table" then
        if not args then
            args = {}
            table.extend(args, _hook_env_flags)
            table.extend(args, { "-s", BASE_SHELL })
        end
        hook_args_line = table.concat(args, " ")
    elseif type(args) == "string" then
        hook_args_line = args
    end

    assert(hook_args_line, "[ERROR]: hook_args_line shouldn't be nil! type(hook_args): " .. type(args))
    local hook_cmd = string.format('"%s" hook-env %s', mise_path, hook_args_line)
    local fh = io.popen(hook_cmd)
    assert(fh, "[ERROR]: failed to run: " .. hook_cmd)
    local output = fh:read("*a")
    local success, _, code = fh:close()
    local refresh = false
    if success then
        for line in output:gmatch("[^\r\n]+") do
            local key, val = parse_env(line)
            if invoked_from_hook then
                if not refresh and key then
                    refresh = true
                end
                set_env(key, val)
            else
                write_env(key, val, env_fh)
            end
        end
    elseif not invoked_from_hook then
        eprint(output)
    end
    return code, refresh
end

--------------------------------------------------------------------------------
-- Activate mise environment
-- This function is called when the user runs "mise activate <args>"
--------------------------------------------------------------------------------
local function activate(args, env_fh, invoked_from_hook)
    -- eprint(inspect(args))
    local shell
    local shims_only = false
    for _, arg in ipairs(args) do
        if arg == "--shims" then
            shims_only = true
            break
        elseif arg == "--status" or arg == "--quiet" or arg == "-q" then
            table.insert(_hook_env_flags, arg)
        elseif mise_shells[arg] then
            shell = arg
        end
    end

    if shell ~= BASE_SHELL then
        local code = run_as_it_is(args)
        return code
    end

    if shims_only then
        local cmd_line = '""' .. table.concat(args, '" "') .. '""'
        local fh, err = io.popen(cmd_line)
        assert(fh, "[ERROR]: failed to run: " .. cmd_line .. (err and " :" .. err or ""))
        local output = fh:read("*a")
        local success, _, code = fh:close()
        if success then
            for line in output:gmatch("[^\r\n]+") do
                local key, val = parse_env(line)
                if invoked_from_hook then
                    set_env(key, val)
                else
                    write_env(key, val, env_fh)
                end
            end
        else
            if output and output ~= "" then eprint(output) end
        end
        return code
    end

    local cmd_line = '""' .. table.concat(args, '" "') .. '""'
    local fh = io.popen(cmd_line)
    assert(fh, "[ERROR]: failed to run: " .. cmd_line .. (err and " :" .. err or ""))
    local output = fh:read("*a")
    local success, _, code = fh:close()
    if success then
        for line in output:gmatch("[^\r\n]+") do
            local key, val = parse_env(line)
            if invoked_from_hook then
                set_env(key, val)
            else
                write_env(key, val, env_fh)
            end
        end
        local h_args = {}
        table.extend(h_args, _hook_env_flags)
        table.extend(h_args, { "-s", BASE_SHELL })
        local h_args_line = table.concat(h_args, " ")
        if invoked_from_hook then
            -- hook-env will be automatically called from the hook
            set_env(MISE_ACTIVATED_KEY, 1)
            set_env(MISE_HOOK_ENV_ARGS_KEY, h_args_line)
        else
            local hook_cmd = string.format('call "%s\\%s" "%s\\mise.cmd" hook-env %s', mise_cmd_dir, EVAL_CMD_NAME,
                mise_cmd_dir,
                h_args_line)
            write_line(hook_cmd, env_fh)
            write_env(MISE_ACTIVATED_KEY, 1, env_fh)
            write_env(MISE_HOOK_ENV_ARGS_KEY, h_args_line, env_fh)
        end
    elseif not invoked_from_hook then
        if output and output ~= "" then eprint(output) end
    end
    return code
end

--------------------------------------------------------------------------------
-- Generate mise usage completions
-- To use it, you'd have to run `mise completion clink -- [OPTIONS] [SUBCOMMANDS] [ARGS]`
-- The completions are stored in the same directory as mise.cmd
--------------------------------------------------------------------------------
local function completion(args)
    -- Generate mise usage completions
    local Cuc = require("cuc")
    local mise_cmd_bin_dir = path.join(mise_cmd_dir, "bin")
    local cuc_path = path.join(mise_cmd_bin_dir, Cuc.name_with_version("cuc"))
    local cuc = Cuc.new(cuc_path)
    if not cuc:check_cuc() then
        local all_cucs = path.join(mise_cmd_bin_dir, "cuc-*.exe")
        delete_files_and_dirs_with({ all_cucs }, -1, false, false)
        local ok, code = cuc:download_cuc()
        if not ok then
            eprint("[ERROR] failed to download cuc at " .. cuc.path)
            return code
        else
            os.execute(string.format([[copy "%s" "%s" >nul]], cuc.path, path.join(mise_cmd_bin_dir, "cuc.exe")))
        end
    end
    local mise_completions_lua = path.join(mise_cmd_dir, "mise.usage.lua")
    if cuc:check_cuc() then
        print("Generating completions ...")
        local ok, code, completions = cuc:generate_completions(mise_path, args)
        if ok then
            local file = io.open(mise_completions_lua, "w+")
            assert(file, "[ERROR] failed to open file: " .. mise_completions_lua)
            file:write(completions)
            file:close()
            print(mise_completions_lua)
            print("Reload Clink to apply the completions!")
            return 0
        else
            eprint("[ERROR] failed to generate completions (path:" .. mise_completions_lua .. "); exit code: " .. code)
            return code
        end
    else
        eprint("[ERROR] cuc doesn't exist at " .. cuc.path)
    end
    return 1
end

--------------------------------------------------------------------------------
-- Common subcommand handler for various subcommands
--------------------------------------------------------------------------------
local function common_subcommand(command, args, env_fh, invoked_from_hook)
    local shell, found_shell_flag = get_shell_from_args(args, true)
    if shell ~= BASE_SHELL and found_shell_flag then
        local code = run_as_it_is(args)
        os.exit(code)
    end

    local cmd_line = '""' .. table.concat(args, '" "') .. '""'
    local fh, err = io.popen(cmd_line)
    assert(fh, "[ERROR]: failed to run: " .. cmd_line .. (err and " :" .. err or ""))
    local output = fh:read("*a")
    local success, _, code = fh:close()
    if success then
        for line in output:gmatch("[^\r\n]+") do
            local key, val = parse_env(line)
            if invoked_from_hook then
                set_env(key, val)
            else
                write_env(key, val, env_fh)
            end
        end
        if command == "deactivate" then
            if invoked_from_hook then
                set_env(MISE_ACTIVATED_KEY, nil)
                set_env(MISE_HOOK_ENV_ARGS_KEY, nil)
            else
                write_env(MISE_ACTIVATED_KEY, nil, env_fh)
                write_env(MISE_HOOK_ENV_ARGS_KEY, nil, env_fh)
            end
        end
    elseif not invoked_from_hook then
        if output and output ~= "" then eprint(output) end
    end
    return code
end

--------------------------------------------------------------------------------
-- Check if the command is a common subcommand that should be handled as a
-- common_subcommand.
--------------------------------------------------------------------------------
local function is_common_subcommand(command)
    if not command or command == "" then return false end
    local common_cmds = { "deactivate", "e", "env", "sh", "shell" }
    for _, cmd in ipairs(common_cmds) do
        if command == cmd then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- Run the command as it is, without any modifications.
-- This is used for commands that doesn't needs to be processed.
--------------------------------------------------------------------------------
function run_as_it_is(args)
    local cmd_line
    if type(args) == "table" then
        cmd_line = '""' .. table.concat(args, '" "') .. '""'
    elseif type(args) == "string" then
        cmd_line = args
    else
        eprint("[function run_as_it_is]: Unknown param type of args")
        return 1
    end
    local _, _, code = os.execute(cmd_line)
    return code
end

--------------------------------------------------------------------------------
-- Parse and run the appropriate mise command.
-- This function is the entry point for the mise command.
-- It checks for subcommands and handles them accordingly.
--------------------------------------------------------------------------------
function parse_command_and_run_mise(args)
    local subcmds = {}
    local process_cmds = { "activate", "deactivate", "e", "env", "hook-env", "sh", "shell", "completion", "clink" }

    -- Set process commands
    for _, cmd in ipairs(process_cmds) do
        subcmds[cmd] = 1
    end

    local subcommand
    local help_requested
    for _, arg in ipairs(args) do
        if string.match(arg, "^[-]*h[elp]*$") then
            help_requested = 1
            break
        end
    end

    args[1] = mise_path
    local arg = args[2] -- This is the arg that points to subcommand
    if subcmds[arg] ~= nil then
        subcommand = arg
    end

    if help_requested or not subcommand then
        local code = run_as_it_is(args)
        os.exit(code)
    else
        local nargs = {}
        table.extend(nargs, { subcommand })
        table.extend(nargs, args)
        mise(nargs)
    end
end

--------------------------------------------------------------------------------
-- Mise command handler run by the parser if the subcommand
-- requires processing by mise.lua.
--------------------------------------------------------------------------------
function mise(args)
    assert(#args > 0, "[ERROR]: this shouldn't happen, args are always provided")

    local command = args[1]

    local env_fn, env_fh
    if args[#args - 1] == "--redirect" then
        env_fn = args[#args]
        env_fh, err = io.open(env_fn, "w")
        assert(env_fh, "[ERROR]: failed to open: " .. env_fn .. (err and " :" .. err or ""))
        env_fh:write("@echo off\r\n")
        table.remove(args, #args)
        table.remove(args, #args)
    end


    if command == "activate" then
        local code = activate({ table.unpack(args, 2) }, env_fh)
        os.exit(code)
    end

    if command == "hook-env" then
        local nargs = { table.unpack(args, 2) }
        local shell = get_shell_from_args(nargs, true)
        if shell and shell ~= BASE_SHELL then
            local code = run_as_it_is(nargs)
            os.exit(code)
        end

        local code = hook_env({ table.unpack(nargs, 3) }, env_fh)
        os.exit(code)
    end

    if command == "completion" then
        local nargs = { table.unpack(args, 2) }
        local shell = get_shell_from_args(nargs, nil, { bash = 1, fish = 1, zsh = 1, clink = 1 })
        if shell ~= "clink" then
            local code = run_as_it_is(nargs)
            os.exit(code)
        end

        local collect_index = #nargs + 1
        for i, arg in ipairs(nargs) do
            if arg == "--" then
                collect_index = i + 1
                break
            end
        end
        local gargs = {}
        if #nargs >= collect_index then
            table.extend(gargs, { table.unpack(nargs, collect_index) })
        end

        local code = completion(gargs)
        os.exit(code)
    end

    if command == "clink" then
        if args[4] == "reset-config" then
            print("Resetting mise-clink config to default: [" .. mise_clink_config_path .. "]")
            save_default_mise_clink_config(mise_clink_config_path)
        end
        os.exit(0)
    end

    if is_common_subcommand(command) then
        local code = common_subcommand(command, { table.unpack(args, 2) }, env_fh)
        os.exit(code)
    end

    local nargs = { table.unpack(args, 2) }
    local code = run_as_it_is(nargs)
    os.exit(code)
end

if standalone then
    local args = { ... }
    -- eprint(inspect(args))
    parse_command_and_run_mise(args)
end

--------------------------------------------------------------------------------
-- Setup for mise-clink
-- This section is executed when mise.lua is loaded as a Clink script.
--------------------------------------------------------------------------------
if not standalone then
    -- Ensure required scripts are in the PATH
    if not os.getenv(MISE_CMD_ACTIVATED_KEY) then
        local path = os.getenv("PATH")
        assert(path, "[ERROR]: %PATH% shouldn't be nil!")
        path = path:gsub(string.format("%s;", mise_cmd_dir:escape()), "")
        os.setenv("PATH", mise_cmd_dir .. ";" .. path)
        os.setenv(MISE_CMD_ACTIVATED_KEY, 1)
        os.setenv(CLINK_PID_KEY, CLINK_PID)
    end

    -- Check for automatic activation of mise
    if not os.getenv(MISE_ACTIVATED_KEY) then
        -- Running a coroutine to activate mise
        -- so to not block the shell startup
        local co = coroutine.create(function()
            if MISE_CLINK_AUTO_ACTIVATE then
                local args = { mise_path, "activate", BASE_SHELL }
                if MISE_CLINK_AUTO_ACTIVATE_ARGS and MISE_CLINK_AUTO_ACTIVATE_ARGS ~= "" then
                    local line_args = string.split(MISE_CLINK_AUTO_ACTIVATE_ARGS, "%s")
                    table.extend(args, line_args)
                end
                activate(args, nil, true)
                local _, refresh = hook_env(os.getenv(MISE_HOOK_ENV_ARGS_KEY), nil, true)
                if refresh then
                    clink.refilterprompt()
                end
            end
        end)
        clink.runcoroutineuntilcomplete(co)
    end

    -- Hook environment variables if mise is activated
    local function _mise_hook()
        if not os.getenv(MISE_ACTIVATED_KEY) then return end
        local info = {}
        -- Note: shouldn't be run in a coroutine because the prompt must wait
        -- for the environment to be updated before rendering and taking input
        info.code, info.refresh = hook_env(os.getenv(MISE_HOOK_ENV_ARGS_KEY), nil, true)
        -- Handle refresh of the prompt if needed
        return info
    end

    -- Auto-evaluate commands for mise
    -- For example: "mise deactivate" or "mise shell" doesn't need to be passed to 'eval'
    local function _mise_auto_eval_cmds(input)
        local cmd, subcmd = input:match("^%s-([%w-_]+)%s-([%w-_]+)")
        if not cmd or not subcmd then return end

        local allowed_cmds = {
            mise = true,
        }

        local allowed_subcmds = {
            deactivate = true,
            shell = true,
            sh = true,
        }

        if not allowed_cmds[cmd] or not allowed_subcmds[subcmd] then return end

        local help_args = { "-h", "--help", "/h", "/help" }
        for _, help_arg in ipairs(help_args) do
            if input:find("%f[%w_%-]" .. help_arg:escape() .. "%f[^%w_%-]") then return end
        end

        return EVAL_CMD_NAME .. " " .. input
    end

    -- Delete temp paths older than threshold_hour
    local function _delete_temps(threshold_hour)
        local tmps_t = {}
        table.insert(tmps_t, mise_cmd_dir .. "\\temp")
        table.insert(tmps_t, "$env:TEMP" .. "\\mise-clink")
        local recurse = true
        local wait = false
        delete_files_and_dirs_with(tmps_t, threshold_hour, recurse, wait)
        local now = os.time()
        os.setenv(MISE_CMD_TEMP_DIRS_LAST_DELETED_KEY, tostring(now))
        os.setenv(MISE_CMD_TEMP_DIRS_SHOULD_DELETE_KEY, nil)
    end


    ------------------------------------------------------------------------------------
    -- Hooks
    ------------------------------------------------------------------------------------
    if not clink.onbeginedit or not clink.promptfilter then
        print("mise.lua requires a newer version of Clink; please upgrade.")
    else
        clink.onbeginedit(function()
            if not os.getenv(MISE_ACTIVATED_KEY) then return end
            local use_async_hook = settings.get("mise.async_hook")

            if use_async_hook ~= MISE_CLINK_ASYNC_HOOK then
                MISE_CLINK_ASYNC_HOOK = use_async_hook
                clink.reload()
                return
            end

            if os.getenv(MISE_CMD_TEMP_DIRS_SHOULD_DELETE_KEY) then
                local now = os.time()
                local last_deleted = tonumber(os.getenv(MISE_CMD_TEMP_DIRS_LAST_DELETED_KEY) or 0)
                local threshold_hour = 1
                local threshold_secs = threshold_hour * 60 * 60
                if now - last_deleted > threshold_secs then
                    local co = coroutine.create(function()
                        _delete_temps(threshold_hour)
                    end)
                    clink.runcoroutineuntilcomplete(co)
                end
            end

            if not MISE_CLINK_ASYNC_HOOK then
                _mise_hook()
            end
        end)

        if MISE_CLINK_ASYNC_HOOK then
            local mise_filter = clink.promptfilter(settings.get("mise.prompt_hook_priority"))
            function mise_filter:filter()
                local info = clink.promptcoroutine(_mise_hook)
            end
        end
    end

    if not clink.onfilterinput then
        print("mise.lua requires a newer version of Clink; please upgrade.")
    else
        clink.onfilterinput(function(input)
            if not os.getenv(MISE_ACTIVATED_KEY) then return end
            if not input or input:gsub("%s", "") == "" then return end
            local mod_cmd = _mise_auto_eval_cmds(input)
            if mod_cmd then
                return mod_cmd
            end
        end)
    end
end
