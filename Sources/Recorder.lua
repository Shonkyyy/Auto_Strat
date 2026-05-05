local Globals = getgenv()

return function(ctx)
    if not ctx or not ctx.Window then
        return
    end

	local Window = ctx.Window
    local replicated_storage = ctx.ReplicatedStorage or game:GetService("ReplicatedStorage")
    local http_service = ctx.HttpService or game:GetService("HttpService")
    local game_state = ctx.GameState or "UNKNOWN"
    local workspace_ref = ctx.workspace or workspace
    local tds = ctx.TDS or shared.TDSTable or shared["TDS_Table"]
    local StrategyHelper = shared.ADSStrategyHelper

    if not StrategyHelper then
        local ok, helper = pcall(function()
            return loadstring(game:HttpGet("https://raw.githubusercontent.com/Shonkyyy/Auto_Strat/main/Sources/StrategyHelper.lua"))()
        end)

        if ok and type(helper) == "table" then
            StrategyHelper = helper
            shared.ADSStrategyHelper = helper
        end
    end

    local players_service = game:GetService("Players")
    local local_player = ctx.LocalPlayer or players_service.LocalPlayer or players_service.PlayerAdded:Wait()

    Globals.record_strat = Globals.record_strat or false

    local spawned_towers = {}
    local tower_count = 0
    local last_wave = 0
    local record_session = nil
    local Recorder
    local has_hook = type(hookmetamethod) == "function"

    local modifier_options = ctx.ModifierList or {
        "HiddenEnemies", "Glass", "ExplodingEnemies", "Limitation",
        "Committed", "HealthyEnemies", "Fog", "FlyingEnemies",
        "Broke", "SpeedyEnemies", "Quarantine", "JailedTowers", "Inflation"
    }

    local mode_options = {
        "Easy", "Intermediate", "Molten", "Fallen", "Hardcore",
        "Frost", "PizzaParty", "PollutedWasteland", "Badlands",
        "DuckyEasy", "DuckyHard", "Trial"
    }
    local pending_record = StrategyHelper and StrategyHelper.load_pending_record() or nil

    local function clone_list(list)
        local result = {}
        if type(list) == "table" then
            for i = 1, #list do
                result[i] = list[i]
            end
        end
        return result
    end

    local function copy_strategy_data(strategy)
        if type(strategy) ~= "table" then
            return nil
        end

        return {
            version = strategy.version or 1,
            format = strategy.format or "ads_strategy",
            name = strategy.name,
            mode = strategy.mode,
            map = strategy.map,
            skipGameInfo = strategy.skipGameInfo == true,
            loadout = clone_list(strategy.loadout),
            modifiers = clone_list(strategy.modifiers),
            actions = clone_list(strategy.actions),
            createdAt = strategy.createdAt
        }
    end

    local function mode_uses_game_info(mode_name)
        if type(mode_name) ~= "string" or mode_name == "" then
            return true
        end

        if mode_name == "Trial" then
            return false
        end

        local direct_modes = tds and tds.MatchmakingMap or {
            Hardcore = "hardcore",
            PizzaParty = "halloween",
            Badlands = "badlands",
            PollutedWasteland = "polluted",
            DuckyEasy = "ducky2025",
            DuckyHard = "ducky2025"
        }

        return direct_modes[mode_name] == nil
    end

    local function save_pending_record(strategy, should_auto_join, game_info_applied)
        if not StrategyHelper or not strategy then
            return nil, "Strategy helper unavailable."
        end

        local normalized, err = StrategyHelper.normalize(strategy, {allow_empty_actions = true})
        if not normalized then
            return nil, err
        end

        pending_record = {
            strategy = copy_strategy_data(normalized),
            shouldAutoJoin = should_auto_join == true,
            gameInfoApplied = game_info_applied == true
        }

        StrategyHelper.save_pending_record(pending_record)
        return pending_record
    end

    local function get_current_wave()
        local success, current_wave = pcall(function()
            return replicated_storage.StateReplicators.GameStateReplicator:GetAttribute("Wave")
        end)
        if success then
            return tonumber(current_wave) or 0
        end
        return 0
    end

    local function save_record_session()
        if not StrategyHelper or not record_session then
            return nil, nil
        end

        local path, normalized, json = StrategyHelper.save(record_session, record_session.name, {
            allow_empty_actions = true
        })

        if path then
            record_session.file_path = path
            record_session.cached_json = json
        end

        return path, normalized
    end

    local function clear_pending_record()
        pending_record = nil
        if StrategyHelper then
            StrategyHelper.clear_pending_record()
        end
    end

    local function record_action(command_str)
        if not Globals.record_strat or not record_session then
            return
        end

        local current_wave = get_current_wave()
        if current_wave > last_wave then
            last_wave = current_wave
        end

        table.insert(record_session.actions, {
            command = command_str,
            wave = current_wave
        })

        save_record_session()
    end

    local function log_line(message)
        if Recorder and Recorder.Log then
            Recorder:Log(message)
        end
    end

    local function get_equipped_towers()
        local result = {"None", "None", "None", "None", "None"}
        local state_replicators = replicated_storage:FindFirstChild("StateReplicators")

        if not state_replicators then
            return result
        end

        for _, folder in ipairs(state_replicators:GetChildren()) do
            if folder.Name == "PlayerReplicator" and folder:GetAttribute("UserId") == local_player.UserId then
                local equipped = folder:GetAttribute("EquippedTowers")
                if type(equipped) == "string" then
                    local cleaned_json = equipped:match("%[.*%]")
                    local success, tower_table = pcall(function()
                        return http_service:JSONDecode(cleaned_json)
                    end)

                    if success and type(tower_table) == "table" then
                        for i = 1, 5 do
                            result[i] = tower_table[i] or "None"
                        end
                    end
                end
                break
            end
        end

        return result
    end

    local function get_current_game_info()
        local current_mode = "Unknown"
        local current_map = ""
        local current_modifiers = {}
        local skip_game_info = false

        local state_folder = replicated_storage:FindFirstChild("State")
        if state_folder then
            local difficulty = state_folder:FindFirstChild("Difficulty")
            local map_value = state_folder:FindFirstChild("Map")
            local mode_obj = state_folder:FindFirstChild("Mode")

            if difficulty then
                current_mode = difficulty.Value
            end

            if map_value then
                current_map = map_value.Value
            end

            if mode_obj and mode_obj.Value == "DuckEvent" then
                if current_mode == "Easy" then
                    current_mode = "DuckyEasy"
                elseif current_mode == "Hard" then
                    current_mode = "DuckyHard"
                end
                skip_game_info = true
            elseif current_mode == "Trial" or (mode_obj and mode_obj.Value == "Special") then
                skip_game_info = true
            end
        end

        local state_replicators = replicated_storage:FindFirstChild("StateReplicators")
        if state_replicators then
            local modifier_replicator = state_replicators:FindFirstChild("ModifierReplicator")
            if modifier_replicator then
                local raw_votes = modifier_replicator:GetAttribute("Votes")
                if type(raw_votes) == "string" then
                    local cleaned_json = raw_votes:match("{.*}")
                    local success, mod_table = pcall(function()
                        return http_service:JSONDecode(cleaned_json)
                    end)

                    if success and type(mod_table) == "table" then
                        for modifier_name, enabled in pairs(mod_table) do
                            if enabled then
                                table.insert(current_modifiers, modifier_name)
                            end
                        end
                        table.sort(current_modifiers)
                    end
                end
            end
        end

        return current_mode, current_map, current_modifiers, skip_game_info
    end

    local function build_strategy_metadata(name, mode, map, modifiers, loadout)
        local strategy_name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local strategy_mode = tostring(mode or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local strategy_map = tostring(map or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local strategy_modifiers = {}

        if type(modifiers) == "table" then
            for _, modifier_name in ipairs(modifiers) do
                table.insert(strategy_modifiers, modifier_name)
            end
        end

        local skip_game_info = not mode_uses_game_info(strategy_mode)

        return {
            version = 1,
            format = "ads_strategy",
            name = strategy_name,
            mode = strategy_mode,
            map = strategy_map,
            skipGameInfo = skip_game_info,
            loadout = loadout or {"None", "None", "None", "None", "None"},
            modifiers = strategy_modifiers,
            actions = {}
        }
    end

    local function resolve_tower_index(tower)
        if typeof(tower) ~= "Instance" then
            return nil
        end

        if spawned_towers[tower] then
            return spawned_towers[tower]
        end

        local current = tower.Parent
        while current do
            if spawned_towers[current] then
                return spawned_towers[current]
            end
            current = current.Parent
        end

        return nil
    end

    local function sync_existing_towers()
        if game_state ~= "GAME" then
            return
        end

        local towers_folder = workspace_ref:FindFirstChild("Towers")
        if not towers_folder then
            return
        end

        table.clear(spawned_towers)
        tower_count = 0

        for _, tower in ipairs(towers_folder:GetChildren()) do
            local replicator = tower:FindFirstChild("TowerReplicator")
            if replicator and replicator:GetAttribute("OwnerId") == local_player.UserId then
                tower_count += 1
                spawned_towers[tower] = tower_count
            end
        end
    end

    local function num_to_str(n)
        if type(n) ~= "number" then
            return tostring(n)
        end
        if n == math.huge then
            return "math.huge"
        end
        if n == -math.huge then
            return "-math.huge"
        end
        if n ~= n then
            return "0/0"
        end
        return tostring(n)
    end

    local serialize_value
    local serialize_value_raw
    local serialize_table
    local serialize_table_raw

    local function format_key(key)
        if type(key) == "string" and key:match("^[_%a][_%w]*$") then
            return key
        end
        if type(key) == "number" then
            return "[" .. num_to_str(key) .. "]"
        end
        return "[" .. serialize_value(key) .. "]"
    end

    local function is_array(tbl)
        local max_idx = 0
        for k, _ in pairs(tbl) do
            if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
                return false, 0
            end
            if k > max_idx then
                max_idx = k
            end
        end
        return true, max_idx
    end

    serialize_value = function(v, depth)
        depth = depth or 0
        if depth > 4 then
            return "nil"
        end

        local t = typeof(v)
        if t == "string" then
            return string.format("%q", v)
        elseif t == "number" then
            return num_to_str(v)
        elseif t == "boolean" then
            return tostring(v)
        elseif t == "Vector3" then
            return string.format(
                "Vector3.new(%s, %s, %s)",
                num_to_str(v.X),
                num_to_str(v.Y),
                num_to_str(v.Z)
            )
        elseif t == "CFrame" then
            local comps = {v:GetComponents()}
            local parts = {}
            for i = 1, #comps do
                parts[i] = num_to_str(comps[i])
            end
            return "CFrame.new(" .. table.concat(parts, ", ") .. ")"
        elseif t == "Instance" then
            local idx = resolve_tower_index(v)
            if idx then
                return tostring(idx)
            end
            return "nil"
        elseif t == "table" then
            return serialize_table(v, depth + 1)
        end

        return "nil"
    end

    serialize_value_raw = function(v, depth)
        depth = depth or 0
        if depth > 4 then
            return "nil"
        end

        local t = typeof(v)
        if t == "string" then
            return string.format("%q", v)
        elseif t == "number" then
            return num_to_str(v)
        elseif t == "boolean" then
            return tostring(v)
        elseif t == "Vector3" then
            return string.format(
                "Vector3.new(%s, %s, %s)",
                num_to_str(v.X),
                num_to_str(v.Y),
                num_to_str(v.Z)
            )
        elseif t == "CFrame" then
            local comps = {v:GetComponents()}
            local parts = {}
            for i = 1, #comps do
                parts[i] = num_to_str(comps[i])
            end
            return "CFrame.new(" .. table.concat(parts, ", ") .. ")"
        elseif t == "Instance" then
            local full = v:GetFullName()
            if type(full) == "string" and full ~= "" then
                local parts = string.split(full, ".")
                local expr = 'game:GetService("' .. parts[1] .. '")'
                for i = 2, #parts do
                    local part = parts[i]
                    if part:match("^[_%a][_%w]*$") then
                        expr = expr .. "." .. part
                    else
                        expr = expr .. "[" .. string.format("%q", part) .. "]"
                    end
                end
                return expr
            end
            return "nil"
        elseif t == "table" then
            return serialize_table_raw(v, depth + 1)
        end

        return "nil"
    end

    serialize_table = function(tbl, depth)
        local is_arr, max_idx = is_array(tbl)
        local parts = {}

        if is_arr then
            for i = 1, max_idx do
                parts[i] = serialize_value(tbl[i], depth)
            end
        else
            local keys = {}
            for k, _ in pairs(tbl) do
                table.insert(keys, k)
            end
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            for _, k in ipairs(keys) do
                table.insert(parts, format_key(k) .. " = " .. serialize_value(tbl[k], depth))
            end
        end

        return "{" .. table.concat(parts, ", ") .. "}"
    end

    serialize_table_raw = function(tbl, depth)
        local is_arr, max_idx = is_array(tbl)
        local parts = {}

        if is_arr then
            for i = 1, max_idx do
                parts[i] = serialize_value_raw(tbl[i], depth)
            end
        else
            local keys = {}
            for k, _ in pairs(tbl) do
                table.insert(keys, k)
            end
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            for _, k in ipairs(keys) do
                local key_str
                if type(k) == "string" and k:match("^[_%a][_%w]*$") then
                    key_str = k
                elseif type(k) == "number" then
                    key_str = "[" .. num_to_str(k) .. "]"
                else
                    key_str = "[" .. serialize_value_raw(k, depth) .. "]"
                end
                table.insert(parts, key_str .. " = " .. serialize_value_raw(tbl[k], depth))
            end
        end

        return "{" .. table.concat(parts, ", ") .. "}"
    end

    local function build_remote_call(remote, method, args)
        if typeof(remote) ~= "Instance" then
            return nil
        end

        local full = remote:GetFullName()
        if type(full) ~= "string" or full == "" then
            return nil
        end

        local parts = string.split(full, ".")
        local expr = 'game:GetService("' .. parts[1] .. '")'
        for i = 2, #parts do
            local part = parts[i]
            if part:match("^[_%a][_%w]*$") then
                expr = expr .. "." .. part
            else
                expr = expr .. "[" .. string.format("%q", part) .. "]"
            end
        end

        local arg_parts = {}
        for i = 1, #args do
            arg_parts[i] = serialize_value_raw(args[i])
        end

        return expr .. ":" .. method .. "(" .. table.concat(arg_parts, ", ") .. ")"
    end

    local function is_consumable_call(remote, args)
        local first = args[1]
        if type(first) == "string" then
            local lower = first:lower()
            if lower:find("consum") then
                return true
            end
            if lower:find("item") and type(args[2]) == "string" and tostring(args[2]):lower():find("use") then
                return true
            end
        end

        if typeof(remote) == "Instance" then
            local full = remote:GetFullName()
            if type(full) == "string" then
                local lower = full:lower()
                if lower:find("consum") then
                    return true
                end
                if lower:find("item") and lower:find("use") then
                    return true
                end
            end
        end

        return false
    end

    local function any_string_contains(args, token)
        for i = 1, #args do
            local v = args[i]
            if type(v) == "string" then
                local lower = v:lower()
                if lower:find(token, 1, true) then
                    return true
                end
            end
        end
        return false
    end

    local function collect_non_keyword_strings(args)
        local keywords = {
            troops = true,
            troop = true,
            option = true,
            options = true,
            target = true,
            ability = true,
            abilities = true,
            activate = true,
            set = true,
            voting = true,
            skip = true,
            inventory = true,
            equip = true,
            unequip = true,
            tower = true
        }

        local list = {}
        for i = 1, #args do
            local v = args[i]
            if type(v) == "string" then
                local lower = v:lower()
                if not keywords[lower] then
                    table.insert(list, v)
                end
            end
        end
        return list
    end

    local function find_payload(args)
        for i = 1, #args do
            local v = args[i]
            if type(v) == "table" then
                if v.Troop or v.troop or v.Tower or v.tower then
                    return v
                end
            end
        end
        return nil
    end

    local function find_tower_arg(args)
        for i = 1, #args do
            local v = args[i]
            if typeof(v) == "Instance" then
                local idx = resolve_tower_index(v)
                if idx then
                    return v
                end
            end
        end
        return nil
    end

    local function record_line(line, message)
        record_action(line)
        if message then
            log_line(message)
        end
    end

    Globals.__tds_record_equip = function(tower_name)
        if type(tower_name) ~= "string" then
            return
        end
        local cmd = string.format("TDS:Equip(%s)", string.format("%q", tower_name))
        record_line(cmd, "Equipped: " .. tower_name)
    end

    Globals.__tds_record_unequip = function(tower_name)
        if type(tower_name) ~= "string" then
            return
        end
        local cmd = string.format("TDS:Unequip(%s)", string.format("%q", tower_name))
        record_line(cmd, "Unequipped: " .. tower_name)
    end

    local function handle_namecall(remote, method, args, results)
        if not Globals.record_strat then
            return
        end

        if method ~= "InvokeServer" and method ~= "FireServer" then
            return
        end

        local handled = false

        local a1 = args[1]
        local a2 = args[2]
        local a3 = args[3]
        local a4 = args[4]
        local a5 = args[5]

        if a1 == "Troops" and a2 == "Abilities" and a3 == "Activate" then
            if type(a4) == "table" and type(a4.Name) == "string" then
                local abilityName = a4.Name
                if abilityName == "Call Of Arms" or abilityName == "Support Caravan" or abilityName == "Drop The Beat" or abilityName == "Raise The Dead" then
                    return
                end
            end
            
            if not results or results[1] ~= true then
                return
            end
            
            if type(a4) == "table" then
                local idx = resolve_tower_index(a4.Troop)
                local name = a4.Name
                if idx and type(name) == "string" then
                    local data = a4.Data
                    local cmd
                    if data == nil or (type(data) == "table" and next(data) == nil) then
                        cmd = string.format("TDS:Ability(%d, %s)", idx, string.format("%q", name))
                    else
                        cmd = string.format(
                            "TDS:Ability(%d, %s, %s)",
                            idx,
                            string.format("%q", name),
                            serialize_value(data)
                        )
                    end

                    record_line(cmd, "Ability: " .. name .. " (Index: " .. idx .. ")")
                    handled = true
                    return
                end
            end
        end

        if a1 == "Troops" and a2 == "Target" and a3 == "Set" then
            if type(a4) == "table" then
                local idx = resolve_tower_index(a4.Troop)
                local target_type = a4.Target
                if idx and type(target_type) == "string" then
                    local cmd = string.format("TDS:SetTarget(%d, %s)", idx, string.format("%q", target_type))
                    record_line(cmd, "Target: " .. idx .. " -> " .. target_type)
                    handled = true
                    return
                end
            end
        end

        if a1 == "Troops" and a2 == "Option" and a3 == "Set" then
            if type(a4) == "table" then
                local idx = resolve_tower_index(a4.Troop)
                local opt_name = a4.Name or a4.Option or a4.Key or a4.Track
                local opt_val = a4.Value or a4.Val
                if idx and type(opt_name) == "string" then
                    local cmd = string.format(
                        "TDS:SetOption(%d, %s, %s)",
                        idx,
                        string.format("%q", opt_name),
                        serialize_value(opt_val)
                    )
                    record_line(cmd, "Option: " .. idx .. " " .. opt_name .. " = " .. tostring(opt_val))
                    handled = true
                    return
                end
            end
        end

        if a1 == "Troops" and a2 == "TowerServerEvent" and a3 == "ToggleSelectedTower" then
            local idx = resolve_tower_index(a4)
            local target_idx = resolve_tower_index(a5)
            if idx and target_idx then
                local cmd = string.format("TDS:MedicSelect(%d, %d)", idx, target_idx)
                record_line(cmd, "Medic: " .. idx .. " -> " .. target_idx)
                handled = true
                return
            end
        end

        if a1 == "Voting" and a2 == "Skip" then
            local current_wave = 0
            current_wave = replicated_storage.StateReplicators.GameStateReplicator:GetAttribute("Wave") or 0
            if current_wave == 0 then
                record_line("TDS:Ready()", "Readied up for the match")
            else
                record_line("TDS:VoteSkip(" .. current_wave .. ")", "Voted to skip wave " .. current_wave)
            end
            handled = true
            return
        end

        if a1 == "Inventory" and a2 == "Equip" and a3 == "tower" then
            if type(args[4]) == "string" then
                local tower_name = args[4]
                local cmd = string.format("TDS:Equip(%s)", string.format("%q", tower_name))
                record_line(cmd, "Equipped: " .. tower_name)
            end
            handled = true
            return
        end

        if a1 == "Inventory" and a2 == "Unequip" and a3 == "tower" then
            if type(args[4]) == "string" then
                local tower_name = args[4]
                local cmd = string.format("TDS:Unequip(%s)", string.format("%q", tower_name))
                record_line(cmd, "Unequipped: " .. tower_name)
            end
            handled = true
            return
        end

        if is_consumable_call(remote, args) then
            local raw_call = build_remote_call(remote, method, args)
            if raw_call then
                record_line(raw_call, "Consumable used")
            end
            handled = true
            return
        end

        if handled then
            return
        end

        if a1 ~= "Troops" then
            return
        end

        local payload = find_payload(args)
        local tower_obj = payload and (payload.Troop or payload.troop or payload.Tower or payload.tower) or find_tower_arg(args)
        local idx = resolve_tower_index(tower_obj)
        if not idx then
            return
        end

        local strings = collect_non_keyword_strings(args)
        local has_option = any_string_contains(args, "option") or any_string_contains(args, "track")
        local has_ability = any_string_contains(args, "abil")
        local has_target = any_string_contains(args, "target")

        if has_option then
            local opt_name = payload and (payload.Name or payload.Option or payload.Key or payload.Track)
            local opt_val = payload and (payload.Value or payload.Val)

            if not opt_name and #strings >= 1 then
                opt_name = strings[1]
            end
            if opt_val == nil and #strings >= 2 then
                opt_val = strings[2]
            end
            if not opt_name and any_string_contains(args, "track") then
                opt_name = "Track"
            end

            if opt_name then
                local cmd = string.format(
                    "TDS:SetOption(%d, %s, %s)",
                    idx,
                    string.format("%q", opt_name),
                    serialize_value(opt_val)
                )
                record_line(cmd, "Option: " .. idx .. " " .. opt_name .. " = " .. tostring(opt_val))
            end
            return
        end

        if has_target then
            local target_type = payload and payload.Target or (#strings >= 1 and strings[1] or nil)
            if target_type then
                local cmd = string.format("TDS:SetTarget(%d, %s)", idx, string.format("%q", target_type))
                record_line(cmd, "Target: " .. idx .. " -> " .. tostring(target_type))
            end
            return
        end

        if has_ability then
            local name = payload and payload.Name or (#strings >= 1 and strings[1] or nil)
            if name then
                local data = payload and payload.Data or nil
                local cmd
                if data == nil or (type(data) == "table" and next(data) == nil) then
                    cmd = string.format("TDS:Ability(%d, %s)", idx, string.format("%q", name))
                else
                    cmd = string.format(
                        "TDS:Ability(%d, %s, %s)",
                        idx,
                        string.format("%q", name),
                        serialize_value(data)
                    )
                end
                record_line(cmd, "Ability: " .. name .. " (Index: " .. idx .. ")")
            end
            return
        end
    end

    local RecorderTab = Window:Tab({Title = "Recorder", Icon = "camera"}) do
        local detected_mode, detected_map, detected_modifiers = get_current_game_info()
        local pending_strategy = pending_record and pending_record.strategy or nil

        local selected_strategy_name = pending_strategy and pending_strategy.name or "New Strategy"
        local selected_mode = pending_strategy and pending_strategy.mode or ((detected_mode ~= "" and detected_mode) or mode_options[1])
        local selected_map = pending_strategy and pending_strategy.map or (detected_map or "")
        local selected_modifiers = pending_strategy and clone_list(pending_strategy.modifiers) or detected_modifiers

        local has_mode = false
        for _, mode_name in ipairs(mode_options) do
            if mode_name == selected_mode then
                has_mode = true
                break
            end
        end
        if not has_mode then
            table.insert(mode_options, selected_mode)
        end

        RecorderTab:Section({Title = "Recording Setup"})

        RecorderTab:Textbox({
            Title = "Strategy Name",
            Desc = "Saved as a JSON file in the Strategies folder",
            Placeholder = "Example: Wasteland Chug 3",
            Value = selected_strategy_name,
            ClearTextOnFocus = false,
            Callback = function(text)
                selected_strategy_name = text ~= "" and text or "New Strategy"
            end
        })

        RecorderTab:Dropdown({
            Title = "Mode",
            Desc = "Pick the gamemode this recording is for",
            List = mode_options,
            Value = selected_mode,
            Callback = function(choice)
                selected_mode = choice
            end
        })

        RecorderTab:Textbox({
            Title = "Map",
            Desc = "Required for normal survival recordings",
            Placeholder = "Example: Honey Valley",
            Value = selected_map,
            ClearTextOnFocus = false,
            Callback = function(text)
                selected_map = text or ""
            end
        })

        RecorderTab:Dropdown({
            Title = "Modifiers",
            Desc = "Leave empty if the run has no modifiers",
            List = modifier_options,
            Value = selected_modifiers,
            Multi = true,
            Callback = function(choice)
                selected_modifiers = choice
            end
        })

        RecorderTab:Button({
            Title = "CREATE NEW",
            Desc = "Save the lobby setup as a pending JSON strategy",
            Callback = function()
                if game_state ~= "LOBBY" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Create New is only available in the lobby.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                if not StrategyHelper then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Strategy helper failed to load.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                local strategy = build_strategy_metadata(
                    selected_strategy_name,
                    selected_mode,
                    selected_map,
                    selected_modifiers,
                    {"None", "None", "None", "None", "None"}
                )

                if strategy.name == "" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Enter a strategy name first.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                if strategy.mode == "" or strategy.mode == "--" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Select a gamemode first.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                if mode_uses_game_info(strategy.mode) and strategy.map == "" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Enter a map before creating the recorder setup.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                local path, err = StrategyHelper.save(strategy, strategy.name, {
                    allow_empty_actions = true
                })
                if not path then
                    Window:Notify({
                        Title = "ADS",
                        Desc = err or "Failed to save strategy JSON.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                save_pending_record(strategy, false, strategy.skipGameInfo)

                Window:Notify({
                    Title = "ADS",
                    Desc = "Recorder setup saved to " .. path,
                    Time = 4,
                    Type = "normal"
                })
            end
        })

        RecorderTab:Button({
            Title = "JOIN MAP",
            Desc = "Lobby only. Uses the saved setup to join the chosen mode, then continues in-game.",
            Callback = function()
                if game_state ~= "LOBBY" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Join Map is only available in the lobby.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                if not StrategyHelper or not tds or type(tds.Mode) ~= "function" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Recorder cannot access the matchmaking logic right now.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                local strategy = build_strategy_metadata(
                    selected_strategy_name,
                    selected_mode,
                    selected_map,
                    selected_modifiers,
                    {"None", "None", "None", "None", "None"}
                )

                if strategy.name == "" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Enter a strategy name first.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                if strategy.mode == "" or strategy.mode == "--" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Select a gamemode first.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                if mode_uses_game_info(strategy.mode) and strategy.map == "" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Enter a map before joining.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                local path, err = StrategyHelper.save(strategy, strategy.name, {
                    allow_empty_actions = true
                })
                if not path then
                    Window:Notify({
                        Title = "ADS",
                        Desc = err or "Failed to save strategy JSON.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                save_pending_record(strategy, mode_uses_game_info(strategy.mode), strategy.skipGameInfo)

                Window:Notify({
                    Title = "ADS",
                    Desc = mode_uses_game_info(strategy.mode)
                        and "Joining mode now. Map and modifiers will be applied in-game."
                        or "Joining mode now.",
                    Time = 4,
                    Type = "normal"
                })

                task.spawn(function()
                    pcall(function()
                        tds:Mode(strategy.mode)
                    end)
                end)
            end
        })

        RecorderTab:Section({Title = "Recorder Log"})

        Recorder = RecorderTab:CreateLogger({
            Title = "RECORDER:",
            Size = UDim2.new(0, 330, 0, 230)
        })

        if pending_strategy then
            Recorder:Log("Pending strategy loaded: " .. tostring(pending_strategy.name))
        elseif game_state == "LOBBY" then
            Recorder:Log("Create the setup here, then use Join Map.")
        else
            Recorder:Log("No pending lobby setup found. Using current match data.")
        end

        if game_state == "GAME" and pending_record and pending_record.strategy then
            if pending_record.shouldAutoJoin and not pending_record.gameInfoApplied and not pending_record.strategy.skipGameInfo then
                if tds and type(tds.GameInfo) == "function" then
                    Recorder:Log("Applying pending map and modifiers...")
                    task.spawn(function()
                        local ok, err = pcall(function()
                            tds:GameInfo(pending_record.strategy.map, pending_record.strategy.modifiers)
                        end)

                        if ok then
                            pending_record.shouldAutoJoin = false
                            pending_record.gameInfoApplied = true
                            StrategyHelper.save_pending_record(pending_record)
                            log_line("Pending map setup applied.")
                        else
                            log_line("Failed to apply pending setup: " .. tostring(err))
                        end
                    end)
                else
                    Recorder:Log("Pending setup exists, but GameInfo is unavailable.")
                end
            elseif pending_record.shouldAutoJoin then
                pending_record.shouldAutoJoin = false
                pending_record.gameInfoApplied = pending_record.strategy.skipGameInfo or pending_record.gameInfoApplied
                StrategyHelper.save_pending_record(pending_record)
            end
        end

        if has_hook then
            Globals.__tds_recorder_handler = function(remote, method, args, results)
                handle_namecall(remote, method, args, results)
            end

            if not Globals.__tds_recorder_hooked then
                Globals.__tds_recorder_hooked = true
                local original
                original = hookmetamethod(game, "__namecall", function(self, ...)
                    local method = getnamecallmethod and getnamecallmethod() or nil
                    local args = {...}
                    local results = table.pack(original(self, ...))
                    local handler = Globals.__tds_recorder_handler
                    if handler and method then
                        task.spawn(function()
                            local set_id = setthreadidentity or setidentity or setthreadcontext
                            if set_id then set_id(7) end
                            pcall(handler, self, method, args, results)
                        end)
                    end
                    return table.unpack(results, 1, results.n)
                end)
            end
        end

        RecorderTab:Button({
            Title = "START",
            Desc = "",
            Callback = function()
                if game_state ~= "GAME" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Start recording after you are inside the match. Use Create New and Join Map in the lobby first.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                if not StrategyHelper then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Strategy helper failed to load. Recorder cannot export JSON yet.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                if Globals.record_strat then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "A recording is already running.",
                        Time = 3,
                        Type = "error"
                    })
                    return
                end

                local loadout = get_equipped_towers()
                local base_strategy

                if pending_record and pending_record.strategy then
                    base_strategy = copy_strategy_data(pending_record.strategy)
                    base_strategy.loadout = loadout
                    base_strategy.actions = {}
                else
                    base_strategy = build_strategy_metadata(
                        selected_strategy_name,
                        selected_mode,
                        selected_map,
                        selected_modifiers,
                        loadout
                    )
                end

                if base_strategy.name == "" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Enter a strategy name before starting the recorder.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                if base_strategy.mode == "" or base_strategy.mode == "--" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Select a gamemode before starting the recorder.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                if mode_uses_game_info(base_strategy.mode) and base_strategy.map == "" then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "Enter a map name before starting the recorder.",
                        Time = 4,
                        Type = "error"
                    })
                    return
                end

                Recorder:Clear()
                Recorder:Log("Recorder started")

                record_session = base_strategy
                record_session.loadout = loadout
                record_session.actions = {}

                local path = save_record_session()
                if pending_record then
                    save_pending_record(record_session, false, record_session.skipGameInfo)
                end

                Recorder:Log("Name: " .. record_session.name)
                Recorder:Log("Mode: " .. record_session.mode)
                Recorder:Log("Map: " .. (record_session.skipGameInfo and "(Skipped)" or record_session.map))
                Recorder:Log("Modifiers: " .. (#record_session.modifiers > 0 and table.concat(record_session.modifiers, ", ") or "None"))
                Recorder:Log("Towers: " .. loadout[1] .. ", " .. loadout[2])
                Recorder:Log(loadout[3] .. ", " .. loadout[4] .. ", " .. loadout[5])

                sync_existing_towers()
                last_wave = 0
                Globals.record_strat = true
                if has_hook then
                    Recorder:Log("Extended recording enabled")
                else
                    Recorder:Log("Limited recording (place/upgrade/sell)")
                end
                if #record_session.modifiers == 0 then
                    Recorder:Log("Warning: no modifiers were selected.")
                end
                if path then
                    Recorder:Log("Saving to: " .. path)
                end

                Window:Notify({
                    Title = "ADS",
                    Desc = "Recorder started. The JSON file is being saved in the Strategies folder.",
                    Time = 3,
                    Type = "normal"
                })
            end
        })

        RecorderTab:Button({
            Title = "STOP",
            Desc = "",
            Callback = function()
                if not Globals.record_strat and not record_session then
                    Window:Notify({
                        Title = "ADS",
                        Desc = "No active recording to stop.",
                        Time = 3,
                        Type = "error"
                    })
                    return
                end

                Globals.record_strat = false
                local final_path = nil
                if record_session then
                    final_path = save_record_session()
                end
                Recorder:Clear()
                Recorder:Log("Strategy saved as JSON.")
                if final_path then
                    Recorder:Log(final_path)
                end
                record_session = nil
                clear_pending_record()
                Window:Notify({
                    Title = "ADS",
                    Desc = final_path and ("Recording saved to " .. final_path) or "Recording saved to the Strategies folder.",
                    Time = 3,
                    Type = "normal"
                })
            end
        })

        if game_state == "GAME" then
            local towers_folder = workspace_ref:WaitForChild("Towers", 5)

            towers_folder.ChildAdded:Connect(function(tower)
                if not Globals.record_strat then return end
                
                local replicator = tower:WaitForChild("TowerReplicator", 5)
                if not replicator then return end

                local owner_id = replicator:GetAttribute("OwnerId")
                if owner_id and owner_id ~= local_player.UserId then return end

                if replicator:GetAttribute("Hologram") == true then return end

                tower_count = tower_count + 1
                local my_index = tower_count
                spawned_towers[tower] = my_index

                local tower_name = replicator:GetAttribute("Name") or tower.Name
                local raw_pos = replicator:GetAttribute("Position")
                
                local pos_x, pos_y, pos_z
                if typeof(raw_pos) == "Vector3" then
                    pos_x, pos_y, pos_z = raw_pos.X, raw_pos.Y, raw_pos.Z
                else
                    local p = tower:GetPivot().Position
                    pos_x, pos_y, pos_z = p.X, p.Y, p.Z
                end
                
                local command
                if Globals.StackEnabled then
                    command = 'TDS:Place("' .. tower_name .. '", ' .. tostring(pos_x) .. ', ' .. tostring(pos_y) .. ', ' .. tostring(pos_z) .. ', true)'
                else
                    command = 'TDS:Place("' .. tower_name .. '", ' .. tostring(pos_x) .. ', ' .. tostring(pos_y) .. ', ' .. tostring(pos_z) .. ')'
                end
                record_action(command)
                Recorder:Log("Placed " .. tower_name .. " (Index: " .. my_index .. ")")

                replicator:GetAttributeChangedSignal("Upgrade"):Connect(function()
                    if not Globals.record_strat then return end
                    record_action(string.format('TDS:Upgrade(%d)', my_index))
                    Recorder:Log("Upgraded Tower " .. my_index)
                end)
            end)

            towers_folder.ChildRemoved:Connect(function(tower)
                if not Globals.record_strat then return end
                
                local my_index = spawned_towers[tower]
                if my_index then
                    record_action(string.format('TDS:Sell(%d)', my_index))
                    Recorder:Log("Sold Tower " .. my_index)
                    
                    spawned_towers[tower] = nil
                end
            end)
        end
    end
end
