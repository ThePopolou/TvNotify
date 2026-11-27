--------------------------------------------------------------------------------
-- TvNotify Controller  -  Control4 DriverWorks driver by popolou
--
-- Broadcasts TvOverlay (app) commands to up to 12 "TvNotify" TV drivers that
-- are connected to this driver's bindings in Composer Pro (Connections tab).
-- Every command has a "Targets" parameter: All Members, one member, or a named subgroup.
-- Shows each member's online status and keeps online-count variables / events.
--
-- Lua 5.1 compatible.
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
local nz        = Common.nz
local normalize = Common.normalize

local MAX_MEMBERS   = 12
local MAX_SUBGROUPS = 6

-- web page bookkeeping: fixed badges this Controller put on TVs, and recent sends
local Badges       = {}    -- ordered list: { id = "...", message = "...", members = {1, 3}, label = "Upstairs", profile = n, expiresAt = epoch or nil }
local BadgeSeq     = 0
local MutedMembers = {}    -- [memberIndex] = true (persisted; whole-house mute = all bound members muted)
local sendWebUrl           -- defined with the web view code below
local History      = {}    -- newest first: { t = "16:31", what = "...", to = "Upstairs", n = 2 }

-- the TV Notifications page is updated when something it shows changes (no timed refresh of the page);
-- assigned with the web view code below
local pushIfChanged = function() end
local updateExperienceButton = function() end
local flashExperienceConfirm = function() end

local BadgeTimers = {}    -- badge id -> timer that removes it from "On screen now" when it expires

--------------------------------------------------------------------------------
-- Programming: LAST_ variables, Message Sent and badge events (0.1.2)
-- The LAST_ values are kept with PersistSetValue so they survive a restart; variables are set before the event fires.
--------------------------------------------------------------------------------
local Last = { LAST_PROFILE = "0", LAST_SOURCE = "", LAST_TYPE = "", LAST_TITLE = "", LAST_MESSAGE = "", LAST_TARGETS = "",
               LAST_BADGE_PROFILE = "0" }
local LAST_TYPES = { LAST_PROFILE = "NUMBER", LAST_BADGE_PROFILE = "NUMBER" }
local LAST_ORDER = { "LAST_PROFILE", "LAST_SOURCE", "LAST_TYPE", "LAST_TITLE", "LAST_MESSAGE", "LAST_TARGETS", "LAST_BADGE_PROFILE" }
local MsgEventAt = nil    -- os.time() of the last Message Sent event (loop guard)

local function restoreLast()
    local ok, v = pcall(function() return C4:PersistGetValue("LastValues") end)
    if ok and type(v) == "table" then for k in pairs(Last) do if v[k] ~= nil then Last[k] = tostring(v[k]) end end end
end

local function setLast(t)
    for k, v in pairs(t) do
        Last[k] = tostring(v or "")
        pcall(function() C4:SetVariable(k, Last[k]) end)
    end
    pcall(function() C4:PersistSetValue("LastValues", Last) end)
end

-- time / date tokens as the room drivers fill them in ({DEVICE} differs per TV, so it is left as typed)
local function fillTokens(s)
    if s == nil or not tostring(s):find("{", 1, true) then return s end
    local now = os.time()
    local map = { TIME = os.date("%H:%M", now), TIME12 = os.date("%I:%M %p", now), DATE = os.date("%Y-%m-%d", now),
                  DAY = os.date("%A", now), DATETIME = os.date("%Y-%m-%d %H:%M", now) }
    return (tostring(s):gsub("{(%u[%u%d]*)}", function(k) return map[k] end))
end

-- a message went out: info = { profile = n or 0, source = "Page" | "Programming", type = ..., title, message, targets }
local function messageSent(info)
    setLast({ LAST_PROFILE = info.profile or 0, LAST_SOURCE = info.source, LAST_TYPE = info.type,
              LAST_TITLE = fillTokens(info.title) or "", LAST_MESSAGE = fillTokens(info.message) or "",
              LAST_TARGETS = info.targets or "" })
    local summary = nz(info.title) or nz(info.message) or info.type or "Notification"
    if info.targets == "All TVs" or info.wholeHouse then
        flashExperienceConfirm(summary)
    end
    -- loop guard: a message sent by programming within 2 s of the last Message Sent event (i.e. by the
    -- programming that event started) updates the variables but does not fire the event again
    local now = os.time()
    if info.source == "Programming" and MsgEventAt and now - MsgEventAt < 2 then
        C4:DebugLog("[TvNotify Controller] Message Sent not fired again (sent by Message Sent programming)")
        return
    end
    MsgEventAt = now
    C4:FireEvent("Message Sent")
end

local function badgeEvent(profile, ...)
    if not profile then return end            -- only profile badges have events
    setLast({ LAST_BADGE_PROFILE = profile })
    for _, e in ipairs({ ... }) do C4:FireEvent(e) end
end

local function saveBadges()
    pcall(function() C4:PersistSetValue("ActiveBadges", Badges) end)
end

local function cancelBadgeTimer(id)
    if BadgeTimers[id] then BadgeTimers[id]:Cancel(); BadgeTimers[id] = nil end
end

-- remove a badge from "On screen now"; reason "expired" fires Badge Expired as well as Badge Cleared
local function untrackBadge(id, reason)
    local profile = nil
    local removed = false
    for i = #Badges, 1, -1 do
        if Badges[i].id == id then
            profile = profile or Badges[i].profile
            table.remove(Badges, i)
            removed = true
        end
    end
    cancelBadgeTimer(id)
    if removed then saveBadges() end
    updateExperienceButton()
    pushIfChanged()
    if reason == "expired" then badgeEvent(profile, "Badge Expired", "Badge Cleared")
    elseif profile then badgeEvent(profile, "Badge Cleared") end
end

local function armBadgeExpiry(id, at)
    cancelBadgeTimer(id)
    at = tonumber(at)
    if not at then return end
    local left = at - os.time()
    if left <= 0 then left = 1 end
    BadgeTimers[id] = C4:SetTimer(math.min(left, Common.MAX_TIMER_SEC) * 1000, function()
        BadgeTimers[id] = nil
        if left > Common.MAX_TIMER_SEC then return armBadgeExpiry(id, at) end
        untrackBadge(id, "expired")
    end)
end

