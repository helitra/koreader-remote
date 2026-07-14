-- KOReader Remote v0.9.0
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

local VERSION = "0.9.0"
local DEFAULT_PORT = 8081
local LEGACY_SETTINGS_KEY = "koreaderremote"
local PORT_SETTINGS_KEY = "koreaderremote_port"
local AUTOSTART_SETTINGS_KEY = "koreaderremote_autostart"
local PLUGIN_DIR = DataStorage:getDataDir() .. "/plugins/koreaderremote.koplugin"
local INDEX_FILE = PLUGIN_DIR .. "/web/index.html"
local DeviceControls = dofile(PLUGIN_DIR .. "/devicecontrols.lua")
local Interaction = dofile(PLUGIN_DIR .. "/interaction.lua")
local Updater = dofile(PLUGIN_DIR .. "/updater.lua")
local ReadingPresets = dofile(PLUGIN_DIR .. "/readingpresets.lua")

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
    [413] = "Payload Too Large",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [500] = "Internal Server Error",
    [501] = "Not Implemented",
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


local function jsonEscape(value)
    value = tostring(value)
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    value = value:gsub("\b", "\\b")
    value = value:gsub("\f", "\\f")
    value = value:gsub("\n", "\\n")
    value = value:gsub("\r", "\\r")
    value = value:gsub("\t", "\\t")
    value = value:gsub("[%z\1-\31]", function(character)
        return string.format("\\u%04x", string.byte(character))
    end)
    return '"' .. value .. '"'
end

local function jsonEncode(value)
    local value_type = type(value)

    if value_type == "nil" then
        return "null"
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        return tostring(value)
    elseif value_type == "string" then
        return jsonEscape(value)
    elseif value_type ~= "table" then
        return jsonEscape(tostring(value))
    end

    local is_array = true
    local maximum_index = 0
    local item_count = 0

    for key in pairs(value) do
        item_count = item_count + 1
        if type(key) ~= "number"
            or key < 1
            or key % 1 ~= 0 then
            is_array = false
            break
        end
        if key > maximum_index then
            maximum_index = key
        end
    end

    if is_array and maximum_index == item_count then
        local parts = {}
        for index = 1, maximum_index do
            parts[index] = jsonEncode(value[index])
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for key in pairs(value) do
        table.insert(keys, tostring(key))
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(
            parts,
            jsonEscape(key) .. ":" .. jsonEncode(value[key])
        )
    end

    return "{" .. table.concat(parts, ",") .. "}"
end

local function urlDecode(value)
    value = tostring(value or "")
    value = value:gsub("%+", " ")
    return value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function parseRequestURI(raw_uri)
    local path, query = raw_uri:match("^([^?]*)%??(.*)$")
    local params = {}

    if query and query ~= "" then
        for pair in query:gmatch("[^&]+") do
            local key, value = pair:match("^([^=]+)=?(.*)$")
            if key then
                params[urlDecode(key)] = urlDecode(value)
            end
        end
    end

    return path or raw_uri, params
end

local function parseHeaders(data)
    local headers = {}

    for line in tostring(data or ""):gmatch("[^\r\n]+") do
        local name, value = line:match("^([^:]+):%s*(.*)$")
        if name then
            headers[name:lower()] = value
        end
    end

    return headers
end

local function parseBoolean(value)
    if value == true
        or value == "true"
        or value == "1"
        or value == "on" then
        return true
    end

    if value == false
        or value == "false"
        or value == "0"
        or value == "off" then
        return false
    end

    return nil
end

