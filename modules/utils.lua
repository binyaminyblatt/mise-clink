local M = {}

--------------------------------------------------------------------------------
-- Convert a PowerShell environment variable key to CMD-compatible form.
-- Unescapes backticks and rejects keys containing "%".
--------------------------------------------------------------------------------
function M.pwsh_env_key_to_cmd(key)
    key = key:gsub("`(.)", "%1")

    if key:find("%", 1, true) then
        return nil
    end

    return key
end

--------------------------------------------------------------------------------
-- Parse a PowerShell environment variable key starting at the key name.
-- Handles braced and normal variable name forms.
--------------------------------------------------------------------------------
local function _parse_pwsh_env_key(s, start_pos, braced)
    if braced then
        local i = start_pos

        while i <= #s do
            local c = s:sub(i, i)

            if c == "`" then
                if i == #s then
                    return nil
                end
                i = i + 2
            elseif c == "}" then
                local key = M.pwsh_env_key_to_cmd(s:sub(start_pos, i - 1))

                if not key then
                    return nil
                end

                return key, i
            else
                i = i + 1
            end
        end

        return nil
    end

    local key_start, key_end, key = s:find("([%w_]+)", start_pos)

    if key_start ~= start_pos then
        return nil
    end

    key = M.pwsh_env_key_to_cmd(key)

    if not key then
        return nil
    end

    return key, key_end
end

--------------------------------------------------------------------------------
-- Parse a PowerShell environment variable starting at the given position.
-- Supports both $Env:VAR and ${Env:VAR} forms.
--------------------------------------------------------------------------------
function M.parse_pwsh_env_key(s, start_pos)
    start_pos = start_pos or 1

    local ref_start, _, name_start = s:find("%${[eE][nN][vV]:()", start_pos)

    if ref_start == start_pos then
        return _parse_pwsh_env_key(s, name_start, true)
    end

    ref_start, _, name_start = s:find("%$[eE][nN][vV]:()", start_pos)

    if ref_start == start_pos then
        return _parse_pwsh_env_key(s, name_start, false)
    end

    return nil
end

--------------------------------------------------------------------------------
-- Find and parse the next PowerShell environment variable reference.
-- Returns its start, end, and CMD-compatible key.
--------------------------------------------------------------------------------
local function _parse_pwsh_env_ref(s, start_pos)
    start_pos = start_pos or 1

    local braced_start = s:find("%${[eE][nN][vV]:", start_pos)
    local normal_start = s:find("%$[eE][nN][vV]:", start_pos)
    local ref_start

    if braced_start and normal_start then
        ref_start = math.min(braced_start, normal_start)
    else
        ref_start = braced_start or normal_start
    end

    if not ref_start then
        return nil
    end

    local key, ref_end = M.parse_pwsh_env_key(s, ref_start)

    if not key then
        return nil
    end

    return ref_start, ref_end, key
end

--------------------------------------------------------------------------------
-- Convert PowerShell environment variable references in a value to CMD form.
-- Replaces both $Env:VAR and ${Env:VAR} references with %VAR%.
--------------------------------------------------------------------------------
function M.convert_pwsh_env_refs(val)
    local pos = 1

    while true do
        local first, last, key = _parse_pwsh_env_ref(val, pos)

        if not first then
            break
        end

        local replacement = "%" .. key .. "%"

        val = val:sub(1, first - 1)
            .. replacement
            .. val:sub(last + 1)

        pos = first + #replacement
    end

    return val
end

--------------------------------------------------------------------------------
-- Parse a PowerShell environment variable key from an Env: provider path.
-- Supports quoted and unquoted Env:/KEY or Env:\KEY forms.
--------------------------------------------------------------------------------
function M.parse_pwsh_env_path_key(s, start_pos)
    start_pos = start_pos or 1
    local quote = s:sub(start_pos - 1, start_pos - 1)
    local _, _, name_start = s:find("[eE][nN][vV]:[/\\]()", start_pos)
    if not name_start then return nil end
    local key

    if quote == "'" or quote == '"' then
        local key_end = s:find(quote, name_start, true)
        if not key_end then return nil end

        key = s:sub(name_start, key_end - 1)
    else
        local key_start, key_end = s:find("%S+", name_start)
        if key_start ~= name_start then return nil end

        key = s:sub(key_start, key_end)
    end

    if not key then return nil end
    return M.pwsh_env_key_to_cmd(key)
end

--------------------------------------------------------------------------------
-- Parse a PowerShell environment variable assignment into a key-value pair.
-- Converts the resulting value and environment references to CMD-compatible form.
--------------------------------------------------------------------------------
function M.parse_pwsh_env_assignment(line)
    local key, key_end = M.parse_pwsh_env_key(line, 1)
    if not key then return nil end

    local val = line:sub(key_end + 1):match("^%s*=%s*(.*)$")
    if not val then return nil end

    -- Remove outer single quotes.
    val = val:gsub("^'", ""):gsub("'$", "")

    val = val:gsub("'?%+%[IO%.Path%]::PathSeparator%+", ";")
    val = M.convert_pwsh_env_refs(val)

    -- Handle escaped quotes or trailing backslashes.
    val = val:gsub("\\'", "'"):gsub("\\\\", "\\")

    return key, val
end

--------------------------------------------------------------------------------
-- Parse an environment variable key from a PowerShell Remove-Item command.
-- Supports both -Path and -LiteralPath with quoted or unquoted Env: paths.
--------------------------------------------------------------------------------
function M.parse_pwsh_remove_env_key(line)
    local path_start = line:match("%-LiteralPath%s+['\"]?()")
        or line:match("%-Path%s+['\"]?()")

    if not path_start then return nil end

    return M.parse_pwsh_env_path_key(line, path_start)
end

return M
