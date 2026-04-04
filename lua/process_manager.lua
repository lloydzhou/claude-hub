-- process_manager.lua
-- Single-turn Claude runner with session-level locking.

local _M = {}

local utils = require "utils"
local pipe = require "ngx.pipe"

local LOCK_TTL = 86400

local function get_dict()
    return ngx.shared.sessions
end

local function session_key(session_id)
    return "session:" .. session_id
end

local function lock_key(session_id)
    return "session_lock:" .. session_id
end

local function build_env_vars()
    local env_vars = {}
    local env_keys = {
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "LANG", "LC_ALL",
        "ANTHROPIC_API_KEY", "NODE_PATH", "TMPDIR", "XDG_CONFIG_HOME",
        "XDG_DATA_HOME", "XDG_CACHE_HOME", "CLAUDE_CONFIG_DIR",
    }

    for _, key in ipairs(env_keys) do
        local val = os.getenv(key)
        if val then
            table.insert(env_vars, key .. "=" .. val)
        end
    end

    return env_vars
end

local function build_user_event_line(body, session_id)
    local payload = body
    if type(payload) ~= "table" then
        local decoded = utils.json_decode(body)
        if decoded then
            payload = decoded
        else
            payload = { content = tostring(body or "") }
        end
    end

    local text = payload.content
    if type(text) ~= "string" then
        if type(payload.message) == "table" then
            local msg_content = payload.message.content
            if type(msg_content) == "string" then
                text = msg_content
            elseif type(msg_content) == "table" and msg_content[1] and msg_content[1].text then
                text = msg_content[1].text
            end
        end
    end

    text = tostring(text or "")
    local event_uuid = payload.uuid or utils.uuid()
    local content = {
        { type = "text", text = text }
    }

    return utils.json_encode({
        type = "user",
        role = "user",
        content = content,
        message = {
            role = "user",
            content = content
        },
        session_id = session_id,
        uuid = event_uuid,
        isReplay = true,
    })
end

local function is_turn_request(body)
    if type(body) ~= "table" then
        local decoded = utils.json_decode(body)
        if not decoded then
            return false
        end
        body = decoded
    end
    if type(body) ~= "table" then
        return false
    end
    if body.type == "turn_request" then
        return true
    end
    return body.type == "user" and body.session_id == nil
end

local function extract_text_message(msg)
    if type(msg) ~= "table" then
        return nil
    end

    if type(msg.content) == "string" then
        return msg.content
    end

    if type(msg.content) == "table" then
        local parts = {}
        for _, part in ipairs(msg.content) do
            if type(part) == "table" then
                if type(part.text) == "string" then
                    table.insert(parts, part.text)
                elseif type(part.content) == "string" then
                    table.insert(parts, part.content)
                end
            elseif type(part) == "string" then
                table.insert(parts, part)
            end
        end
        if #parts > 0 then
            return table.concat(parts, "")
        end
    end

    if type(msg.message) == "table" and type(msg.message.content) == "string" then
        return msg.message.content
    end

    if type(msg.message) == "table" and type(msg.message.content) == "table" then
        local parts = {}
        for _, part in ipairs(msg.message.content) do
            if type(part) == "table" then
                if type(part.text) == "string" then
                    table.insert(parts, part.text)
                elseif type(part.content) == "string" then
                    table.insert(parts, part.content)
                end
            elseif type(part) == "string" then
                table.insert(parts, part)
            end
        end
        if #parts > 0 then
            return table.concat(parts, "")
        end
    end

    return nil
end

local function upsert_session(session_id, patch)
    local dict = get_dict()
    local raw = dict:get(session_key(session_id))
    local info = raw and utils.json_decode(raw) or {}
    if not info then
        info = {}
    end

    for k, v in pairs(patch) do
        info[k] = v
    end

    dict:set(session_key(session_id), utils.json_encode(info))
    return info
end

local function session_turn_mode(session_id)
    local info = _M.get(session_id)
    if info and info.claude_initialized then
        return "resume"
    end
    return "session-id"
end

local function acquire_lock(session_id)
    return get_dict():add(lock_key(session_id), ngx.now(), LOCK_TTL)
end

local function release_lock(session_id)
    get_dict():delete(lock_key(session_id))
end