function Remote:init()
    self.port = tonumber(G_reader_settings:readSetting(PORT_SETTINGS_KEY))
        or DEFAULT_PORT
    runtime.autostart = G_reader_settings:isTrue(AUTOSTART_SETTINGS_KEY)
    runtime.owner = self
    runtime.document_open = self.ui ~= nil and self.ui.document ~= nil

    if not runtime.device_controls then
        runtime.device_controls = DeviceControls:new{
            get_ui = function()
                local owner = runtime.owner
                return owner and owner.ui or nil
            end,
        }
    end

    if not runtime.reading_presets then
        runtime.reading_presets = ReadingPresets:new{
            device_controls = runtime.device_controls,
            get_ui = function()
                local owner = runtime.owner
                return owner and owner.ui or nil
            end,
        }
    end

    if not runtime.interaction then
        runtime.interaction = Interaction:new{
            get_owner = function()
                return runtime.owner
            end,
            ensure_server = function()
                local owner = runtime.owner
                if owner and not owner:isRunning() then
                    owner:requestStart(false, "manual")
                end
            end,
        }
    end

    UIManager:nextTick(function()
        if runtime.interaction then
            runtime.interaction:attachUI(self.ui)
        end
    end)

    self.updater = Updater:new{
        installed_version = VERSION,
        plugin_dir = PLUGIN_DIR,
        prepare_install = function()
            return self:prepareForPluginUpdate()
        end,
        restore_after_failure = function(snapshot)
            self:restoreAfterPluginUpdateFailure(snapshot)
        end,
    }

    runtime.update_restart_required =
        self.updater:isRestartRequired()

    if not runtime.update_restart_required then
        UIManager:nextTick(function()
            if self.updater then
                self.updater:finalizePendingInstall()
            end
        end)
    end

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

    -- A plugin directory may already contain the new version while the old
    -- KOReader process is still running. Do not start or finalize anything
    -- until a real process restart has occurred.
    if runtime.update_restart_required then
        logger.info(
            "KOReaderRemote: update installed; waiting for KOReader restart"
        )
        return
    end

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

function Remote:prepareForPluginUpdate()
    local snapshot = {
        request_origin = runtime.request_origin,
        was_running = self:isRunning(),
        manual_session = runtime.manual_session,
        user_stopped = runtime.user_stopped,
        update_restart_required = runtime.update_restart_required,
    }

    self:stop(false, false)
    runtime.update_restart_required = true
    return snapshot
end

function Remote:restoreAfterPluginUpdateFailure(snapshot)
    snapshot = snapshot or {}
    runtime.user_stopped = snapshot.user_stopped == true
    runtime.update_restart_required =
        snapshot.update_restart_required == true

    if snapshot.was_running or snapshot.request_origin then
        runtime.manual_session = snapshot.manual_session == true
        self:requestStart(
            true,
            snapshot.request_origin or "manual"
        )
    end
end

function Remote:shutdownRuntime()
    if runtime.interaction then
        runtime.interaction:cancelNoteSession("KOReader exit")
    end
    self:stop(true, false)
    runtime.user_stopped = false
    runtime.document_open = false
    runtime.owner = nil
end

-- KOReader lifecycle events --------------------------------------------------

function Remote:onReaderReady()
    if runtime.interaction then
        runtime.interaction:attachUI(self.ui)
    end
end

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
    if runtime.interaction then
        runtime.interaction:onUIClosed(self.ui)
    end
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


function Remote:sendJSON(request_id, status, payload, counts_as_input)
    return self:sendResponse(
        request_id,
        status,
        "application/json; charset=utf-8",
        jsonEncode(payload),
        counts_as_input
    )
end

