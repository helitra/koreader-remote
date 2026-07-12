-- KOReader Remote v0.5.0
-- Local HTTP remote control for page turning.

local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local VERSION = "0.5.0"
local DEFAULT_PORT = 8081
local LEGACY_SETTINGS_KEY = "koreaderremote"
local PORT_SETTINGS_KEY = "koreaderremote_port"
local AUTOSTART_SETTINGS_KEY = "koreaderremote_autostart"
local PLUGIN_DIR = DataStorage:getDataDir() .. "/plugins/koreaderremote.koplugin"
local INDEX_FILE = PLUGIN_DIR .. "/web/index.html"

local STATE_STOPPED = "stopped"
local STATE_WAITING = "waiting_for_wifi"
local STATE_STARTING = "starting"
local STATE_RUNNING = "running"
local STATE_RETRYING = "retrying"
local STATE_ERROR = "error"

-- Covers KOReader's potentially slow Wi-Fi restore window without retrying
-- forever. A later NetworkConnected event can still recover after this list.
local RETRY_DELAYS = { 2, 5, 10, 20, 30 }
local MANUAL_SLEEP_GRACE_SECONDS = 5 * 60

local HTTP_STATUS = {
    [200] = "OK",
    [204] = "No Content",
    [400] = "Bad Request",
    [409] = "Conflict",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [500] = "Internal Server Error",
    [503] = "Service Unavailable",
}

local Remote = WidgetContainer:extend{
    name = "koreaderremote",
    is_doc_only = false,
}

-- PluginLoader evaluates third-party plugins with dofile() for each UI. Keep
-- the server and session state in package.loaded so changing between ReaderUI
-- and FileManagerUI does not destroy a manually started remote session.
local RUNTIME_KEY = "koreaderremote.runtime.v1"
local runtime = package.loaded[RUNTIME_KEY]

if type(runtime) ~= "table" then
    runtime = {
        owner = nil,
        http_socket = nil,
        http_messagequeue = nil,
        running_port = nil,
        firewall_port = nil,
        state = STATE_STOPPED,
        last_error = nil,
        network_ready = false,
        request_origin = nil,
        manual_session = false,
        user_stopped = false,
        retry_index = 0,
        retry_scheduled = false,
        retry_action = nil,
        local_ip = nil,
        connection_url = nil,
        qr_url = nil,
        connection_revision = 0,
        sleep_started_at = nil,
        sleeping = false,
        document_open = false,
    }
    package.loaded[RUNTIME_KEY] = runtime
end

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
    runtime.autostart = G_reader_settings:isTrue(AUTOSTART_SETTINGS_KEY)
    runtime.owner = self
    runtime.document_open = self.ui ~= nil and self.ui.document ~= nil

    -- Keep one stable function reference so UIManager:unschedule() can remove
    -- it, while always dispatching to the newest plugin instance.
    if not runtime.retry_action then
        runtime.retry_action = function()
            local owner = runtime.owner
            if owner then
                owner:onRetryTimer()
            end
        end
    end

    -- Migrate settings written by previous v0.2 builds.
    local legacy = G_reader_settings:readSetting(LEGACY_SETTINGS_KEY)
    if type(legacy) == "table" then
        if legacy.port and not G_reader_settings:has(PORT_SETTINGS_KEY) then
            self.port = tonumber(legacy.port) or DEFAULT_PORT
            G_reader_settings:saveSetting(PORT_SETTINGS_KEY, self.port)
        end

        if legacy.autostart == true
            and not G_reader_settings:has(AUTOSTART_SETTINGS_KEY) then
            runtime.autostart = true
            G_reader_settings:makeTrue(AUTOSTART_SETTINGS_KEY)
        end
    end

    self.ui.menu:registerToMainMenu(self)
    logger.info("KOReaderRemote: plugin initialized, version", VERSION)

    -- A running server belongs to the KOReader process, not to one book or UI.
    if runtime.http_socket then
        return
    end

    if runtime.autostart
        and not runtime.user_stopped
        and not runtime.request_origin then
        runtime.request_origin = "autostart"
        UIManager:nextTick(function()
            local owner = runtime.owner
            if owner then
                owner:attemptRecovery(true, "startup")
            end
        end)
    end
end

-- Settings ------------------------------------------------------------------

function Remote:isRunning()
    return runtime.http_socket ~= nil
end

function Remote:hasStartRequest()
    return runtime.request_origin ~= nil
end