local function restoreBadges()
    local ok, v = pcall(function() return C4:PersistGetValue("ActiveBadges") end)
    if not ok or type(v) ~= "table" then return end
    local now, changed = os.time(), false
    Badges = {}
    for _, b in ipairs(v) do
        if type(b) == "table" and b.id then
            local at = tonumber(b.expiresAt)
            if at and at <= now then
                changed = true
            else
                Badges[#Badges + 1] = b
                if at then armBadgeExpiry(b.id, at) end
            end
        end
    end
    if changed then saveBadges() end
end

local function saveMuted()
    pcall(function() C4:PersistSetValue("MutedMembers", MutedMembers) end)
end

local function restoreMuted()
    local ok, v = pcall(function() return C4:PersistGetValue("MutedMembers") end)
    if ok and type(v) == "table" then
        MutedMembers = {}
        for k, flag in pairs(v) do
            local idx = tonumber(k)
            if idx and flag == true then MutedMembers[idx] = true end
        end
    end
end

local function trackBadge(id, message, list, label, expiration, profile)
    for i = #Badges, 1, -1 do if Badges[i].id == id then table.remove(Badges, i) end end
    cancelBadgeTimer(id)
    local nums = {}
    for _, t in ipairs(list) do nums[#nums + 1] = t[1] end
    local at = Common.expiresAt(expiration)
    Badges[#Badges + 1] = { id = id, message = message or id, members = nums, label = label, profile = profile, expiresAt = at }
    saveBadges()
    if at then armBadgeExpiry(id, at) end
    updateExperienceButton()
    pushIfChanged()
    badgeEvent(profile, "Badge Shown")
end

-- programming removed badges: untrack those whose TVs were all included. id = nil -> every badge.
local function untrackRemoved(list, id)
    local sent = {}
    for _, t in ipairs(list) do sent[t[1]] = true end
    local gone = {}
    for _, b in ipairs(Badges) do
        if id == nil or b.id == id then
            local all = true
            for _, m in ipairs(b.members) do if not sent[m] then all = false end end
            if all then gone[#gone + 1] = b.id end
        end
    end
    for _, g in ipairs(gone) do untrackBadge(g) end
end

local function remember(what, label, count)
    table.insert(History, 1, { t = os.date("%H:%M"), what = what, to = label, n = count })
    while #History > 20 do table.remove(History) end
    pushIfChanged()
end
local DebugMode   = "Off"
local DebugTimer  = nil

local function dbg(...)
    if DebugMode == "Off" then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local msg = "[TvNotify Controller] " .. table.concat(parts, " ")
    if DebugMode == "Print" or DebugMode == "Print and Log" then print(msg) end
    if DebugMode == "Log" or DebugMode == "Print and Log" then
        if C4.DebugLog then C4:DebugLog(msg) else C4:ErrorLog(msg) end
    end
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
local function updateAvailable() return UpdateChecker.available() end
local function restoreLatest() UpdateChecker.restore() end
local function checkForUpdate(done) UpdateChecker.check(done) end

-- Commands that may be forwarded to member TVs
local FORWARD = {
    SEND_NOTIFICATION = true, SEND_ALERT = true, SEND_CAMERA_NOTIFICATION = true,
    SEND_FIXED_NOTIFICATION = true, REMOVE_FIXED_NOTIFICATION = true,
    REMOVE_ALL_FIXED_NOTIFICATIONS = true, SET_OVERLAY = true,
    SET_NOTIFICATION_SETTINGS = true,
}

-- Group actions that are forwarded as-is (same command keys as the TV driver)
local ACTIONS = {
    TEST_NOTIFICATION = true,
    TEST_FIXED        = true,
    REMOVE_TEST_FIXED = true,
    BACKGROUND_OFF    = true,
    REMOVE_ALL_FIXED  = true,
    REPEAT_LAST       = true,
    CHECK_CONNECTION  = true,
}

-- how many members the user asked for (property "Number of TV Members")
local function memberCount()
    local n = math.floor(tonumber(Properties["Number of TV Members"]) or MAX_MEMBERS)
    if n < 1 then n = 1 end
    if n > MAX_MEMBERS then n = MAX_MEMBERS end
    return n
end

local function memberDevice(i)
    local id = C4:GetBoundProviderDevice(C4:GetDeviceID(), i)
    if id and id ~= 0 then return id end
    return nil
end

-- subgroups ------------------------------------------------------------------
local function subgroupCount()
    local n = math.floor(tonumber(Properties["Number of Subgroups"]) or 0)
    if n < 0 then n = 0 end
    if n > MAX_SUBGROUPS then n = MAX_SUBGROUPS end
    return n
end

-- "1, 3;4" -> { [1]=true, [3]=true, [4]=true }   (only members within the member count)
local function subgroupMembers(k)
    local set, max = {}, memberCount()
    for num in tostring(Properties["Subgroup " .. k .. " Members"] or ""):gmatch("%d+") do
        local n = tonumber(num)
        if n >= 1 and n <= max then set[n] = true end
    end
    return set
end

local function subgroupName(k)
    local n = tostring(Properties["Subgroup " .. k .. " Name"] or "")
    n = n:gsub("^%s+", ""):gsub("%s+$", "")
    if n == "" then n = "Subgroup " .. k end
    return n
end

-- display name of a profile target ("All Members" / "Member N" / "Subgroup K")
local function targetName(t)
    t = tostring(t or "All Members")
    local k = t:match("^Subgroup (%d+)$")
    if k then
        k = tonumber(k)
        if k > subgroupCount() then return "Subgroup " .. k .. " (not set up)" end
        return subgroupName(k)
    end
    local i = t:match("^Member (%d+)$")
    if i then
        i = tonumber(i)
        local d = (i <= memberCount()) and memberDevice(i) or nil
        if not d then return "Member " .. i .. " (no TV connected)" end
        local name = ""
        pcall(function() name = C4:GetDeviceDisplayName(d) or "" end)
        return name ~= "" and name or ("Member " .. i)
    end
    return "All TVs"
end

-- Profile Targets dropdown entry for a stored target, e.g. "Member 2 - Lounge TV" (no commas: the list is comma-separated)
local function targetLabel(t)
    t = tostring(t or "All Members")
    if t == "All Members" then return "All TVs" end
    local name = targetName(t)
    local label = name:find("^" .. t) and name or (t .. " - " .. name)
    return (label:gsub(",", " "))
end

-- dropdown entry (or a stored value) -> stored target
local function targetFromLabel(l)
    l = tostring(l or "")
    return l:match("^(Member %d+)") or l:match("^(Subgroup %d+)") or "All Members"
end

local runProfile
local function targets(sel)
    sel = tostring(sel or "All Members")
    local n = sel:match("^Member (%d+)$")
    local k = sel:match("^Subgroup (%d+)$")
    local list = {}
    if n then
        n = tonumber(n)
        local d = (n <= memberCount()) and memberDevice(n) or nil
        if d then list[1] = { n, d } end
    elseif k then
        k = tonumber(k)
        if k >= 1 and k <= subgroupCount() then
            local set = subgroupMembers(k)
            for i = 1, memberCount() do
                local d = set[i] and memberDevice(i) or nil
                if d then list[#list + 1] = { i, d } end
            end
        end
    else
        for i = 1, memberCount() do
            local d = memberDevice(i)
            if d then list[#list + 1] = { i, d } end
        end
    end
    return list
end

-- profiles ---------------------------------------------------------------------
-- One editor on the properties page ("Profile to Edit" + the fields below it); every profile is
-- stored with PersistSetValue so it survives reboots and driver updates.  "Send Profile N" builds the
-- matching TV command from the stored profile and sends it to the profile's Targets.
local MAX_PROFILES = 20

-- field names are the TV driver's command parameter names, so a profile maps 1:1 onto a command
local PROFILE_TYPES = {
    ["Notification"] = { cmd = "SEND_NOTIFICATION", fields = { "Title", "Message", "Source", "Image", "Video URL",
                         "Large Icon", "Small Icon", "Small Icon Color", "Corner", "Duration (sec)", "Notification ID" } },
    ["Alert"]        = { cmd = "SEND_ALERT", fields = { "Alert Type", "Title", "Message", "Corner", "Duration (sec)", "Notification ID" } },
    ["Camera"]       = { cmd = "SEND_CAMERA_NOTIFICATION", fields = { "Title", "Message", "Camera", "Output", "Camera Vendor", "Snapshot URL",
                         "Stream URL", "Corner", "Duration (sec)", "Notification ID" } },
    ["Fixed"]        = { cmd = "SEND_FIXED_NOTIFICATION", fields = { "Fixed Notification ID", "Message", "Icon", "Message Color",
                         "Icon Color", "Border Color", "Background Color", "Shape", "Expiration" } },
    ["Set Overlay"]  = { cmd = "SET_OVERLAY", fields = { "Background Visibility", "Clock Visibility", "Hot Corner" } },
    ["Set Notification Settings"] = { cmd = "SET_NOTIFICATION_SETTINGS", fields = { "Display Notifications",
                         "Display Fixed Notifications", "Layout Name", "Notification Duration (sec)", "Fixed Notification Visibility" } },
}

-- every editor field (union of the above, page order) and its default
local PROFILE_FIELDS = {
    { "Title", "" }, { "Message", "" }, { "Source", "" }, { "Alert Type", "Information" }, { "Camera", "None" }, { "Output", "Snapshot" }, { "Camera Vendor", "Use Default" },
    { "Snapshot URL", "" }, { "Stream URL", "" }, { "Image", "" }, { "Video URL", "" }, { "Large Icon", "" },
    { "Small Icon", "" }, { "Small Icon Color", "" }, { "Corner", "Use Default" }, { "Duration (sec)", "0" },
    { "Notification ID", "" }, { "Fixed Notification ID", "" }, { "Icon", "" }, { "Message Color", "" },
    { "Icon Color", "" }, { "Border Color", "" }, { "Background Color", "" }, { "Shape", "Default" }, { "Expiration", "" },
    { "Background Visibility", "-1" }, { "Clock Visibility", "-1" }, { "Hot Corner", "Unchanged" },
    { "Display Notifications", "Unchanged" }, { "Display Fixed Notifications", "Unchanged" }, { "Layout Name", "" },
    { "Notification Duration (sec)", "-1" }, { "Fixed Notification Visibility", "-2" },
}
local IS_FIELD = {}
for _, f in ipairs(PROFILE_FIELDS) do IS_FIELD[f[1]] = f[2] end
-- Colour fields are stored in the profile as hex ("" = default) and edited as a dropdown
-- (the field itself: default option / Custom) plus a colour picker ("R,G,B"), and Opacity for the background.
local COLOR_EDIT = {
    ["Small Icon Color"] = { default = "Use TV Default", picker = "Small Icon Custom Color", rgb = "3,169,244" },
    ["Message Color"]    = { default = "Use Default", picker = "Message Custom Color", rgb = "255,255,255" },
    ["Icon Color"]       = { default = "No Tint", picker = "Icon Custom Color", rgb = "255,255,255" },
    ["Border Color"]     = { default = "Use Default", picker = "Border Custom Color", rgb = "255,255,255" },
    ["Background Color"] = { default = "Use Default", picker = "Background Custom Color", rgb = "0,0,0", opacity = "Background Opacity" },
}
local COLOR_PART = {}          -- picker / opacity property -> its colour field
for f, c in pairs(COLOR_EDIT) do
    COLOR_PART[c.picker] = f
    if c.opacity then COLOR_PART[c.opacity] = f end
end
local OPACITY_LEVELS = { 100, 80, 60, 40, 20, 0 }

-- "#RRGGBB" / "#AARRGGBB" -> "R,G,B", opacity label ("100%" for 6 digits); nil if not hex
local function hexToEditor(hex)
    local h = tostring(hex or ""):match("^%s*#?(%x+)%s*$")
    if not h or (#h ~= 6 and #h ~= 8) then return nil end
    local a = 255
    if #h == 8 then a = tonumber(h:sub(1, 2), 16); h = h:sub(3) end
    local rgb = string.format("%d,%d,%d", tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16))
    local pct, best = a / 255 * 100, 100
    for _, l in ipairs(OPACITY_LEVELS) do if math.abs(l - pct) < math.abs(best - pct) then best = l end end
    return rgb, best .. "%"
end

-- "R,G,B" (+ opacity label) -> "#RRGGBB" / "#AARRGGBB"
local function editorToHex(rgb, opacity)
    local r, g, b = tostring(rgb or ""):match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
    if not r then
        local h = tostring(rgb or ""):match("^%s*#?(%x%x%x%x%x%x)%s*$")
        if not h then return nil end
        r, g, b = tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16)
    end
    local function c(x) x = tonumber(x) or 0; if x > 255 then x = 255 end; return x end
    local hex = string.format("%02X%02X%02X", c(r), c(g), c(b))
    local pct = tonumber(tostring(opacity or ""):match("(%d+)"))
    if pct and pct < 100 then return "#" .. string.format("%02X", math.floor(pct / 100 * 255 + 0.5)) .. hex end
    return "#" .. hex
end

local HEADER_FIELDS = { { "Profile Name", "" }, { "Profile Type", "Notification" }, { "Profile Targets", "All Members" } }

local Profiles = nil          -- [n] = { ["Profile Name"]=..., ["Profile Type"]=..., Title=..., ... }
local Loading  = false        -- true while the editor is being filled (ignore OnPropertyChanged)

local function loadProfiles()
    if Profiles then return Profiles end
    local ok, v = pcall(function() return C4:PersistGetValue("Profiles") end)
    Profiles = (ok and type(v) == "table") and v or {}
    return Profiles
end

local function saveProfiles()
    pcall(function() C4:PersistSetValue("Profiles", Profiles or {}) end)
    pushIfChanged()
end

local function profileCount()
    local n = math.floor(tonumber(Properties["Number of Profiles"]) or 5)
    if n < 1 then n = 1 end
    if n > MAX_PROFILES then n = MAX_PROFILES end
    return n
end

local function editIndex()
    local n = math.floor(tonumber(Properties["Profile to Edit"]) or 1)
    if n < 1 then n = 1 end
    if n > MAX_PROFILES then n = MAX_PROFILES end
    return n
end

local function pget(prof, field)
    local v = prof and prof[field]
    if v == nil then v = IS_FIELD[field] end
    if v == nil then
        for _, h in ipairs(HEADER_FIELDS) do if h[1] == field then v = h[2] end end
    end
    return v
end

local function short(s, n)
    s = tostring(s or "")
    if #s > n then s = s:sub(1, n - 3) .. "..." end
    return s
end

local function profileSummary(n)
    local p = loadProfiles()[n]
    if not p or not p["Profile Type"] then return "(not set up)" end
    local t = p["Profile Type"]
    local name = nz(p["Profile Name"]) or ("Profile " .. n)
    local what
    if t == "Set Overlay" then
        what = "background " .. pget(p, "Background Visibility") .. " | clock " .. pget(p, "Clock Visibility") .. " | hot corner " .. pget(p, "Hot Corner")
    elseif t == "Set Notification Settings" then
        what = "popups " .. pget(p, "Display Notifications") .. " | fixed " .. pget(p, "Display Fixed Notifications")
    else
        local parts = {}
        if t == "Alert" then parts[#parts + 1] = pget(p, "Alert Type") end
        if t == "Camera" then parts[#parts + 1] = tostring(pget(p, "Camera")):gsub(" %(id %d+%)", "") end
        if nz(p["Title"]) and t ~= "Fixed" then parts[#parts + 1] = '"' .. short(p["Title"], 30) .. '"' end
        if nz(p["Message"]) then parts[#parts + 1] = '"' .. short(p["Message"], 40) .. '"' end
        what = table.concat(parts, " | ")
    end
    local out = { name, t }
    if what ~= "" then out[#out + 1] = what end
    out[#out + 1] = targetName(pget(p, "Profile Targets"))
    return short(table.concat(out, " | "), 160)
end

local function updateSummaries()
    for n = 1, MAX_PROFILES do
        C4:UpdateProperty("Profile " .. n .. " Summary", profileSummary(n))
    end
end

-- show only the editor fields used by the type being edited
local function updateEditorVisibility()
    local t = Properties["Profile Type"] or "Notification"
    local used = {}
    for _, f in ipairs((PROFILE_TYPES[t] or PROFILE_TYPES["Notification"]).fields) do used[f] = true end
    for _, f in ipairs(PROFILE_FIELDS) do
        pcall(function() C4:SetPropertyAttribs(f[1], used[f[1]] and 0 or 1) end)
    end
    for f, c in pairs(COLOR_EDIT) do
        local show = used[f] and Properties[f] == "Custom"
        pcall(function() C4:SetPropertyAttribs(c.picker, show and 0 or 1) end)
        if c.opacity then pcall(function() C4:SetPropertyAttribs(c.opacity, show and 0 or 1) end) end
    end
    local c = profileCount()
    for n = 1, MAX_PROFILES do
        pcall(function() C4:SetPropertyAttribs("Profile " .. n .. " Summary", n <= c and 0 or 1) end)
    end
end

-- Profile Targets is a dynamic list: All TVs, the connected members and the subgroups, by name
-- (DriverWorks API: C4:UpdatePropertyList(strName, strValueList, strValueDefault), comma-separated, default must be in the list)
local TargetListCache = nil
local function refreshTargetList(force)
    local cur = targetFromLabel(pget(loadProfiles()[editIndex()] or {}, "Profile Targets"))
    local items, seen = { "All TVs" }, { ["All Members"] = true }
    for i = 1, memberCount() do
        local t = "Member " .. i
        if memberDevice(i) or cur == t then items[#items + 1] = targetLabel(t); seen[t] = true end
    end
    for k = 1, subgroupCount() do
        local t = "Subgroup " .. k
        items[#items + 1] = targetLabel(t); seen[t] = true
    end
    if not seen[cur] then items[#items + 1] = targetLabel(cur) end
    local list, def = table.concat(items, ","), targetLabel(cur)
    if not force and TargetListCache == list .. "|" .. def then return end
    TargetListCache = list .. "|" .. def
    pcall(function() C4:UpdatePropertyList("Profile Targets", list, def) end)
end

-- fill the editor with the stored values of the profile being edited
local function loadEditor()
    local p = loadProfiles()[editIndex()] or {}
    Loading = true
    for _, h in ipairs(HEADER_FIELDS) do
        if h[1] == "Profile Targets" then refreshTargetList(true)
        else C4:UpdateProperty(h[1], tostring(pget(p, h[1]))) end
    end
    for _, f in ipairs(PROFILE_FIELDS) do
        local c = COLOR_EDIT[f[1]]
        if c then
            local rgb, op = hexToEditor(pget(p, f[1]))
            C4:UpdateProperty(f[1], rgb and "Custom" or c.default)
            C4:UpdateProperty(c.picker, rgb or c.rgb)
            if c.opacity then C4:UpdateProperty(c.opacity, rgb and op or "40%") end
        else
            C4:UpdateProperty(f[1], tostring(pget(p, f[1])))
        end
    end
    Loading = false
    updateEditorVisibility()
end

-- an editor property changed: store it in the profile being edited
local function editorChanged(name)
    if Loading then return false end
    local cf = COLOR_EDIT[name] and name or COLOR_PART[name]
    if cf then
        local c = COLOR_EDIT[cf]
        local hex = ""
        if Properties[cf] == "Custom" then
            hex = editorToHex(Properties[c.picker], c.opacity and Properties[c.opacity]) or ""
        end
        local all = loadProfiles()
        local n = editIndex()
        all[n] = all[n] or {}
        all[n][cf] = hex
        if not all[n]["Profile Type"] then all[n]["Profile Type"] = Properties["Profile Type"] or "Notification" end
        saveProfiles()
        updateEditorVisibility()
        dbg("profile", n, "field", cf, "=", hex == "" and "(default)" or hex)
        return true
    end
    local isHeader = false
    for _, h in ipairs(HEADER_FIELDS) do if h[1] == name then isHeader = true end end
    if not isHeader and IS_FIELD[name] == nil then return false end
    local all = loadProfiles()
    local n = editIndex()
    local value = Properties[name]
    if name == "Profile Targets" then
        value = targetFromLabel(value)
        -- an unchanged value (e.g. the list being refreshed) is not a user edit
        if value == pget(all[n] or {}, "Profile Targets") then return true end
    end
    all[n] = all[n] or {}
    all[n][name] = value
    if not all[n]["Profile Type"] then all[n]["Profile Type"] = Properties["Profile Type"] or "Notification" end
    saveProfiles()
    C4:UpdateProperty("Profile " .. n .. " Summary", profileSummary(n))
    if name == "Profile Type" then updateEditorVisibility() end
    dbg("profile", n, "field", name, "=", tostring(Properties[name]))
    return true
end

local CachedCameras = nil
local function queryCameras()
    local rows = {}
    local ok, devs = pcall(function() return C4:GetDevicesByC4iName("camera.c4i") end)
    if ok and type(devs) == "table" then
        for k, info in pairs(devs) do
            local id = tonumber(k)
            local name = type(info) == "table" and (info.deviceName or info.name) or (type(info) == "string" and info or nil)
            if id then rows[#rows + 1] = { id = id, name = (name and name ~= "") and name or ("Camera " .. id) } end
        end
        table.sort(rows, function(a, b) return a.id < b.id end)
    end
    CachedCameras = rows
    return rows
end

-- fill the "Camera" editor dropdown with the camera drivers in the project
local function refreshCameraList()
    local items = { "None" }
    local rows = queryCameras()
    for _, r in ipairs(rows) do items[#items + 1] = (tostring(r.name):gsub(",", " ")) .. " (id " .. r.id .. ")" end
    local cur, def = tostring(Properties["Camera"] or ""), "None"
    for _, it in ipairs(items) do if it == cur then def = it end end
    pcall(function() C4:UpdatePropertyList("Camera", table.concat(items, ","), def) end)
    dbg("camera list:", #items - 1, "camera(s)")
    print("[TvNotify Controller] Camera list refreshed: " .. (#items - 1) .. " camera(s)")
    pushIfChanged()
end

local function sendTo(list, cmd, params)
    for _, t in ipairs(list) do
        dbg(cmd, "-> member", t[1], "device", t[2])
        C4:SendToDevice(t[2], cmd, params)
    end
end

-- "Send Profile" / "Clear Profile Badge" -> returns ok, message
runProfile = function(cmd, tParams, source)
    local n = math.floor(tonumber(tostring(tParams.Profile or ""):match("(%d+)")) or 0)
    if n < 1 or n > profileCount() then
        local err = "Profile " .. tostring(tParams.Profile) .. " is not available (Number of Profiles = " .. profileCount() .. ")"
        C4:ErrorLog("[TvNotify Controller] " .. err)
        return false, err
    end
    local p = loadProfiles()[n]
    if not p or not p["Profile Type"] then
        local err = "Profile " .. n .. " has not been set up"
        C4:ErrorLog("[TvNotify Controller] " .. err)
        return false, err
    end
    local list = targets(pget(p, "Profile Targets"))
    if #list == 0 then
        local err = "No connected TV for target '" .. targetName(pget(p, "Profile Targets")) .. "'"
        C4:ErrorLog("[TvNotify Controller] Profile " .. n .. ": " .. err)
        return false, err
    end
    local ptype = PROFILE_TYPES[p["Profile Type"]] and p["Profile Type"] or "Notification"

    if cmd == "CLEAR_PROFILE_BADGE" then
        if ptype ~= "Fixed" then
            local err = "Profile " .. n .. " is not a Fixed profile"
            C4:ErrorLog("[TvNotify Controller] " .. err)
            return false, err
        end
        local bid = nz(p["Fixed Notification ID"]) or ("profile-" .. n)
        sendTo(list, "REMOVE_FIXED_NOTIFICATION", { ["Fixed Notification ID"] = bid })
        untrackBadge(bid)
        return true, "Cleared " .. (nz(p["Profile Name"]) or ("Profile " .. n))
    end

    local def = PROFILE_TYPES[ptype]
    local params = {}
    for _, f in ipairs(def.fields) do
        local v = pget(p, f)
        if f == "Camera" then v = tostring(v or ""):match("%(id (%d+)%)") end
        if nz(v) then params[f] = tostring(v) end
    end
    if def.fields[#def.fields] == "Notification ID" and not params["Notification ID"] then params["Notification ID"] = "profile-" .. n end
    if ptype == "Fixed" and not params["Fixed Notification ID"] then params["Fixed Notification ID"] = "profile-" .. n end
    dbg("Send Profile", n, tostring(p["Profile Name"]), ptype)
    sendTo(list, def.cmd, params)
    local label = pget(p, "Profile Targets")
    local sg = tostring(label):match("^Subgroup (%d+)$")
    if sg then label = subgroupName(tonumber(sg)) elseif label == "All Members" then label = "All TVs" end
    if ptype == "Fixed" then trackBadge(params["Fixed Notification ID"], params["Message"], list, label, params["Expiration"], n) end
    local pname = nz(p["Profile Name"]) or ("Profile " .. n)
    remember(pname .. " (profile " .. n .. ")", label, #list)
    local mtype = ({ Notification = "Notification", Alert = "Alert", Camera = "Camera", Fixed = "Badge" })[ptype]
    if mtype then
        messageSent({ profile = n, source = source or "Programming", type = mtype,
                      title = params["Title"], message = params["Message"], targets = label })
    end
    return true, "Sent " .. pname .. ((#list > 1) and (" (" .. #list .. " TVs)") or "")
end


-- Actions-tab profile tools ----------------------------------------------------
local ArmedDelete = nil       -- { what = "one" | "all", n = profile, at = tick }
local CONFIRM_SEC = 10

local function armed(what, n)
    local now = os.time()
    if ArmedDelete and ArmedDelete.what == what and ArmedDelete.n == n and (now - ArmedDelete.at) <= CONFIRM_SEC then
        ArmedDelete = nil
        return true
    end
    ArmedDelete = { what = what, n = n, at = now }
    return false
end

local function say(msg)
    print("[TvNotify Controller] " .. msg)
    C4:ErrorLog("[TvNotify Controller] " .. msg)
    C4:UpdateProperty("Profile Status", os.date("%H:%M:%S") .. "  " .. msg)
end

local ProfileActions = {}

ProfileActions.DELETE_PROFILE = function()
    local n = editIndex()
    local p = loadProfiles()[n]
    local label = "Profile " .. n .. ((p and nz(p["Profile Name"])) and (" (" .. p["Profile Name"] .. ")") or "")
    if not armed("one", n) then
        say("Press again within " .. CONFIRM_SEC .. " s to delete " .. label)
        return
    end
    loadProfiles()[n] = nil
    saveProfiles()
    loadEditor()
    C4:UpdateProperty("Profile " .. n .. " Summary", profileSummary(n))
    say(label .. " deleted")
end

ProfileActions.DELETE_ALL_PROFILES = function()
    if not armed("all", 0) then
        say("Press again within " .. CONFIRM_SEC .. " s to delete ALL profiles")
        return
    end
    Profiles = {}
    saveProfiles()
    loadEditor()
    updateSummaries()
    say("All profiles deleted")
end

ProfileActions.COPY_PROFILE = function()
    local from = editIndex()
    local all = loadProfiles()
    local src = all[from]
    if not src or not src["Profile Type"] then
        say("Profile " .. from .. " has not been set up - nothing to copy")
        return
    end
    local to = nil
    for n = 1, MAX_PROFILES do
        if n ~= from and not (all[n] and all[n]["Profile Type"]) then to = n; break end
    end
    if not to then
        say("No empty profile slot to copy into (all " .. MAX_PROFILES .. " are in use)")
        return
    end
    local copy = {}
    for k, v in pairs(src) do copy[k] = v end
    copy["Profile Name"] = (nz(src["Profile Name"]) or ("Profile " .. from)) .. " (copy)"
    if nz(copy["Notification ID"]) then copy["Notification ID"] = nil end          -- the copy gets its own profile-N id
    if nz(copy["Fixed Notification ID"]) then copy["Fixed Notification ID"] = nil end
    all[to] = copy
    saveProfiles()
    if to > profileCount() then
        C4:UpdateProperty("Number of Profiles", tostring(to))
        updateEditorVisibility()
    end
    C4:UpdateProperty("Profile " .. to .. " Summary", profileSummary(to))
    C4:UpdateProperty("Profile to Edit", tostring(to))
    loadEditor()
    say("Profile " .. from .. " copied to Profile " .. to .. " (now being edited)")
end

function ExecuteCommand(strCommand, tParams)
    tParams = tParams or {}

    if strCommand == "LUA_ACTION" then
        local a = normalize(tParams.ACTION)
        if a == "REFRESH_CAMERA_LIST" then return refreshCameraList() end
        if ProfileActions[a] then return ProfileActions[a]() end
        if not ACTIONS[a] then return end
        for _, t in ipairs(targets("All Members")) do
            dbg("action ->", t[1], t[2], a)
            C4:SendToDevice(t[2], "LUA_ACTION", { ACTION = a })
        end
        if a == "REMOVE_ALL_FIXED" then untrackRemoved(targets("All Members"), nil) end
        return
    end

    local cmd = normalize(strCommand)
    if cmd == "SEND_PROFILE" or cmd == "CLEAR_PROFILE_BADGE" then
        return runProfile(cmd, tParams)
    end
    if not FORWARD[cmd] then
        dbg("Unhandled command", tostring(strCommand))
        return
    end

    local params = {}
    for k, v in pairs(tParams) do
        if k ~= "Targets" then params[k] = v end
    end

    local list = targets(tParams["Targets"])
    if #list == 0 then
        C4:ErrorLog("[TvNotify Controller] " .. tostring(strCommand) .. ": no bound TV drivers for target '"
                    .. tostring(tParams["Targets"]) .. "'")
        return
    end
    if cmd == "SEND_FIXED_NOTIFICATION" and not nz(params["Fixed Notification ID"]) then
        BadgeSeq = BadgeSeq + 1
        params["Fixed Notification ID"] = "prog-" .. os.time() .. "-" .. BadgeSeq
    end
    for _, t in ipairs(list) do
        dbg(cmd, "-> member", t[1], "device", t[2])
        C4:SendToDevice(t[2], cmd, params)
    end
    local label = tostring(tParams["Targets"] or "All Members")
    local sg = label:match("^Subgroup (%d+)")
    if sg then label = subgroupName(tonumber(sg))
    elseif label == "All Members" or label == "" then label = "All TVs"
    else label = label:gsub("^Member %d+ %- ", "") end
    if cmd == "SEND_FIXED_NOTIFICATION" then
        trackBadge(params["Fixed Notification ID"], nz(params["Message"]), list, label, params["Expiration"], nil)
    elseif cmd == "REMOVE_FIXED_NOTIFICATION" then untrackRemoved(list, nz(params["Fixed Notification ID"]))
    elseif cmd == "REMOVE_ALL_FIXED_NOTIFICATIONS" then untrackRemoved(list, nil) end
    local mtype = ({ SEND_NOTIFICATION = "Notification", SEND_ALERT = "Alert", SEND_CAMERA_NOTIFICATION = "Camera",
                     SEND_FIXED_NOTIFICATION = "Badge" })[cmd]
    if mtype then
        messageSent({ profile = 0, source = "Programming", type = mtype, title = params["Title"], message = params["Message"], targets = label })
    end
end

-- member status ---------------------------------------------------------------
local OnlineState = {}          -- [i] = true / false / nil (unknown)
local Listening   = {}          -- [deviceId] = varId once a variable listener is registered
local Primed      = false       -- no events for the very first reading

local function truthy(v)
    v = tostring(v):lower()
    return v == "1" or v == "true" or v == "on"
end

-- ONLINE variable of a TV driver:  true / false / nil
local function readOnline(deviceId)
    local ok, vars = pcall(function() return C4:GetDeviceVariables(deviceId) end)
    if not ok or type(vars) ~= "table" then return nil end
    for k, v in pairs(vars) do
        if type(v) == "table" and v.name == "ONLINE" then
            local varId = tonumber(k)
            if not Listening[deviceId] and varId then
                local reg = pcall(function() C4:RegisterVariableListener(deviceId, varId) end)
                if reg then Listening[deviceId] = varId end
            end
            return truthy(v.value)
        end
    end
    return nil
end

local function unlistenDevice(deviceId)
    deviceId = tonumber(deviceId)
    if not deviceId then return end
    local varId = Listening[deviceId]
    if varId then
        pcall(function() C4:UnregisterVariableListener(deviceId, varId) end)
        Listening[deviceId] = nil
    end
end

local function memberNames(i)
    local names = {}
    for k = 1, subgroupCount() do
        if subgroupMembers(k)[i] then names[#names + 1] = subgroupName(k) end
    end
    return #names > 0 and (" [" .. table.concat(names, ", ") .. "]") or ""
end

local function refreshMember(i)
    local d = (i <= memberCount()) and memberDevice(i) or nil
    local label = "Not bound"
    if d then
        local name = ""
        pcall(function() name = C4:GetDeviceDisplayName(d) or "" end)
        local on = readOnline(d)
        local st = (on == true) and "Online" or (on == false and "Offline" or "Status unknown")
        label = (name ~= "" and name or "Device") .. " (id " .. d .. ") - " .. st .. memberNames(i)
        local prev = OnlineState[i]
        OnlineState[i] = on
        if Primed and on ~= nil and prev ~= nil and on ~= prev then
            C4:SetVariable("LAST_CHANGED_MEMBER", name ~= "" and name or ("Member " .. i))
            C4:FireEvent(on and "Member Online" or "Member Offline")
        end
    else
        OnlineState[i] = nil
    end
    C4:UpdateProperty("Member " .. i, label)
    return d, OnlineState[i]
end

local AllWasOnline = nil

-- No status poll: each room driver's ONLINE variable has a listener (OnWatchedVariableChanged).
-- A listener can only be set once that variable exists (documented), so while a bound room driver has
-- no listener yet (e.g. it is still starting), try again every 30 s, at most 20 times.
local refreshAll                -- defined below
local ListenTimer, ListenTries = nil, 0
local LISTEN_RETRY_MS, LISTEN_MAX_TRIES = 30 * 1000, 20
local function scheduleListenRetry(bound)
    local missing = false
    for i = 1, math.min(memberCount(), MAX_MEMBERS) do
        local d = memberDevice(i)
        if d and not Listening[d] then missing = true end
    end
    if not missing or bound == 0 then ListenTries = 0; return end
    if ListenTimer or ListenTries >= LISTEN_MAX_TRIES then return end
    ListenTries = ListenTries + 1
    ListenTimer = C4:SetTimer(LISTEN_RETRY_MS, function() ListenTimer = nil; refreshAll() end)
end

-- TV / subgroup names shown in Profile Targets and the Profile summaries: refresh both when a name changes
local NamesSig = nil
local function refreshTargetNames()
    local parts = {}
    for i = 1, memberCount() do parts[#parts + 1] = targetName("Member " .. i) end
    for k = 1, subgroupCount() do parts[#parts + 1] = targetName("Subgroup " .. k) end
    local sig = table.concat(parts, "\n")
    refreshTargetList(false)
    if sig ~= NamesSig then
        NamesSig = sig
        updateSummaries()
    end
end

local function updateTotalsAndEvents(bound, online)
    local all = (bound > 0 and online == bound)
    C4:SetVariable("MEMBERS_BOUND", tostring(bound))
    C4:SetVariable("MEMBERS_ONLINE", tostring(online))
    C4:SetVariable("ALL_ONLINE", all and "1" or "0")
    local st
    if bound == 0 then st = "No room drivers bound"
    else st = online .. " of " .. bound .. " online" end
    setStatus(st)
    if Primed and AllWasOnline ~= nil and AllWasOnline ~= all then
        C4:FireEvent(all and "All Members Online" or "Not All Members Online")
    end
    AllWasOnline = all
    Primed = true
    updateExperienceButton()
    return st
end

function refreshAll()
    local bound, online = 0, 0
    for i = 1, MAX_MEMBERS do
        local d, on = refreshMember(i)
        if d then
            bound = bound + 1
            if on == true then online = online + 1 end
        end
    end
    local st = updateTotalsAndEvents(bound, online)
    scheduleListenRetry(bound)
    dbg("status:", st)
    refreshTargetNames()
    pushIfChanged()
end

-- show one "Member N" entry per requested member, one block per requested subgroup
local function updateVisibility()
    local n, s = memberCount(), subgroupCount()
    for i = 1, MAX_MEMBERS do
        pcall(function() C4:SetPropertyAttribs("Member " .. i, i <= n and 0 or 1) end)
    end
    for k = 1, MAX_SUBGROUPS do
        local hide = (k > s) and 1 or 0
        pcall(function() C4:SetPropertyAttribs("Subgroup " .. k .. " Name", hide) end)
        pcall(function() C4:SetPropertyAttribs("Subgroup " .. k .. " Members", hide) end)
    end
end

-- Update check (Controller): GitHub once a minute after start-up, then once a day; the result is passed on
-- to every connected room driver so they need not ask GitHub themselves.
local function sendReleaseTo(dev)
    if dev and Update.latest then C4:SendToDevice(dev, "TVN_LATEST_RELEASE", { TAG = Update.latest }) end
end

local function sendReleaseToMembers()
    for i = 1, math.min(memberCount(), MAX_MEMBERS) do sendReleaseTo(memberDevice(i)) end
end

local function runUpdateCheck()
    checkForUpdate(function()
        sendReleaseToMembers()
        pushIfChanged()
    end)
end

local function startUpdateChecks()
    UpdateChecker.cancel()
    Update.first = C4:SetTimer(60 * 1000, function() Update.first = nil; runUpdateCheck() end)
    Update.timer = C4:SetTimer(Common.UPDATE_DAY_MS, function() runUpdateCheck() end, true)
end

function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
    if idBinding >= 1 and idBinding <= MAX_MEMBERS then
        if not bIsBound then unlistenDevice(otherDeviceId) end
        ListenTries = 0; refreshAll()
        if bIsBound then sendReleaseTo(tonumber(otherDeviceId)) end
    end
end

-- a TV driver's ONLINE variable changed: update only the matching member(s) instead of re-querying all 12
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
    local devId = tonumber(idDevice)
    local matched = false
    local bound, online = 0, 0
    for i = 1, MAX_MEMBERS do
        local d = (i <= memberCount()) and memberDevice(i) or nil
        if d then
            bound = bound + 1
            if d == devId then
                matched = true
                local on = truthy(strValue)
                local name = ""
                pcall(function() name = C4:GetDeviceDisplayName(d) or "" end)
                local st = on and "Online" or "Offline"
                local label = (name ~= "" and name or "Device") .. " (id " .. d .. ") - " .. st .. memberNames(i)
                local prev = OnlineState[i]
                OnlineState[i] = on
                C4:UpdateProperty("Member " .. i, label)
                if Primed and prev ~= nil and on ~= prev then
                    C4:SetVariable("LAST_CHANGED_MEMBER", name ~= "" and name or ("Member " .. i))
                    C4:FireEvent(on and "Member Online" or "Member Offline")
                end
            end
            if OnlineState[i] == true then online = online + 1 end
        end
    end
    if not matched then return refreshAll() end
    local st = updateTotalsAndEvents(bound, online)
    dbg("status:", st)
    pushIfChanged()
end

local function setDebug(mode)
    if DebugTimer then DebugTimer:Cancel(); DebugTimer = nil end
    DebugMode = mode or "Off"
    if DebugMode ~= "Off" then
        DebugTimer = C4:SetTimer(8 * 60 * 60 * 1000, function()
            DebugTimer = nil
            DebugMode = "Off"
            C4:UpdateProperty("Debug Mode", "Off")
        end)
    end
end

function OnDriverInit()
    C4:AddVariable("MEMBERS_BOUND", "0", "NUMBER")
    C4:AddVariable("MEMBERS_ONLINE", "0", "NUMBER")
    C4:AddVariable("ALL_ONLINE", "0", "BOOL")
    C4:AddVariable("LAST_CHANGED_MEMBER", "", "STRING")
    restoreLast()
    for _, k in ipairs(LAST_ORDER) do C4:AddVariable(k, Last[k], LAST_TYPES[k] or "STRING") end
end


-- TV Notifications web view --------------------------------------------------------------
-- The Controller's Experience Button (uibutton proxy) opens www/web/index.html, served by the
-- controller's own web server. The page talks to this driver through the Control4 web view
-- channel: C4.sendCommand(cmd, json, false, true) arrives in UIRequest() below, and the reply
-- (plus SendDataToUI pushes) reaches the page's onDataToUi(). No extra network port is used.
local UI_BINDING = 5001
local WebUrl     = nil
local UrlTimer   = nil

local WEB_ALERTS = { "Information", "Success", "Warning", "Error", "Doorbell", "Motion", "Security",
                     "Fire / Smoke", "Water Leak", "Door Open", "Garage", "Phone Call", "Package", "Reminder" }
local WEB_CORNERS = { "Use Default", "Bottom Left", "Bottom Right", "Top Left", "Top Right" }

-- tiny JSON encoder: tables with ._arr = true (or a [1]) are arrays
local function jenc(v)
    local t = type(v)
    if v == nil then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then return tostring(v)
    elseif t == "string" then
        -- ASCII-only JSON: apostrophes, &, <, >, control and non-ASCII characters become \uXXXX escapes, so nothing in
        -- the text can upset the Navigator's XML / JSON handling (an apostrophe in a TV name stopped the iOS app's page, v61)
        local out, i, n = {}, 1, #v
        while i <= n do
            local c, cp, len = v:byte(i), nil, 1
            if c < 0x80 then cp = c
            elseif c >= 0xF0 and i + 3 <= n then
                cp = (c % 8) * 262144 + (v:byte(i + 1) % 64) * 4096 + (v:byte(i + 2) % 64) * 64 + (v:byte(i + 3) % 64); len = 4
            elseif c >= 0xE0 and i + 2 <= n then
                cp = (c % 16) * 4096 + (v:byte(i + 1) % 64) * 64 + (v:byte(i + 2) % 64); len = 3
            elseif c >= 0xC0 and i + 1 <= n then
                cp = (c % 32) * 64 + (v:byte(i + 1) % 64); len = 2
            else cp = 0xFFFD end
            if cp == 34 then out[#out + 1] = '\\"'
            elseif cp == 92 then out[#out + 1] = "\\\\"
            elseif cp >= 0x10000 then
                local x = cp - 0x10000
                out[#out + 1] = string.format("\\u%04x\\u%04x", 0xD800 + math.floor(x / 1024), 0xDC00 + x % 1024)
            elseif cp < 0x20 or cp > 0x7E or cp == 39 or cp == 38 or cp == 60 or cp == 62 then
                out[#out + 1] = string.format("\\u%04x", cp)
            else out[#out + 1] = string.char(cp) end
            i = i + len
        end
        return '"' .. table.concat(out) .. '"'
    elseif t == "table" then
        local out = {}
        if v._arr or v[1] ~= nil then
            for _, x in ipairs(v) do out[#out + 1] = jenc(x) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do out[#out + 1] = jenc(k) .. ":" .. jenc(v[k]) end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return "null"
end
local function A(t) t = t or {}; t._arr = true; return t end

local function webCameras()
    local rows = A()
    local list = CachedCameras or queryCameras()
    for _, c in ipairs(list) do rows[#rows + 1] = { id = c.id, name = c.name } end
    return rows
end

local function webTargetLabel(t)
    return targetName(t)
end

local function allBoundMuted()
    local bound = 0
    for i = 1, math.min(memberCount(), MAX_MEMBERS) do
        if memberDevice(i) then
            bound = bound + 1
            if not MutedMembers[i] then return false end
        end
    end
    return bound > 0
end

local function webState()
    local badgeCounts = {}
    for _, b in ipairs(Badges) do
        for _, m in ipairs(b.members or {}) do
            badgeCounts[m] = (badgeCounts[m] or 0) + 1
        end
    end
    local s = { version = DRIVER_VERSION, update = updateAvailable() or "", muted = allBoundMuted(),
                members = A(), subgroups = A(), profiles = A(), cameras = webCameras(),
                badges = A(), history = A(), alerts = A(), corners = A() }
    for _, a in ipairs(WEB_ALERTS) do s.alerts[#s.alerts + 1] = a end
    for _, c in ipairs(WEB_CORNERS) do s.corners[#s.corners + 1] = c end
    local bound, online = 0, 0
    for i = 1, memberCount() do
        local d = memberDevice(i)
        if d then
            local name = ""
            pcall(function() name = C4:GetDeviceDisplayName(d) or "" end)
            s.members[#s.members + 1] = {
                n = i,
                name = (name ~= "") and name or ("Member " .. i),
                online = OnlineState[i],
                muted = MutedMembers[i] == true,
                badges = badgeCounts[i] or 0,
            }
            bound = bound + 1
            if OnlineState[i] == true then online = online + 1 end
        end
    end
    s.bound, s.online = bound, online
    for k = 1, subgroupCount() do
        local set, nums = subgroupMembers(k), A()
        for i = 1, memberCount() do if set[i] and memberDevice(i) then nums[#nums + 1] = i end end
        s.subgroups[#s.subgroups + 1] = { k = k, name = subgroupName(k), members = nums }
    end
    local all = loadProfiles()
    for n = 1, profileCount() do
        local p = all[n]
        if p and p["Profile Type"] then
            s.profiles[#s.profiles + 1] = { n = n, name = nz(p["Profile Name"]) or ("Profile " .. n),
                                            type = p["Profile Type"], targets = webTargetLabel(pget(p, "Profile Targets")) }
        end
    end
    for n = 1, MAX_PROFILES do
        if not (all[n] and all[n]["Profile Type"]) then s.nextSlot = n; break end
    end
    for _, b in ipairs(Badges) do s.badges[#s.badges + 1] = { id = b.id, message = b.message, label = b.label } end
    for _, h in ipairs(History) do s.history[#s.history + 1] = h end
    return s
end

-- "all" | "sg:K" | "m:1,3,4"  ->  member list { {n, deviceId}, ... }, label
local function webTargets(sel)
    sel = tostring(sel or "all")
    if sel == "all" then return targets("All Members"), "All TVs" end
    local k = sel:match("^sg:(%d+)$")
    if k then return targets("Subgroup " .. k), subgroupName(tonumber(k)) end
    local list, names = {}, {}
    for num in (sel:match("^m:(.*)$") or ""):gmatch("%d+") do
        local i = tonumber(num)
        local d = (i >= 1 and i <= memberCount()) and memberDevice(i) or nil
        if d then
            list[#list + 1] = { i, d }
            local name = ""
            pcall(function() name = C4:GetDeviceDisplayName(d) or "" end)
            names[#names + 1] = (name ~= "") and name or ("Member " .. i)
        end
    end
    return list, (#names <= 2) and table.concat(names, ", ") or (#names .. " TVs")
end

local function webSend(f)
    local list, label = webTargets(f.targets)
    if #list == 0 then return false, "No connected TV in that selection" end
    local t = f.type or "notification"
    local title, message = nz(f.title), nz(f.message)
    local corner = nz(f.corner) or "Use Default"
    local duration = tostring(math.floor(tonumber(f.duration) or 0))
    local cmd, p, what
    if t == "alert" then
        cmd = "SEND_ALERT"
        p = { ["Alert Type"] = nz(f.alertType) or "Information", Title = title, Message = message, Corner = corner, ["Duration (sec)"] = duration }
        what = (nz(f.alertType) or "Alert") .. ": " .. (title or message or "")
    elseif t == "camera" then
        local cam = tonumber(f.camera)
        if not cam then return false, "Choose a camera" end
        cmd = "SEND_CAMERA_NOTIFICATION"
        p = { Camera = tostring(cam), Output = nz(f.output) or "Snapshot", Title = title, Message = message, Corner = corner, ["Duration (sec)"] = duration }
        what = "Camera: " .. (title or message or ("camera " .. cam))
    elseif t == "badge" then
        if not message then return false, "Enter the badge text in Message" end
        cmd = "SEND_FIXED_NOTIFICATION"
        BadgeSeq = BadgeSeq + 1
        local id = "web-" .. os.time() .. "-" .. BadgeSeq
        local exp = math.floor(tonumber(f.expire) or 0)
        p = { ["Fixed Notification ID"] = id, Message = message, Expiration = (exp > 0) and tostring(exp) or nil }
        what = "Badge: " .. message
        trackBadge(id, message, list, label, p.Expiration)
    else
        if not title and not message then return false, "Type a message first" end
        cmd = "SEND_NOTIFICATION"
        p = { Title = title, Message = message, Corner = corner, ["Duration (sec)"] = duration }
        what = title or message
    end
    sendTo(list, cmd, p)
    remember(what, label, #list)
    messageSent({ profile = 0, source = "Page", type = ({ alert = "Alert", camera = "Camera", badge = "Badge" })[t] or "Notification",
                  title = p.Title, message = p.Message, targets = label })
    return true, "Sent to " .. label .. ((#list > 1) and (" (" .. #list .. " TVs)") or "")
end

-- the ticked TVs ("m:1,3") as a profile target: All Members, one Subgroup or one Member.
-- Offline TVs cannot be ticked on the page, so they are allowed to be missing from a match.
local function webProfileTarget(sel)
    local picked, n = {}, 0
    for num in (tostring(sel or ""):match("^m:(.*)$") or ""):gmatch("%d+") do
        local i = tonumber(num)
        if i and memberDevice(i) and not picked[i] then picked[i] = true; n = n + 1 end
    end
    if n == 0 then return nil end
    local function candidate(set)                 -- exact, relaxed (only offline TVs missing), or nil
        local exact = true
        for i in pairs(picked) do if not set[i] then return nil end end
        for i in pairs(set) do
            if not picked[i] then
                if OnlineState[i] ~= false then return nil end
                exact = false
            end
        end
        return exact and "exact" or "relaxed"
    end
    local allSet, groups = {}, {}
    for i = 1, memberCount() do if memberDevice(i) then allSet[i] = true end end
    for k = 1, subgroupCount() do
        local set = {}
        for i in pairs(subgroupMembers(k)) do if memberDevice(i) then set[i] = true end end
        groups[k] = set
    end
    local single = nil
    if n == 1 then for i in pairs(picked) do single = i end end
    -- exact matches first: all, a subgroup, one TV; then matches that only leave out offline TVs
    for _, want in ipairs({ "exact", "relaxed" }) do
        if candidate(allSet) == want then return "All Members" end
        for k = 1, subgroupCount() do if next(groups[k]) and candidate(groups[k]) == want then return "Subgroup " .. k end end
        if single and want == "exact" then return "Member " .. single end
    end
    if single then return "Member " .. single end
    return nil
end

local WEB_PROFILE_TYPE = { notification = "Notification", alert = "Alert", camera = "Camera", badge = "Fixed" }

local function webSaveProfile(f)
    local t = WEB_PROFILE_TYPE[tostring(f.type or "")]
    if not t then return false, "Unknown message type" end
    local target = webProfileTarget(f.targets)
    if not target then return false, "Profiles can target all TVs, one TV or a subgroup - adjust Send to" end
    local name = nz(f.name)
    if not name then return false, "Enter a profile name" end
    local all = loadProfiles()
    local n
    if tostring(f.slot or "next") == "next" then
        for i = 1, MAX_PROFILES do
            if not (all[i] and all[i]["Profile Type"]) then n = i; break end
        end
        if not n then return false, "All " .. MAX_PROFILES .. " profiles are in use - choose one to replace" end
    else
        n = math.floor(tonumber(f.slot) or 0)
        if n < 1 or n > MAX_PROFILES then return false, "Unknown profile number" end
        if all[n] and all[n]["Profile Type"] and not f.confirm then
            return false, "Replaces '" .. (nz(all[n]["Profile Name"]) or ("Profile " .. n)) .. "' - tap Save again to confirm"
        end
    end
    local title, message = nz(f.title), nz(f.message)
    local corner = nz(f.corner) or "Use Default"
    local duration = tostring(math.floor(tonumber(f.duration) or 0))
    local p = { ["Profile Name"] = name, ["Profile Type"] = t, ["Profile Targets"] = target }
    if t == "Fixed" then
        if not message then return false, "Enter the badge text in Message" end
        p.Message = message
        local exp = math.floor(tonumber(f.expire) or 0)
        if exp > 0 then p.Expiration = tostring(exp) end
    else
        p.Title, p.Message, p.Corner, p["Duration (sec)"] = title or "", message or "", corner, duration
        if t == "Alert" then p["Alert Type"] = nz(f.alertType) or "Information" end
        if t == "Camera" then
            local cam = tonumber(f.camera)
            if not cam then return false, "Choose a camera" end
            local cname = "Camera " .. cam
            for _, c in ipairs(webCameras()) do if c.id == cam then cname = c.name end end
            p.Camera = (tostring(cname):gsub(",", " ")) .. " (id " .. cam .. ")"
            p.Output = nz(f.output) or "Snapshot"
            p["Camera Vendor"] = "Use Default"
        elseif not title and not message then
            return false, "Enter a title or message"
        end
    end
    all[n] = p
    saveProfiles()
    local raised = ""
    if n > profileCount() then
        C4:UpdateProperty("Number of Profiles", tostring(n))
        raised = " (Number of Profiles raised to " .. n .. ")"
    end
    updateSummaries()
    if editIndex() == n then loadEditor() else updateEditorVisibility() end
    dbg("web view saved profile", n, name, t, target)
    return true, "Saved as profile " .. n .. " - " .. name .. raised
end

local function xmlEsc(s)
    return (tostring(s):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&apos;" }))
end

-- every reply / push: <tvnotify>{"tvo":1,"state":{...},"result":{...}}</tvnotify>
local function uiPayload(result)
    return "<tvnotify>" .. xmlEsc(jenc({ tvo = 1, state = webState(), result = result })) .. "</tvnotify>"
end

local function pushState()
    pcall(function() C4:SendDataToUI(uiPayload(nil)) end)
end

-- send the state to an open page only when it differs from what was last sent
local LastPushed = nil
pushIfChanged = function()
    local ok, payload = pcall(uiPayload, nil)
    if not ok or payload == LastPushed then return end
    LastPushed = payload
    pcall(function() C4:SendDataToUI(payload) end)
end

-- parameters from the page: a table, or a JSON object string
local function uiParams(tParams)
    if type(tParams) ~= "table" then
        local ok, t = pcall(function() return C4:JsonDecode(tostring(tParams or "")) end)
        return (ok and type(t) == "table") and t or {}
    end
    if tParams.json or tParams.JSON then
        local ok, t = pcall(function() return C4:JsonDecode(tostring(tParams.json or tParams.JSON)) end)
        if ok and type(t) == "table" then return t end
    end
    return tParams
end

local function uiHandle(cmd, f)
    if cmd == "TVO_STATE" then
        queryCameras()              -- pick up newly added / renamed cameras
        refreshAll()                -- page opened: pick up renamed rooms / TVs (there is no status poll)
        return nil
    elseif cmd == "TVO_SEND" then
        local ok, text = webSend(f)
        return { ok = ok, text = text }
    elseif cmd == "TVO_SAVE_PROFILE" then
        local ok, text = webSaveProfile(f)
        return { ok = ok, text = text, saved = ok or nil }
    elseif cmd == "TVO_PROFILE" then
        local n = tonumber(f.n)
        local p = n and loadProfiles()[n]
        if not p then return { ok = false, text = "Unknown profile" } end
        local ok, text = runProfile("SEND_PROFILE", { Profile = tostring(n) }, "Page")
        return { ok = ok, text = text }
    elseif cmd == "TVO_MUTE" then
        local memberIdx = tonumber(f.member)
        if memberIdx then
            local d = (memberIdx >= 1 and memberIdx <= memberCount()) and memberDevice(memberIdx) or nil
            if not d then return { ok = false, text = "TV is not connected" } end
            local want = (f.muted ~= nil) and (f.muted == true or f.muted == "true") or (not MutedMembers[memberIdx])
            MutedMembers[memberIdx] = want or nil
            saveMuted()
            sendTo({ { memberIdx, d } }, "SET_NOTIFICATION_SETTINGS", { ["Display Notifications"] = want and "Off" or "On" })
            local name = targetName("Member " .. memberIdx)
            remember(want and "Muted" or "Unmuted", name, 1)
            updateExperienceButton()
            pushIfChanged()
            return { ok = true, text = name .. (want and " muted" or " unmuted") }
        end
        local list = targets("All Members")
        if #list == 0 then return { ok = false, text = "No connected TVs" } end
        local want = (f.muted ~= nil) and (f.muted == true or f.muted == "true") or (not allBoundMuted())
        for _, t in ipairs(list) do MutedMembers[t[1]] = want or nil end
        saveMuted()
        sendTo(list, "SET_NOTIFICATION_SETTINGS", { ["Display Notifications"] = want and "Off" or "On" })
        remember(want and "Notifications muted" or "Notifications unmuted", "All TVs", #list)
        updateExperienceButton()
        pushIfChanged()
        return { ok = true, text = want and "All TVs muted" or "All TVs unmuted" }
    elseif cmd == "TVO_CLEAR" then
        local id = f.id
        for _, b in ipairs(Badges) do
            if b.id == id then
                local list = {}
                for _, i in ipairs(b.members) do
                    local d = memberDevice(i)
                    if d then list[#list + 1] = { i, d } end
                end
                sendTo(list, "REMOVE_FIXED_NOTIFICATION", { ["Fixed Notification ID"] = id })
                untrackBadge(id)
                remember("Cleared: " .. tostring(b.message), b.label or "", #list)
                return { ok = true, text = "Cleared" }
            end
        end
        return { ok = false, text = "That badge is no longer listed" }
    end
    return { ok = false, text = "Unknown request " .. tostring(cmd) }
end

-- synchronous request from the web view
function UIRequest(strCommand, tParams)
    local cmd = tostring(strCommand or ""):upper()
    if cmd:sub(1, 4) ~= "TVO_" then return "" end
    local f = uiParams(tParams)
    dbg("web view", cmd)
    local ok, result = pcall(uiHandle, cmd, f)
    if not ok then
        C4:ErrorLog("[TvNotify Controller] web view error: " .. tostring(result))
        result = { ok = false, text = "Error - see the Controller's log" }
    end
    if type(result) == "table" and f.reqId ~= nil then
        result.reqId = f.reqId
    end
    local reply = uiPayload(result)
    if cmd ~= "TVO_STATE" then
        C4:SetTimer(300, function() pushIfChanged() end)     -- fallback for navigators that ignore the reply
    end
    return reply
end

-- the Experience Button was selected (web view opening): send fresh state
function ReceivedFromProxy(idBinding, strCommand, tParams)
    dbg("from proxy", idBinding, strCommand)
    if idBinding == UI_BINDING then pushState() end
end

--------------------------------------------------------------------------------
-- Whole-house UI Experience Button (binding 5001)
-- Because one Controller button appears identically in every room's Navigator,
-- its states are reserved strictly for whole-house conditions:
--   sent_confirm (4s flash on whole-house send) > muted (all TVs muted) >
--   all_offline (no TVs bound) > badge_active (same badge on every bound TV) >
--   idle_online (default calm state, including TVs in standby).
-- Per-TV status (online/standby, per-TV badges, per-TV mute) lives in the Advanced view.
--------------------------------------------------------------------------------
local LastUiIcon, LastUiDesc = nil, nil
local ConfirmTimer = nil
local ConfirmText  = nil

local function wholeHouseBadges(boundSet, boundCount)
    local out = {}
    if boundCount == 0 then return out end
    for _, b in ipairs(Badges) do
        local covered = 0
        for _, m in ipairs(b.members or {}) do
            if boundSet[m] then covered = covered + 1 end
        end
        if covered >= boundCount then out[#out + 1] = b end
    end
    return out
end

local function computeExperienceState()
    local boundSet, bound, online = {}, 0, 0
    for i = 1, math.min(memberCount(), MAX_MEMBERS) do
        if memberDevice(i) then
            boundSet[i] = true
            bound = bound + 1
            if OnlineState[i] == true then online = online + 1 end
        end
    end
    local staticLabel = (Properties["Experience Button Subtitle"] == "Static (TV Notifications)")

    if ConfirmText then
        return "sent_confirm", staticLabel and "TV Notifications" or ("Sent: " .. short(ConfirmText, 24))
    end
    if bound == 0 then
        return "all_offline", staticLabel and "TV Notifications" or "No TVs Connected"
    end
    if allBoundMuted() then
        return "muted", staticLabel and "TV Notifications" or "All TVs Muted"
    end
    local globalBadges = wholeHouseBadges(boundSet, bound)
    if #globalBadges > 0 then
        local desc
        if #globalBadges == 1 then
            desc = "Badge: " .. short(globalBadges[1].message or globalBadges[1].id, 22)
        else
            desc = #globalBadges .. " Whole-Home Badges"
        end
        return "badge_active", staticLabel and "TV Notifications" or desc
    end
    local desc
    if online == bound then
        desc = (bound == 1) and "1 TV Ready" or (bound .. " TVs Ready")
    else
        desc = online .. " of " .. bound .. " TVs Active"
    end
    return "idle_online", staticLabel and "TV Notifications" or desc
end

updateExperienceButton = function(force)
    local icon, desc = computeExperienceState()
    if not force and icon == LastUiIcon and desc == LastUiDesc then return end
    LastUiIcon, LastUiDesc = icon, desc
    pcall(function()
        C4:SendToProxy(UI_BINDING, "ICON_CHANGED", { icon = icon, icon_description = desc })
    end)
    dbg("experience button:", icon, "|", desc)
end

flashExperienceConfirm = function(text)
    if ConfirmTimer then ConfirmTimer:Cancel(); ConfirmTimer = nil end
    ConfirmText = text
    updateExperienceButton()
    ConfirmTimer = C4:SetTimer(4000, function()
        ConfirmTimer = nil
        ConfirmText = nil
        updateExperienceButton()
    end)
end

-- tell the Experience Button which page to open (controller://driver/<c4z name>/web/index.html)
sendWebUrl = function()
    local name = nil
    pcall(function() name = C4:GetDriverFileName() end)
    name = tostring(name or ""):gsub("%.c4z$", "")
    if name == "" then name = "tvnotify_controller" end
    WebUrl = "controller://driver/" .. name .. "/web/index.html"
    C4:UpdateProperty("Web View Address", WebUrl)
    if UrlTimer then UrlTimer:Cancel() end
    UrlTimer = C4:SetTimer(3000, function()
        UrlTimer = nil
        C4:SendToProxy(UI_BINDING, "URL_CHANGED", { url = WebUrl })
        updateExperienceButton(true)
        dbg("web view URL:", WebUrl)
    end)
end

function OnDriverLateInit()
    C4:UpdateProperty("Driver Version", DRIVER_VERSION)
    restoreLatest()
    restoreBadges()
    restoreMuted()
    setDebug(Properties["Debug Mode"])
    refreshCameraList()
    updateVisibility()
    loadEditor()
    updateSummaries()
    ListenTries = 0
    refreshAll()
    sendWebUrl()
    startUpdateChecks()
end

function OnDriverDestroyed()
    if DebugTimer then DebugTimer:Cancel() end
    if ListenTimer then ListenTimer:Cancel() end
    if UrlTimer then UrlTimer:Cancel() end
    if ConfirmTimer then ConfirmTimer:Cancel() end
    for id in pairs(BadgeTimers) do cancelBadgeTimer(id) end
    for devId in pairs(Listening) do unlistenDevice(devId) end
    UpdateChecker.cancel()
end

function OnPropertyChanged(strProperty)
    if strProperty == "Debug Mode" then setDebug(Properties[strProperty]) end
    if strProperty == "Experience Button Subtitle" then updateExperienceButton(true); return end
    if strProperty == "Profile to Edit" then loadEditor() end
    if strProperty == "Number of Profiles" then updateEditorVisibility() end
    if editorChanged(strProperty) then return end
    if strProperty == "Number of TV Members" or strProperty == "Number of Subgroups"
       or strProperty:match("^Subgroup %d+ ") then
        updateVisibility()
        refreshAll()
    end
end

--------------------------------------------------------------------------------
-- Conditionals (driver.xml <conditionals>; also shown on Composer's Loops tab).
-- TestCondition(name, tParams) must return a boolean. NUMBER / LIST give tParams.VALUE and tParams.LOGIC.
--------------------------------------------------------------------------------
local compare = Common.compare

-- LIST conditionals ask a yes/no question about the chosen item: EQUAL = yes, NOT_EQUAL = no
local function listAnswer(logic, yes)
    if tostring(logic or "EQUAL"):upper() == "NOT_EQUAL" then return not yes end
    return yes
end

function TestCondition(name, tParams)
    tParams = tParams or {}
    local logic, value = tParams.LOGIC, tParams.VALUE
    if name == "LAST_PROFILE_SENT" then
        return compare(logic, tonumber(Last.LAST_PROFILE) or 0, tonumber(value) or 0)
    elseif name == "LAST_BADGE_PROFILE" then
        return compare(logic, tonumber(Last.LAST_BADGE_PROFILE) or 0, tonumber(value) or 0)
    elseif name == "MEMBER_ONLINE" then
        local i = tonumber(tostring(value or ""):match("(%d+)"))
        local yes = i ~= nil and i <= memberCount() and memberDevice(i) ~= nil and OnlineState[i] == true
        return listAnswer(logic, yes)
    elseif name == "ALL_ONLINE" or name == "ONLINE_COUNT" then
        local bound, online = 0, 0
        for i = 1, math.min(memberCount(), MAX_MEMBERS) do
            if memberDevice(i) then
                bound = bound + 1
                if OnlineState[i] == true then online = online + 1 end
            end
        end
        if name == "ALL_ONLINE" then              -- LIST: "All online" / "Not all online"
            local all = bound > 0 and online == bound
            local want = tostring(value or "All online"):lower():find("not", 1, true) == nil
            return listAnswer(logic, all == want)
        end
        return compare(logic, online, tonumber(value) or 0)
    elseif name == "PROFILE_BADGE_ON" then
        local n = tonumber(tostring(value or ""):match("(%d+)"))
        local yes = false
        for _, b in ipairs(Badges) do if n and b.profile == n then yes = true end end
        return listAnswer(logic, yes)
    end
    return false
end
