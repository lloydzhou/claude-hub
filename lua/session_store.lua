local _M = {}

local redis = require "resty.redis"
local utils = require "utils"

local SESSION_INDEX_KEY = "cw:sessions:index"

local function redis_config()
    return {
        host = os.getenv("REDIS_HOST") or "redis",
        port = tonumber(os.getenv("REDIS_PORT") or "6379"),
        db = tonumber(os.getenv("REDIS_DB") or "0"),
        password = os.getenv("REDIS_PASSWORD"),
        timeout = tonumber(os.getenv("REDIS_TIMEOUT_MS") or "1000"),
        prefix = os.getenv("REDIS_KEY_PREFIX") or "cw:",
    }
end

local function session_key(session_id)
    local cfg = redis_config()
    return cfg.prefix .. "session:" .. session_id
end

local function connect()
    local cfg = redis_config()
    local red = redis:new()
    red:set_timeouts(cfg.timeout, cfg.timeout, cfg.timeout)

    local ok, err = red:connect(cfg.host, cfg.port)
    if not ok then
        return nil, err
    end

    if cfg.password and cfg.password ~= "" then
        ok, err = red:auth(cfg.password)
        if not ok then
            pcall(function() red:close() end)
            return nil, err
        end
    end

    if cfg.db and cfg.db > 0 then
        ok, err = red:select(cfg.db)
        if not ok then
            pcall(function() red:close() end)
            return nil, err
        end
    end

    return red
end

local function keepalive(red)
    if not red then
        return
    end
    local ok, err = red:set_keepalive(10000, 100)
    if not ok and err then
        ngx.log(ngx.WARN, "redis keepalive failed: ", err)
    end
end

local function decode_session(raw)
    if not raw or raw == ngx.null then
        return nil
    end
    local info = utils.json_decode(raw)
    if not info then
        return nil
    end
    return info
end

local function store_session(info)
    if type(info) ~= "table" or type(info.session_id) ~= "string" then
        return nil, "invalid session info"
    end

    local red, err = connect()
    if not red then
        return nil, err
    end

    local encoded = utils.json_encode(info)
    local ok, set_err = red:set(session_key(info.session_id), encoded)
    if not ok then
        keepalive(red)
        return nil, set_err
    end

    ok, set_err = red:sadd(SESSION_INDEX_KEY, info.session_id)
    if not ok then
        keepalive(red)
        return nil, set_err
    end

    keepalive(red)
    return info
end

function _M.create(info)
    return store_session(info)
end

function _M.upsert(session_id, patch)
    local info, err = _M.get(session_id)
    if err and err ~= "not found" then
        return nil, err
    end

    info = info or { session_id = session_id }
    for k, v in pairs(patch or {}) do
        info[k] = v
    end
    info.session_id = session_id

    return store_session(info)
end

function _M.get(session_id)
    local red, err = connect()
    if not red then
        return nil, err
    end

    local raw
    raw, err = red:get(session_key(session_id))
    keepalive(red)
    if err then
        return nil, err
    end

    if raw == ngx.null then
        return nil, "not found"
    end

    local info = decode_session(raw)
    if not info then
        return nil, "invalid session data"
    end
    return info
end

function _M.list()
    local red, err = connect()
    if not red then
        return nil, err
    end

    local ids
    ids, err = red:smembers(SESSION_INDEX_KEY)
    if not ids then
        keepalive(red)
        return nil, err
    end

    if #ids == 0 then
        keepalive(red)
        return {}
    end

    local keys = {}
    for _, session_id in ipairs(ids) do
        table.insert(keys, session_key(session_id))
    end

    local rows
    rows, err = red:mget(unpack(keys))
    if not rows then
        keepalive(red)
        return nil, err
    end

    local sessions = {}
    for idx, raw in ipairs(rows) do
        local info = decode_session(raw)
        if info then
            table.insert(sessions, info)
        else
            local session_id = ids[idx]
            if session_id then
                ngx.log(ngx.WARN, "failed to load session ", session_id, ": invalid session data")
            end
        end
    end

    keepalive(red)

    if #sessions == 0 then
        return {}
    end

    table.sort(sessions, function(a, b)
        local at = tonumber(a.created_at or 0) or 0
        local bt = tonumber(b.created_at or 0) or 0
        return at > bt
    end)

    return sessions
end

function _M.delete(session_id)
    local red, err = connect()
    if not red then
        return nil, err
    end

    local ok, del_err = red:del(session_key(session_id))
    if not ok then
        keepalive(red)
        return nil, del_err
    end

    ok, del_err = red:srem(SESSION_INDEX_KEY, session_id)
    if not ok then
        keepalive(red)
        return nil, del_err
    end

    keepalive(red)
    return true
end

return _M
