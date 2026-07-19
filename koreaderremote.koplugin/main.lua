-- KOReader Remote v0.9.5
-- Local HTTP remote control for page turning.

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local VERSION = "0.9.5"
local DEFAULT_PORT = 8081
local LEGACY_SETTINGS_KEY = "koreaderremote"
local PORT_SETTINGS_KEY = "koreaderremote_port"
local AUTOSTART_SETTINGS_KEY = "koreaderremote_autostart"
local IDLE_TIMEOUT_SETTINGS_KEY = "koreaderremote_idle_timeout_minutes"
local UPDATE_CHANNEL_SETTINGS_KEY = "koreaderremote_update_channel"
local PLUGIN_DIR = DataStorage:getDataDir() .. "/plugins/koreaderremote.koplugin"
local INDEX_FILE = PLUGIN_DIR .. "/web/index.html"
local BUILD = {
    channel = "stable",
    source = "main",
    version = VERSION,
    release_version = VERSION,
    build_id = "legacy",
    commit = "unknown",
}
local build_loader = loadfile(PLUGIN_DIR .. "/build.lua")
if build_loader then
    local build_ok, build_result = pcall(build_loader)
    if build_ok and type(build_result) == "table" then
        BUILD = build_result
    end
end
local DeviceControls = dofile(PLUGIN_DIR .. "/devicecontrols.lua")
local Interaction = dofile(PLUGIN_DIR .. "/interaction.lua")
local Updater = dofile(PLUGIN_DIR .. "/updater.lua")

local STATE_STOPPED = "stopped"
local STATE_WAITING = "waiting_for_wifi"
local STATE_STARTING = "starting"
local STATE_RUNNING = "running"
local STATE_RETRYING = "retrying"
local STATE_ERROR = "error"

-- Keep checking until KOReader reports a usable network or the user stops the
-- remote. Network events normally wake recovery immediately; these retries
-- are only a low-frequency fallback for devices that miss those events.
local RETRY_DELAYS = { 2, 5, 10, 20, 40, 80, 160, 300 }
local RECOVERY_RETRY_SECONDS = 300
local MANUAL_RECOVERY_MAX_SLEEP_SECONDS = 300
local LOCAL_IP_CACHE_SECONDS = 15
local FIREWALL_INPUT_CHAIN = "KOREADERREMOTE_IN"
local FIREWALL_OUTPUT_CHAIN = "KOREADERREMOTE_OUT"

local HTTP_STATUS = {
    [200] = "OK",
    [204] = "No Content",
    [401] = "Unauthorized",
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
    repository = "helitra/koreader-remote",
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
        idle_timeout_minutes = 0,
        idle_timeout_seconds = 0,
        idle_timer_scheduled = false,
        idle_timer_action = nil,
        idle_deadline = nil,
        retry_index = 0,
        retry_scheduled = false,
        retry_action = nil,
        local_ip = nil,
        local_ip_cache = nil,
        local_ip_checked_at = nil,
        connection_url = nil,
        qr_url = nil,
        connection_revision = 0,
        sleep_started_at = nil,
        sleeping = false,
        document_open = false,
    }
    package.loaded[RUNTIME_KEY] = runtime
end

function Remote:init()
    self.port = tonumber(G_reader_settings:readSetting(PORT_SETTINGS_KEY))
        or DEFAULT_PORT
    runtime.autostart = G_reader_settings:isTrue(AUTOSTART_SETTINGS_KEY)
    runtime.idle_timeout_minutes =
        tonumber(G_reader_settings:readSetting(IDLE_TIMEOUT_SETTINGS_KEY)) or 0
    runtime.idle_timeout_seconds = math.max(
        0,
        math.floor(runtime.idle_timeout_minutes * 60)
    )
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
        installed_channel = BUILD.channel,
        installed_release_version = BUILD.release_version,
        installed_build_id = BUILD.build_id,
        installed_commit = BUILD.commit,
        channel = G_reader_settings:readSetting(UPDATE_CHANNEL_SETTINGS_KEY)
            or BUILD.channel,
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

    if runtime.idle_timeout_minutes > 0 then
        G_reader_settings:saveSetting(
            IDLE_TIMEOUT_SETTINGS_KEY,
            runtime.idle_timeout_minutes
        )
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

function Remote:getIdleTimeoutMinutes()
    return tonumber(runtime.idle_timeout_minutes) or 0
end

function Remote:getIdleTimeoutRemainingSeconds()
    if not self:isRunning() then
        return 0
    end

    local deadline = tonumber(runtime.idle_deadline)
    if not deadline then
        return 0
    end

    return math.max(0, math.floor(deadline - os.time()))
end

function Remote:setIdleTimeoutMinutes(minutes)
    minutes = math.max(0, tonumber(minutes) or 0)
    runtime.idle_timeout_minutes = minutes
    runtime.idle_timeout_seconds = minutes * 60

    if minutes > 0 then
        G_reader_settings:saveSetting(IDLE_TIMEOUT_SETTINGS_KEY, minutes)
    else
        G_reader_settings:delSetting(IDLE_TIMEOUT_SETTINGS_KEY)
    end

    if self:isRunning() then
        self:scheduleIdleStop()
    else
        self:cancelIdleStop()
    end
end


local Network = dofile(PLUGIN_DIR .. "/network.lua")
local HTTP = dofile(PLUGIN_DIR .. "/http.lua")
local Menu = dofile(PLUGIN_DIR .. "/menu.lua")

local module_context = {
    runtime = runtime,
    runtime_key = RUNTIME_KEY,
    version = VERSION,
    build = BUILD,
    index_file = INDEX_FILE,
    http_status = HTTP_STATUS,
    default_port = DEFAULT_PORT,
    update_channel_settings_key = UPDATE_CHANNEL_SETTINGS_KEY,
    retry_delays = RETRY_DELAYS,
    recovery_retry_seconds = RECOVERY_RETRY_SECONDS,
    manual_recovery_max_sleep_seconds = MANUAL_RECOVERY_MAX_SLEEP_SECONDS,
    local_ip_cache_seconds = LOCAL_IP_CACHE_SECONDS,
    firewall_input_chain = FIREWALL_INPUT_CHAIN,
    firewall_output_chain = FIREWALL_OUTPUT_CHAIN,
    state_stopped = STATE_STOPPED,
    state_waiting = STATE_WAITING,
    state_starting = STATE_STARTING,
    state_running = STATE_RUNNING,
    state_retrying = STATE_RETRYING,
    state_error = STATE_ERROR,
}

Network.attach(Remote, module_context)
HTTP.attach(Remote, module_context)
Menu.attach(Remote, module_context)
return Remote