function Remote:getPort()
    return tonumber(self.port) or DEFAULT_PORT
end

function Remote:setPort(port)
    self.port = math.floor(port)
    G_reader_settings:saveSetting(PORT_SETTINGS_KEY, self.port)
end

function Remote:setAutostart(enabled)
    runtime.autostart = enabled == true

    if runtime.autostart then
        runtime.user_stopped = false
        G_reader_settings:makeTrue(AUTOSTART_SETTINGS_KEY)
    else
        G_reader_settings:delSetting(AUTOSTART_SETTINGS_KEY)

        -- Disabling autostart should cancel an automatic pending start, but it
        -- should not stop a server that is already running.
        if runtime.request_origin == "autostart" then
            if self:isRunning() then
                runtime.request_origin = "manual"
                runtime.manual_session = true
            else
                runtime.request_origin = nil
                runtime.manual_session = false
                self:cancelRetry()
                self:setState(STATE_STOPPED)
            end
        end
    end
end

-- State and retry handling ---------------------------------------------------

function Remote:setState(state, last_error)
    if runtime.state ~= state or runtime.last_error ~= last_error then
        logger.info(
            "KOReaderRemote: state",
            tostring(runtime.state),
            "->",
            tostring(state),
            last_error and ("(" .. tostring(last_error) .. ")") or ""
        )
    end

    runtime.state = state
    runtime.last_error = last_error
end

function Remote:getStateText()
    if runtime.state == STATE_RUNNING then
        return _("Running")
    elseif runtime.state == STATE_WAITING then
        return _("Waiting for Wi-Fi")
    elseif runtime.state == STATE_STARTING then
        return _("Starting")
    elseif runtime.state == STATE_RETRYING then
        return _("Retrying")
    elseif runtime.state == STATE_ERROR then
        return _("Error")
    end

    return _("Stopped")
end

function Remote:cancelRetry(reset_counter)
    if runtime.retry_action then
        UIManager:unschedule(runtime.retry_action)
    end

    runtime.retry_scheduled = false

    if reset_counter ~= false then
        runtime.retry_index = 0
    end
end

function Remote:scheduleRetry()
    if runtime.sleeping
        or runtime.retry_scheduled
        or not self:hasStartRequest() then
        return false
    end

    if runtime.retry_index >= #RETRY_DELAYS then
        self:setState(STATE_WAITING)
        logger.info("KOReaderRemote: retry window exhausted; waiting for NetworkConnected")
        return false
    end

    runtime.retry_index = runtime.retry_index + 1
    local delay = RETRY_DELAYS[runtime.retry_index]

    runtime.retry_scheduled = true

    if runtime.retry_index == 1 then
        self:setState(STATE_WAITING)
    else
        self:setState(STATE_RETRYING)
    end

    logger.info(
        "KOReaderRemote: scheduling network retry",
        runtime.retry_index,
        "in",
        delay,
        "seconds"
    )

    UIManager:scheduleIn(delay, runtime.retry_action)
    return true
end

function Remote:onRetryTimer()
    runtime.retry_scheduled = false

    if runtime.sleeping or not self:hasStartRequest() then
        return
    end

    self:attemptRecovery(true, "retry")
end

-- Network detection ----------------------------------------------------------

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

function Remote:isNetworkReady()
    -- queryNetworkState updates KOReader's cached connection state. If a
    -- platform cannot provide it reliably, a successfully detected IPv4
    -- address remains the final source of truth for this local-only plugin.
    local state_ok, connected = pcall(function()
        NetworkMgr:queryNetworkState()
        return NetworkMgr:getConnectionState()
    end)

    local ip = self:detectLocalIP()

    if state_ok and connected == false then
        return false, nil
    end

    return ip ~= nil, ip
end

function Remote:updateConnectionInfo(ip)
    if not isUsableIPv4(ip) then
        return false
    end

    local port = runtime.running_port or self:getPort()
    local new_url = string.format("http://%s:%d/", ip, port)

    -- Keep the existing URL and QR payload when nothing actually changed.
    -- This is important after standby when the device receives the same IP.
    if runtime.local_ip == ip and runtime.connection_url == new_url then
        return false
    end

    local old_url = runtime.connection_url

    runtime.local_ip = ip
    runtime.connection_url = new_url
    runtime.qr_url = new_url
    runtime.connection_revision = runtime.connection_revision + 1

    logger.info(
        "KOReaderRemote: connection URL changed",
        old_url or "<none>",
        "->",
        new_url
    )

    return true
