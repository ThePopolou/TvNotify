--------------------------------------------------------------------------------
-- tvnotify_common.lua  -  Shared Lua 5.1 utilities for TvNotify drivers
--
-- Used by both tvnotify_controller and tvnotify_android_tv so version checks,
-- expiration parsing, conditional comparisons, and helpers stay in sync.
--
-- Copyright (C) 2026 popolou  -  https://github.com/ThePopolou/TvNotify
-- Licensed under GPL-3.0 (https://www.gnu.org/licenses/gpl-3.0.html)
--------------------------------------------------------------------------------

local M = {}

M.UPDATE_URL    = "https://api.github.com/repos/ThePopolou/TvNotify/releases/latest"
M.UPDATE_DAY_MS = 24 * 60 * 60 * 1000
M.MAX_TIMER_SEC = 20 * 24 * 3600    -- chunk timers > 20 days to avoid 32-bit ms overflow

function M.trim(s)
    if s == nil then return "" end
    return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.nz(v)
    local s = M.trim(v)
    if s == "" then return nil end
    return s
end

function M.normalize(cmd)
    return (tostring(cmd or ""):upper():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

function M.versionParts(v)
    v = tostring(v or ""):gsub("^%s*[vV]", ""):gsub("[-+].*$", "")
    local t = {}
    for n in v:gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end

-- true when release tag a is newer than version b, compared number by number (0.10.0 > 0.9.0)
function M.isNewer(a, b)
    local x, y = M.versionParts(a), M.versionParts(b)
    if #x == 0 then return false end
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

-- Epoch timestamp when a badge with this Expiration will expire, or nil for no / unknown expiry.
-- Supports epoch (> 1000000000), plain seconds ("600"), or compound durations ("1y2w3d4h5m6s", "10m", "1h30m").
function M.expiresAt(v)
    v = tostring(v or ""):lower():gsub("%s", "")
    if v == "" then return nil end
    local n = tonumber(v)
    if n then
        if n <= 0 then return nil end
        return (n > 1000000000) and math.floor(n) or (os.time() + math.floor(n))
    end
    local secs = 0
    local UNIT = { y = 31536000, w = 604800, d = 86400, h = 3600, m = 60, s = 1 }
    for num, u in v:gmatch("(%d+)([ywdhms])") do
        secs = secs + tonumber(num) * UNIT[u]
    end
    local rest = v:gsub("%d+[ywdhms]", "")
    if secs <= 0 or rest ~= "" then return nil end
    return os.time() + secs
end

-- Conditional comparison helper (falls back to Lua comparison if C4:EvaluateExpression is unavailable)
function M.compare(logic, actual, value)
    local ok, r = pcall(function() return C4:EvaluateExpression(logic, actual, value) end)
    if ok and type(r) == "boolean" then return r end
    local a, v = tonumber(actual), tonumber(value)
    if a == nil or v == nil then a, v = tostring(actual), tostring(value) end
    logic = tostring(logic or "EQUAL"):upper()
    if logic == "EQUAL" then return a == v end
    if logic == "NOT_EQUAL" then return a ~= v end
    if logic == "LESS_THAN" then return a < v end
    if logic == "LESS_THAN_OR_EQUAL" then return a <= v end
    if logic == "GREATER_THAN" then return a > v end
    if logic == "GREATER_THAN_OR_EQUAL" then return a >= v end
    return false
end

-- Create a GitHub latest-release update checker bound to a driver's version, debug logger, and status callback.
function M.createUpdateChecker(opts)
    local version  = opts.version
    local dbg      = opts.dbg or function() end
    local onChange = opts.onChange or function() end
    local state    = { latest = nil, xfer = nil, timer = nil, first = nil }
    local checker  = { state = state }

    function checker.available()
        if state.latest and M.isNewer(state.latest, version) then return state.latest end
        return nil
    end

    function checker.latest()
        return state.latest
    end

    function checker.setLatest(tag)
        tag = tostring(tag or ""):match("^%s*(.-)%s*$")
        if tag == "" or not tag:match("%d") or tag == state.latest then return false end
        state.latest = tag
        pcall(function() C4:PersistSetValue("LatestRelease", tag) end)
        onChange(tag)
        return true
    end

    function checker.restore()
        local ok, v = pcall(function() return C4:PersistGetValue("LatestRelease") end)
        if ok and type(v) == "string" and v ~= "" then state.latest = v end
    end

    function checker.check(done)
        if state.xfer then return end
        local x = C4:url()
        state.xfer = x
        x:SetOption("fail_on_error", false)
        x:SetOption("timeout", 20)
        x:SetOption("connect_timeout", 10)
        x:OnDone(function(_, responses, errCode, errMsg)
            state.xfer = nil
            local r = (type(responses) == "table") and responses[#responses] or nil
            local code = r and tonumber(r.code) or 0
            local tag = nil
            if code == 200 then tag = tostring(r.body or ""):match('"tag_name"%s*:%s*"([^"]+)"') end
            if tag then
                dbg("Update check: latest release " .. tag .. (M.isNewer(tag, version) and " - update available" or " - up to date"))
                checker.setLatest(tag)
            else
                dbg("Update check failed (HTTP " .. tostring(code) .. ", " .. tostring(errMsg or errCode) .. ") - will try again tomorrow")
            end
            if done then done(tag) end
        end)
        x:Get(M.UPDATE_URL, { ["User-Agent"] = "TvNotify/" .. version, ["Accept"] = "application/vnd.github+json" })
    end

    function checker.cancel()
        if state.first then state.first:Cancel(); state.first = nil end
        if state.timer then state.timer:Cancel(); state.timer = nil end
    end

    return checker
end

return M
