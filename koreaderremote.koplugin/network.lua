-- Network, recovery, firewall, and server lifecycle for KOReader Remote.
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local M = {}

function M.attach(Remote, context)
    local runtime = context.runtime
    local RUNTIME_KEY = context.runtime_key
    local VERSION = context.version
    local BUILD = context.build
    local STATE_STOPPED = context.state_stopped
    local STATE_WAITING = context.state_waiting
    local STATE_STARTING = context.state_starting
    local STATE_RUNNING = context.state_running
    local STATE_RETRYING = context.state_retrying
    local STATE_ERROR = context.state_error
    local RETRY_DELAYS = context.retry_delays
    local RECOVERY_RETRY_SECONDS = context.recovery_retry_seconds
    local MANUAL_RECOVERY_MAX_SLEEP_SECONDS =
        context.manual_recovery_max_sleep_seconds
    local LOCAL_IP_CACHE_SECONDS = context.local_ip_cache_seconds
    local FIREWALL_INPUT_CHAIN = context.firewall_input_chain
    local FIREWALL_OUTPUT_CHAIN = context.firewall_output_chain

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

    runtime.retry_index = runtime.retry_index + 1
    local delay = RETRY_DELAYS[runtime.retry_index]
        or RECOVERY_RETRY_SECONDS

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

function Remote:invalidateLocalIPCache()
    runtime.local_ip_cache = nil
    runtime.local_ip_checked_at = nil
end

local function commandSucceeded(command)
    local ok, first, second, third = pcall(
        os.execute,
        command .. " 2>/dev/null"
    )

    if not ok then
        return false
    end

    -- Support Lua 5.1's numeric result and newer Lua return conventions.
    return first == true
        or first == 0
        or (second == "exit" and third == 0)
end

function Remote:detectLocalIP(force)
    local now = os.time()
    if not force
        and runtime.local_ip_checked_at
        and now - runtime.local_ip_checked_at < LOCAL_IP_CACHE_SECONDS then
        return runtime.local_ip_cache
    end

    -- Preferred method: ask the kernel which local address it would use for
    -- the default IPv4 route. This creates no real network traffic.
    local socket_ok, socket = pcall(require, "socket")

    if socket_ok and socket then
        local detected, address_or_error = pcall(function()
            local udp = assert(socket.udp())
            local connected = udp:setpeername("203.0.113.1", "53")

            if not connected then
                udp:close()
                return nil
            end

            local address = udp:getsockname()
            udp:close()
            return address
        end)

        if detected and isUsableIPv4(address_or_error) then
            runtime.local_ip_cache = address_or_error
            runtime.local_ip_checked_at = now
            return address_or_error
        end

        logger.dbg(
            "KOReaderRemote: UDP route IP detection failed:",
            tostring(address_or_error)
        )
    else
        logger.dbg(
            "KOReaderRemote: LuaSocket unavailable for IP detection:",
            tostring(socket)
        )
    end

    -- Fallback for platforms where the Lua socket route method is unavailable.
    -- Android may not provide these tools, so each command is best-effort.
    local interface = NetworkMgr.interface

    if not interface and type(NetworkMgr.getNetworkInterfaceName) == "function" then
        local interface_ok
        interface_ok, interface = pcall(
            NetworkMgr.getNetworkInterfaceName,
            NetworkMgr
        )
        if not interface_ok then
            interface = nil
        end
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
                    runtime.local_ip_cache = address
                    runtime.local_ip_checked_at = now
                    return address
                end
            end
        end
    end

    runtime.local_ip_cache = nil
    runtime.local_ip_checked_at = now
    return nil
end

function Remote:isNetworkReady(force_ip_refresh)
    -- queryNetworkState is KOReader's platform abstraction. An explicit
    -- disconnected state must win over a cached or shell-detected address.
    local state_ok, connected = pcall(function()
        NetworkMgr:queryNetworkState()
        return NetworkMgr:getConnectionState()
    end)

    if state_ok and connected == false then
        return false, nil
    end

    local ip = self:detectLocalIP(force_ip_refresh)

    -- If the KOReader query itself is unavailable, a valid local address is
    -- still useful as a compatibility fallback. An explicit false remains
    -- authoritative and was returned above.
    return connected ~= false and ip ~= nil, ip
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
        local ready, ip = self:isNetworkReady(true)

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

    runtime.qr_url = url

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
                .. "Remote URL:\n%s"
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
                .. "Build: %s\n"
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
            self.updater:getInstalledBuildLabel(),
            runtime.autostart and _("Enabled") or _("Disabled"),
            session_text,
            document_text,
            url_text,
            error_text
        ),
    })
