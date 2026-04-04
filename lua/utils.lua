local _M = {}

local cjson = require "cjson.safe"

-- Generate UUID v4 (no external deps)
function _M.uuid()
    local random = math.random
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = random(0, 0xf)
        if c == "x" then return string.format("%x", v) end
        return string.format("%x", (v % 4) + 8)
    end)
end

-- Read request body as string
function _M.read_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "r")
            if f then
                body = f:read("*a")
                f:close()
            end
        end
    end
    return body
end

function _M.json_encode(data)
    return cjson.encode(data)
end

function _M.json_decode(str)
    if type(str) ~= "string" then return nil end
    return cjson.decode(str)
end

function _M.json_response(data, status)
    ngx.status = status or 200
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(data))
    ngx.exit(ngx.status)
end

function _M.error_response(msg, status)
    _M.json_response({ error = msg }, status or 400)
end

return _M