end

function Remote:refreshConnectionInfo(known_ip)
    local ip = known_ip or self:detectLocalIP()

    if not isUsableIPv4(ip) then
        runtime.network_ready = false
        return nil, false
    end

    runtime.network_ready = true
    local changed = self:updateConnectionInfo(ip)

    return runtime.connection_url, changed
end

function Remote:getConnectionURL(refresh)
    if refresh then
        local ready, ip = self:isNetworkReady()

        if not ready then
            runtime.network_ready = false
            return nil
        end

        return self:refreshConnectionInfo(ip)
    end

    if not runtime.network_ready then
        return nil
    end

    return runtime.connection_url
end

-- Pairing and diagnostics ----------------------------------------------------

function Remote:showQRCode()
    local url = self:getConnectionURL(true)

    if not url then
        UIManager:show(InfoMessage:new{
            text = _(
                "No network address could be detected.\n\n"
                .. "Connect the reader to Wi-Fi and try again."
            ),
        })
        return
    end

    local QRMessage = require("ui/widget/qrmessage")

    -- qr_url is only replaced by updateConnectionInfo() when IP or port changed.
    UIManager:show(QRMessage:new{
        text = runtime.qr_url,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
    })
end

function Remote:showPairingDialog()
    if not self:isRunning() then
        UIManager:show(InfoMessage:new{
            text = _("The remote server is not running."),
        })
        return
    end

    local url = self:getConnectionURL(true)

    if not url then
        UIManager:show(InfoMessage:new{
            text = string.format(
                _(
                    "KOReader Remote is waiting for Wi-Fi on port %d.\n\n"
                    .. "It will recover automatically when the network is ready."
                ),
                runtime.running_port or self:getPort()
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
            runtime.local_ip,
            url
        ),
        ok_text = _("Show QR code"),
        ok_callback = function()
            self:showQRCode()
        end,
        cancel_text = _("Close"),
    })
end

function Remote:showConnectionTest()
    local ready, ip = self:isNetworkReady()

    if ready and self:isRunning() then
        self:refreshConnectionInfo(ip)
        self:setState(STATE_RUNNING)
    elseif not ready and self:isRunning() then
        runtime.network_ready = false
        self:setState(STATE_WAITING)
    end

    local server_text = self:isRunning() and _("Running") or _("Stopped")
    local network_text = ready and _("Connected") or _("Not connected")
    local ip_text = ready and ip or _("Not available")
    local url_text = ready and self:isRunning() and runtime.connection_url
        or _("Not available")
    local error_text = runtime.last_error or _("None")
    local session_text = _("None")
    if runtime.request_origin == "manual" then
        session_text = _("Manual")
    elseif runtime.request_origin == "autostart" then
        session_text = _("Autostart")
    end
    local document_text = self:hasOpenDocument()
        and _("Open")
        or _("Not open")

    UIManager:show(InfoMessage:new{
        text = string.format(
            _(
                "KOReader Remote v%s\n\n"
                .. "Server: %s\n"
                .. "State: %s\n"
                .. "Network: %s\n"
                .. "IP: %s\n"
                .. "Port: %d\n"
                .. "Autostart: %s\n"
                .. "Session: %s\n"
                .. "Document: %s\n"
                .. "URL: %s\n"
                .. "Last error: %s"
            ),
            VERSION,
            server_text,
            self:getStateText(),
            network_text,
            ip_text,
            runtime.running_port or self:getPort(),
            runtime.autostart and _("Enabled") or _("Disabled"),
            session_text,
            document_text,
            url_text,
            error_text
        ),
    })
end

-- Kindle firewall ------------------------------------------------------------

function Remote:openFirewall(port)
    if not Device:isKindle() or runtime.firewall_port then
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

    runtime.firewall_port = port
end

function Remote:closeFirewall()
    if not Device:isKindle() or not runtime.firewall_port then
        return
    end

    local port = runtime.firewall_port

    os.execute(string.format(
        "iptables -D INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        port
    ))
    os.execute(string.format(
        "iptables -D OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
        port
    ))

    runtime.firewall_port = nil
end

-- Server lifecycle -----------------------------------------------------------