end

-- Kindle firewall ------------------------------------------------------------

function Remote:removeFirewallJumps(table_name, chain)
    local jump = string.format(
        "iptables -D %s -j %s",
        table_name,
        chain
    )

    while commandSucceeded(jump) do end
end

function Remote:removeLegacyFirewallRules(port)
    if not port then
        return
    end

    local legacy_rules = {
        string.format(
            "iptables -D INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
            port
        ),
        string.format(
            "iptables -D OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
            port
        ),
    }

    for _, rule in ipairs(legacy_rules) do
        while commandSucceeded(rule) do end
    end
end

function Remote:prepareFirewallChain(chain)
    local create_chain = string.format("iptables -N %s", chain)
    local list_chain = string.format("iptables -L %s -n", chain)
    local flush_chain = string.format("iptables -F %s", chain)

    if not commandSucceeded(create_chain)
        and not commandSucceeded(list_chain) then
        return false
    end

    return commandSucceeded(flush_chain)
end

function Remote:deleteFirewallChain(table_name, chain)
    self:removeFirewallJumps(table_name, chain)
    commandSucceeded(string.format("iptables -F %s", chain))
    commandSucceeded(string.format("iptables -X %s", chain))
end

function Remote:openFirewall(port)
    if not Device:isKindle() or runtime.firewall_port then
        return
    end

    self:removeLegacyFirewallRules(port)
    self:deleteFirewallChain("INPUT", FIREWALL_INPUT_CHAIN)
    self:deleteFirewallChain("OUTPUT", FIREWALL_OUTPUT_CHAIN)

    if not self:prepareFirewallChain(FIREWALL_INPUT_CHAIN)
        or not self:prepareFirewallChain(FIREWALL_OUTPUT_CHAIN) then
        logger.warn("KOReaderRemote: could not prepare Kindle firewall chains")
        self:deleteFirewallChain("INPUT", FIREWALL_INPUT_CHAIN)
        self:deleteFirewallChain("OUTPUT", FIREWALL_OUTPUT_CHAIN)
        return
    end

    local input_rule = string.format(
        "iptables -A %s -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        FIREWALL_INPUT_CHAIN,
        port
    )
    local output_rule = string.format(
        "iptables -A %s -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
        FIREWALL_OUTPUT_CHAIN,
        port
    )

    if not commandSucceeded(input_rule)
        or not commandSucceeded(output_rule) then
        logger.warn("KOReaderRemote: could not add Kindle firewall rules")
        self:deleteFirewallChain("INPUT", FIREWALL_INPUT_CHAIN)
        self:deleteFirewallChain("OUTPUT", FIREWALL_OUTPUT_CHAIN)
        return
    end

    local input_jump = string.format(
        "iptables -I INPUT 1 -j %s",
        FIREWALL_INPUT_CHAIN
    )
    local output_jump = string.format(
        "iptables -I OUTPUT 1 -j %s",
        FIREWALL_OUTPUT_CHAIN
    )

    if not commandSucceeded(input_jump)
        or not commandSucceeded(output_jump) then
        logger.warn("KOReaderRemote: could not attach Kindle firewall chains")
        self:deleteFirewallChain("INPUT", FIREWALL_INPUT_CHAIN)
        self:deleteFirewallChain("OUTPUT", FIREWALL_OUTPUT_CHAIN)
        return
    end

    runtime.firewall_port = port
end

function Remote:closeFirewall()
    if not Device:isKindle() then
        return
    end

    self:deleteFirewallChain("INPUT", FIREWALL_INPUT_CHAIN)
    self:deleteFirewallChain("OUTPUT", FIREWALL_OUTPUT_CHAIN)
    self:removeLegacyFirewallRules(runtime.firewall_port)
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
    logger.dbg("KOReaderRemote: preserving last remote URL for comparison")
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
    self:invalidateLocalIPCache()

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
    self:invalidateLocalIPCache()

    local manual_recovery_allowed = runtime.manual_session
        and slept_for <= MANUAL_RECOVERY_MAX_SLEEP_SECONDS
    local should_restart = (runtime.autostart and not runtime.user_stopped)
        or manual_recovery_allowed

    if not should_restart then
        runtime.request_origin = nil
        runtime.manual_session = false
        runtime.network_ready = false
        self:setState(STATE_STOPPED)
        logger.info(
            "KOReaderRemote: no session to recover after sleep",
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

    self:invalidateLocalIPCache()

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

    self:invalidateLocalIPCache()
    local ready, ip = self:isNetworkReady(true)

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
    self:invalidateLocalIPCache()

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


end

return M
