--[[

Copyright (c) 2011-2015 chukong-inc.com

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

]]

local DEBUG = DEBUG
local type = type
local tostring = tostring
local ngx = ngx
local ngx_log = ngx.log
local ngx_thread_spawn = ngx.thread.spawn
local req_read_body = ngx.req.read_body
local req_get_headers = ngx.req.get_headers
local table_insert = table.insert
local table_concat = table.concat
local string_format = string.format
local string_sub = string.sub

local ConnectBase = import(".ConnectBase")

local WebSocketConnectBase = class("WebSocketConnectBase", ConnectBase)

local Constants = import(".Constants")

function WebSocketConnectBase:ctor(config)
    WebSocketConnectBase.super.ctor(self, config)

    self.config.websocketsTimeout       = self.config.websocketsTimeout or Constants.WEBSOCKET_DEFAULT_TIME_OUT
    self.config.websocketsMaxPayloadLen = self.config.websocketsMaxPayloadLen or Constants.WEBSOCKET_DEFAULT_MAX_PAYLOAD_LEN
    self.config.maxSubscribeRetryCount  = self.config.maxSubscribeRetryCount or Constants.WEBSOCKET_DEFAULT_MAX_SUB_RETRY_COUNT

    self._requestType = Constants.WEBSOCKET_REQUEST_TYPE
    self._channelEnabled = false
    self._subscribeRetryCount = 0
end

function WebSocketConnectBase:run()
    local ok, err = xpcall(function()
        self:_authConnect()
        self:runEventLoop()
    end, function(err)
        if DEBUG > 1 then
            ngx_log(ngx.ERR, err .. debug.traceback("", 4))
        else
            ngx_log(ngx.ERR, err)
        end
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.exit(ngx.ERROR)
    end)
end