function Remote:startServer(silent, known_ip)
    if self:isRunning() then
        self:refreshConnectionInfo(known_ip)
        self:setState(STATE_RUNNING)

        if not silent then
            self:showPairingDialog()
        end

        return true
    end

    local port = self:getPort()
    self:setState(STATE_STARTING)
    logger.info("KOReaderRemote: starting server on port", port)

    local ServerClass = require("ui/message/simpletcpserver")
    runtime.http_socket = ServerClass:new{
        host = "*",
        port = port,
        receiveCallback = function(data, request_id)
            local owner = runtime.owner
            if owner then
                return owner:onRequest(data, request_id)
            end
        end,
    }

    local ok, err = runtime.http_socket:start()
    if not ok then
        local error_text = tostring(err or "Unknown server error")

        logger.err("KOReaderRemote: failed to start server:", error_text)
        runtime.http_socket = nil
        runtime.running_port = nil
        runtime.network_ready = false
        self:closeFirewall()
        runtime.request_origin = nil
        runtime.manual_session = false
        self:setState(STATE_ERROR, error_text)

        if not silent then
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _("KOReader Remote could not start on port %d.\n\n%s"),
                    port,
                    error_text
                ),
            })
        end

        return false
    end

    runtime.running_port = port
    runtime.http_messagequeue = UIManager:insertZMQ(runtime.http_socket)
    self:openFirewall(port)
    self:cancelRetry()
    self:refreshConnectionInfo(known_ip)
    self:setState(STATE_RUNNING)

    if not silent then
        self:showPairingDialog()
    end

    logger.info("KOReaderRemote: server started")
    return true
end

function Remote:stopServer()
    if runtime.http_socket then
        logger.info("KOReaderRemote: stopping server")
        runtime.http_socket:stop()
        runtime.http_socket = nil
    end

    if runtime.http_messagequeue then
        UIManager:removeZMQ(runtime.http_messagequeue)
        runtime.http_messagequeue = nil
    end

    runtime.running_port = nil
    runtime.network_ready = false
    self:closeFirewall()

    -- Keep the last real URL across standby/reconnect so the cached URL and QR
    -- payload remain unchanged when the same IP returns. They are hidden while
    -- the server is stopped or the network is unavailable.
    logger.dbg("KOReaderRemote: preserving last pairing URL for comparison")
    logger.info("KOReaderRemote: server stopped")
end

function Remote:attemptRecovery(silent, reason)
    if runtime.sleeping or not self:hasStartRequest() then
        return false
    end

    local ready, ip = self:isNetworkReady()

    if not ready then
        runtime.network_ready = false

        if runtime.retry_index == 0 then
            self:setState(STATE_WAITING)
        else
            self:setState(STATE_RETRYING)
        end

        self:scheduleRetry()

        if not silent then
            UIManager:show(InfoMessage:new{
                text = _(
                    "Wi-Fi is not ready yet.\n\n"
                    .. "KOReader Remote will retry automatically."
                ),
                timeout = 4,
            })
        end

        logger.info("KOReaderRemote: network not ready during", reason or "start")
        return false
    end

    runtime.network_ready = true
    self:cancelRetry()

    if self:isRunning() then
        self:refreshConnectionInfo(ip)
        self:setState(STATE_RUNNING)

        if not silent then
            self:showPairingDialog()
        end

        return true
    end

    return self:startServer(silent, ip)
end

function Remote:requestStart(silent, origin)
    origin = origin or "manual"
    runtime.request_origin = origin
    runtime.manual_session = origin == "manual"
    runtime.user_stopped = false
    runtime.sleep_started_at = nil
    runtime.sleeping = false
    runtime.retry_index = 0
    self:cancelRetry(false)

    return self:attemptRecovery(silent, origin)
end

function Remote:stop(clear_cached_url, user_initiated)
    if user_initiated == nil then
        user_initiated = true
    end

    runtime.request_origin = nil
    runtime.manual_session = false
    runtime.user_stopped = user_initiated
    runtime.sleep_started_at = nil
    runtime.sleeping = false
    self:cancelRetry()
    self:stopServer()

    if clear_cached_url then
        runtime.local_ip = nil
        runtime.connection_url = nil
        runtime.qr_url = nil
    end

    self:setState(STATE_STOPPED)
end

