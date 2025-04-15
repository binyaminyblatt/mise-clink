--[[
    Clink init.lua for integrating mise with PowerShell dynamically.

    Features:
    • Dynamically finds mise.exe using "where"
    • Sets MISE_SHELL and __MISE_ORIG_PATH
    • Defines updateEnv() using "mise hook-env -s pwsh"
    • Handles directory changes
    • Hooks after relevant mise commands (e.g., install/use/activate/shell/sh)
--]]

--------------------------------------------------------------------------------
-- Dynamic Environment Initialization
--------------------------------------------------------------------------------
local current_path = os.getenv("PATH") or ""
os.setenv("PATH", current_path)
os.setenv("MISE_SHELL", "pwsh")
os.setenv("__MISE_ORIG_PATH", current_path)

--------------------------------------------------------------------------------
-- Find the path to mise.exe dynamically using the "where" command.
--------------------------------------------------------------------------------
local function findMiseExe()
    local fh = io.popen("where mise.exe 2>nul")
    if not fh then return nil end
    local path = fh:read("*l")
    fh:close()
    return path or "mise.exe"
end

local mise_path = findMiseExe()
if not mise_path or mise_path == "" then
    print("Error: mise.exe not found in PATH.")
    mise_path = "mise.exe"
end

--------------------------------------------------------------------------------
-- updateEnv()
-- Executes "mise env" and sets environment variables accordingly.
--------------------------------------------------------------------------------
local function updateEnv()
    local hook_cmd = string.format('"%s" env', mise_path)
    local fh = io.popen(hook_cmd)
    if not fh then return end
    local output = fh:read("*a")
    fh:close()

    -- Parse lines like: $Env:KEY='value'
    for line in output:gmatch("[^\r\n]+") do
        local key, val = line:match("^%$Env:([^=]+)='(.*)'$")
        if key and val then
            -- Handle escaped quotes or trailing backslashes
            val = val:gsub("\\'", "'"):gsub("\\\\", "\\")
            os.setenv(key, val)
        end
    end
end

--------------------------------------------------------------------------------
-- Install if there is a mise config exists
--------------------------------------------------------------------------------
local function install()
    local config_check = io.popen(string.format('"%s" config', mise_path))
    if not config_check then return end
    local config_output = config_check:read("*a")
    config_check:close()

    -- trim
    config_output = config_output:match("^%s*(.-)%s*$")

    if config_output == "" then
        -- nothing found -> no action needed
        return
    end

    local hook_cmd = string.format('"%s" install', mise_path)
    os.execute(hook_cmd)
end

--------------------------------------------------------------------------------
-- Handle "mise" command directly in Clink (optional fallback)
--------------------------------------------------------------------------------
function clink_command_mise(args)
    if #args == 0 then
        os.execute(string.format('"%s"', mise_path))
        return
    end

    local command = args[1]
    local help_requested = false
    for _, a in ipairs(args) do
        if a == "--help" or a == "-h" then
            help_requested = true
            break
        end
    end

    local cmd_line = string.format('"%s"', mise_path)
    for _, arg in ipairs(args) do
        cmd_line = cmd_line .. " " .. arg
    end

    if command == "deactivate" or command == "shell" or command == "sh" then
        if help_requested then
            os.execute(cmd_line)
        else
            local fh = io.popen(cmd_line)
            if fh then
                local output = fh:read("*a")
                fh:close()
                if output and output:match("%S") then
                    os.execute(output)
                end
            end
        end
    else
        os.execute(cmd_line)
        updateEnv()
    end
end

--------------------------------------------------------------------------------
-- Hooks
--------------------------------------------------------------------------------

-- Auto install and auto update env when changing directory
local last_dir = ""
clink.onbeginedit(function()
    local current_dir = os.getcwd()
    if current_dir ~= last_dir then
        last_dir = current_dir
        install()
        updateEnv()
    end
end)

-- Auto-update env after specific mise commands (install/use/activate/etc)
clink.onfilterinput(function(input)
    if not input then return end

    local cmd = input:match("^%s*([%w-_]+)")
    if not cmd then return end

    local allowed_cmds = {
        mise = true,
        ms = true,
        mi = true,
    }

    if not allowed_cmds[cmd] then return end

    local triggers = { "use", "activate", "shell", "sh", "install", "deactivate" }
    for _, sub in ipairs(triggers) do
        if input:find("%f[%w]" .. sub .. "%f[%W]") then
            clink.promptfilter(100).filter = function()
                updateEnv()
            end
            break
        end
    end
end)
