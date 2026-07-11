-- KOReader Remote v0.3.0
-- Local HTTP remote control for page turning.

local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local VERSION = "0.3.0"
local DEFAULT_PORT = 8081
local LEGACY_SETTINGS_KEY = "koreaderremote"
local PORT_SETTINGS_KEY = "koreaderremote_port"
local AUTOSTART_SETTINGS_KEY = "koreaderremote_autostart"
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

local function isUsableIPv4(address)
    if type(address) ~= "string"
        or address == "0.0.0.0"
        or address == "127.0.0.1" then
        return false
    end

    local a, b, c, d = address:match(
        "^(%d+)%.(%d+)%.(%d+)%.(%d+)$"
    )

    if not a then
        return false
    end

    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)

    return a <= 255 and b <= 255 and c <= 255 and d <= 255
end

function Remote:init()
    self.port = tonumber(G_reader_settings:readSetting(PORT_SETTINGS_KEY))
        or DEFAULT_PORT
    self.autostart = G_reader_settings:isTrue(AUTOSTART_SETTINGS_KEY)

    -- Migrate settings written by previous v0.2 builds.
    local legacy = G_reader_settings:readSetting(LEGACY_SETTINGS_KEY)
    if type(legacy) == "table" then
        if legacy.port and not G_reader_settings:has(PORT_SETTINGS_KEY) then
            self.port = tonumber(legacy.port) or DEFAULT_PORT
            G_reader_settings:saveSetting(PORT_SETTINGS_KEY, self.port)
        end

        if legacy.autostart == true
            and not G_reader_settings:has(AUTOSTART_SETTINGS_KEY) then
            self.autostart = true
            G_reader_settings:makeTrue(AUTOSTART_SETTINGS_KEY)
        end
    end

    self.ui.menu:registerToMainMenu(self)
    logger.info("KOReaderRemote: plugin initialized, version", VERSION)

    if self.autostart then
        UIManager:nextTick(function()
            self:start(true)
        end)
    end
end

function Remote:isRunning()
    return self.http_socket ~= nil
end

function Remote:getPort()
    return tonumber(self.port) or DEFAULT_PORT
end

function Remote:setPort(port)
    self.port = math.floor(port)
    G_reader_settings:saveSetting(PORT_SETTINGS_KEY, self.port)
end

function Remote:setAutostart(enabled)
    self.autostart = enabled == true

    if self.autostart then
        G_reader_settings:makeTrue(AUTOSTART_SETTINGS_KEY)
    else
        G_reader_settings:delSetting(AUTOSTART_SETTINGS_KEY)
    end
end

function Remote:detectLocalIP()
    -- Preferred method: ask the kernel which local address it would use for
    -- the default IPv4 route. This creates no real network traffic.
    local socket = require("socket")
    local udp, err = socket.udp()

    if udp then
        local ok
        ok, err = udp:setpeername("203.0.113.1", "53")

        if ok then
            local address = udp:getsockname()
            udp:close()

            if isUsableIPv4(address) then
                return address
            end
        else
            udp:close()
            logger.dbg(
                "KOReaderRemote: UDP route IP detection failed:",
                err
            )
        end
    else
        logger.dbg(
            "KOReaderRemote: could not create UDP socket for IP detection:",
            err
        )
    end

    -- Fallback for platforms where the Lua socket route method is unavailable.
    local NetworkMgr = require("ui/network/manager")
    local interface = NetworkMgr.interface

    if not interface and NetworkMgr.getNetworkInterfaceName then
        interface = NetworkMgr:getNetworkInterfaceName()
    end

    local commands = {}

    if type(interface) == "string"
        and interface:match("^[%w_.:-]+$") then
        table.insert(
            commands,
            string.format(
                "ip -4 -o addr show dev %s scope global 2>/dev/null",
                interface
            )
        )
        table.insert(
            commands,
            string.format("ifconfig %s 2>/dev/null", interface)
        )
    end

    table.insert(commands, "hostname -I 2>/dev/null")

    for _, command in ipairs(commands) do
        local opened, pipe = pcall(io.popen, command)

        if opened and pipe then
            local output = pipe:read("*all") or ""
            pipe:close()

            for address in output:gmatch("(%d+%.%d+%.%d+%.%d+)") do
                if isUsableIPv4(address) then
                    return address
                end
            end
        end
    end

    return nil
end

function Remote:refreshConnectionInfo()
    self.local_ip = self:detectLocalIP()

    if self.local_ip then
        self.connection_url = string.format(
            "http://%s:%d/",
            self.local_ip,
            self.running_port or self:getPort()
        )
        logger.info(
            "KOReaderRemote: detected connection URL",
            self.connection_url
        )
    else
        self.connection_url = nil
        logger.warn("KOReaderRemote: no usable IPv4 address detected")
    end

    return self.connection_url
end

function Remote:getConnectionURL(refresh)
    if refresh or not self.connection_url then
        return self:refreshConnectionInfo()
    end

    return self.connection_url
end

function Remote:showQRCode()
    local url = self:getConnectionURL(true)

    if not url then
        UIManager:show(InfoMessage:new{
            text = _(
                "No network address could be detected.\n\n"
                .. "Connect the Kindle to Wi-Fi and try again."
            ),
        })
        return
    end

    local QRMessage = require("ui/widget/qrmessage")

    UIManager:show(QRMessage:new{
        text = url,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
    })
end

