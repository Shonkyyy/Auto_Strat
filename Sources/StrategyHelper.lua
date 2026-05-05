local HttpService = game:GetService("HttpService")

local Helper = {}

Helper.StrategyFolder = "Strategies"
Helper.FileExtension = ".json"
Helper.PendingRecordFile = "ADS_PendingRecord.json"

local function clone_array(list)
    local out = {}
    for i = 1, #list do
        out[i] = list[i]
    end
    return out
end

local function get_timestamp()
    local ok, stamp = pcall(function()
        return DateTime.now().UnixTimestampMillis
    end)
    if ok then
        return stamp
    end
    return os.time()
end

local function normalize_text(value, fallback)
    if type(value) ~= "string" then
        value = tostring(value or "")
    end

    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return fallback or ""
    end

    return value
end

local function sanitize_file_name(name)
    name = normalize_text(name, "Untitled Strategy")
    name = name:gsub("[<>:\"/\\|%?%*%c]", "_")
    name = name:gsub("%s+", " ")
    name = name:gsub("^%.+", ""):gsub("%.+$", "")

    if name == "" then
        return "Untitled Strategy"
    end

    return name
end

local function normalize_loadout(loadout)
    local result = {"None", "None", "None", "None", "None"}
    if type(loadout) ~= "table" then
        return result
    end

    for i = 1, 5 do
        local tower_name = loadout[i]
        if type(tower_name) == "string" and tower_name ~= "" then
            result[i] = tower_name
        end
    end

    return result
end

local function normalize_modifiers(modifiers)
    if type(modifiers) ~= "table" then
        return {}
    end

    local result = {}
    local seen = {}

    if #modifiers > 0 then
        for _, modifier_name in ipairs(modifiers) do
            if type(modifier_name) == "string" and modifier_name ~= "" and not seen[modifier_name] then
                seen[modifier_name] = true
                table.insert(result, modifier_name)
            end
        end
    else
        for modifier_name, enabled in pairs(modifiers) do
            if enabled and type(modifier_name) == "string" and modifier_name ~= "" and not seen[modifier_name] then
                seen[modifier_name] = true
                table.insert(result, modifier_name)
            end
        end
    end

    table.sort(result)
    return result
end

local function get_sorted_numeric_keys(tbl)
    local keys = {}
    for key, _ in pairs(tbl) do
        local numeric_key = tonumber(key)
        if numeric_key then
            table.insert(keys, numeric_key)
        end
    end
    table.sort(keys)
    return keys
end

local function normalize_actions(actions)
    if type(actions) ~= "table" then
        return {}
    end

    local result = {}

    local function append_entry(entry)
        local command
        local wave = 0

        if type(entry) == "string" then
            command = entry
        elseif type(entry) == "table" then
            command = entry.command or entry.Command or entry.line or entry.Line
            wave = tonumber(entry.wave or entry.Wave) or 0
        end

        if type(command) == "string" then
            command = command:gsub("^%s+", ""):gsub("%s+$", "")
            if command ~= "" then
                table.insert(result, {
                    command = command,
                    wave = wave
                })
            end
        end
    end

    if #actions > 0 then
        for _, entry in ipairs(actions) do
            append_entry(entry)
        end
    else
        for _, key in ipairs(get_sorted_numeric_keys(actions)) do
            append_entry(actions[key] or actions[tostring(key)])
        end
    end

    return result
end

local function modifiers_to_lua(modifiers)
    if #modifiers == 0 then
        return "{}"
    end

    local parts = {}
    for _, modifier_name in ipairs(modifiers) do
        table.insert(parts, string.format("[%q] = true", modifier_name))
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

function Helper.ensure_folder()
    if makefolder and isfolder and not isfolder(Helper.StrategyFolder) then
        pcall(makefolder, Helper.StrategyFolder)
    end
end

function Helper.get_file_name(name)
    return sanitize_file_name(name) .. Helper.FileExtension
end

function Helper.get_file_path(name)
    return Helper.StrategyFolder .. "/" .. Helper.get_file_name(name)
end

function Helper.file_exists(name)
    if not isfile then
        return false
    end

    return isfile(Helper.get_file_path(name))
end

function Helper.ensure_unique_name(name)
    local base_name = sanitize_file_name(name)
    local candidate = base_name
    local index = 2

    while Helper.file_exists(candidate) do
        candidate = string.format("%s (%d)", base_name, index)
        index += 1
    end

    return candidate
end

function Helper.get_display_name(file_name)
    if type(file_name) ~= "string" then
        return ""
    end

    return file_name:gsub("%.json$", "")
end

function Helper.normalize(data, opts)
    opts = opts or {}

    if type(data) ~= "table" then
        return nil, "Strategy payload must be a table."
    end

    local normalized = {
        version = tonumber(data.version or data.Version) or 1,
        format = "ads_strategy",
        name = normalize_text(data.name or data.Name, "Untitled Strategy"),
        mode = normalize_text(data.mode or data.Mode, "Unknown"),
        map = normalize_text(data.map or data.Map, "Unknown"),
        skipGameInfo = data.skipGameInfo == true or data.SkipGameInfo == true or data.skip_game_info == true,
        loadout = normalize_loadout(data.loadout or data.Loadout),
        modifiers = normalize_modifiers(data.modifiers or data.Modifiers),
        actions = normalize_actions(data.actions or data.Actions),
        createdAt = tonumber(data.createdAt or data.CreatedAt) or get_timestamp()
    }

    if not opts.allow_empty_actions and #normalized.actions == 0 then
        return nil, "Strategy has no recorded actions."
    end

    return normalized
