--------------------------------------------------------------------------------
-- TvNotify (for Android TV)  -  Control4 DriverWorks driver by popolou
--
-- Talks to the TvOverlay Android TV app (github.com/gugutab/TvOverlay) using its
-- REST API:  /notify  /notify_fixed  /set/overlay  /set/notifications
--            /set/settings  /set/mqtt
--
-- Lua 5.1 compatible (no goto, no bit ops, no integer division).
--
-- Copyright (C) 2026 popolou  -  https://github.com/ThePopolou/TvNotify
-- This program is free software: you can redistribute it and/or modify it under the terms of the
-- GNU General Public License as published by the Free Software Foundation, version 3 of the License
-- or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY; without even the
-- implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public
-- License for more details: https://www.gnu.org/licenses/gpl-3.0.html
--------------------------------------------------------------------------------

DRIVER_VERSION = "0.1.2"

local Common = require("tvnotify_common")

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local DebugMode     = "Off"
local DebugTimer    = nil
local Heartbeat     = nil
local Watchdog      = nil
local Queue         = {}
local Busy          = false
local Online        = nil       -- nil = unknown, true / false once known
local ActiveXfer    = nil       -- keep a reference so the transfer is not collected
local LastNotify    = nil       -- { path=, body= } of the last popup, for "Repeat Last"
local SentCount     = 0
local IdSeq         = 0

local MAX_QUEUE     = 50
local DEFAULT_PORT  = 5001

local doRequest, finish, pump   -- forward declarations

--------------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------------
local function out(msg)
    if DebugMode == "Print" or DebugMode == "Print and Log" then
        print("[TvNotify] " .. msg)
    end
    if DebugMode == "Log" or DebugMode == "Print and Log" then
        if C4.DebugLog then C4:DebugLog("[TvNotify] " .. msg) else C4:ErrorLog("[TvNotify] " .. msg) end
    end
end

local function dbg(...)
    if DebugMode == "Off" then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    out(table.concat(parts, " "))
end

local function errlog(msg)
    C4:ErrorLog("[TvNotify] " .. tostring(msg))
    dbg("ERROR:", msg)
end

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------
local trim      = Common.trim
local nz        = Common.nz
local normalize = Common.normalize

-- hide passwords in log lines (user:pass@ and pwd= / password= query values)
local function maskUrl(url)
    url = tostring(url):gsub("(%a+://)([^/%s]*)@", "%1***@")
    url = url:gsub('([?&][Pp][Ww][Dd]=)[^&"%s]*', "%1***"):gsub('([?&][Pp]assword=)[^&"%s]*', "%1***")
    return url
end

local function num(v)
    return tonumber(trim(v))
end

local function setProp(name, value)
    C4:UpdateProperty(name, tostring(value))
end

local function setVar(name, value)
    C4:SetVariable(name, tostring(value))
end

local function fire(evt)
    C4:FireEvent(evt)
end

--------------------------------------------------------------------------------
-- Update check: latest release of github.com/ThePopolou/TvNotify
-- Every write to the Status property goes through setStatus(), which appends
-- " | Driver update available (vX.Y.Z)" while a newer release exists.
--------------------------------------------------------------------------------
local BaseStatus = ""
local UpdateChecker
local function setStatus(s)
    BaseStatus = tostring(s or "")
    local v = UpdateChecker and UpdateChecker.available() or nil
    C4:UpdateProperty("Status", v and (BaseStatus .. " | Driver update available (" .. v .. ")") or BaseStatus)
end

UpdateChecker = Common.createUpdateChecker({
    version = DRIVER_VERSION,
    dbg = dbg,
    onChange = function() setStatus(BaseStatus) end,
})
local Update = UpdateChecker.state
local function setLatest(tag) return UpdateChecker.setLatest(tag) end
local function restoreLatest() UpdateChecker.restore() end
local function checkForUpdate(done) UpdateChecker.check(done) end

-- A room driver connected to a TvNotify Controller is told the result by the Controller (TVN_LATEST_RELEASE)
-- and does not ask GitHub itself. On its own it checks once a day: the first check 10 minutes after start-up,
-- skipped while the Controller has reported within the last 25 hours.
local function heardFromController()
    local ok, t = pcall(function() return C4:PersistGetValue("ControllerReleaseAt") end)
    return ok and tonumber(t) and (os.time() - tonumber(t)) < 25 * 3600
end

local function dailyUpdateCheck()
    if heardFromController() then dbg("Update check: result comes from the TvNotify Controller") return end
    checkForUpdate()
end

local function startUpdateChecks()
    UpdateChecker.cancel()
    Update.first = C4:SetTimer(10 * 60 * 1000, function() Update.first = nil; dailyUpdateCheck() end)
    Update.timer = C4:SetTimer(Common.UPDATE_DAY_MS, function() dailyUpdateCheck() end, true)
end

-- Lists -> values ----------------------------------------------------------------
local CORNER_MAP = {
    ["bottom left"]  = "bottom_start", ["bottom right"] = "bottom_end",
    ["top left"]     = "top_start",    ["top right"]    = "top_end",
    ["bottom_start"] = "bottom_start", ["bottom_end"]   = "bottom_end",
    ["top_start"]    = "top_start",    ["top_end"]      = "top_end",
}
local function corner(v)
    v = nz(v)
    if not v then return nil end
    return CORNER_MAP[v:lower()]          -- "Use Default"/"Unchanged"/... -> nil
end

local SHAPE_MAP = { rounded = "rounded", circle = "circle", rectangular = "rectangular" }
local function shape(v)
    v = nz(v)
    if not v then return nil end
    return SHAPE_MAP[v:lower()]
end

-- "Unchanged" / "On" / "Off"  ->  nil / true / false
local function tri(v)
    v = nz(v)
    if not v then return nil end
    v = v:lower()
    if v == "on" or v == "true" or v == "yes" or v == "1" then return true end
    if v == "off" or v == "false" or v == "no" or v == "0" then return false end
    return nil
end

-- Replace {TIME} {DATE} ... tokens in free text
local function expand(s)
    if s == nil then return nil end
    if not s:find("{", 1, true) then return s end
    local now = os.time()
    local devName = ""
    pcall(function() devName = C4:GetDeviceDisplayName(C4:GetDeviceID()) or "" end)
    local map = {
        TIME     = os.date("%H:%M", now),
        TIME12   = os.date("%I:%M %p", now),
        DATE     = os.date("%Y-%m-%d", now),
        DAY      = os.date("%A", now),
        DATETIME = os.date("%Y-%m-%d %H:%M", now),
        DEVICE   = devName,
    }
    return (s:gsub("{(%u[%u%d]*)}", function(k) return map[k] end))
end