function WebSocketConnectBase:runEventLoop()
    self:beforeConnectReady()

    local server = require("resty.websocket.server")
    local socket, err = server:new({
        timeout = self.config.websocketsTimeout,
        max_payload_len = self.config.websocketsMaxPayloadLen,
    })
    if err then
        throw("failed to create websocket server, %s", err)
    end

    -- ready
    self._socket = socket

    -- spawn a thread to subscribe redis channel for broadcast
    self:_subscribeChannel()

    -- event callback
    self:afterConnectReady()

    local retryCount = 0
    local framesPool = {}
    -- event loop
    while true do
        --[[
        Receives a WebSocket frame from the wire.

        In case of an error, returns two nil values and a string describing the error.

        The second return value is always the frame type, which could be
        one of continuation, text, binary, close, ping, pong, or nil (for unknown types).

        For close frames, returns 3 values: the extra status message
        (which could be an empty string), the string "close", and a Lua number for
        the status code (if any). For possible closing status codes, see

        http://tools.ietf.org/html/rfc6455#section-7.4.1

        For other types of frames, just returns the payload and the type.

        For fragmented frames, the err return value is the Lua string "again".
        ]]
        local frame, ftype, err = socket:recv_frame()
        if err then
            if err == "again" then
                framesPool[#framesPool + 1] = frame
                goto recv_next_message
            end

            if string_sub(err, -7) == "timeout" then
                goto recv_next_message
            end

            printWarn("failed to receive frame, type \"%s\", %s", ftype, err)
            break
        end

        if #framesPool > 0 then
            -- merging fragmented frames
            framesPool[#framesPool + 1] = frame
            frame = table.concat(framesPool)
            framesPool = {}
        end

        if ftype == "close" then
            break -- exit event loop
        elseif ftype == "ping" then
            local bytes, err = socket:send_pong()
            if err then
                printWarn("failed to send pong, %s", err)
            end
        elseif ftype == "pong" then
            -- client ponged
        elseif ftype == "text" or ftype == "binary" then
            local ok, err = self:_processMessage(frame, ftype)
            if err then
                printWarn("process %s message failed, %s", ftype, err)
            end
        else
            printWarn("unknwon frame type \"%s\"", tostring(ftype))
        end

::recv_next_message::

    end -- while

    -- end the subscribe thread
    self:_unsubscribeChannel()

    -- cleanup tag
    self:beforeConnectClose()
    self:removeConnectTag()

    -- close connect
    self._socket:send_close()
    self._socket = nil

    self:afterConnectClose()
end

function WebSocketConnectBase:_processMessage(rawMessage, messageType)
    local message = self:_parseMessage(rawMessage, messageType)
    local msgid = message.__id
    local actionName = message.action
    local err = nil
    local ok, result = xpcall(function()
        return self:runAction(actionName, message, true) -- true = persistent action instance
    end, function(_err)
        err = _err
        if DEBUG > 1 then
            err = err .. debug.traceback("", 4)
        end
    end)
    if err then
        return nil, err
    end

    local rtype = type(result)
    if rtype == "nil" then return end
    if rtype ~= "table" then
        if msgid then
            printWarn("action \"%s\" return invalid result for message [__id:\"%s\"]", actionName, msgid)
        else
            printWarn("action \"%s\" return invalid result", actionName)
        end
    end

    if not msgid then
        printWarn("action \"%s\" return unused result", actionName)
        return true
    end

    if not self._socket then
        return nil, string.format("socket removed, action \"%s\"", actionName)
    end

    result.__id = msgid
    local message = json.encode(result)
    local bytes, err = self._socket:send_text(message)
    if err then
        return nil, string.format("send message to client failed, %s", err)
    end

    return true
end

function WebSocketConnectBase:_parseMessage(rawMessage, messageType)
    -- TODO: support message type plugin
    if messageType ~= Constants.WEBSOCKET_TEXT_MESSAGE_TYPE then
        throw("not supported message type \"%s\"", messageType)
    end

    -- TODO: support message format plugin
    if self.config.websocketsMessageFormat == "json" then
        local message = json.decode(rawMessage)
        if type(message) == "table" then
            return message
        else
            throw("not supported message format \"%s\"", type(message))
        end
    else
        throw("not support message format \"%s\"", tostring(self.config.websocketsMessageFormat))
    end
end

function WebSocketConnectBase:_subscribeChannel()
    if self._channelEnabled then
        printWarn("already subscribed broadcast channel \"%s\"", self._channel)
        return
    end

    local function subscribe()
        self._channelEnabled = true
        local isRunning = true

        -- pubsub thread need separated redis connect
        local redis = self:_newRedis()

        local channel = self._channel
        local loop, err = redis:pubsub({subscribe = channel})
        if not loop then
            throw("subscribe channel \"%s\" failed, %s", channel, err)
        end

        for msg, abort in loop do
            if msg.kind == "subscribe" then
                printInfo("subscribe channel \"%s\"", channel)
            elseif msg.kind == "message" then
                local payload = msg.payload
                printInfo("get msg from channel \"%s\", msg: %s", channel, payload)
                if payload == "QUIT" then
                    -- quit connect thread
                    if self._socket then
                        self._socket:send_close()
                    end
                    abort()
                    isRunning = false
                    break
                end
                -- forward message to client
                self._socket:send_text(payload)
            end
        end

        -- when error occured or exit normally,
        -- connect will auto close, channel will be unsubscribed
        self._channelEnabled = false
        redis:setKeepAlive()

        -- if recv "QUIT", exit thread
        if not isRunning then return end

        -- if an error leads to an exiting, retry to subscribe channel
        if self._subscribeRetryCount < self.config.maxSubscribeRetryCount then
            self._subscribeRetryCount = self._subscribeRetryCount + 1
            printWarn("subscribe channel \"%s\" loop ended, try [%d]", channel, self._subscribeRetryCount)
            self:_subscribeChannel()
        else
            printWarn("subscribe channel \"%s\" loop ended, max try", channel)
        end
    end

    ngx_thread_spawn(subscribe)
end

function WebSocketConnectBase:_unsubscribeChannel()
    local redis = self:_getRedis()
    redis:command("PUBLISH", self._channel, "QUIT")
end

function WebSocketConnectBase:_authConnect()
    if ngx.headers_sent then
        throw("response header already sent")
    end

    req_read_body()
    local headers = ngx.req.get_headers()
    local protocols = headers["sec-websocket-protocol"]
    if type(protocols) == "table" then
        protocols = protocols[1]
    end
    if not protocols then
        throw("not set header: Sec-WebSocket-Protocol")
    end

    local token = string.match(protocols, Constants.WEBSOCKET_SUBPROTOCOL_PATTERN)
    if not token then
        throw("not found token in header: Sec-WebSocket-Protocol")
    end

    -- convert token to session id
    local sid = self:convertTokenToSessionId(token)
    if not sid then
        throw("convertTokenToSessionId() return invalid sid")
    end

    local session = self:openSession(sid)
    if not session then
        throw("not set valid session id in header: Sec-WebSocket-Protocol")
    end

    -- save connect id in session
    local connectId = self:getConnectId()
    session:setConnectId(connectId)
    session:setKeepAlive()
    session:save()
    self._channel = Constants.CONNECT_CHANNEL_PREFIX .. connectId
end

function WebSocketConnectBase:getConnectId()
    if not self._connectId then
        local redis = self:_getRedis()
        self._connectId = tostring(redis:command("INCR", Constants.NEXT_CONNECT_ID_KEY))
    end
    return self._connectId
end

function WebSocketConnectBase:setConnectTag(tag)
    if not tag then
        throw("set connect tag with invalid tag \"%s\"", tostring(tag))
    else
        if self._connectTag then
            self:removeConnectTag()
        end

        local connectId = self:getConnectId()
        tag = tostring(tag)
        local pipe = self:_getRedis():newPipeline()
        pipe:command("HMSET", Constants.CONNECTS_ID_DICT_KEY, connectId, tag)
        pipe:command("HMSET", Constants.CONNECTS_TAG_DICT_KEY, tag, connectId)
        pipe:commit()
        self._connectTag = tag
    end
end

function WebSocketConnectBase:getConnectTag()
    if not self._connectTag then
        local connectId = self:getConnectId()
        local redis = self:_getRedis()
        self._connectTag = redis:command("HGET", Constants.CONNECTS_ID_DICT_KEY, connectId)
    end
    return self._connectTag
end

function WebSocketConnectBase:removeConnectTag()
    if not self._connectId then return end
    local connectId = self:getConnectId()
    local tag = self:getConnectTag()
    local pipe = self:_getRedis():newPipeline()
    pipe:command("HDEL", Constants.CONNECTS_ID_DICT_KEY, connectId)
    pipe:command("HDEL", Constants.CONNECTS_TAG_DICT_KEY, tag)
    pipe:commit()
end

function WebSocketConnectBase:beforeConnectReady()
end

function WebSocketConnectBase:afterConnectReady()
end

function WebSocketConnectBase:beforeConnectClose()
end

function WebSocketConnectBase:afterConnectClose()
end

function WebSocketConnectBase:convertTokenToSessionId(token)
    return token
end

return WebSocketConnectBase