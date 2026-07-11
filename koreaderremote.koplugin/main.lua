-- KOReader Remote v0.1.1
-- Minimal local HTTP remote control for page turning.

local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local PORT = 8081
local PLUGIN_DIR = DataStorage:getDataDir() .. "/plugins/koreaderremote.koplugin"
local INDEX_FILE = PLUGIN_DIR .. "/web/index.html"

local HTTP_STATUS = {
    [200] = "OK",
    [204] = "No Content",
    [400] = "Bad Request",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [500] = "Internal Server Error",
    [503] = "Service Unavailable",
}

local Remote = WidgetContainer:extend{
    name = "koreaderremote",
    is_doc_only = false,
}

function Remote:init()
    self.ui.menu:registerToMainMenu(self)
end

function Remote:isRunning()
    return self.http_socket ~= nil
end

function Remote:openFirewall()
    if not Device:isKindle() or self.firewall_open then
        return
    end

    os.execute(string.format(
        "iptables -A INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        PORT
    ))
    os.execute(string.format(
        "iptables -A OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
        PORT
    ))
    self.firewall_open = true
end

function Remote:closeFirewall()
    if not Device:isKindle() or not self.firewall_open then
        return
    end

    os.execute(string.format(
        "iptables -D INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        PORT
    ))
    os.execute(string.format(
        "iptables -D OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
        PORT
    ))
    self.firewall_open = false
end

function Remote:start()
    if self:isRunning() then
        return true
    end

    logger.info("KOReaderRemote: starting server on port", PORT)

    local ServerClass = require("ui/message/simpletcpserver")
    self.http_socket = ServerClass:new{
        host = "*",
        port = PORT,
        receiveCallback = function(data, request_id)
            return self:onRequest(data, request_id)
        end,
    }

    local ok, err = self.http_socket:start()
    if not ok then
        logger.err("KOReaderRemote: failed to start server:", err)
        self.http_socket = nil
        UIManager:show(InfoMessage:new{
            text = string.format(
                _("KOReader Remote could not start on port %d.\n\n%s"),
                PORT,
                tostring(err)
            ),
        })
        return false
    end

    self.http_messagequeue = UIManager:insertZMQ(self.http_socket)
    self:openFirewall()

    UIManager:show(InfoMessage:new{
        text = string.format(
            _("KOReader Remote is running.\n\nOpen this address on your phone:\nhttp://KINDLE-IP:%d/"),
            PORT
        ),
        timeout = 5,
    })

    logger.info("KOReaderRemote: server started")
    return true
end

function Remote:stop()
    if not self:isRunning() then
        self:closeFirewall()
        return
    end

    logger.info("KOReaderRemote: stopping server")

    if self.http_socket then
        self.http_socket:stop()
        self.http_socket = nil
    end

    if self.http_messagequeue then
        UIManager:removeZMQ(self.http_messagequeue)
        self.http_messagequeue = nil
    end

    self:closeFirewall()
    logger.info("KOReaderRemote: server stopped")
end

function Remote:onEnterStandby()
    self:stop()
end

function Remote:onSuspend()
    self:stop()
end

function Remote:onExit()
    self:stop()
end

function Remote:onCloseWidget()
    self:stop()
end

function Remote:sendResponse(request_id, status, content_type, body)
    status = status or 500
    body = body or ""

    local headers = {
        string.format(
            "HTTP/1.0 %d %s",
            status,
            HTTP_STATUS[status] or "Unspecified"
        ),
        "Connection: close",
        "Cache-Control: no-store",
    }

    if content_type then
        table.insert(headers, "Content-Type: " .. content_type)
    end

    table.insert(headers, "Content-Length: " .. tostring(#body))
    table.insert(headers, "")
    table.insert(headers, body)

    if self.http_socket then
        self.http_socket:send(table.concat(headers, "\r\n"), request_id)
    end

    -- Treat remote activity like an input event so KOReader can reset
    -- its normal idle/suspend timers.
    return Event:new("InputEvent")
end

function Remote:readIndex()
    local file, err = io.open(INDEX_FILE, "rb")
    if not file then
        return nil, err
    end

    local body = file:read("*all")
    file:close()
    return body
end

function Remote:turnPage(delta)
    UIManager:nextTick(function()
        UIManager:sendEvent(Event:new("GotoViewRel", delta))
    end)
end

function Remote:onRequest(data, request_id)
    local method, uri = data:match("^(%u+)%s+([^%s]+)%s+HTTP/%d%.%d")
    if not method or not uri then
        return self:sendResponse(
            request_id,
            400,
            "text/plain; charset=utf-8",
            "Invalid HTTP request"
        )
    end

    -- Ignore the query string for v0.1.
    uri = uri:match("^([^?]*)") or uri
    logger.dbg("KOReaderRemote:", method, uri)

    if method ~= "GET" then
        return self:sendResponse(
            request_id,
            405,
            "text/plain; charset=utf-8",
            "Only GET is supported"
        )
    end

    if uri == "/" or uri == "/index.html" then
        local body, err = self:readIndex()
        if not body then
            logger.err("KOReaderRemote: could not read index.html:", err)
            return self:sendResponse(
                request_id,
                500,
                "text/plain; charset=utf-8",
                "Remote UI file is missing"
            )
        end
        return self:sendResponse(
            request_id,
            200,
            "text/html; charset=utf-8",
            body
        )
    end

    if uri == "/api/ping" then
        return self:sendResponse(
            request_id,
            200,
            "application/json; charset=utf-8",
            '{"ok":true,"version":"0.1.0"}'
        )
    end

    if uri == "/api/next" then
        self:turnPage(1)
        return self:sendResponse(
            request_id,
            200,
            "application/json; charset=utf-8",
            '{"ok":true,"action":"next"}'
        )
    end

    if uri == "/api/previous" then
        self:turnPage(-1)
        return self:sendResponse(
            request_id,
            200,
            "application/json; charset=utf-8",
            '{"ok":true,"action":"previous"}'
        )
    end

    if uri == "/favicon.ico" then
        return self:sendResponse(request_id, 204, nil, "")
    end

    return self:sendResponse(
        request_id,
        404,
        "text/plain; charset=utf-8",
        "Not found"
    )
end

function Remote:addToMainMenu(menu_items)
    menu_items.koreader_remote = {
        text = _("KOReader Remote"),
        -- No sorting_hint: place the plugin directly in KOReader's
        -- Tools menu instead of Tools -> More tools.
        sub_item_table = {
            {
                text_func = function()
                    if self:isRunning() then
                        return _("Stop remote server")
                    end
                    return _("Start remote server")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    if self:isRunning() then
                        self:stop()
                    else
                        self:start()
                    end
                    touchmenu_instance:updateItems()
                end,
            },
            {
                text_func = function()
                    if self:isRunning() then
                        return string.format(_("Listening on port %d"), PORT)
                    end
                    return _("Not running")
                end,
                enabled_func = function()
                    return self:isRunning()
                end,
                separator = true,
            },
            {
                text = _("Show connection address"),
                enabled_func = function()
                    return self:isRunning()
                end,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = string.format(
                            _("Open on your phone:\nhttp://KINDLE-IP:%d/"),
                            PORT
                        ),
                    })
                end,
            },
        },
    }
end

return Remote