local function publish_to_session(session_id, payload)
    local sock = ngx.socket.tcp()
    sock:settimeouts(1000, 1000, 1000)

    local ok, err = sock:connect("127.0.0.1", 8081)
    if not ok then
        ngx.log(ngx.ERR, "nchan publish connect failed session=", session_id,
                " err=", err)
        return
    end

    local req = table.concat({
        "POST /pub/", session_id, " HTTP/1.1\r\n",
        "Host: 127.0.0.1:8081\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ", #payload, "\r\n",
        "Connection: close\r\n\r\n",
        payload,
    })

    local bytes, send_err = sock:send(req)
    if not bytes then
        ngx.log(ngx.ERR, "nchan publish send failed session=", session_id,
                " err=", send_err)
        sock:close()
        return
    end

    local status_line, read_err = sock:receive("*l")
    if not status_line then
        ngx.log(ngx.ERR, "nchan publish read failed session=", session_id,
                " err=", read_err)
        sock:close()
        return
    end

    local status = tonumber(status_line:match("^HTTP/%d%.%d%s+(%d%d%d)"))
    if not status or (status ~= 200 and status ~= 201 and status ~= 202 and status ~= 204) then
        ngx.log(ngx.ERR, "nchan publish failed session=", session_id,
                " status_line=", status_line)
    end

    while true do
        local line, hdr_err = sock:receive("*l")
        if not line or line == "" then
            break
        end
        if hdr_err then
            break
        end
    end

    sock:close()
end

local function publish_user_event(session_id, body)
    local payload = build_user_event_line(body, session_id)
    upsert_session(session_id, {
        last_user_text = extract_text_message(type(body) == "string" and utils.json_decode(body) or body),
        last_input_at = ngx.now(),
    })
    publish_to_session(session_id, payload)
    return payload
end

local function stderr_reader(proc, session_id)
    while true do
        local data, err = proc:stderr_read_any(4096)
        if err then
            if err ~= "closed" then
                ngx.log(ngx.ERR, "stderr read error for ", session_id, ": ", err)
            end
            break
        end

        if data then
            ngx.log(ngx.WARN, "stderr[", session_id, "]: ", data)
        end
    end
end

local function stdout_reader(proc, session_id)
    while true do
        local data, err, partial = proc:stdout_read_line()
        if err then
            if err == "closed" and partial then
                local decoded = utils.json_decode(partial)
                publish_to_session(session_id, partial)
                break
            end
            if err ~= "closed" then
                return nil, err
            end
            break
        end

        if data then
            local decoded = utils.json_decode(data)
            if decoded then
                if decoded.type == "system" and decoded.subtype == "init" and decoded.session_id then
                    upsert_session(session_id, {
                        claude_initialized = true,
                        claude_session_id = decoded.session_id,
                    })
                elseif decoded.type == "result" then
                    local session_info = _M.get(session_id) or {}
                    upsert_session(session_id, {
                        last_result = decoded.result,
                        last_exit_code = 0,
                        last_finished_at = ngx.now(),
                        claude_initialized = true,
                        claude_session_id = decoded.session_id or session_info.claude_session_id,
                    })
                end
                publish_to_session(session_id, data)
            else
                publish_to_session(session_id, data)
            end
        end
    end

    return true
end