--------------------------------------------------------------------------------
-- Minimal JSON encoder (ordered keys, so payloads are stable and readable)
--------------------------------------------------------------------------------
local ESC = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
local function jsonStr(s)
    s = tostring(s)
    s = s:gsub('[%c"\\]', function(c)
        return ESC[c] or string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

local function newObj() return { _keys = {}, _vals = {} } end
local function oset(o, k, v)
    if v ~= nil then
        o._keys[#o._keys + 1] = k
        o._vals[k] = v
    end
end

local jsonVal
jsonVal = function(v)
    local t = type(v)
    if t == "string" then return jsonStr(v) end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return tostring(v)
    end
    if t == "table" and v._keys then
        local parts = {}
        for _, k in ipairs(v._keys) do
            parts[#parts + 1] = jsonStr(k) .. ":" .. jsonVal(v._vals[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function empty(o) return #o._keys == 0 end

--------------------------------------------------------------------------------
-- Connection state
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Reading data from other drivers in the project
--------------------------------------------------------------------------------
local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
    return keys
end

local function devName(id)
    local n = ""
    pcall(function() n = C4:GetDeviceDisplayName(id) or "" end)
    return n
end

-- Control4 reports many things against the *proxy* device (what a picker lists) while the
-- driver's own bindings and network connection live on the *driver* (protocol) device. Map proxy -> driver.
-- C4:GetDevices() entries carry a `protocol` table (on a proxy) and a `proxies` table (on a protocol driver).
local ProxyMap = nil
local function buildProxyMap()
    ProxyMap = {}
    local ok, all = pcall(function() return C4:GetDevices() end)
    if not ok or type(all) ~= "table" then return end
    local found = false
    for k, info in pairs(all) do
        local devId = tonumber(k)
        if devId and type(info) == "table" then
            if type(info.protocol) == "table" then
                local pr = tonumber(info.protocol.deviceId or info.protocol.deviceid)
                if pr and pr ~= devId then ProxyMap[devId] = pr; found = true end
            end
            if type(info.proxies) == "table" then
                for pk in pairs(info.proxies) do
                    local px = tonumber(pk)
                    if px and px ~= devId then ProxyMap[px] = devId; found = true end
                end
            end
        end
    end
    if found then return end
    -- fallback: C4:GetProxyDevicesById returns SEVERAL VALUES (not a table)
    for k in pairs(all) do
        local devId = tonumber(k)
        if devId then
            local res = { pcall(function() return C4:GetProxyDevicesById(devId) end) }
            if res[1] then
                for n = 2, #res do
                    local px = tonumber(res[n])
                    if px and px > 0 and px ~= devId then ProxyMap[px] = devId end
                end
            end
        end
    end
end

local function driverFor(id)
    if ProxyMap == nil then buildProxyMap() end
    return ProxyMap[id]
end

local function ipv4(v)
    if type(v) ~= "string" then return nil end
    local a, b, c, d = v:match("^%s*(%d+)%.(%d+)%.(%d+)%.(%d+)")
    if not a then return nil end
    for _, x in ipairs({ a, b, c, d }) do
        if tonumber(x) > 255 then return nil end
    end
    return a .. "." .. b .. "." .. c .. "." .. d
end

-- the address of a device's network connection(s):  { networkbindings = { {addr=..., status=...} } }
local function networkAddrOf(id)
    local ok, res = pcall(function() return C4:GetNetworkBindingsByDevice(id) end)
    if not ok or type(res) ~= "table" then return nil end
    local list = res.networkbindings
    if type(list) ~= "table" then list = res end
    for _, k in ipairs(sortedKeys(list)) do
        local b = list[k]
        if type(b) == "table" and b.addr ~= nil then
            local ip = ipv4(tostring(b.addr))
            if ip then return ip, b.status end
        end
    end
    return nil
end

-- same, for a device and (if it is a proxy) its driver device
local function networkAddr(id)
    local ip, st = networkAddrOf(id)
    if ip then return ip, st, id end
    local parent = driverFor(id)
    if parent then
        ip, st = networkAddrOf(parent)
        if ip then return ip, st, parent end
    end
    return nil
end

local HostSource = nil
local autoDiag   = nil          -- assigned further down (needs the diagnostics helpers)
local DiagDone   = {}

local function varNameValue(k, info)
    local name = (type(info) == "table") and (info.name or info.strName) or tostring(k)
    local value = (type(info) == "table") and (info.value or info.strValue) or info
    return tostring(name), value
end

-- Learn another device's IP address using only calls that exist (see DRIVERWORKS_API_NOTES.md).
-- Control4 offers no way to read another driver's Composer properties.
local function discoverIp(id)
    local nip, _, nowner = networkAddr(id)
    if nip then return nip, "network connection of device " .. tostring(nowner) end

    local owners = { id }
    local parent = driverFor(id)
    if parent then owners[#owners + 1] = parent end
    for _, o in ipairs(owners) do
        -- an address carried inside one of the device's binding records
        local ob, binds = pcall(function() return C4:GetBindingsByDevice(o) end)
        if ob and type(binds) == "table" then
            if type(binds.bindings) == "table" then binds = binds.bindings end
            for _, k in ipairs(sortedKeys(binds)) do
                local info = binds[k]
                if type(info) == "table" then
                    for _, fk in ipairs(sortedKeys(info)) do
                        local found = ipv4(type(info[fk]) == "string" and info[fk] or "")
                        if found then return found, "binding " .. tostring(k) .. " field '" .. tostring(fk) .. "' of device " .. o end
                    end
                end
            end
        end
        -- an address published as a variable
        local okv, vars = pcall(function() return C4:GetDeviceVariables(o) end)
        if okv and type(vars) == "table" then
            for _, k in ipairs(sortedKeys(vars)) do
                local nm, val = varNameValue(k, vars[k])
                local nl = nm:lower()
                local found = ipv4(type(val) == "string" and val or tostring(val or ""))
                if found and (nl:find("ip", 1, true) or nl:find("address", 1, true) or nl:find("host", 1, true)) then
                    return found, "variable '" .. nm .. "' of device " .. o
                end
            end
        end
    end
    return nil
end

local HostCache = { host = nil, at = 0 }
local HostErr   = nil

local NO_TV = "(none - use Manual IP Address)"

local function selectedTvId()
    local raw = tostring(Properties["TV Driver"] or "")
    local id = tonumber(raw:match("%(id (%d+)%)")) or tonumber(raw)
    if id and id > 0 then return id end
    return nil
end

-- fill the "TV Driver" dropdown with every TV-type device in the project
local function refreshTvList()
    local items = { NO_TV }
    local ok, devs = pcall(function() return C4:GetDevicesByC4iName("tv.c4i") end)
    if ok and type(devs) == "table" then
        local rows = {}
        for k, info in pairs(devs) do
            local id, name
            if type(info) == "table" then
                id, name = tonumber(k), info.deviceName or info.name
            elseif type(info) == "string" then
                id, name = tonumber(k), info
            else
                id = tonumber(info)
            end
            if id then rows[#rows + 1] = { id = id, name = (name and name ~= "") and name or devName(id) } end
        end
        table.sort(rows, function(x, y) return x.id < y.id end)
        for _, r in ipairs(rows) do
            items[#items + 1] = (tostring(r.name):gsub(",", " ")) .. " (id " .. r.id .. ")"
        end
    end
    local current = tostring(Properties["TV Driver"] or "")
    local default = NO_TV
    for _, it in ipairs(items) do if it == current then default = it end end
    pcall(function() C4:UpdatePropertyList("TV Driver", table.concat(items, ","), default) end)
    dbg("TV list:", table.concat(items, " | "))
end

-- address of the TV endpoint: read from the selected TV driver, else the manual fallback.
-- Kept until something asks for a fresh read: start-up, a TV Driver / port / manual-IP change,
-- Refresh TV Driver List, or a send that got no answer (so a DHCP change is followed). No timed re-reads.
local function resolveTvHost(force)
    local now = os.time()
    if not force and HostCache.host then return HostCache.host end
    local host = nil
    HostErr = nil

    local id = selectedTvId()
    if id then
        host, HostSource = discoverIp(id)
        if host then
            dbg("TV address", host, "found via", HostSource)
        else
            HostErr = "Cannot read an IP from '" .. devName(id) .. "' - enter the Manual IP Address"
            if autoDiag and not DiagDone[id] then
                DiagDone[id] = true
                autoDiag(id)
            end
        end
    end

    if not host then
        local manual = nz(Properties["Manual IP Address (fallback)"])
        if manual then
            manual = manual:gsub("^https?://", ""):gsub("/.*$", "")
            if manual ~= "" then host = manual; HostErr = nil end
        end
    end

    HostCache.host, HostCache.at = host, now
    return host
end

local function baseUrl()
    local host = resolveTvHost()
    if not host then return nil end
    if not host:find(":", 1, true) then
        host = host .. ":" .. tostring(tonumber(Properties["TV Port"]) or DEFAULT_PORT)
    end
    return "http://" .. host
end

local function notConfigured()
    return HostErr or "Not configured - select a TV Driver"
end

local function hideProp(name, hidden)
    pcall(function() C4:SetPropertyAttribs(name, hidden and 1 or 0) end)
end

local function updateVisibility()
    hideProp("Default Small Icon Custom Color", Properties["Default Small Icon Color"] ~= "Custom")
    local login = (Properties["Login Method"] == "Specify Below")
    hideProp("NVR/Camera Username", not login)
    hideProp("NVR/Camera Password", not login)
    local addr = (Properties["Address Method"] == "Specify Below")
    hideProp("NVR/Camera IP Address", not addr)
    hideProp("NVR/Camera HTTP Port", not addr)
    hideProp("NVR/Camera RTSP Port", not addr)
    local other = (Properties["Default Vendor"] == "Other Vendor")
    hideProp("Snapshot URL Format", not other)
    hideProp("Stream URL Format", not other)
    hideProp("Manual IP Address (fallback)", not (selectedTvId() == nil or HostErr ~= nil))
end

local function setOnline(state)
    if Online == state then return end
    Online = state
    setVar("ONLINE", state and "1" or "0")
    setStatus(state and "Online" or "Offline - TV not reachable")
    fire(state and "TV Online" or "TV Offline")
    dbg("TV is now", state and "ONLINE" or "OFFLINE")
end

--------------------------------------------------------------------------------
-- HTTP request queue (serialised, with retry + watchdog)
--------------------------------------------------------------------------------
local function maxRetries()
    return tonumber(Properties["Retry Attempts"]) or 0
end

local function timeoutSec()
    return tonumber(Properties["Request Timeout (sec)"]) or 5
end

local function startWatchdog(job)
    if Watchdog then Watchdog:Cancel(); Watchdog = nil end
    Watchdog = C4:SetTimer((timeoutSec() + 5) * 1000, function()
        Watchdog = nil
        if Busy and ActiveXfer then
            errlog("request watchdog fired for " .. tostring(job.path))
            finish(job, 0, -1, "watchdog timeout", "")
        end
    end)
end

doRequest = function(job)
    local base = baseUrl()
    if not base then
        Busy = false
        setStatus(notConfigured())
        if not job.isCheck then
            setProp("Last Result", "Failed: no TV address (select a TV Driver)")
            setVar("LAST_RESULT", "Failed: no TV address (select a TV Driver)")
            fire("Request Failed")
        end
        pump()
        return
    end

    job.done = false
    local url = base .. job.path
    dbg(job.method, url, maskUrl((job.body or ""):sub(1, 300)))

    local xfer = C4:url()
    xfer:SetOption("fail_on_error", false)          -- we want to see 4xx/5xx codes, not a failed transfer
    xfer:SetOption("timeout", timeoutSec())
    xfer:SetOption("connect_timeout", timeoutSec())
    xfer:OnDone(function(_, responses, errCode, errMsg)
        local resp = nil
        if type(responses) == "table" then resp = responses[#responses] end
        local code = 0
        local body = ""
        if resp then
            code = tonumber(resp.code) or 0
            body = resp.body or ""
        end
        finish(job, code, errCode, errMsg, body)
    end)
    ActiveXfer = xfer
    startWatchdog(job)

    if job.method == "GET" then
        xfer:Get(url, {})
    else
        xfer:Post(url, job.body or "", { ["Content-Type"] = "application/json; charset=utf-8" })
    end
end

finish = function(job, code, errCode, errMsg, body)
    if job.done then return end            -- late callback after watchdog / duplicate
    job.done = true
    if Watchdog then Watchdog:Cancel(); Watchdog = nil end
    ActiveXfer = nil

    code = tonumber(code) or 0
    local reachable = code > 0
    local ok = code >= 200 and code < 300

    -- transport-level failure: retry a few times before giving up
    if not reachable and not job.isCheck and job.tries < maxRetries() then
        job.tries = job.tries + 1
        dbg("No response (", tostring(errMsg), ") - retry", job.tries, "of", maxRetries())
        C4:SetTimer(1500, function() doRequest(job) end)
        return                              -- queue stays busy during the retry
    end

    Busy = false
    setOnline(reachable)
    setVar("LAST_HTTP_CODE", code)

    if job.isCheck then
        pump()
        return
    end

    local label = job.label or job.path
    if ok then
        SentCount = SentCount + 1
        setProp("Notifications Sent", SentCount)
        setVar("NOTIFICATION_COUNT", SentCount)
        local res = "OK (" .. code .. ") " .. label
        setProp("Last Result", res)
        setVar("LAST_RESULT", res)
        dbg("Success:", res, body)
        if job.event then fire(job.event) end
        if job.onOk then job.onOk() end
    else
        local why = reachable and ("HTTP " .. code) or ("no response: " .. tostring(errMsg or "timeout"))
        local res = "Failed (" .. why .. ") " .. label
        setProp("Last Result", res)
        setVar("LAST_RESULT", res)
        errlog(res .. " " .. tostring(body))
        fire("Request Failed")
        if not reachable then
            -- the TV endpoint may have a new address (DHCP): read it again for the next send
            local old = HostCache.host
            local new = resolveTvHost(true)
            if new and new ~= old then
                print("[TvNotify] TV endpoint address changed: " .. tostring(old) .. " -> " .. new .. " (used from the next send)")
            end
        end
    end
    pump()
end

pump = function()
    if Busy then return end
    local job = table.remove(Queue, 1)
    if not job then return end
    Busy = true
    job.tries = 0
    doRequest(job)
end

-- Ordering: a camera notification holds back everything sent after it until its snapshot has been
-- fetched (or the "Consecutive Popup Wait (sec)" time runs out), so the TV receives popups in programmed order.
local Holds   = {}      -- ordered list: { hold = true, done = bool, jobs = {...} }  or  { job = job }
local Capture = nil     -- while a hold is being released, jobs are collected here

local function rawEnqueue(job)
    if #Queue >= MAX_QUEUE then
        table.remove(Queue, 1)
        errlog("queue full - dropped oldest request")
    end
    Queue[#Queue + 1] = job
    pump()
end

local function enqueue(job)
    if Capture then Capture[#Capture + 1] = job; return end
    if #Holds > 0 and not job.isCheck then
        Holds[#Holds + 1] = { job = job }
        dbg("held behind a camera snapshot:", job.label or job.path)
        return
    end
    rawEnqueue(job)
end

local function flushHolds()
    while Holds[1] and (not Holds[1].hold or Holds[1].done) do
        local h = table.remove(Holds, 1)
        if h.hold then
            for _, j in ipairs(h.jobs or {}) do rawEnqueue(j) end
        else
            rawEnqueue(h.job)
        end
    end
end

-- reserve a place in the send order; returns nil when holding is switched off
local function newHold()
    local wait = tonumber(Properties["Consecutive Popup Wait (sec)"]) or 3
    if wait <= 0 then return nil end
    local h = { hold = true, done = false, wait = wait }
    Holds[#Holds + 1] = h
    return h
end

-- fill a reserved place: whatever fn() sends goes out in the reserved position
local function releaseHold(h, fn)
    if not h then return fn() end
    if h.done then return end
    h.done = true
    if h.timer then h.timer:Cancel(); h.timer = nil end
    Capture = {}
    local ok, err = pcall(fn)
    h.jobs, Capture = Capture, nil
    if not ok then errlog("camera notification: " .. tostring(err)) end
    flushHolds()
end

local function post(path, obj, label, event, onOk)
    if empty(obj) then
        dbg("Nothing to send for", path)
        return false
    end
    enqueue({ method = "POST", path = path, body = jsonVal(obj), label = label, event = event, onOk = onOk })
    return true
end

local function checkConnection()
    if not baseUrl() then
        setStatus(notConfigured())
        return
    end
    if Busy or #Queue > 0 then return end   -- real traffic will tell us soon enough
    enqueue({ method = "GET", path = "/", isCheck = true })
end

local function startHeartbeat()
    if Heartbeat then Heartbeat:Cancel(); Heartbeat = nil end
    local m = tonumber(Properties["Connection Check Interval (min)"]) or 0
    if m > 0 then
        Heartbeat = C4:SetTimer(m * 60 * 1000, function() checkConnection() end, true)
    end
end

--------------------------------------------------------------------------------
-- Notification builders
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Colours: Composer colour pickers give "R,G,B"; profiles / older programming give hex
--------------------------------------------------------------------------------
-- returns "#RRGGBB" / "#AARRGGBB", or nil for empty / unrecognised
local function toHexColor(v)
    v = nz(v)
    if not v then return nil end
    local r, g, b = v:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
    if r then
        local function c(x) x = tonumber(x) or 0; if x > 255 then x = 255 end; return x end
        return string.format("#%02X%02X%02X", c(r), c(g), c(b))
    end
    local h = v:match("^%s*#?(%x+)%s*$")
    if h and (#h == 6 or #h == 8) then return "#" .. h:upper() end
    return nil
end


-- the TV driver's Default Small Icon Color (TvOverlay Default / Custom + picker; older versions: hex text)
local function defaultSmallIconColor()
    local mode = nz(Properties["Default Small Icon Color"])
    if mode == "Custom" then return toHexColor(Properties["Default Small Icon Custom Color"]) end
    if mode == "TvOverlay Default" or not mode then return nil end
    return toHexColor(mode)
end

local function applyDefaults(f)
    f.source         = f.source or nz(Properties["Default Source"])
    f.smallIconColor = f.smallIconColor or defaultSmallIconColor()
    if not f.corner then
        f.corner = corner(Properties["Default Corner"])
    end
    if not f.duration then
        local d = tonumber(Properties["Default Duration (sec)"]) or 0
        if d > 0 then f.duration = d end
    end
    return f
end

local function sendNotification(f)
    f = applyDefaults(f)
    f.title   = expand(f.title)
    f.message = expand(f.message)
    f.source  = expand(f.source)

    if not (f.title or f.message or f.image or f.video or f.largeIcon) then
        errlog("Send Notification: nothing to show (title/message/image all empty)")
        return
    end

    local o = newObj()
    oset(o, "id", f.id)
    oset(o, "title", f.title)
    oset(o, "message", f.message)
    oset(o, "source", f.source)
    oset(o, "image", f.image)
    oset(o, "video", f.video)
    oset(o, "largeIcon", f.largeIcon)
    oset(o, "smallIcon", f.smallIcon)
    oset(o, "smallIconColor", f.smallIconColor)
    oset(o, "corner", f.corner)
    oset(o, "duration", f.duration)

    LastNotify = { path = "/notify", body = jsonVal(o) }
    setProp("Last Notification", (f.title or "") .. ((f.title and f.message) and " - " or "") .. (f.message or ""))
    setVar("LAST_TITLE", f.title or "")
    setVar("LAST_MESSAGE", f.message or "")
    post("/notify", o, "notification", "Notification Sent")
end

local function newFixedId()
    IdSeq = IdSeq + 1
    return "c4_" .. tostring(os.time()) .. "_" .. IdSeq
end

local expiresAt = Common.expiresAt
local MAX_TIMER_SEC = Common.MAX_TIMER_SEC

local FixedCache = nil
local fixedIds, saveFixedIds
fixedIds = function()
    if FixedCache == nil then
        local ok, v = pcall(function() return C4:PersistGetValue("FixedIds") end)
        FixedCache = (ok and type(v) == "table") and v or {}
    end
    return FixedCache
end
saveFixedIds = function()
    pcall(function() C4:PersistSetValue("FixedIds", FixedCache or {}) end)
end

-- Badge events (0.1.2): Badge Shown / Badge Cleared when the TV accepts the badge / its removal, Badge Expired
-- (then Badge Cleared) when its Expiration runs out. LAST_BADGE_ID is set first and survives a restart.
local LastBadgeId = ""
local BadgeTimers = {}

local function badgeEvents(id, ...)
    LastBadgeId = tostring(id or "")
    setVar("LAST_BADGE_ID", LastBadgeId)
    pcall(function() C4:PersistSetValue("LastBadgeId", LastBadgeId) end)
    for _, e in ipairs({ ... }) do fire(e) end
end

local function cancelExpiry(id)
    if BadgeTimers[id] then BadgeTimers[id]:Cancel(); BadgeTimers[id] = nil end
end

local function armExpiry(id, at)
    cancelExpiry(id)
    at = tonumber(at)
    if not at then return end
    local left = at - os.time()
    if left <= 0 then left = 1 end
    BadgeTimers[id] = C4:SetTimer(math.min(left, MAX_TIMER_SEC) * 1000, function()
        BadgeTimers[id] = nil
        if left > MAX_TIMER_SEC then return armExpiry(id, at) end
        if fixedIds()[id] == at then
            fixedIds()[id] = nil
            saveFixedIds()
            dbg("Badge expired:", id)
            badgeEvents(id, "Badge Expired", "Badge Cleared")
        end
    end)
end

-- start-up: restore LAST_BADGE_ID, forget badges that expired while the driver was not running, re-arm the rest
local function restoreBadges()
    local ok, v = pcall(function() return C4:PersistGetValue("LastBadgeId") end)
    if ok and type(v) == "string" then LastBadgeId = v end
    setVar("LAST_BADGE_ID", LastBadgeId)
    local now, changed = os.time(), false
    for id, at in pairs(fixedIds()) do
        if tonumber(at) then
            if tonumber(at) <= now then fixedIds()[id] = nil; changed = true else armExpiry(id, at) end
        end
    end
    if changed then saveFixedIds() end
end

local function sendFixed(f)
    f.id = f.id or newFixedId()
    f.message = expand(f.message)
    if f.visible == nil then f.visible = true end

    local o = newObj()
    oset(o, "id", f.id)
    oset(o, "visible", f.visible)
    oset(o, "icon", f.icon)
    oset(o, "message", f.message)
    oset(o, "messageColor", f.messageColor)
    oset(o, "iconColor", f.iconColor)
    oset(o, "borderColor", f.borderColor)
    oset(o, "backgroundColor", f.backgroundColor)
    oset(o, "shape", f.shape)
    oset(o, "expiration", f.expiration)

    if f.visible then
        fixedIds()[f.id] = expiresAt(f.expiration) or true     -- epoch when it expires, or true (no expiry)
    else
        fixedIds()[f.id] = nil
    end
    saveFixedIds()
    local id, visible, at = f.id, f.visible, fixedIds()[f.id]
    if not visible then cancelExpiry(id) end
    post("/notify_fixed", o, "fixed notification '" .. f.id .. "'", "Notification Sent", function()
        if visible then
            if at ~= true then armExpiry(id, at) else cancelExpiry(id) end
            badgeEvents(id, "Badge Shown")
        else
            badgeEvents(id, "Badge Cleared")
        end
    end)
end

local function removeFixed(id)
    id = nz(id)
    if not id then
        errlog("Remove Fixed Notification: ID is required")
        return
    end
    sendFixed({ id = id, visible = false })
end

local function removeAllFixed()
    local ids = {}
    for id in pairs(fixedIds()) do ids[#ids + 1] = id end
    if #ids == 0 then
        dbg("No tracked fixed notifications to remove")
        return
    end
    for _, id in ipairs(ids) do removeFixed(id) end
end


-- badges this room driver has put on screen and that have not expired (ids)
local function badgesOnScreen()
    local now, ids = os.time(), {}
    for id, v in pairs(fixedIds()) do
        if v == true or (tonumber(v) and tonumber(v) > now) then ids[#ids + 1] = id end
    end
    return ids
end

--------------------------------------------------------------------------------
-- Snapshot fetching (HTTP Digest / Basic auth) -> Base64 for the "image" field
--------------------------------------------------------------------------------
local MAX_IMAGE_BYTES = 3 * 1024 * 1024
local Fetches = {}              -- keeps in-flight transfers referenced

local function md5hex(str)
    local h = C4:Hash("MD5", str, { return_encoding = "HEX", data_encoding = "NONE" })
    return (h or ""):lower()
end

-- case-insensitive header lookup; returns a list of values (a header may repeat)
local function headerValues(h, name)
    local list = {}
    if type(h) ~= "table" then return list end
    name = name:lower()
    for k, v in pairs(h) do
        if tostring(k):lower() == name then
            if type(v) == "table" then
                for _, x in ipairs(v) do list[#list + 1] = tostring(x) end
            else
                list[#list + 1] = tostring(v)
            end
        end
    end
    return list
end

local function parseChallenge(str)
    local scheme = str:match("^%s*(%a+)")
    local t = {}
    for k, v in str:gmatch('(%w+)="([^"]*)"') do t[k:lower()] = v end
    for k, v in str:gmatch('(%w+)=([^%s,"]+)') do
        if t[k:lower()] == nil then t[k:lower()] = v end
    end
    return scheme and scheme:lower() or "", t
end

local function digestHeader(user, pass, method, uri, ch)
    local realm  = ch.realm or ""
    local nonce  = ch.nonce or ""
    local algo   = ch.algorithm
    local qop    = nil
    if ch.qop then
        for q in ch.qop:gmatch("[^%s,]+") do
            if q == "auth" then qop = "auth" end
        end
    end
    local nc     = "00000001"
    local cnonce = TEST_CNONCE or string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))

    local ha1 = md5hex(user .. ":" .. realm .. ":" .. pass)
    if algo and algo:lower() == "md5-sess" then
        ha1 = md5hex(ha1 .. ":" .. nonce .. ":" .. cnonce)
    end
    local ha2 = md5hex(method .. ":" .. uri)
    local response
    if qop then
        response = md5hex(ha1 .. ":" .. nonce .. ":" .. nc .. ":" .. cnonce .. ":" .. qop .. ":" .. ha2)
    else
        response = md5hex(ha1 .. ":" .. nonce .. ":" .. ha2)
    end

    local parts = {
        'username="' .. user .. '"', 'realm="' .. realm .. '"', 'nonce="' .. nonce .. '"',
        'uri="' .. uri .. '"', 'response="' .. response .. '"',
    }
    if algo then parts[#parts + 1] = "algorithm=" .. algo end
    if ch.opaque then parts[#parts + 1] = 'opaque="' .. ch.opaque .. '"' end
    if qop then
        parts[#parts + 1] = "qop=" .. qop
        parts[#parts + 1] = "nc=" .. nc
        parts[#parts + 1] = 'cnonce="' .. cnonce .. '"'
    end
    return "Digest " .. table.concat(parts, ", ")
end

local function httpGet(url, headers, cb)
    local x = C4:url()
    x:SetOption("fail_on_error", false)             -- a 401 must reach us: it carries the digest challenge
    x:SetOption("response_headers_duplicates", true) -- keep every WWW-Authenticate header
    x:SetOption("timeout", timeoutSec() + 5)
    x:SetOption("connect_timeout", timeoutSec())
    x:SetOption("ssl_verify_host", false)           -- cameras often use self-signed certificates
    x:SetOption("ssl_verify_peer", false)
    Fetches[x] = true
    x:OnDone(function(_, responses, errCode, errMsg)
        Fetches[x] = nil
        local resp = nil
        if type(responses) == "table" then resp = responses[#responses] end
        cb(resp and tonumber(resp.code) or 0, resp and resp.body or "", resp and resp.headers or nil, errMsg)
    end)
    x:Get(url, headers or {})
end

local function imageMime(b)
    if b:sub(1, 2) == "\255\216" then return "image/jpeg" end
    if b:sub(1, 4) == "\137PNG" then return "image/png" end
    if b:sub(1, 3) == "GIF" then return "image/gif" end
    if b:sub(1, 2) == "BM" then return "image/bmp" end
    if b:sub(1, 4) == "RIFF" and b:sub(9, 12) == "WEBP" then return "image/webp" end
    return nil
end

-- cb(imageValue, errorMessage)
local function fetchImageAsBase64(url, user, pass, cb)
    local uri = url:match("^%a+://[^/]+(/.*)$") or "/"

    local function finishImage(code, body)
        if code ~= 200 then
            return cb(nil, "snapshot HTTP " .. tostring(code))
        end
        if #body == 0 then return cb(nil, "snapshot was empty") end
        if #body > MAX_IMAGE_BYTES then
            return cb(nil, "snapshot too large (" .. #body .. " bytes)")
        end
        local mime = imageMime(body)
        if not mime then return cb(nil, "snapshot is not an image (check URL / login)") end
        local b64 = (C4:Base64Encode(body) or ""):gsub("%s", "")
        dbg("snapshot", #body, "bytes ->", #b64, "chars base64")
        cb(b64)
    end

    httpGet(url, nil, function(code, body, hdrs, err)
        if code == 0 then return cb(nil, "snapshot request failed: " .. tostring(err or "no response")) end
        if code ~= 401 then return finishImage(code, body) end

        if not user or not pass then
            return cb(nil, "snapshot needs a login (HTTP 401) - set NVR/Camera Username/Password")
        end
        local chosen, scheme, ch
        for _, v in ipairs(headerValues(hdrs, "www-authenticate")) do
            local sch, t = parseChallenge(v)
            if sch == "digest" then chosen, scheme, ch = v, sch, t; break end
            if sch == "basic" and not chosen then chosen, scheme, ch = v, sch, t end
        end
        if not chosen then return cb(nil, "snapshot 401 without a usable WWW-Authenticate header") end

        local auth
        if scheme == "digest" then
            auth = digestHeader(user, pass, "GET", uri, ch)
        else
            auth = "Basic " .. (C4:Base64Encode(user .. ":" .. pass) or ""):gsub("%s", "")
        end
        dbg("snapshot auth scheme:", scheme)
        httpGet(url, { Authorization = auth }, function(code2, body2, _, err2)
            if code2 == 0 then return cb(nil, "snapshot request failed: " .. tostring(err2 or "no response")) end
            if code2 == 401 then return cb(nil, "snapshot login rejected (HTTP 401)") end
            finishImage(code2, body2)
        end)
    end)
end

--------------------------------------------------------------------------------
-- Camera lookup (selected camera driver -> snapshot URL + NVR channel)
--------------------------------------------------------------------------------
local function urldecode(str)
    return (str:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function urlencode(str)
    return (tostring(str):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- "http://user:pass@host:80/x" -> "http://host:80/x", "user", "pass"
local function splitUserinfo(url)
    local scheme, rest = url:match("^(https?://)(.*)$")
    if not scheme then return url, nil, nil end
    local authority = rest:match("^[^/]*")
    local tail = rest:sub(#authority + 1)
    local ui, host = authority:match("^(.*)@([^@]*)$")
    if not ui then return url, nil, nil end
    local u, pw = ui:match("^([^:]*):?(.*)$")
    if u == "" then u = nil else u = urldecode(u) end
    if pw == "" then pw = nil else pw = urldecode(pw) end
    return scheme .. host .. tail, u, pw
end

-- hide credentials in anything we print
local function mask(key, value)
    local k = tostring(key):lower()
    if k:find("pass", 1, true) or k:find("secret", 1, true) or k:find("token", 1, true) then return "****" end
    local sv = tostring(value)
    return (sv:gsub("(%a+://)([^/%s]*)@", function(scheme, ui)
        return scheme .. (ui:match("^([^:]*)") or "") .. ":****@"
    end))
end

local function diag(line)
    print(line)
    C4:ErrorLog("[TvNotify] " .. line)
end

local function bindingListFor(owner, out)
    local ok, binds = pcall(function() return C4:GetBindingsByDevice(owner) end)
    if ok and type(binds) == "table" and type(binds.bindings) == "table" then
        binds = binds.bindings          -- the real list is wrapped in a "bindings" entry
    end
    if ok and type(binds) == "table" then
        for k, info in pairs(binds) do
            local bid = (type(info) == "table" and tonumber(info.bindingid or info.bindingId or info.id)) or tonumber(k)
            if bid then out[#out + 1] = { id = bid, info = info, owner = owner } end
        end
    end
end

local function bindingList(id)
    local list = {}
    bindingListFor(id, list)
    local parent = driverFor(id)
    if parent then bindingListFor(parent, list) end
    table.sort(list, function(x, y)
        if x.id ~= y.id then return x.id < y.id end
        return x.owner < y.owner
    end)
    return list
end

local function bindingLabel(devId, bid)
    for _, b in ipairs(bindingList(devId)) do
        if b.id == bid and type(b.info) == "table" then
            local i = b.info
            return i.name or i.bindingName or i.connectionName or i.connection_name or i.connectionname
                   or i.description or i.displayName or i.display_name or i.label
        end
    end
    return nil
end

local function providerOf(devId, bid)
    local ok, pid, pbind = pcall(function() return C4:GetBoundProviderDevice(devId, bid) end)
    pid = ok and tonumber(pid) or nil
    if pid and pid > 0 and pid ~= devId then return pid, tonumber(pbind) end
    return nil
end

-- print the raw result (or error) of a Control4 call, so we can see exactly what a system returns
local function showValue(v)
    if type(v) == "table" then
        local n, parts = 0, {}
        for _, k in ipairs(sortedKeys(v)) do
            n = n + 1
            if n <= 8 then
                local x = v[k]
                if type(x) == "table" then
                    local inner = {}
                    for _, ik in ipairs(sortedKeys(x)) do inner[#inner + 1] = tostring(ik) .. "=" .. tostring(x[ik]) end
                    x = "{" .. table.concat(inner, ", ") .. "}"
                end
                parts[#parts + 1] = tostring(k) .. "=" .. tostring(x)
            end
        end
        return "table(" .. n .. " entries) " .. table.concat(parts, "; ")
    end
    return tostring(v)
end

local function probe(label, fn)
    local ok, a, b = pcall(fn)
    local text
    if ok then
        text = showValue(a) .. ((b ~= nil) and (" , " .. showValue(b)) or "")
    else
        text = "ERROR: " .. tostring(a)
    end
    diag(string.format("    probe %-38s -> %s", label, text))
end

local function providerFromInfo(info)
    if type(info) ~= "table" then return nil end
    local bp = info.boundprovider or info.boundProvider
    if type(bp) ~= "table" then return nil end
    if type(bp.bound) == "table" then bp = bp.bound          -- OBSERVED real shape
    elseif type(bp[1]) == "table" then bp = bp[1] end
    local pid = tonumber(bp.deviceid or bp.deviceId or bp.id)
    local pbind = tonumber(bp.bindingid or bp.bindingId)
    if pid and pid > 0 then return pid, pbind, bp.name end
    return nil
end

local function bindingProvider(b)
    local pid, pbind, pname = providerFromInfo(b.info)
    if pid then return pid, pbind, pname end
    return providerOf(b.owner, b.id)
end

local function flat(v, depth)
    if type(v) ~= "table" then return tostring(v) end
    if depth <= 0 then return "{...}" end
    local out = {}
    for _, k in ipairs(sortedKeys(v)) do out[#out + 1] = tostring(k) .. "=" .. flat(v[k], depth - 1) end
    return "{" .. table.concat(out, ", ") .. "}"
end

local function dumpDevice(id, label, depth, noParent)
    diag(string.format("[%s] device %s '%s'", label, tostring(id), devName(id)))
    diag("    (Composer properties of other drivers cannot be read: DriverWorks has no API for it)")
    local okv, vars = pcall(function() return C4:GetDeviceVariables(id) end)
    if okv and type(vars) == "table" then
        for _, k in ipairs(sortedKeys(vars)) do
            local nm, val = varNameValue(k, vars[k])
            diag("    variable  " .. nm .. " = " .. mask(nm, val))
        end
    end
    probe("GetBindingsByDevice(" .. id .. ")", function()
        local r = C4:GetBindingsByDevice(id)
        if type(r) == "table" and type(r.bindings) == "table" then
            local n = 0
            for _ in pairs(r.bindings) do n = n + 1 end
            return "bindings{" .. n .. " entries}, other keys: " .. (function()
                local o = {}
                for k in pairs(r) do if k ~= "bindings" then o[#o + 1] = tostring(k) end end
                return #o > 0 and table.concat(o, ",") or "none"
            end)()
        end
        return r
    end)
    probe("GetNetworkBindingsByDevice(" .. id .. ")", function()
        local r = C4:GetNetworkBindingsByDevice(id)
        if r == nil then return nil end
        return flat(r, 3)
    end)
    probe("GetBoundProviderDevice(" .. id .. ", 6001)", function() return C4:GetBoundProviderDevice(id, 6001) end)
    probe("GetBoundConsumerDevices(" .. id .. ", 6001)", function() return C4:GetBoundConsumerDevices(id, 6001) end)
    local seen = {}
    for _, b in ipairs(bindingList(id)) do
        local info = b.info
        local text
        if type(info) == "table" then
            if info.isbound then
                local parts = {}
                for _, ik in ipairs(sortedKeys(info)) do
                    if ik ~= "bindingclasses" then parts[#parts + 1] = tostring(ik) .. "=" .. flat(info[ik], 3) end
                end
                text = table.concat(parts, ", ")
            else
                local parts = {}
                for _, ik in ipairs(sortedKeys(info)) do
                    if type(info[ik]) ~= "table" and info[ik] ~= "" then parts[#parts + 1] = tostring(ik) .. "=" .. tostring(info[ik]) end
                end
                text = table.concat(parts, ", ")
            end
        else
            text = tostring(info)
        end
        local pid, pbind = bindingProvider(b)
        diag(string.format("    binding %s (on device %s): %s%s", tostring(b.id), tostring(b.owner), text,
             pid and (string.format("  --> provider device %s '%s' binding %s", pid, devName(pid), tostring(pbind))) or ""))
        if pid and depth > 0 and not seen[pid] then
            seen[pid] = true
            dumpDevice(pid, label .. " > provider", depth - 1)
        end
    end
    local parent = (not noParent) and driverFor(id) or nil
    if parent then dumpDevice(parent, label .. " (its driver device)", 0, true) end
end

local function looksLikeNvr(id)
    local n = devName(id):lower()
    if n:find("nvr", 1, true) or n:find("dvr", 1, true) then return true end
    for _, b in ipairs(bindingList(id)) do
        local label = type(b.info) == "table" and tostring(b.info.name or ""):lower() or ""
        if label:find("channel", 1, true) or label:find("camera", 1, true) then return true end
    end
    return false
end

autoDiag = function(id)
    diag("==== TvNotify: could not read the TV's IP automatically - diagnostics follow (passwords hidden) ====")
    dumpDevice(id, "tv driver", 0)
    diag("Enter the TV's address in 'Manual IP Address (fallback)', and send this output to the driver author. ====")
end

-- the NVR (and the NVR-side binding) this camera driver is connected to
local function findNvrLink(camId)
    local first = nil
    local mine = { [camId] = true }
    local parent = driverFor(camId)
    if parent then mine[parent] = true end
    local list = bindingList(camId)
    if #list == 0 then
        for i = 1, 32 do list[#list + 1] = { id = i, owner = camId } end
    end
    for _, b in ipairs(list) do
        local pid, pbind, pname = bindingProvider(b)
        if pid and not mine[pid] then
            if looksLikeNvr(pid) then return pid, pbind, pname end
            first = first or { pid, pbind, pname }
        end
    end
    if first then return first[1], first[2], first[3] end
    return nil
end

-- Driver details of a device and its driver / proxy device: driver file names, manufacturer, model
local function deviceInfo(id)
    local r = { files = {}, manufacturer = nil, model = nil, sources = {} }
    local seenFile = {}
    local function addFile(f)
        f = (type(f) == "string") and nz(f) or nil
        if f and not seenFile[f] then seenFile[f] = true; r.files[#r.files + 1] = f end
    end
    local ids = { id }
    local parent = driverFor(id)
    if parent then ids[#ids + 1] = parent end
    local ok, all = pcall(function() return C4:GetDevices() end)
    if ok and type(all) == "table" then
        for _, i in ipairs(ids) do
            local d = all[i] or all[tostring(i)]
            if type(d) == "table" then
                addFile(d.driverFileName or d.driverfilename)
                if type(d.protocol) == "table" then addFile(d.protocol.driverFileName or d.protocol.driverfilename) end
            end
        end
    end
    for _, i in ipairs(ids) do
        for _, tag in ipairs({ "manufacturer", "model" }) do
            if not r[tag] then
                local okd, v = pcall(function() return C4:GetDeviceData(i, tag) end)
                if okd and type(v) == "string" and nz(v) then r[tag] = v end
            end
        end
    end
    return r
end

local function infoText(r)
    local parts = {}
    if #r.files > 0 then parts[#parts + 1] = "driver " .. table.concat(r.files, " / ") end
    parts[#parts + 1] = "manufacturer " .. (r.manufacturer and ("'" .. r.manufacturer .. "'") or "(not available)")
    parts[#parts + 1] = "model " .. (r.model and ("'" .. r.model .. "'") or "(not available)")
    return table.concat(parts, ", ")
end

-- vendor keywords looked for in the manufacturer, model and driver file name
local VENDOR_WORDS = {
    { "hikvision", "hikvision" }, { "%f[%a]hik%f[%A]", "hikvision" },
    { "dahua", "dahua" }, { "amcrest", "dahua" },
    { "foscam", "foscam" }, { "reolink", "reolink" }, { "%f[%a]axis%f[%A]", "axis" },
}
-- detected make -> Camera Vendor, when reached through an NVR / when reached directly
local NVR_VENDOR    = { hikvision = "Hikvision NVR", dahua = "Dahua / Amcrest", reolink = "Reolink" }
local DIRECT_VENDOR = { hikvision = "Hikvision Camera", dahua = "Dahua / Amcrest", foscam = "Foscam",
                        reolink = "Reolink", axis = "Axis" }

-- returns makeKey, "how it was found"   or   nil, info
local function detectMake(id)
    local r = deviceInfo(id)
    local fields = {}
    if r.manufacturer then fields[#fields + 1] = { "manufacturer", r.manufacturer } end
    if r.model then fields[#fields + 1] = { "model", r.model } end
    for _, f in ipairs(r.files) do fields[#fields + 1] = { "driver", f } end
    for _, f in ipairs(fields) do
        local text = f[2]:lower()
        for _, w in ipairs(VENDOR_WORDS) do
            if text:find(w[1]) then return w[2], f[1] .. " '" .. f[2] .. "'", r end
        end
    end
    return nil, infoText(r), r
end

-- camera ports published by the camera driver as variables (names containing "port")
local function cameraPorts(id)
    local http, rtsp
    local owners = { id }
    local parent = driverFor(id)
    if parent then owners[#owners + 1] = parent end
    for _, o in ipairs(owners) do
        local okv, vars = pcall(function() return C4:GetDeviceVariables(o) end)
        if okv and type(vars) == "table" then
            for _, k in ipairs(sortedKeys(vars)) do
                local nm, val = varNameValue(k, vars[k])
                local nl, n = nm:lower(), tonumber(val)
                if n and n > 0 and n < 65536 and nl:find("port", 1, true) then
                    if nl:find("rtsp", 1, true) then rtsp = rtsp or math.floor(n)
                    elseif nl:find("http", 1, true) or nl:find("web", 1, true) or nl == "port" then http = http or math.floor(n) end
                end
            end
        end
    end
    return http, rtsp
end

-- Each camera's standard Control4 camera settings (Address, HTTP / RTSP port, login), stored by Director in the
-- camera proxy's <state> and returned by C4:GetProjectItems("PROXIES", "NO_ROOT_TAGS") - the one query that
-- contains them (LIMIT_DEVICE_DATA leaves the states out). Read once and kept; re-read after 10 minutes, or
-- (at most once a minute) when a camera is not found.
local CamSettings = { at = nil, map = {}, size = 0, missAt = 0 }
local SETTING_KEYS = { "address", "http_port", "https_port", "use_https", "rtsp_port",
                       "authentication_required", "authentication_type", "username", "password" }

-- Control4 stores camera passwords Base64-encoded in the project data. Only a value that is valid Base64
-- is decoded (C4:Base64Decode, documented since OS 1.6.0); anything else is used as it is.
local function b64decode(str)
    if type(str) ~= "string" or #str == 0 or #str % 4 ~= 0 or not str:match("^[%w+/]+=?=?$") then return nil end
    local ok, d = pcall(function() return C4:Base64Decode(str) end)
    return ok and type(d) == "string" and d or nil
end

-- the stored password decoded; returns password, wasEncoded
local function decodePassword(stored)
    local d = b64decode(stored)
    if d and #d > 0 and not d:find("[^\32-\126]") then return d, true end
    return stored, false
end

local function xmlUnescape(str)
    return (str:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

-- the id of the item a <state> belongs to: the first <id> of the nearest <item> before it
-- (ids inside <itemdata> are skipped); falls back to the last <id> seen
local function stateOwner(xml, sS, fallback)
    local from = math.max(1, sS - 20000)
    local chunk = xml:sub(from, sS)
    local lastItem, p = nil, 1
    while true do
        local a = chunk:find("<item[%s>]", p)
        if not a then break end
        lastItem, p = a, a + 1
    end
    if lastItem then
        local id = chunk:match("^<item[^>]*>%s*<id>(%d+)</id>", lastItem)
        if id then return tonumber(id) end
    end
    return fallback
end

-- { [proxyId] = { address=..., http_port=..., ... } } for every <state> that holds an <address>
local function parseCameraStates(xml)
    local map, n = {}, 0
    local lastId = nil
    local iS, iE, idv = xml:find("<id>(%d+)</id>", 1)
    local sS, sE = xml:find("<state>", 1, true)
    while sS do
        if iS and iS < sS then
            lastId = tonumber(idv)
            iS, iE, idv = xml:find("<id>(%d+)</id>", iE + 1)
        else
            local cS = xml:find("</state>", sE + 1, true)
            if not cS then break end
            local inner = xmlUnescape(xml:sub(sE + 1, cS - 1))
            local owner = inner:find("<address>", 1, true) and stateOwner(xml, sS, lastId)
            if owner then
                local t = {}
                for _, k in ipairs(SETTING_KEYS) do
                    local v = inner:match("<" .. k .. ">(.-)</" .. k .. ">")
                    if v then t[k] = xmlUnescape(v) end
                end
                if t.password and t.password ~= "" then t.password, t.passwordEncoded = decodePassword(t.password) end
                if not map[owner] then n = n + 1 end
                map[owner] = t
            end
            local pos = cS + 8
            sS, sE = xml:find("<state>", pos, true)
            if iS and iS < pos then iS, iE, idv = xml:find("<id>(%d+)</id>", pos) end
        end
    end
    return map, n
end

local function loadCameraSettings(force)
    local now = os.time()
    if not force and CamSettings.at and now - CamSettings.at < 600 then return end
    local ok, xml = pcall(function() return C4:GetProjectItems("PROXIES", "NO_ROOT_TAGS") end)
    if ok and type(xml) == "string" and #xml > 0 then
        local map, n = parseCameraStates(xml)
        if n > 0 then
            CamSettings.map, CamSettings.at, CamSettings.size = map, now, #xml
            dbg("camera settings read for", n, "cameras (project data, " .. math.floor(#xml / 1024) .. " KB)")
            return
        end
    end
    CamSettings.map, CamSettings.at, CamSettings.size = {}, now, 0
    dbg("camera settings: none found in the project data")
end

local function settingsFor(id)
    if not id then return nil end
    local s = CamSettings.map[id]
    if s then return s end
    local d = driverFor(id)                                  -- a driver id given: look at its proxies
    if d and CamSettings.map[d] then return CamSettings.map[d] end
    for px, dv in pairs(ProxyMap or {}) do
        if dv == id and CamSettings.map[px] then return CamSettings.map[px] end
    end
    return nil
end

-- the camera's Control4 camera settings, or nil
local function cameraSettings(camId)
    loadCameraSettings(false)
    local s = settingsFor(camId)
    if not s and os.time() - (CamSettings.missAt or 0) >= 60 then
        CamSettings.missAt = os.time()
        loadCameraSettings(true)
        s = settingsFor(camId)
    end
    return s
end

-- channel code for a camera: N*100 + stream (1 main, 2 sub, 3 third); codes >= 100 keep their camera part
local function percentChannel(chan, stream)
    chan = math.floor(chan)
    stream = stream or 1
    if chan >= 100 then
        if chan % 100 == 1 then return chan - 1 + stream end     -- 101 -> 102 / 103
        return chan
    end
    return chan * 100 + stream
end

-- Build the NVR snapshot URL for a camera.  The camera driver's own snapshot URL cannot be read (no API),
-- so: NVR address from its network connection, channel from the NVR binding's name.
-- returns url, note   or   nil, errorMessage
-- Camera vendors: snapshot and live-stream URL patterns per manufacturer.
--   where : "nvr"    always through the camera's NVR connection (NVR/Camera IP Address property)
--           "camera" always the camera's own address (read from its driver's network connection)
--           "either" the NVR when the camera is connected to one, otherwise the camera itself
-- placeholders: {code} 101-style channel code (stream 1/2/3 = x01/x02/x03), {channel} 1-based channel,
--   {channel0} 0-based, {nn} two-digit channel, {subtype} 0/1/2, {foscam} videoMain/videoSub,
--   {reolink} main/sub, {user} {pass} login (URL-encoded) for vendors that take it in the query string
local CAMERA_VENDORS = {
    ["Hikvision NVR"]    = { where = "nvr",    port = 80, rtsp = 554, path = "/ISAPI/ContentMgmt/StreamingProxy/channels/{code}/picture",
                             stream = "/Streaming/Channels/{code}" },
    ["Hikvision Camera"] = { where = "camera", port = 80, rtsp = 554, path = "/ISAPI/Streaming/channels/{code}/picture",
                             stream = "/Streaming/Channels/{code}" },
    ["Dahua / Amcrest"]  = { where = "either", port = 80, rtsp = 554, path = "/cgi-bin/snapshot.cgi?channel={channel}",
                             stream = "/cam/realmonitor?channel={channel}&subtype={subtype}" },
    ["Foscam"]           = { where = "camera", port = 88, rtsp = 88,  path = "/cgi-bin/CGIProxy.fcgi?cmd=snapPicture2&usr={user}&pwd={pass}",
                             stream = "/{foscam}" },
    ["Reolink"]          = { where = "either", port = 80, rtsp = 554, path = "/cgi-bin/api.cgi?cmd=Snap&channel={channel0}&rs=tvnotify&user={user}&password={pass}",
                             stream = "/h264Preview_{nn}_{reolink}" },
    ["Axis"]             = { where = "camera", port = 80, rtsp = 554, path = "/axis-cgi/jpg/image.cgi?camera={channel}",
                             stream = "/axis-media/media.amp?camera={channel}" },
    ["Other Vendor"]     = { where = "either", port = 80, rtsp = 554, template = true },
}

-- the vendor asked for: action field, else the Default Vendor property ("Auto Detect" when empty)
local function chosenVendor(override)
    local m = nz(override)
    if not m or m == "Use Default" then m = nz(Properties["Default Vendor"]) or "Auto Detect" end
    if m ~= "Auto Detect" and not CAMERA_VENDORS[m] then m = "Hikvision NVR" end
    return m
end

-- 1 main, 2 sub, 3 third (accepts the old "Main Stream (x01)" style values too)
local function streamNumber()
    local n = (Properties["Camera Stream"] or Properties["Snapshot Stream"] or ""):lower()
    return n:find("third", 1, true) and 3 or (n:find("sub", 1, true) and 2 or 1)
end

-- NVR link + channel number (1-based) of a camera.   returns nvrId, channel, how   or   nil, nil, nil, err
local function linkChannel(camId)
    local nvrId, nvrBind, linkName = findNvrLink(camId)
    if not nvrId then
        return nil, nil, nil, "no NVR connection found for '" .. devName(camId) .. "' (run Dump Camera Info)"
    end
    local chan, how
    if linkName or nvrBind then
        local label = linkName or bindingLabel(nvrId, nvrBind)
        local n = label and tostring(label):match("(%d+)%D*$")
        if n then chan, how = tonumber(n), "NVR binding '" .. tostring(label) .. "'" end
    end
    if not chan and nvrBind and nvrBind >= 101 and nvrBind < 1000 and nvrBind % 100 <= 2 then
        chan, how = nvrBind, "NVR binding id " .. tostring(nvrBind)
    end
    if not chan then
        return nvrId, nil, nil, "NVR channel for '" .. devName(camId) .. "' could not be determined - run Dump Camera Info"
    end
    if chan >= 100 then chan = math.floor(chan / 100) end       -- 101 / 201 style -> 1 / 2
    return nvrId, chan, how
end

-- Where a camera is reached: NVR or the camera itself.
--   Auto Detect: an NVR of a known make (and a channel) -> through the NVR; else the camera's own make, directly.
--   Hikvision NVR chosen but the camera has no NVR connection -> the camera directly (its detected make, else Hikvision Camera).
-- returns { vendor, def, host, port, rtsp, chan, how }   or   nil, errorMessage
local function cameraTarget(camId, vendorOverride, purpose)
    local vendorName = chosenVendor(vendorOverride)
    local cam = "'" .. devName(camId) .. "'"
    local nvrId, nvrChan, nvrHow, linkErr = linkChannel(camId)
    local route, why = nil, nil          -- route: "nvr" / "camera"; why: how the vendor / route was decided
    local guessed = false                -- true when the driver chose the route itself (no property-address fallback)

    if vendorName == "Auto Detect" then
        guessed = true
        local nk, nt = nil, nil
        if nvrId and nvrChan then nk, nt = detectMake(nvrId) end
        if nk and NVR_VENDOR[nk] then
            vendorName, route = NVR_VENDOR[nk], "nvr"
            why = "detected from the NVR's " .. nt
        else
            local ck, ct = detectMake(camId)
            if ck and DIRECT_VENDOR[ck] then
                vendorName, route = DIRECT_VENDOR[ck], "camera"
                why = "detected from the camera's " .. ct .. (nvrId and "" or ", not connected to an NVR")
            else
                return nil, "Auto Detect: the vendor of " .. cam .. " could not be recognised (" .. tostring(ct) ..
                    ") - choose its Camera Vendor in the action, or set the Default Vendor property"
            end
        end
    end
    local def = CAMERA_VENDORS[vendorName]

    if not route then
        if def.where == "nvr" then
            if nvrChan then
                route = "nvr"
            elseif not nvrId then
                -- not connected to an NVR (e.g. an off-site camera): go to the camera itself
                local ck, ct = detectMake(camId)
                local direct = (ck and DIRECT_VENDOR[ck]) or "Hikvision Camera"
                why = vendorName .. " chosen but " .. cam .. " is not connected to an NVR - using the camera directly as " .. direct ..
                      (ck and (" (detected from its " .. ct .. ")") or "")
                vendorName, def, route, guessed = direct, CAMERA_VENDORS[direct], "camera", true
            else
                return nil, vendorName .. ": " .. tostring(linkErr)
            end
        elseif def.where == "either" and nvrId and nvrChan then
            route = "nvr"
        else
            route = "camera"
        end
    end

    local t = { vendor = vendorName, def = def }
    local cs = cameraSettings(camId)
    local csAddr = cs and nz(cs.address)
    if route == "nvr" then
        local prop = nz(Properties["NVR/Camera IP Address"])
        local function fromProperty()
            t.host = prop
            t.port = tostring(tonumber(Properties["NVR/Camera HTTP Port"]) or 80)
            t.rtsp = tostring(tonumber(Properties["NVR/Camera RTSP Port"]) or def.rtsp)
            t.src = "address: NVR/Camera IP Address property"
        end
        if Properties["Address Method"] == "Specify Below" and prop then
            fromProperty()
        elseif csAddr then
            t.host = csAddr
            t.port = tostring(tonumber(cs.http_port) or 80)
            t.rtsp = tostring(tonumber(cs.rtsp_port) or def.rtsp)
            t.src = "address: camera settings"
        elseif prop then
            fromProperty()
        else
            t.host = discoverIp(nvrId)
            if not t.host then
                return nil, "the NVR address for " .. cam .. " was not found in the camera's settings or the NVR driver '" .. devName(nvrId) ..
                    "' - fill in the camera's Address in Composer, or set Address Method to Specify Below and enter the NVR's address in NVR/Camera IP Address"
            end
            t.port = tostring(tonumber(Properties["NVR/Camera HTTP Port"]) or 80)
            t.rtsp = tostring(tonumber(Properties["NVR/Camera RTSP Port"]) or def.rtsp)
            t.src = "address: NVR driver"
        end
        t.chan, t.how = nvrChan, nvrHow .. ", NVR '" .. devName(nvrId) .. "'"
    else
        if csAddr then
            t.host = csAddr
            t.port = tostring(tonumber(cs.http_port) or def.port)
            t.rtsp = tostring(tonumber(cs.rtsp_port) or def.rtsp)
            t.chan, t.how, t.src = 1, "camera's own address", "address: camera settings"
        else
            t.host = discoverIp(camId)
            if not t.host then
                -- cameras not on an NVR never use the NVR/Camera IP Address property (it holds the NVR's address)
                return nil, cam .. " is not on an NVR and its address could not be read from its camera settings or its driver" ..
                    (why and (" (" .. why .. ")") or "") .. " - check the camera's Address in Composer, or type this camera's " .. purpose .. " in the action"
            end
            local hp, rp = cameraPorts(camId)
            t.port, t.rtsp = tostring(hp or def.port), tostring(rp or def.rtsp)
            t.chan, t.how, t.src = 1, "camera's own address", "address: camera driver" .. ((hp or rp) and " (ports from the camera driver)" or "")
        end
    end
    t.how = t.how .. "; " .. t.src .. " " .. t.host .. ", HTTP " .. t.port .. ", RTSP " .. t.rtsp
    if why then t.how = t.how .. "; " .. why end
    local st = streamNumber()
    t.vals = {
        ip = t.host, port = t.port, channel = tostring(t.chan), channel0 = tostring(t.chan - 1),
        nn = string.format("%02d", t.chan), code = tostring(percentChannel(t.chan, st)),
        subtype = tostring(st - 1), foscam = (st == 1) and "videoMain" or "videoSub",
        reolink = (st == 1) and "main" or "sub",
    }
    return t
end

local function fill(pattern, vals)
    return (pattern:gsub("{(%w+)}", function(k) return vals[k] end))    -- {user}/{pass} stay for fillLogin
end

-- Build the snapshot URL for a camera.   returns url, note   or   nil, errorMessage
local function resolveCameraSnapshot(camId, vendorOverride)
    local t, err = cameraTarget(camId, vendorOverride, "Snapshot URL")
    if not t then return nil, err end
    local url
    if t.def.template then
        url = nz(Properties["Snapshot URL Format"])
        if not url then return nil, "Default Vendor is 'Other Vendor' but the 'Snapshot URL Format' property is empty" end
        if not url:lower():find("^https?://") then return nil, "the 'Snapshot URL Format' property must start with http:// or https://" end
    else
        url = "http://{ip}:{port}" .. t.def.path
    end
    return fill(url, t.vals), string.format("%s, channel %s via %s", t.vendor, t.vals.channel, t.how)
end

-- Build the live-stream (RTSP) URL for a camera.   returns url, note   or   nil, errorMessage
local function resolveCameraStream(camId, vendorOverride)
    local t, err = cameraTarget(camId, vendorOverride, "Stream URL")
    if not t then return nil, err end
    local vals = {}
    for k, v in pairs(t.vals) do vals[k] = v end
    vals.port = t.rtsp
    local pattern
    if t.def.template then
        pattern = nz(Properties["Stream URL Format"])
        if not pattern then return nil, "Default Vendor is 'Other Vendor' but the 'Stream URL Format' property is empty" end
    else
        pattern = "rtsp://{ip}:{port}" .. t.def.stream
    end
    return fill(pattern, vals), string.format("%s stream, channel %s via %s", t.vendor, vals.channel, t.how)
end

-- put the login into {user}/{pass} placeholders (URL-encoded); true if the URL carries the login itself
local function fillLogin(url, user, pass)
    if not url:find("{user}", 1, true) and not url:find("{pass}", 1, true) then return url, false end
    url = url:gsub("{user}", function() return urlencode(user or "") end)
    url = url:gsub("{pass}", function() return urlencode(pass or "") end)
    return url, true
end

-- add the login to a typed or built URL that has none: {user}/{pass} placeholders, else USER:PASS@
local function withLogin(url, user, pass)
    local u, inUrl = fillLogin(url, user, pass)
    if inUrl or not (user and pass) or u:match("^%a[%w+.-]*://[^/]*@") then return u end
    local cred = urlencode(user) .. ":" .. urlencode(pass) .. "@"
    return (u:gsub("^(%a[%w+.-]*://)", function(scheme) return scheme .. cred end, 1))
end



--------------------------------------------------------------------------------
-- Alert presets (icon + colour per alert type)
--------------------------------------------------------------------------------
local ALERTS = {
    ["information"]  = { "mdi:information",         "#2196F3" },
    ["success"]      = { "mdi:check-circle",        "#4CAF50" },
    ["warning"]      = { "mdi:alert",               "#FFC107" },
    ["error"]        = { "mdi:alert-circle",        "#F44336" },
    ["doorbell"]     = { "mdi:doorbell",            "#03A9F4" },
    ["motion"]       = { "mdi:motion-sensor",       "#FF9800" },
    ["security"]     = { "mdi:shield-alert",        "#F44336" },
    ["fire / smoke"] = { "mdi:fire",                "#FF5722" },
    ["water leak"]   = { "mdi:water-alert",         "#00BCD4" },
    ["door open"]    = { "mdi:door-open",           "#FFC107" },
    ["garage"]       = { "mdi:garage-open",         "#FFC107" },
    ["phone call"]   = { "mdi:phone-in-talk",       "#4CAF50" },
    ["package"]      = { "mdi:package-variant-closed", "#A1887F" },
    ["reminder"]     = { "mdi:bell-ring",           "#9C27B0" },
}

--------------------------------------------------------------------------------
-- Programming commands (Composer Pro "Programming" tab)
--------------------------------------------------------------------------------
local Commands = {}

Commands.SEND_NOTIFICATION = function(p)
    sendNotification({
        id = nz(p["Notification ID"]), title = nz(p["Title"]), message = nz(p["Message"]),
        source = nz(p["Source"]), image = nz(p["Image"]), video = nz(p["Video URL"]),
        largeIcon = nz(p["Large Icon"]), smallIcon = nz(p["Small Icon"]),
        smallIconColor = (function()
            local mode = nz(p["Small Icon Color"])
            if mode == "Custom" then return toHexColor(p["Small Icon Custom Color"]) end
            if mode == "Use TV Default" or not mode then return nil end
            return toHexColor(mode)                     -- hex from a profile / older programming
        end)(), corner = corner(p["Corner"]),
        duration = (function() local d = num(p["Duration (sec)"]); if d and d > 0 then return d end end)(),
    })
end

Commands.SEND_ALERT = function(p)
    local preset = ALERTS[(nz(p["Alert Type"]) or "information"):lower()] or ALERTS["information"]
    local d = num(p["Duration (sec)"])
    sendNotification({
        id = nz(p["Notification ID"]), title = nz(p["Title"]), message = nz(p["Message"]),
        smallIcon = preset[1], smallIconColor = preset[2], largeIcon = preset[1],
        corner = corner(p["Corner"]), duration = (d and d > 0) and d or nil,
    })
end

-- login: Device Actions fields > Login Method (camera's own settings, or Specify Below) > user:pass@ inside a URL
-- returns user, pass, source
local function resolveLogin(p, camId)
    local user = nz(p["NVR/Camera Username"])
    local pass = nz(p["NVR/Camera Password"])
    local loginSrc = (user or pass) and "Device Actions" or nil
    if not user or not pass then
        if Properties["Login Method"] == "Specify Below" then
            user = user or nz(Properties["NVR/Camera Username"])
            pass = pass or nz(Properties["NVR/Camera Password"])
            loginSrc = loginSrc or "specified below"
        elseif camId then
            local cs = cameraSettings(camId)
            if not cs then
                loginSrc = loginSrc or "none (the camera's settings could not be read - set Login Method to Specify Below or fill in Username / Password in Device Actions)"
            elseif tostring(cs.authentication_required or ""):lower() == "true" then
                user = user or nz(cs.username)
                pass = pass or nz(cs.password)
                loginSrc = loginSrc or "camera settings"
            else
                loginSrc = loginSrc or "none (the camera's settings do not require a login)"
            end
        end
    end
    return user, pass, loginSrc or "none"
end

Commands.SEND_CAMERA_NOTIFICATION = function(p)
    local d = num(p["Duration (sec)"])
    local f = {
        id = nz(p["Notification ID"]), title = nz(p["Title"]), message = nz(p["Message"]),
        video = nz(p["Stream URL"]), smallIcon = "mdi:cctv", smallIconColor = "#03A9F4",
        corner = corner(p["Corner"]), duration = (d and d > 0) and d or nil,
    }

    local function withoutImage(err)
        -- still show the popup (with the stream, if any) rather than lose the alert
        local msg = "Snapshot not included: " .. tostring(err)
        errlog(msg)
        setProp("Last Result", "Failed (" .. msg .. ")")
        setVar("LAST_RESULT", "Failed (" .. msg .. ")")
        fire("Request Failed")
        sendNotification(f)
    end

    -- Output decides what is BUILT from the Camera picker; typed Snapshot URL / Stream URL are always used
    local camId = tonumber(nz(p["Camera"]))
    if camId and camId <= 0 then camId = nil end

    local user, pass, loginSrc = resolveLogin(p, camId)
    dbg("login:", tostring(loginSrc or "none") .. (user and (" (user " .. user .. ")") or ""))
    local output = nz(p["Output"]) or "Snapshot"
    local wantSnap = output ~= "Stream"
    local wantStream = output:find("Stream", 1, true) ~= nil

    -- live stream: typed Stream URL, else built from the camera when Output asks for it
    local streamNote = nil
    if not f.video and camId and wantStream then
        local su, sn = resolveCameraStream(camId, p["Camera Vendor"])
        if su then f.video = su; dbg("stream:", maskUrl(su), "(" .. sn .. ")")
        else streamNote = sn end
    end
    if f.video then f.video = withLogin(f.video, user, pass) end
    if streamNote then
        errlog("Stream not included: " .. streamNote)
        setProp("Last Result", "Failed (Stream not included: " .. streamNote .. ")")
        fire("Request Failed")
    end

    local custom = nz(p["Snapshot URL"])
    local url, note
    if custom then
        -- any other address: use exactly what was typed
        if not custom:lower():find("^https?://") then
            return withoutImage("Snapshot URL must start with http:// or https://")
        end
        url, note = custom, "typed snapshot URL"
    elseif camId and wantSnap then
        url, note = resolveCameraSnapshot(camId, p["Camera Vendor"])
    else
        sendNotification(f)                  -- no snapshot wanted / possible: text and / or stream only
        return
    end
    if not url then return withoutImage(note) end
    local loginInUrl
    url, loginInUrl = fillLogin(url, user, pass)
    dbg("camera", camId, "->", maskUrl(url), "(" .. tostring(note) .. ")")

    -- Encode the Image to Base64? = No  ->  hand the URL to the TV exactly as it is
    if (Properties["Encode the Image to Base64?"] or "Yes") == "No" then
        if user and pass and not loginInUrl and not url:find("@", 1, true) then
            local cred = urlencode(user) .. ":" .. urlencode(pass) .. "@"      -- function form: '%' in cred must stay literal
            url = url:gsub("^(https?://)", function(scheme) return scheme .. cred end, 1)
        end
        f.image = url
        sendNotification(f)
        return
    end

    -- user:pass@ inside the URL is used when the command / properties give no login
    local clean, uUser, uPass = splitUserinfo(url)
    user = user or uUser
    pass = pass or uPass

    local h = newHold()
    if h then
        h.timer = C4:SetTimer(h.wait * 1000, function()
            h.timer = nil
            if not h.done then
                releaseHold(h, function() withoutImage("snapshot took longer than " .. h.wait .. " s (Consecutive Popup Wait)") end)
            end
        end)
    end
    fetchImageAsBase64(clean, user, pass, function(img, err)
        if h and h.done then
            dbg("snapshot arrived after the Consecutive Popup Wait time - not used")
            return
        end
        releaseHold(h, function()
            if img then
                f.image = img
                sendNotification(f)
            else
                withoutImage(err)
            end
        end)
    end)
end

Commands.DUMP_CAMERA_INFO = function(p)
    local camId = tonumber(nz(p["Camera"]))
    if not camId or camId <= 0 then errlog("Dump Camera Info: choose a camera"); return end
    diag("==== TvNotify camera diagnostics (passwords hidden) ====")
    dumpDevice(camId, "camera", 2)
    local ck, ct = detectMake(camId)
    diag("CAMERA DRIVER: " .. infoText(deviceInfo(camId)) .. "  -> make " .. (ck and (ck .. " (from " .. ct .. ")") or "not recognised"))
    local nvrId = findNvrLink(camId)
    if nvrId then
        local nk, nt = detectMake(nvrId)
        diag("NVR DRIVER: '" .. devName(nvrId) .. "' " .. infoText(deviceInfo(nvrId)) .. "  -> make " .. (nk and (nk .. " (from " .. nt .. ")") or "not recognised"))
    else
        diag("NVR DRIVER: none - this camera is not connected to an NVR")
    end
    local hp, rp = cameraPorts(camId)
    diag("CAMERA PORTS: HTTP " .. tostring(hp or "not published") .. ", RTSP " .. tostring(rp or "not published"))
    loadCameraSettings(true)
    local cs = settingsFor(camId)
    if cs then
        diag(string.format("CAMERA SETTINGS: address %s, HTTP %s, RTSP %s, HTTPS %s (port %s, not used), login required %s (%s), user %s, password %s",
            tostring(cs.address), tostring(cs.http_port), tostring(cs.rtsp_port), tostring(cs.use_https), tostring(cs.https_port),
            tostring(cs.authentication_required), tostring(cs.authentication_type), tostring(cs.username),
            nz(cs.password) and ("****" .. (cs.passwordEncoded and " (stored Base64-encoded, decoded)" or "")) or "(empty)"))
    else
        diag("CAMERA SETTINGS: not found in the project data" .. (CamSettings.size > 0 and "" or " (no camera settings could be read)"))
    end
    diag("Address Method: " .. tostring(Properties["Address Method"]) .. ", Login Method: " .. tostring(Properties["Login Method"]))
    local user, pass, loginSrc = resolveLogin(p, camId)
    diag("LOGIN: " .. tostring(loginSrc) .. (user and (", user " .. user) or ", no username") .. (pass and ", password ****" or ", no password"))
    local url, note = resolveCameraSnapshot(camId, p["Camera Vendor"])
    if url then
        local inUrl
        url, inUrl = fillLogin(url, user, pass)
        if not inUrl and user and pass then note = tostring(note) .. "; login sent as Digest / Basic (Encode = Yes) or user:pass@ (Encode = No)" end
    end
    diag("RESULT: " .. (url and (maskUrl(url) .. "   (" .. tostring(note) .. ")")
                            or ("FAILED - " .. tostring(note))))
    local su, sn = resolveCameraStream(camId, p["Camera Vendor"])
    if su then su = withLogin(su, user, pass) end
    diag("STREAM: " .. (su and (maskUrl(su) .. "   (" .. tostring(sn) .. ")") or ("not available - " .. tostring(sn))))
    diag("==== end ====")
end

Commands.SEND_FIXED_NOTIFICATION = function(p)
    sendFixed({
        id = nz(p["Fixed Notification ID"]), message = nz(p["Message"]), icon = nz(p["Icon"]),
        messageColor = nz(p["Message Color"]), iconColor = nz(p["Icon Color"]),
        borderColor = nz(p["Border Color"]), backgroundColor = nz(p["Background Color"]),
        shape = shape(p["Shape"]), expiration = nz(p["Expiration"]), visible = true,
    })
end

Commands.REMOVE_FIXED_NOTIFICATION = function(p)
    removeFixed(p["Fixed Notification ID"])
end

Commands.REMOVE_ALL_FIXED_NOTIFICATIONS = function() removeAllFixed() end

local function clampVis(v, lo)
    v = num(v)
    if v == nil or v < lo then return nil end
    if v > 95 then v = 95 end
    return math.floor(v)
end

Commands.SET_OVERLAY = function(p)
    local o = newObj()
    oset(o, "overlayVisibility", clampVis(p["Background Visibility"], 0))
    oset(o, "clockOverlayVisibility", clampVis(p["Clock Visibility"], 0))
    oset(o, "hotCorner", corner(p["Hot Corner"]))
    post("/set/overlay", o, "overlay settings")
end

Commands.SET_NOTIFICATION_SETTINGS = function(p)
    local o = newObj()
    oset(o, "displayNotifications", tri(p["Display Notifications"]))
    oset(o, "displayFixedNotifications", tri(p["Display Fixed Notifications"]))
    oset(o, "notificationLayoutName", nz(p["Layout Name"]))
    local d = num(p["Notification Duration (sec)"])
    if d and d >= 1 then oset(o, "notificationDuration", math.floor(d)) end
    local fv = num(p["Fixed Notification Visibility"])
    if fv and fv >= -1 then
        if fv > 95 then fv = 95 end
        oset(o, "fixedNotificationsVisibility", math.floor(fv))
    end
    post("/set/notifications", o, "notification settings")
end

Commands.SET_SETTINGS = function(p)
    local o = newObj()
    oset(o, "deviceName", nz(p["Device Name"]))
    oset(o, "displayDebug", tri(p["Display Debug Info"]))
    oset(o, "pixelShift", tri(p["Pixel Shift"]))
    post("/set/settings", o, "settings")
end

Commands.SET_MQTT = function(p)
    local o = newObj()
    oset(o, "displayMqttStatusChange", tri(p["Display Status Changes"]))
    local broker = nz(p["Broker"])
    if broker then
        local cfg = newObj()
        oset(cfg, "broker", broker)
        oset(cfg, "port", math.floor(num(p["Port"]) or 1883))
        oset(cfg, "user", nz(p["User"]))
        oset(cfg, "password", nz(p["Password"]))
        oset(o, "mqttConfig", cfg)
    end
    post("/set/mqtt", o, "mqtt settings")
end

Commands.SEND_RAW_JSON = function(p)
    local path = nz(p["Endpoint"])
    local body = nz(p["JSON"])
    if not path or not body then
        errlog("Send Raw JSON: Endpoint and JSON are required")
        return
    end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    enqueue({ method = "POST", path = path, body = expand(body), label = "raw " .. path })
end

--------------------------------------------------------------------------------
-- Programming actions (buttons on the driver's Actions tab)
--------------------------------------------------------------------------------
local Actions = {}

Actions.TEST_NOTIFICATION = function()
    sendNotification({
        title = "Control4", message = "TvNotify test notification - {TIME}",
        smallIcon = "mdi:home-automation", smallIconColor = "#03A9F4",
    })
end

Actions.TEST_FIXED = function()
    sendFixed({ id = "c4_test", message = "Control4 test", icon = "mdi:home-automation",
                expiration = "30" })
end

Actions.REMOVE_TEST_FIXED = function() removeFixed("c4_test") end
Actions.REMOVE_ALL_FIXED  = function() removeAllFixed() end

Actions.BACKGROUND_OFF = function()
    Commands.SET_OVERLAY({ ["Background Visibility"] = "0", ["Clock Visibility"] = "-1" })
end

Actions.REPEAT_LAST = function()
    if not LastNotify then
        errlog("Nothing to repeat yet")
        return
    end
    enqueue({ method = "POST", path = LastNotify.path, body = LastNotify.body,
              label = "repeat notification", event = "Notification Sent" })
end

Actions.REFRESH_TV_LIST = function()
    ProxyMap = nil
    refreshTvList()
    local host = resolveTvHost(true)
    print("[TvNotify] TV driver list refreshed; TV endpoint address: " .. tostring(host or "not found"))
end

Actions.DUMP_CAMERA_INFO = function()
    ProxyMap = nil
    local ok, devs = pcall(function() return C4:GetDevicesByC4iName("camera.c4i") end)
    local rows = {}
    if ok and type(devs) == "table" then
        for k, info in pairs(devs) do
            local id = tonumber(k)
            if id then rows[#rows + 1] = { id = id, name = (type(info) == "table" and (info.deviceName or info.name)) or devName(id) } end
        end
    end
    table.sort(rows, function(x, y) return x.id < y.id end)
    diag("==== TvNotify: cameras in this project (camera.c4i) ====")
    if #rows == 0 then diag("  none found") end
    for _, r in ipairs(rows) do
        local nvrId, nvrBind, linkName = findNvrLink(r.id)
        local label = linkName or (nvrId and nvrBind and bindingLabel(nvrId, nvrBind)) or nil
        local ck = detectMake(r.id)
        diag(string.format("  camera id %s '%s'  -> NVR %s binding %s '%s'  make %s", r.id, tostring(r.name),
             tostring(nvrId), tostring(nvrBind), tostring(label), tostring(ck or "?")))
    end
    if rows[1] then Commands.DUMP_CAMERA_INFO({ ["Camera"] = tostring(rows[1].id) }) end
end

Actions.LIST_DEVICES = function()
    ProxyMap = nil
    diag("==== TV and camera devices in this project ====")
    for _, c4i in ipairs({ "tv.c4i", "camera.c4i" }) do
        local ok, devs = pcall(function() return C4:GetDevicesByC4iName(c4i) end)
        local n = 0
        if ok and type(devs) == "table" then
            for k, info in pairs(devs) do
                local id = type(info) == "number" and info or tonumber(k)
                local name = type(info) == "table" and (info.deviceName or info.name) or (type(info) == "string" and info) or devName(id)
                diag(string.format("  %-11s id %s  %s", c4i, tostring(id), tostring(name)))
                n = n + 1
            end
        end
        if n == 0 then diag("  " .. c4i .. ": none found (or lookup not available)") end
    end
    diag("==== end ====")
end

Actions.DUMP_TV_INFO = function()
    diag("==== TvNotify TV diagnostics (passwords hidden) ====")
    local id = selectedTvId()
    if id then dumpDevice(id, "tv driver", 0) else diag("No TV Driver selected") end
    local h = resolveTvHost(true)
    diag("RESULT: TV address = " .. tostring(h) .. (HostSource and (" (found via " .. HostSource .. ")") or "") .. (HostErr and ("   (" .. HostErr .. ")") or ""))
    diag("==== end ====")
end

Actions.CHECK_CONNECTION = function()
    if not baseUrl() then
        setStatus(notConfigured())
        return
    end
    setStatus("Checking...")
    enqueue({ method = "GET", path = "/", isCheck = true })
end

function ExecuteCommand(strCommand, tParams)
    tParams = tParams or {}
    dbg("ExecuteCommand", tostring(strCommand))

    if strCommand == "TVN_LATEST_RELEASE" then       -- sent by the TvNotify Controller after its daily check
        pcall(function() C4:PersistSetValue("ControllerReleaseAt", os.time()) end)
        setLatest(tParams.TAG)
        return
    end

    if strCommand == "LUA_ACTION" then
        local a = Actions[normalize(tParams.ACTION)]
        if a then a() else errlog("Unknown action: " .. tostring(tParams.ACTION)) end
        return
    end

    local c = Commands[normalize(strCommand)]
    if c then
        local ok, err = pcall(c, tParams)
        if not ok then errlog("Command " .. tostring(strCommand) .. " failed: " .. tostring(err)) end
    else
        dbg("Unhandled command", tostring(strCommand))
    end
end

--------------------------------------------------------------------------------
-- Driver lifecycle
--------------------------------------------------------------------------------
local function setDebug(mode)
    if DebugTimer then DebugTimer:Cancel(); DebugTimer = nil end
    DebugMode = mode or "Off"
    if DebugMode ~= "Off" then
        out("Debug enabled (" .. DebugMode .. ") - turns itself off after 8 hours")
        DebugTimer = C4:SetTimer(8 * 60 * 60 * 1000, function()
            DebugTimer = nil
            DebugMode = "Off"
            setProp("Debug Mode", "Off")
        end)
    end
end

function OnDriverInit()
    math.randomseed(os.time())
    C4:AddVariable("ONLINE", "0", "BOOL")
    C4:AddVariable("LAST_HTTP_CODE", "0", "NUMBER")
    C4:AddVariable("LAST_RESULT", "", "STRING")
    C4:AddVariable("LAST_TITLE", "", "STRING")
    C4:AddVariable("LAST_MESSAGE", "", "STRING")
    C4:AddVariable("NOTIFICATION_COUNT", "0", "NUMBER")
    C4:AddVariable("LAST_BADGE_ID", "", "STRING")
end

-- v52: Address Method / Login Method replace "Use Default Authentication?". Once, on the first start after the
-- upgrade, a filled-in IP address / login keeps working by switching the method to Specify Below.
local function migrateMethods()
    local ok, done = pcall(function() return C4:PersistGetValue("MethodsMigrated") end)
    if ok and done then return end
    if nz(Properties["NVR/Camera IP Address"]) and Properties["Address Method"] ~= "Specify Below" then
        setProp("Address Method", "Specify Below")
        print("[TvNotify] Address Method set to Specify Below (an NVR/Camera IP Address was already entered)")
    end
    if (nz(Properties["NVR/Camera Username"]) or nz(Properties["NVR/Camera Password"])) and Properties["Login Method"] ~= "Specify Below" then
        setProp("Login Method", "Specify Below")
        print("[TvNotify] Login Method set to Specify Below (a username / password was already entered)")
    end
    pcall(function() C4:PersistSetValue("MethodsMigrated", true) end)
end

-- v54: Default Small Icon Color became TvOverlay Default / Custom + a colour picker; an older hex value moves to the picker
local function migrateSmallIconColor()
    local v = nz(Properties["Default Small Icon Color"])
    if not v or v == "TvOverlay Default" or v == "Custom" then return end
    local hex = toHexColor(v)
    if hex and #hex >= 7 then
        local h = hex:sub(-6)
        setProp("Default Small Icon Custom Color", string.format("%d,%d,%d", tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16)))
        setProp("Default Small Icon Color", "Custom")
        print("[TvNotify] Default Small Icon Color " .. v .. " moved to the colour picker (Custom)")
    else
        setProp("Default Small Icon Color", "TvOverlay Default")
    end
end

function OnDriverLateInit()
    setProp("Driver Version", DRIVER_VERSION)
    restoreLatest()
    restoreBadges()
    migrateMethods()
    migrateSmallIconColor()
    setDebug(Properties["Debug Mode"])
    SentCount = 0
    setProp("Notifications Sent", 0)
    setStatus("Starting...")
    refreshTvList()
    resolveTvHost(true)
    updateVisibility()
    startHeartbeat()
    C4:SetTimer(3000, function() checkConnection() end)
    startUpdateChecks()
end

function OnDriverDestroyed()
    if DebugTimer then DebugTimer:Cancel() end
    if Heartbeat  then Heartbeat:Cancel()  end
    if Watchdog   then Watchdog:Cancel()   end
    for id in pairs(BadgeTimers) do cancelExpiry(id) end
    if Update.first then Update.first:Cancel() end
    if Update.timer then Update.timer:Cancel() end
end

function OnPropertyChanged(strProperty)
    local v = Properties[strProperty]
    if strProperty == "Debug Mode" then
        setDebug(v)
    elseif strProperty == "TV Driver" or strProperty == "Manual IP Address (fallback)" or strProperty == "TV Port" then
        HostCache.host = nil
        ProxyMap = nil
        DiagDone = {}
        Online = nil
        resolveTvHost(true)
        updateVisibility()
        setStatus("Checking...")
        checkConnection()
    elseif strProperty == "Login Method" or strProperty == "Address Method" or strProperty == "Default Vendor" or strProperty == "Default Small Icon Color" then
        updateVisibility()
    elseif strProperty == "Connection Check Interval (min)" then
        startHeartbeat()
    end
end

--------------------------------------------------------------------------------
-- Conditionals (driver.xml <conditionals>; also shown on Composer's Loops tab).
-- TestCondition(name, tParams) must return a boolean. NUMBER / STRING give tParams.VALUE and tParams.LOGIC.
--------------------------------------------------------------------------------
local compare = Common.compare

function TestCondition(name, tParams)
    tParams = tParams or {}
    if name == "TV_ONLINE" then
        return Online == true
    elseif name == "BADGE_ON_SCREEN" then
        local want = tostring(tParams.VALUE or ""):match("^%s*(.-)%s*$")
        local found = false
        for _, id in ipairs(badgesOnScreen()) do if id == want then found = true end end
        if tostring(tParams.LOGIC or "EQUAL"):upper() == "NOT_EQUAL" then return not found end
        return found
    elseif name == "LAST_BADGE_ID" then
        local same = LastBadgeId == tostring(tParams.VALUE or ""):match("^%s*(.-)%s*$")
        if tostring(tParams.LOGIC or "EQUAL"):upper() == "NOT_EQUAL" then return not same end
        return same
    elseif name == "BADGES_ON_SCREEN" then
        return compare(tParams.LOGIC, #badgesOnScreen(), tonumber(tParams.VALUE) or 0)
    end
    return false
end
