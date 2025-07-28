-- VLC Lua Extension : SceneNavigator
-- Version           : 1.0
-- Author            : Ramees Sahlu M V

--------------------------------------------------
-- 1. Descriptor
--------------------------------------------------
function descriptor()
    return {
        title        = "SceneNavigator",
        version      = "1.0",
        author       = "Ramees Sahlu M V",
        shortdesc    = "Scene navigation with flexible timestamp parsing",
        description  = "Displays scenes from .scn files with timestamps parsed with optional milliseconds. Select a row and click Jump to seek.",
        capabilities = {}
    }
end

--------------------------------------------------
-- 2. Globals
--------------------------------------------------
local dlg, list, path_input, status_label
local scenes = {}

--------------------------------------------------
-- 3. Helpers
--------------------------------------------------
local function log(m)  vlc.msg.dbg("[SceneNav] " .. m) end
local function err(m)  vlc.msg.err("[SceneNav] " .. m) end

-- Parses times like "HH:MM:SS" or "HH:MM:SS,mmm"
local function hms_to_sec(t)
    local h, m, s, ms = t:match("(%d+):(%d+):(%d+),?(%d*)")
    if not h or not m or not s then return nil end
    ms = tonumber(ms) or 0
    return tonumber(h)*3600 + tonumber(m)*60 + tonumber(s) + ms/1000
end

local function fmt_time(sec)
    return string.format("%02d:%02d:%02d", sec/3600, (sec/60)%60, sec%60)
end

--------------------------------------------------
-- 4. Dialog creation
--------------------------------------------------
function activate()
    if dlg then return end

    dlg = vlc.dialog("SceneNavigator")
    dlg:add_button("Load .scn File",      load_scn_file,        1, 1, 2, 1)
    dlg:add_button("Jump to Scene",       jump_to_selected_scene, 3, 1, 2, 1)
    dlg:add_button("Close",               close,               5, 1, 1, 1)

    dlg:add_label("<i>Type or paste the path to your .scn file below:</i>", 1, 2, 5, 1)

    -- Try to guess the .scn file path from currently playing media
    local scn_path_guess = ""
    local item = vlc.input.item()
    if item then
        local uri = item:uri() or ""
        local path = vlc.strings.decode_uri(uri):gsub("^file://", "")

        -- Normalize for Windows drive letters (e.g., /C:/...) only if needed
        if path:match("^/[A-Z]:/") then
            path = path:sub(2)
        end

        if path ~= "" then
            scn_path_guess = path:gsub("%.[^%.\\/]+$", ".scn")
            log("Guessed SCN path: " .. scn_path_guess)
        end
    end

    path_input = dlg:add_text_input(scn_path_guess, 1, 3, 5, 1)
    list = dlg:add_list(1, 4, 5, 12)
    if list.set_callback then list:set_callback(nil) end
    list:add_value(string.format("%-4s %-10s %-10s %-30s", "ID", "Start", "End", "Title"), 0)
    status_label = dlg:add_label("", 1, 16, 5, 1)
end

function deactivate()
    if dlg then dlg:delete() end
    dlg, list, path_input, status_label = nil, nil, nil, nil
    scenes = {}
end

function close()
    vlc.deactivate()
end