function Remote:showPairingDialog()
    local url = self:getConnectionURL(true)

    if not url then
        UIManager:show(InfoMessage:new{
            text = string.format(
                _(
                    "KOReader Remote is running on port %d, "
                    .. "but no network address could be detected.\n\n"
                    .. "Connect the Kindle to Wi-Fi and select "
                    .. "\"Pair phone\" again."
                ),
                self.running_port or self:getPort()
            ),
        })
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")

    UIManager:show(ConfirmBox:new{
        text = string.format(
            _(
                "KOReader Remote is running.\n\n"
                .. "IP address: %s\n\n"
                .. "Pairing link:\n%s"
            ),
            self.local_ip,
            url
        ),
        ok_text = _("Show QR code"),
        ok_callback = function()
            self:showQRCode()
        end,
        cancel_text = _("Close"),
    })
end

function Remote:openFirewall(port)
    if not Device:isKindle() or self.firewall_port then
        return
    end

    os.execute(string.format(
        "iptables -A INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        port
    ))
    os.execute(string.format(
        "iptables -A OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
        port
    ))

    self.firewall_port = port
end

function Remote:closeFirewall()
    if not Device:isKindle() or not self.firewall_port then
        return
    end

    local port = self.firewall_port

    os.execute(string.format(
        "iptables -D INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        port
    ))
    os.execute(string.format(
        "iptables -D OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
        port
    ))

    self.firewall_port = nil
end

function Remote:start(silent)
    if self:isRunning() then
        if not silent then
            self:showPairingDialog()
        end
        return true
    end

    local port = self:getPort()
    logger.info("KOReaderRemote: starting server on port", port)

    local ServerClass = require("ui/message/simpletcpserver")
    self.http_socket = ServerClass:new{
        host = "*",
        port = port,
        receiveCallback = function(data, request_id)
            return self:onRequest(data, request_id)
        end,
    }

    local ok, err = self.http_socket:start()
    if not ok then
        logger.err("KOReaderRemote: failed to start server:", err)
        self.http_socket = nil
        self.running_port = nil
        self:closeFirewall()

        if not silent then
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _("KOReader Remote could not start on port %d.\n\n%s"),
                    port,
                    tostring(err)
                ),
            })
        end

        return false
    end

    self.running_port = port
    self.http_messagequeue = UIManager:insertZMQ(self.http_socket)
    self:openFirewall(port)
    self:refreshConnectionInfo()

    if not silent then
        self:showPairingDialog()
    end

    logger.info("KOReaderRemote: server started")
    return true
end

function Remote:stop()
    if not self:isRunning() then
        self.running_port = nil
        self.connection_url = nil
        self.local_ip = nil
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

    self.running_port = nil
    self.connection_url = nil
    self.local_ip = nil
    self:closeFirewall()
    logger.info("KOReaderRemote: server stopped")
end

function Remote:onNetworkConnected()
    if self:isRunning() then
        self:refreshConnectionInfo()
    elseif self.autostart then
        self:start(true)
    end
end

function Remote:onNetworkDisconnected()
    self.connection_url = nil
    self.local_ip = nil
end

function Remote:onEnterStandby()
    self:stop()
end

function Remote:onSuspend()
    self:stop()
end

function Remote:onLeaveStandby()
    if self.autostart and not self:isRunning() then
        self:start(true)
    end
end

function Remote:onResume()
    if self.autostart and not self:isRunning() then
        self:start(true)
    end
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
        local ip_json = self.local_ip
            and string.format('"%s"', self.local_ip)
            or "null"
        local url_json = self.connection_url
            and string.format('"%s"', self.connection_url)
            or "null"
        local body = string.format(
            '{"ok":true,"version":"%s","port":%d,'
            .. '"autostart":%s,"ip":%s,"url":%s}',
            VERSION,
            self.running_port or self:getPort(),
            self.autostart and "true" or "false",
            ip_json,
            url_json
        )

        return self:sendResponse(
            request_id,
            200,
            "application/json; charset=utf-8",
            body
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

function Remote:showPortDialog(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")

    self.port_dialog = InputDialog:new{
        title = _("Set remote-control port"),
        input = tostring(self:getPort()),
        input_type = "number",
        input_hint = tostring(DEFAULT_PORT),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.port_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local port = tonumber(self.port_dialog:getInputText())

                        if not port or port < 1 or port > 65535 then
                            UIManager:show(InfoMessage:new{
                                text = _("Enter a port between 1 and 65535."),
                            })
                            return
                        end

                        local was_running = self:isRunning()

                        if was_running then
                            self:stop()
                        end

                        self:setPort(port)
                        UIManager:close(self.port_dialog)

                        if was_running then
                            self:start()
                        end

                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }

    UIManager:show(self.port_dialog)
    self.port_dialog:onShowKeyboard()
end

function Remote:addToMainMenu(menu_items)
    menu_items.koreader_remote = {
        text = _("KOReader Remote"),
        sorting_hint = "tools",
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
                    if self:isRunning() and self.connection_url then
                        return self.connection_url
                    end

                    if self:isRunning() then
                        return string.format(
                            _("Listening on port %d"),
                            self.running_port or self:getPort()
                        )
                    end

                    return _("Not running")
                end,
                enabled_func = function()
                    return self:isRunning()
                end,
                callback = function()
                    self:showPairingDialog()
                end,
                separator = true,
            },
            {
                text = _("Pair phone / show QR code"),
                enabled_func = function()
                    return self:isRunning()
                end,
                callback = function()
                    self:showPairingDialog()
                end,
            },
            {
                text = _("Auto start remote server"),
                checked_func = function()
                    return self.autostart == true
                end,
                callback = function()
                    self:setAutostart(not self.autostart)
                end,
            },
            {
                text_func = function()
                    return string.format(_("Port: %d"), self:getPort())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showPortDialog(touchmenu_instance)
                end,
            },
        },
    }
end

return Remote