function Remote:prepareForSleep()
    -- Kindle may emit both EnterStandby and Suspend for one sleep cycle. Keep
    -- the first timestamp so the measured duration is not shortened.
    if not runtime.sleep_started_at then
        runtime.sleep_started_at = os.time()
    end
    runtime.sleeping = true

    self:cancelRetry()
    self:stopServer()

    -- Keep the request in memory. Autostart sessions always return. Manual
    -- sessions return only after a short sleep and are never persisted.
    if runtime.autostart and not runtime.user_stopped then
        runtime.request_origin = "autostart"
    elseif runtime.manual_session then
        runtime.request_origin = "manual"
    else
        runtime.request_origin = nil
    end

    self:setState(STATE_STOPPED)
end

function Remote:beginResumeRecovery()
    if self:isRunning() or runtime.retry_scheduled then
        return
    end

    local slept_for = 0
    if runtime.sleep_started_at then
        slept_for = math.max(0, os.time() - runtime.sleep_started_at)
    end
    runtime.sleep_started_at = nil
    runtime.sleeping = false

    local should_restart = (runtime.autostart and not runtime.user_stopped)
        or (runtime.manual_session
            and slept_for <= MANUAL_SLEEP_GRACE_SECONDS)

    if not should_restart then
        runtime.request_origin = nil
        runtime.manual_session = false
        runtime.network_ready = false
        self:setState(STATE_STOPPED)
        logger.info(
            "KOReaderRemote: manual session expired after sleep",
            slept_for,
            "seconds"
        )
        return
    end

    runtime.request_origin = runtime.autostart and "autostart" or "manual"
    runtime.retry_index = 0
    runtime.network_ready = false
    self:setState(STATE_WAITING)

    logger.info(
        "KOReaderRemote: recovering after sleep",
        slept_for,
        "seconds"
    )

    -- Give Wi-Fi a short head start. NetworkConnected may arrive before this
    -- timer and will cancel it.
    self:scheduleRetry()
end

function Remote:shutdownRuntime()
    self:stop(true, false)
    runtime.user_stopped = false
    runtime.document_open = false
    runtime.owner = nil
end

-- KOReader lifecycle events --------------------------------------------------

function Remote:onNetworkConnecting()
    if runtime.sleeping then
        return
    end

    if self:isRunning() or self:hasStartRequest() then
        runtime.network_ready = false
        self:setState(STATE_WAITING)

        if not runtime.retry_scheduled then
            self:scheduleRetry()
        end
    end
end

function Remote:onNetworkConnected()
    if runtime.sleeping then
        return
    end

    local ready, ip = self:isNetworkReady()

    if not ready then
        if self:isRunning() or self:hasStartRequest() then
            self:scheduleRetry()
        end
        return
    end

    runtime.network_ready = true
    self:cancelRetry()

    if self:isRunning() then
        self:refreshConnectionInfo(ip)
        self:setState(STATE_RUNNING)
    elseif self:hasStartRequest() then
        self:startServer(true, ip)
    end
end

function Remote:onNetworkDisconnected()
    runtime.network_ready = false

    if runtime.sleeping then
        return
    end

    if self:isRunning() or self:hasStartRequest() then
        runtime.retry_index = 0
        self:setState(STATE_WAITING)
        self:scheduleRetry()
    end
end

function Remote:onEnterStandby()
    self:prepareForSleep()
end

function Remote:onSuspend()
    self:prepareForSleep()
end

function Remote:onLeaveStandby()
    self:beginResumeRecovery()
end

function Remote:onResume()
    self:beginResumeRecovery()
end

function Remote:onExit()
    self:shutdownRuntime()
end

function Remote:onCloseWidget()
    -- Closing a book or switching to FileManagerUI is not the same as exiting
    -- KOReader. The shared runtime keeps the server alive across that switch.
    runtime.document_open = false
    logger.dbg("KOReaderRemote: UI closed; preserving remote session")
end

function Remote:stopPlugin()
    self:shutdownRuntime()
    package.loaded[RUNTIME_KEY] = nil
end

-- HTTP server ---------------------------------------------------------------

function Remote:sendResponse(request_id, status, content_type, body, counts_as_input)
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

    if runtime.http_socket then
        runtime.http_socket:send(table.concat(headers, "\r\n"), request_id)
    end

    if counts_as_input then
        return Event:new("InputEvent")
    end
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

function Remote:hasOpenDocument()
    local owner = runtime.owner
    runtime.document_open = owner ~= nil
        and owner.ui ~= nil
        and owner.ui.document ~= nil
    return runtime.document_open == true
end