local function run_turn(session_id, body, project_dir)
    local env_vars = build_env_vars()
    local claude_bin = os.getenv("CLAUDE_BIN") or "claude"
    local turn_mode = session_turn_mode(session_id)
    local proc_args = {
        claude_bin,
        "--print",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--include-partial-messages",
        "--verbose",
        "--dangerously-skip-permissions",
    }

    if turn_mode == "resume" then
        table.insert(proc_args, 2, "--resume")
        table.insert(proc_args, 3, _M.get(session_id).claude_session_id or session_id)
    end

    ngx.log(ngx.INFO, "spawn turn(): claude_bin=", claude_bin,
            " session=", session_id, " mode=", turn_mode,
            " env_count=", #env_vars)

    local proc, spawn_err = pipe.spawn(proc_args, {
        cwd = project_dir,
        merge_stderr = false,
        environ = env_vars,
    })

    if not proc then
        ngx.log(ngx.ERR, "spawn failed for ", session_id, ": ", spawn_err)
        ngx.log(ngx.ERR, "process_error session=", session_id, " stage=spawn error=", spawn_err or "unknown")
        upsert_session(session_id, {
            status = "failed",
            last_error = "spawn failed: " .. (spawn_err or "unknown"),
            last_started_at = ngx.now()
        })
        release_lock(session_id)
        return
    end

    proc:set_timeouts(0, 0, 0, 0)

    local current_info = _M.get(session_id) or {}
    upsert_session(session_id, {
        status = "running",
        pid = proc:pid(),
        last_started_at = ngx.now(),
        last_error = nil,
        claude_initialized = current_info.claude_initialized or false,
        claude_session_id = current_info.claude_session_id,
        turn_count = (current_info.turn_count or 0) + 1,
    })
    ngx.log(ngx.INFO, "process_started session=", session_id, " pid=", proc:pid())

    local stderr_thread = ngx.thread.spawn(stderr_reader, proc, session_id)
    local wait_thread = ngx.thread.spawn(function()
        return proc:wait()
    end)

    local input = build_user_event_line(body, session_id)
    if input:sub(-1) ~= "\n" then
        input = input .. "\n"
    end

    local bytes, write_err = proc:write(input)
    if not bytes then
        ngx.log(ngx.ERR, "stdin write failed for ", session_id, ": ", write_err)
        upsert_session(session_id, {
            status = "failed",
            last_error = "stdin write failed: " .. (write_err or "unknown"),
            last_finished_at = ngx.now()
        })
        ngx.log(ngx.ERR, "process_error session=", session_id, " stage=stdin_write error=", write_err or "unknown")
        pcall(function()
            proc:kill(9)
        end)
        if stderr_thread then
            pcall(ngx.thread.wait, stderr_thread)
        end
        release_lock(session_id)
        return
    end

    local ok, shutdown_err = proc:shutdown("stdin")
    if not ok then
        ngx.log(ngx.WARN, "stdin shutdown warning for ", session_id, ": ", shutdown_err)
    end

    local stdout_ok, stdout_err = stdout_reader(proc, session_id)
    if not stdout_ok then
        ngx.log(ngx.ERR, "stdout read failed for ", session_id, ": ", stdout_err)
        upsert_session(session_id, {
            status = "failed",
            last_error = "stdout read failed: " .. (stdout_err or "unknown"),
            last_finished_at = ngx.now()
        })
        ngx.log(ngx.ERR, "process_error session=", session_id, " stage=stdout_read error=", stdout_err or "unknown")
    end

    local wait_ok, reason, status = ngx.thread.wait(wait_thread)
    local exit_code = status
    if not wait_ok then
        upsert_session(session_id, {
            status = "failed",
            last_error = tostring(reason) .. ":" .. tostring(status),
            last_exit_code = status,
            last_finished_at = ngx.now()
        })
    else
        upsert_session(session_id, {
            status = "idle",
            last_exit_code = exit_code or 0,
            last_finished_at = ngx.now()
        })
    end
    ngx.log(ngx.INFO, "process_exit session=", session_id, " reason=", tostring(reason), " status=", tostring(exit_code))

    if stderr_thread then
        local ok_wait, wait_err = ngx.thread.wait(stderr_thread)
        if not ok_wait and wait_err then
            ngx.log(ngx.WARN, "stderr reader failed for ", session_id, ": ", wait_err)
        end
    end

    release_lock(session_id)
end

function _M.spawn(session_id, body)
    local dict = get_dict()
    local raw = dict:get(session_key(session_id))
    if not raw then
        return nil, "session not found"
    end

    if not is_turn_request(body) then
        return nil, "invalid turn request"
    end

    if not acquire_lock(session_id) then
        return nil, "session busy"
    end

    publish_user_event(session_id, body)

    local prefix = ngx.config.prefix()
    local project_dir = prefix .. "projects/" .. session_id
    os.execute("mkdir -p " .. project_dir)

    upsert_session(session_id, {
        status = "running",
        last_error = nil,
        last_input_at = ngx.now()
    })

    local ok, err = ngx.timer.at(0, function(premature, sid, turn_body, cwd)
        if premature then
            return
        end
        run_turn(sid, turn_body, cwd)
    end, session_id, body, project_dir)
    if not ok then
        release_lock(session_id)
        upsert_session(session_id, {
            status = "failed",
            last_error = "failed to schedule turn: " .. (err or "unknown"),
            last_finished_at = ngx.now()
        })
        return nil, "failed to schedule turn: " .. (err or "unknown")
    end

    return upsert_session(session_id, {
        status = "running",
        last_scheduled_at = ngx.now()
    })
end

function _M.list()
    local dict = get_dict()
    local keys = dict:get_keys(0)
    local sessions = {}
    for _, key in ipairs(keys) do
        if string.match(key, "^session:") then
            local raw = dict:get(key)
            if raw then
                local info = utils.json_decode(raw)
                if info then
                    info.locked = dict:get(lock_key(info.session_id or key:sub(9))) ~= nil
                    table.insert(sessions, info)
                end
            end
        end
    end
    return sessions
end

function _M.get(session_id)
    local raw = get_dict():get(session_key(session_id))
    if not raw then
        return nil
    end
    local info = utils.json_decode(raw)
    if info then
        info.locked = get_dict():get(lock_key(session_id)) ~= nil
    end
    return info
end

function _M.delete(session_id)
    local dict = get_dict()
    local info = _M.get(session_id)
    if not info then
        return true
    end

    if info.locked or info.status == "running" then
        return nil, "session busy"
    end

    dict:delete(session_key(session_id))
    dict:delete(lock_key(session_id))
    return true
end

return _M
