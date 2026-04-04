-- app.lua
-- Main application entry point using router.lua
-- All API routes are defined here in one place

local router = require "router"
local utils = require "utils"
local pm = require "process_manager"

local _M = {}

-- Build the router with all routes
local function build_router()
    local r = router.new()

    -- --- Session CRUD ---
    r:post("/api/sessions", function(params)
        local id = utils.uuid()
        local info = {
            session_id = id,
            claude_initialized = false,
            turn_count = 0,
            status = "idle",
            created_at = ngx.now()
        }
        local dict = ngx.shared.sessions
        dict:set("session:" .. id, utils.json_encode(info))
        utils.json_response({
            session_id = id,
            subscribe_url = "/sub/" .. id,
            publish_url = "/pub/" .. id,
            info = info
        }, 201)
    end)

    r:get("/api/sessions", function(params)
        local sessions = pm.list()
        utils.json_response({ sessions = sessions })
    end)

    r:get("/api/sessions/:id", function(params)
        local info = pm.get(params.id)
        if not info then
            utils.error_response("session not found", 404)
            return
        end
        utils.json_response(info)
    end)

    r:delete("/api/sessions/:id", function(params)
        local ok, err = pm.delete(params.id)
        if not ok then
            local status = (err == "session busy") and 409 or 500
            utils.error_response("failed to delete session: " .. (err or "unknown"), status)
            return
        end
        utils.json_response({ status = "deleted", session_id = params.id })
    end)

    -- --- Publish one Claude turn ---
    r:post("/pub/:id", function(params)
        local session_id = params.id
        local info = pm.get(session_id)
        if not info then
            utils.error_response("session not found", 404)
            return
        end

        local body = utils.read_body()
        if not body or body == "" then
            utils.error_response("empty body")
            return
        end

        local ok, err = pm.spawn(session_id, body)
        if not ok then
            local status = (err == "session busy") and 409 or 500
            utils.error_response(err or "failed to start turn", status)
            return
        end

        utils.json_response({ status = "queued", session_id = session_id }, 202)
    end)

    -- --- Health check ---
    r:get("/api/health", function(params)
        utils.json_response({ status = "ok", timestamp = ngx.now() })
    end)

    return r
end

-- Cache the router instance at module level (built once per worker)
local r = build_router()

function _M.dispatch()
    local method = ngx.req.get_method()
    local uri = ngx.var.uri

    -- Strip trailing slash (except root)
    if uri ~= "/" and uri:sub(-1) == "/" then
        uri = uri:sub(1, -2)
    end

    local ok, err = r:execute(method, uri, ngx.req.get_uri_args())
    if not ok then
        ngx.log(ngx.WARN, "route not found: ", method, " ", uri, " - ", tostring(err))
        utils.error_response("not found", 404)
    end
end

return _M