end

function Helper.encode(data, opts)
    local normalized, err = Helper.normalize(data, opts)
    if not normalized then
        return nil, err
    end

    local payload = {
        version = normalized.version,
        format = normalized.format,
        name = normalized.name,
        mode = normalized.mode,
        map = normalized.map,
        skipGameInfo = normalized.skipGameInfo,
        loadout = clone_array(normalized.loadout),
        modifiers = clone_array(normalized.modifiers),
        actions = clone_array(normalized.actions),
        createdAt = normalized.createdAt
    }

    return HttpService:JSONEncode(payload), normalized
end

function Helper.decode(text, opts)
    if type(text) ~= "string" or text == "" then
        return nil, "Strategy text is empty."
    end

    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(text)
    end)

    if not ok then
        return nil, "Failed to decode strategy JSON."
    end

    return Helper.normalize(decoded, opts)
end

function Helper.save(data, name, opts)
    if not writefile then
        return nil, "writefile is unavailable in this executor."
    end

    Helper.ensure_folder()

    local text, normalized_or_err = Helper.encode(data, opts)
    if not text then
        return nil, normalized_or_err
    end

    local normalized = normalized_or_err
    local path = Helper.StrategyFolder .. "/" .. Helper.get_file_name(name or normalized.name)
    writefile(path, text)
    return path, normalized, text
end

function Helper.load_file(file_name, opts)
    if not readfile or not isfile then
        return nil, "readfile is unavailable in this executor."
    end

    local path = file_name
    if not path:find("/", 1, true) and not path:find("\\", 1, true) then
        path = Helper.StrategyFolder .. "/" .. path
    end

    if not isfile(path) then
        return nil, "Strategy file was not found."
    end

    local text = readfile(path)
    local normalized, err = Helper.decode(text, opts)
    if not normalized then
        return nil, err
    end

    return normalized, path, text
end

function Helper.list_files()
    Helper.ensure_folder()

    if not listfiles then
        return {}
    end

    local files = {}
    local ok, paths = pcall(listfiles, Helper.StrategyFolder)
    if not ok or type(paths) ~= "table" then
        return files
    end

    for _, path in ipairs(paths) do
        local file_name = tostring(path):match("[^/\\]+$")
        if file_name and file_name:sub(-#Helper.FileExtension):lower() == Helper.FileExtension then
            table.insert(files, file_name)
        end
    end

    table.sort(files, function(left, right)
        return left:lower() < right:lower()
    end)

    return files
end

function Helper.save_pending_record(data)
    if not writefile then
        return nil, "writefile is unavailable in this executor."
    end

    if type(data) ~= "table" then
        return nil, "Pending record data must be a table."
    end

    local payload = {
        strategy = data.strategy,
        shouldAutoJoin = data.shouldAutoJoin == true,
        gameInfoApplied = data.gameInfoApplied == true
    }

    writefile(Helper.PendingRecordFile, HttpService:JSONEncode(payload))
    return Helper.PendingRecordFile
end

function Helper.load_pending_record()
    if not readfile or not isfile then
        return nil
    end

    if not isfile(Helper.PendingRecordFile) then
        return nil
    end

    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(readfile(Helper.PendingRecordFile))
    end)

    if not ok or type(decoded) ~= "table" then
        return nil
    end

    local strategy = decoded.strategy
    if type(strategy) ~= "table" then
        return nil
    end

    local normalized, err = Helper.normalize(strategy, {allow_empty_actions = true})
    if not normalized then
        return nil, err
    end

    return {
        strategy = normalized,
        shouldAutoJoin = decoded.shouldAutoJoin == true,
        gameInfoApplied = decoded.gameInfoApplied == true
    }
end

function Helper.clear_pending_record()
    if delfile and isfile and isfile(Helper.PendingRecordFile) then
        pcall(delfile, Helper.PendingRecordFile)
    end
end

function Helper.build_lua(data)
    local normalized, err = Helper.normalize(data)
    if not normalized then
        return nil, err
    end

    local lines = {
        "local TDS = shared.TDSTable or shared[\"TDS_Table\"] or TDS",
        "if not TDS then return end",
        "",
        string.format(
            "TDS:Loadout(%q, %q, %q, %q, %q)",
            normalized.loadout[1],
            normalized.loadout[2],
            normalized.loadout[3],
            normalized.loadout[4],
            normalized.loadout[5]
        ),
        string.format("TDS:Mode(%q)", normalized.mode)
    }

    if not normalized.skipGameInfo then
        table.insert(lines, string.format("TDS:GameInfo(%q, %s)", normalized.map, modifiers_to_lua(normalized.modifiers)))
    end

    table.insert(lines, "")

    local last_wave = nil
    for _, action in ipairs(normalized.actions) do
        if action.wave and action.wave > 0 and action.wave ~= last_wave then
            table.insert(lines, string.format("-- [ Wave %d ] --", action.wave))
            last_wave = action.wave
        end
        table.insert(lines, action.command)
    end

    table.insert(lines, "")
    return table.concat(lines, "\n"), normalized
end

return Helper