function Remote:sendControlError(request_id, status, code, message)
    return self:sendJSON(request_id, status, {
        ok = false,
        error = code,
        message = message,
    })
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
    local method, raw_uri = data:match(
        "^(%u+)%s+([^%s]+)%s+HTTP/%d%.%d"
    )

    if not method or not raw_uri then
        return self:sendResponse(
            request_id,
            400,
            "text/plain; charset=utf-8",
            "Invalid HTTP request"
        )
    end

    local uri, params = parseRequestURI(raw_uri)
    local headers = parseHeaders(data)
    logger.dbg("KOReaderRemote:", method, uri)

    if method ~= "GET" and method ~= "POST" then
        return self:sendResponse(
            request_id,
            405,
            "text/plain; charset=utf-8",
            "Only GET and POST are supported"
        )
    end

    if uri == "/" or uri == "/index.html" then
        if method ~= "GET" then
            return self:sendResponse(
                request_id,
                405,
                "text/plain; charset=utf-8",
                "Only GET is supported for this resource"
            )
        end

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
        if method ~= "GET" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use GET for this endpoint."
            )
        end

        return self:sendJSON(request_id, 200, {
            ok = true,
            version = VERSION,
            state = runtime.state,
            port = runtime.running_port or self:getPort(),
            autostart = runtime.autostart == true,
            manual_session = runtime.manual_session == true,
            document_open = self:hasOpenDocument(),
            ip = runtime.local_ip,
            url = runtime.connection_url,
            url_revision = runtime.connection_revision,
            manual_sleep_grace_seconds = MANUAL_SLEEP_GRACE_SECONDS,
            note_session_active = runtime.interaction
                and runtime.interaction:getNoteSessionState().active
                or false,
        })
    end

    if uri == "/api/next" or uri == "/api/previous" then
        if method ~= "GET" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use GET for legacy page-turn endpoints."
            )
        end

        local delta = uri == "/api/next" and 1 or -1
        local action = delta == 1 and "next" or "previous"

        if not self:turnPage(delta) then
            return self:sendControlError(
                request_id,
                409,
                "NO_DOCUMENT_OPEN",
                "Open a book on the reader first."
            )
        end

        return self:sendJSON(
            request_id,
            200,
            { ok = true, action = action },
            true
        )
    end

    local controls = runtime.device_controls

    if uri == "/api/v1/capabilities" then
        if method ~= "GET" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use GET for this endpoint."
            )
        end

        local capabilities = {}
        for name, supported in pairs(controls:getCapabilities()) do
            capabilities[name] = supported
        end
        for name, supported in pairs(
            runtime.interaction:getCapabilities()
        ) do
            capabilities[name] = supported
        end

        return self:sendJSON(request_id, 200, {
            ok = true,
            version = VERSION,
            capabilities = capabilities,
        })
    end

    if uri == "/api/v1/device-state" then
        if method ~= "GET" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use GET for this endpoint."
            )
        end

        return self:sendJSON(request_id, 200, {
            ok = true,
            version = VERSION,
            state = controls:getState(),
        })
    end

    if uri == "/api/v1/reading-presets" then
        if method == "GET" then
            return self:sendJSON(request_id, 200, {
                ok = true, state = runtime.reading_presets:getState(),
            })
        end
        if method ~= "POST" then
            return self:sendControlError(request_id, 405, "METHOD_NOT_ALLOWED", "Use GET or POST for this endpoint.")
        end
        local index = tonumber(params.index)
        local preset = runtime.reading_presets.presets[index]
        if not preset then
            return self:sendControlError(request_id, 400, "MISSING_PRESET", "Preset not found.")
        end
        local values = {}
        for key, value in pairs(preset) do values[key] = value end
        for key, value in pairs(params) do
            if key ~= "index" then values[key] = value end
        end
        if params.night_mode ~= nil then values.night_mode = parseBoolean(params.night_mode) end
        local ok, result, message = runtime.reading_presets:update(index, values)
        if not ok then return self:sendControlError(request_id, 400, result, message) end
        return self:sendJSON(request_id, 200, { ok = true, state = runtime.reading_presets:getState(result) })
    end

    if uri == "/api/v1/reading-presets/apply" then
        if method ~= "POST" then return self:sendControlError(request_id, 405, "METHOD_NOT_ALLOWED", "Use POST for this endpoint.") end
        local ok, result, message = runtime.reading_presets:apply(params.index)
        if not ok then return self:sendControlError(request_id, 400, result, message) end
        return self:sendJSON(request_id, 200, { ok = true, action = "reading_preset_applied", state = result }, true)
    end

    if uri == "/api/v1/note-session" then
        if method ~= "GET" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use GET for this endpoint."
            )
        end

        return self:sendJSON(request_id, 200, {
            ok = true,
            session = runtime.interaction:getNoteSessionState(),
        })
    end

    if uri == "/api/v1/note-session/push" then
        if method ~= "POST" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use POST for this endpoint."
            )
        end

        local ok, result, message, session =
            runtime.interaction:pushEncodedNote(
                headers["x-koreader-note-base64"],
                headers["x-koreader-note-revision"]
            )

        if not ok then
            local status = 400
            if result == "NOTE_CONFLICT"
                or result == "NO_NOTE_SESSION"
                or result == "NOTE_SESSION_EXPIRED" then
                status = 409
            elseif result == "NOTE_TOO_LARGE" then
                status = 413
            end

            return self:sendJSON(request_id, status, {
                ok = false,
                error = result,
                message = message,
                session = session,
            })
        end

        return self:sendJSON(
            request_id,
            200,
            {
                ok = true,
                action = "note_draft_updated",
                session = result,
            },
            true
        )
    end

    if uri == "/api/v1/note-session/save" then
        if method ~= "POST" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use POST for this endpoint."
            )
        end

        local ok, result, message, session =
            runtime.interaction:saveNoteSession(
                headers["x-koreader-note-revision"],
                nil,
                "phone"
            )

        if not ok then
            local status = 400
            if result == "NOTE_CONFLICT"
                or result == "NO_NOTE_SESSION"
                or result == "NOTE_SESSION_EXPIRED"
                or result == "NOTE_DIALOG_CLOSED" then
                status = 409
            end

            return self:sendJSON(request_id, status, {
                ok = false,
                error = result,
                message = message,
                session = session,
            })
        end

        return self:sendJSON(
            request_id,
            200,
            {
                ok = true,
                action = "note_saved",
                session = result,
            },
            true
        )
    end

    if uri == "/api/v1/note-session/cancel" then
        if method ~= "POST" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use POST for this endpoint."
            )
        end

        runtime.interaction:cancelNoteSession(
            "cancelled from phone",
            true,
            true
        )
        return self:sendJSON(request_id, 200, {
            ok = true,
            action = "note_session_cancelled",
        })
    end

    if uri == "/api/v1/bookmarks" then
        if method ~= "GET" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use GET for this endpoint."
            )
        end

        local ok, result, message =
            runtime.interaction:getBookmarks()

        if not ok then
            return self:sendControlError(
                request_id,
                409,
                result,
                message
            )
        end

        return self:sendJSON(request_id, 200, {
            ok = true,
            book = result,
        })
    end

    if uri == "/api/v1/bookmarks/open" then
        if method ~= "POST" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use POST for this endpoint."
            )
        end

        local ok, result, message =
            runtime.interaction:openBookmark(params.id)

        if not ok then
            local status = result == "MISSING_BOOKMARK" and 400 or 409

            return self:sendControlError(
                request_id,
                status,
                result,
                message
            )
        end

        return self:sendJSON(
            request_id,
            200,
            {
                ok = true,
                action = result.action,
                type = result.type,
                page = result.page,
                return_position = result.return_position,
            },
            true
        )
    end

    if uri == "/api/v1/bookmarks/return" then
        if method ~= "POST" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use POST for this endpoint."
            )
        end

        local ok, result, message =
            runtime.interaction:returnToReadingPosition()

        if not ok then
            return self:sendControlError(
                request_id,
                409,
                result,
                message
            )
        end

        return self:sendJSON(
            request_id,
            200,
            {
                ok = true,
                action = result.action,
                page = result.page,
                return_position = result.return_position,
            },
            true
        )
    end

    if uri == "/api/v1/bookmarks/edit-note" then
        if method ~= "POST" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use POST for this endpoint."
            )
        end

        local ok, result, message =
            runtime.interaction:editBookmarkNote(params.id)

        if not ok then
            local status = result == "MISSING_BOOKMARK" and 400 or 409
            return self:sendControlError(
                request_id,
                status,
                result,
                message
            )
        end

        return self:sendJSON(
            request_id,
            200,
            {
                ok = true,
                action = result.action,
                session = result.session,
            },
            true
        )
    end

    if uri == "/api/v1/bookmarks/delete-note" then
        if method ~= "POST" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use POST for this endpoint."
            )
        end

        local ok, result, message =
            runtime.interaction:deleteBookmarkNote(params.id)

        if not ok then
            local status = result == "MISSING_BOOKMARK" and 400 or 409
            return self:sendControlError(
                request_id,
                status,
                result,
                message
            )
        end

        return self:sendJSON(
            request_id,
            200,
            {
                ok = true,
                action = result.action,
                type = result.type,
                return_position = result.return_position,
            },
            true
        )
    end

    if uri == "/api/v1/bookmarks/delete" then
        if method ~= "POST" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use POST for this endpoint."
            )
        end

        local ok, result, message =
            runtime.interaction:deleteBookmark(params.id)

        if not ok then
            local status = result == "MISSING_BOOKMARK" and 400 or 409
            return self:sendControlError(
                request_id,
                status,
                result,
                message
            )
        end

        return self:sendJSON(
            request_id,
            200,
            {
                ok = true,
                action = result.action,
                type = result.type,
                return_position = result.return_position,
            },
            true
        )
    end

    if uri == "/api/v1/footnote/open" then
        if method ~= "POST" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use POST for this endpoint."
            )
        end

        local ok, result, message =
            runtime.interaction:openNextFootnote()

        if not ok then
            local status = result == "NOT_SUPPORTED" and 501 or 404
            return self:sendControlError(
                request_id,
                status,
                result,
                message
            )
        end

        return self:sendJSON(
            request_id,
            200,
            {
                ok = true,
                action = result.action,
            },
            true
        )
    end

    if uri:match("^/api/v1/") then
        if method ~= "POST" then
            return self:sendControlError(
                request_id,
                405,
                "METHOD_NOT_ALLOWED",
                "Use POST for device-control actions."
            )
        end

        local ok, result, message
        local action

        if uri == "/api/v1/frontlight/toggle" then
            action = "frontlight_toggle"
            ok, result, message = controls:toggleFrontlight()
        elseif uri == "/api/v1/frontlight" then
            action = "frontlight"
            local enabled = parseBoolean(params.enabled)
            if enabled == nil then
                return self:sendControlError(
                    request_id,
                    400,
                    "INVALID_VALUE",
                    "The enabled parameter must be true or false."
                )
            end
            ok, result, message = controls:setFrontlight(enabled)
        elseif uri == "/api/v1/brightness" then
            action = "brightness"
            ok, result, message = controls:setBrightness(params.value)
        elseif uri == "/api/v1/warmth" then
            action = "warmth"
            ok, result, message = controls:setWarmth(params.value)
        elseif uri == "/api/v1/night-mode/toggle" then
            action = "night_mode_toggle"
            ok, result, message = controls:toggleNightMode()
        elseif uri == "/api/v1/night-mode" then
            action = "night_mode"
            local enabled = parseBoolean(params.enabled)
            if enabled == nil then
                return self:sendControlError(
                    request_id,
                    400,
                    "INVALID_VALUE",
                    "The enabled parameter must be true or false."
                )
            end
            ok, result, message = controls:setNightMode(enabled)
        elseif uri == "/api/v1/full-refresh" then
            action = "full_refresh"
            ok, result, message = controls:fullRefresh()
        else
            return self:sendControlError(
                request_id,
                404,
                "NOT_FOUND",
                "Unknown device-control endpoint."
            )
        end

        if not ok then
            local status = result == "NOT_SUPPORTED" and 501 or 400
            return self:sendControlError(
                request_id,
                status,
                result,
                message
            )
        end

        return self:sendJSON(
            request_id,
            200,
            {
                ok = true,
                action = action,
                state = result,
            },
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
                text = _("Check for updates"),
                separator = true,
                callback = function()
                    self.updater:checkForUpdates()
                end,
            },
            {
                text_func = function()
                    return string.format(
                        _("Installed version: v%s"),
                        VERSION
                    )
                end,
                enabled_func = function()
                    return false
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