--------------------------------------------------
-- 5. Load and parse .scn file, populate list
--------------------------------------------------
function load_scn_file()
    if not path_input then err("No input widget") return end

    local path = path_input:get_text()
    if not path or path == "" then
        err("File path required")
        if status_label then status_label:set_text("⚠️ File path required.") end
        return
    end

    local f, emsg = io.open(path, "r")
    if not f then
        err("Failed to open file: " .. emsg)
        list:clear()
        list:add_value(string.format("%-4s %-10s %-10s %-30s", "ID", "Start", "End", "Title"), 0)
        list:add_value("Could not open file.", 1)
        if status_label then status_label:set_text("❌ Failed to open SCN file.") end
        return
    end

    scenes = {}
    list:clear()
    list:add_value(string.format("%-4s %-10s %-10s %-30s", "ID", "Start", "End", "Title"), 0)

    local block = {}
    local function push_block(b)
        if #b < 3 then return end
        local id = tonumber(b[1])
        local times = b[2]
        local title = b[3]
        local sStr, eStr = times:match("^(.-)%s*%-%->%s*(.-)$")
        if not (id and sStr and eStr and title) then return end

        local start_sec = hms_to_sec(sStr)
        local end_sec   = hms_to_sec(eStr)
        if not start_sec or not end_sec then return end

        table.insert(scenes, {
            id       = id,
            title    = title,
            startSec = start_sec,
            endSec   = end_sec
        })
    end

    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line == "" then
            push_block(block)
            block = {}
        else
            table.insert(block, line)
        end
    end
    push_block(block)
    f:close()

    if #scenes == 0 then
        list:add_value("No valid scenes found.", 1)
        if status_label then status_label:set_text("⚠️ No valid scenes in SCN file.") end
        return
    end

    for i, sc in ipairs(scenes) do
        local rowvalue = string.format(
            "%-4d %-10s %-10s %-30s",
            sc.id,
            fmt_time(sc.startSec),
            fmt_time(sc.endSec),
            sc.title
        )
        list:add_value(rowvalue, i)
    end

    if status_label then
        status_label:set_text("✅ SCN file loaded with " .. #scenes .. " scene(s).")
    end
end

--------------------------------------------------
-- 6. Jump to selected scene
--------------------------------------------------
function jump_to_selected_scene()
    if not list then
        vlc.msg.err("[SceneNav] List widget missing")
        return
    end

    local sel = list:get_selection()
    if not sel or next(sel) == nil then
        vlc.msg.err("[SceneNav] No selection")
        return
    end

    local selected_index = next(sel)
    if selected_index == 0 then
        vlc.msg.err("[SceneNav] Header row selected; pick a scene row")
        return
    end

    local scene = scenes[selected_index]
    if not scene and selected_index > 0 then
        scene = scenes[selected_index - 1]
        vlc.msg.warn(string.format("[SceneNav] scene[%d] not found, falling back to scene[%d]", selected_index, selected_index - 1))
    end

    if not scene then
        vlc.msg.err("[SceneNav] Scene not found at index: " .. tostring(selected_index))
        return
    end

    local input = vlc.object.input()
    if not input then
        vlc.msg.err("[SceneNav] No active input (video must be playing)")
        return
    end

    for i = 1, 20 do
        if vlc.playlist.status() == "playing" then break end
        vlc.msg.dbg("[SceneNav] Waiting for media to start...")
        vlc.misc.mwait(vlc.misc.mdate() + 200000)
    end

    local duration = vlc.input.item() and vlc.input.item():duration()
    if duration then
        vlc.msg.dbg(string.format("[SceneNav] Media duration: %.3f sec", duration))
        if scene.startSec > duration then
            vlc.msg.err(string.format("[SceneNav] Scene start %.3f exceeds media length %.3f", scene.startSec, duration))
            return
        end
    else
        vlc.msg.warn("[SceneNav] Media duration unavailable; skipping duration check")
    end

    if scene.startSec < 0 or scene.startSec > 86400 then
        vlc.msg.err(string.format("[SceneNav] Abnormal scene time: %.3f s", scene.startSec))
        return
    end

    if vlc.input.seek then
        vlc.input.seek(scene.startSec)
        vlc.msg.dbg(string.format("[SceneNav] Jumped using vlc.input.seek to %.3f sec", scene.startSec))
    else
        vlc.var.set(input, "time", scene.startSec * 1e6)
        vlc.msg.dbg(string.format("[SceneNav] Jumped using legacy time set to %.3f sec", scene.startSec))
    end
end