function Remote:turnPage(delta)
    if not self:hasOpenDocument() then
        return false
    end

    UIManager:nextTick(function()
        UIManager:sendEvent(Event:new("GotoViewRel", delta))
    end)
    return true
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
            body,
            true
        )
    end

    if uri == "/api/ping" then
        local ip_json = runtime.local_ip
            and string.format('"%s"', runtime.local_ip)
            or "null"
        local url_json = runtime.connection_url
            and string.format('"%s"', runtime.connection_url)
            or "null"
        local body = string.format(
            '{"ok":true,"version":"%s","state":"%s","port":%d,'
            .. '"autostart":%s,"manual_session":%s,'
            .. '"document_open":%s,"ip":%s,"url":%s,'
            .. '"url_revision":%d,"manual_sleep_grace_seconds":%d}',
            VERSION,
            runtime.state,
            runtime.running_port or self:getPort(),
            runtime.autostart and "true" or "false",
            runtime.manual_session and "true" or "false",
            self:hasOpenDocument() and "true" or "false",
            ip_json,
            url_json,
            runtime.connection_revision,
            MANUAL_SLEEP_GRACE_SECONDS
        )

        return self:sendResponse(
            request_id,
            200,
            "application/json; charset=utf-8",
            body
        )
    end

    if uri == "/api/next" then
        if not self:turnPage(1) then
            return self:sendResponse(
                request_id,
                409,
                "application/json; charset=utf-8",
                '{"ok":false,"error":"NO_DOCUMENT_OPEN"}'
            )
        end

        return self:sendResponse(
            request_id,
            200,
            "application/json; charset=utf-8",
            '{"ok":true,"action":"next"}',
            true
        )
    end

    if uri == "/api/previous" then
        if not self:turnPage(-1) then
            return self:sendResponse(
                request_id,
                409,
                "application/json; charset=utf-8",
                '{"ok":false,"error":"NO_DOCUMENT_OPEN"}'
            )
        end

        return self:sendResponse(
            request_id,
            200,
            "application/json; charset=utf-8",
            '{"ok":true,"action":"previous"}',
            true
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

-- Menu ----------------------------------------------------------------------

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

                        port = math.floor(port)

                        if port == self:getPort() then
                            UIManager:close(self.port_dialog)
                            return
                        end

                        local previous_origin = runtime.request_origin
                        local was_running = self:isRunning()

                        if was_running then
                            self:cancelRetry()
                            self:stopServer()
                        end

                        self:setPort(port)
                        UIManager:close(self.port_dialog)

                        if was_running or previous_origin then
                            runtime.request_origin = previous_origin or "manual"
                            self:requestStart(false, runtime.request_origin)
                        else
                            self:setState(STATE_STOPPED)
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

function Remote:getMenuStatusText()
    if runtime.state == STATE_RUNNING and runtime.connection_url then
        return runtime.connection_url
    elseif runtime.state == STATE_WAITING then
        return _("Waiting for Wi-Fi…")
    elseif runtime.state == STATE_RETRYING then
        return string.format(
            _("Retrying connection (%d/%d)…"),
            runtime.retry_index,
            #RETRY_DELAYS
        )
    elseif runtime.state == STATE_STARTING then
        return _("Starting remote server…")
    elseif runtime.state == STATE_ERROR then
        return string.format(_("Error: %s"), runtime.last_error or _("Unknown"))
    end

    return _("Server stopped")
end

function Remote:addToMainMenu(menu_items)
    menu_items.koreader_remote = {
        text = _("KOReader Remote"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    if self:isRunning() or self:hasStartRequest() then
                        return _("Stop remote server")
                    end

                    return _("Start remote server")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    if self:isRunning() or self:hasStartRequest() then
                        self:stop()
                    else
                        self:requestStart(false, "manual")
                    end

                    touchmenu_instance:updateItems()
                end,
            },
            {
                text_func = function()
                    return self:getMenuStatusText()
                end,
                callback = function()
                    self:showConnectionTest()
                end,
                separator = true,
            },
            {
                text = _("Pair phone / show QR code"),
                enabled_func = function()
                    return self:isRunning()
                        and runtime.state == STATE_RUNNING
                        and runtime.network_ready
                        and runtime.connection_url ~= nil
                end,
                callback = function()
                    self:showPairingDialog()
                end,
            },
            {
                text = _("Test connection"),
                callback = function()
                    self:showConnectionTest()
                end,
            },
            {
                text = _("Auto start remote server"),
                checked_func = function()
                    return runtime.autostart == true
                end,
                callback = function()
                    self:setAutostart(not runtime.autostart)
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
