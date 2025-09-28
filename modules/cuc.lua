local Cuc = {}
Cuc.__index = Cuc

local COMPATIBLE_VERSION = "0.2.2"

function Cuc.new(path)
    local self = setmetatable({}, Cuc)
    self.version = COMPATIBLE_VERSION
    self.path = path
    return self
end

function Cuc.name_with_version(prefix)
    return string.format("%s-v%s.exe", prefix, COMPATIBLE_VERSION)
end

function Cuc:check_cuc()
    local ok = os.execute(string.format('if not exist "%s" exit 1', self.path))
    return ok
end

function Cuc:download_cuc()
    local outdir = path.getdirectory(self.path)
    local ok, _, code = os.execute(string.format('if not exist "%s" md "%s"', outdir, outdir))
    if not ok then
        return ok, code
    end

    local download_ps1 = string.format(
        [[irm 'https://github.com/IMXEren/cuc/releases/download/v%s/cuc-v%s-x64.exe' -OutFile '%s']], self.version,
        self.version,
        self.path)
    ok, _, code = os.execute([[powershell -NoLogo -NonInteractive -NoProfile -Command ]] .. download_ps1)
    return ok, code
end

function Cuc:generate_completions(mise_path, args)
    args = args or {}
    arg_line = ""
    if #args ~= 0 then
        arg_line = '"' .. table.concat(args, '" "') .. '"'
    end
    local cmd_line = string.format([[""%s" usage | "%s" generate --complete %s"]], mise_path, self.path, arg_line)
    local p = io.popen(cmd_line)
    assert(p, "[ERROR] failed to generate completions: " .. (cmd_line or "(nil)"))
    local output = p:read("*a")
    local ok, _, code = p:close()
    return ok, code, output
end

function Cuc:get_path_last_modified(path, debug)
    local pipe_stderr_nul = not debug and "2>nul" or ""
    local cmd_line = string.format([[""%s" last-modified "%s" %s"]], self.path, path, pipe_stderr_nul)
    local p = io.popen(cmd_line)
    local time
    if p then
        time = tonumber(p:read("*l"))
        local ok, _, code = p:close()
        if debug and not ok then
            io.stderr:write("[ERROR] failed to get last modified; path: (" .. path .. "); exit code: " .. code)
            io.stderr:write("\r\n")
        end
    end
    return time or 0
end

return Cuc
