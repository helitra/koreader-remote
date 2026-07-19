-- KOReader menu integration for KOReader Remote.
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local M = {}

function M.attach(Remote, context)
    local runtime = context.runtime
    local DEFAULT_PORT = context.default_port
    local UPDATE_CHANNEL_SETTINGS_KEY = context.update_channel_settings_key
    local STATE_STOPPED = context.state_stopped
    local STATE_WAITING = context.state_waiting
    local STATE_STARTING = context.state_starting
    local STATE_RUNNING = context.state_running
    local STATE_RETRYING = context.state_retrying
    local STATE_ERROR = context.state_error

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
            _("Retrying connection (%d)…"),
            runtime.retry_index
        )
    elseif runtime.state == STATE_STARTING then
        return _("Starting remote server…")
    elseif runtime.state == STATE_ERROR then
        return string.format(_("Error: %s"), runtime.last_error or _("Unknown"))
    end

    return _("Server stopped")
end

function Remote:getUpdateChannel()
    local channel = self.updater and self.updater:getChannel() or "stable"
    return channel == "dev" and _("Dev") or _("Stable (main)")
end

function Remote:setUpdateChannel(channel, touchmenu_instance)
    channel = channel == "dev" and "dev" or "stable"
    self.updater:setChannel(channel)
    G_reader_settings:saveSetting(UPDATE_CHANNEL_SETTINGS_KEY, channel)

    if touchmenu_instance then
        touchmenu_instance:updateItems()
    end
end

function Remote:showUpdateChannelDialog(touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local selected = self.updater:getChannel()

    self.update_channel_dialog = ButtonDialog:new{
        title = _("Update channel"),
        buttons = {
            {
                {
                    text = selected == "stable"
                        and _("Stable (main, selected)")
                        or _("Stable (main)"),
                    callback = function()
                        self:setUpdateChannel("stable", touchmenu_instance)
                        UIManager:close(self.update_channel_dialog)
                    end,
                },
            },
            {
                {
                    text = selected == "dev"
                        and _("Dev (selected)")
                        or _("Dev"),
                    callback = function()
                        self:setUpdateChannel("dev", touchmenu_instance)
                        UIManager:close(self.update_channel_dialog)
                    end,
                },
            },
        },
    }

    UIManager:show(self.update_channel_dialog)
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
                text = _("Show QR code"),
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
                        _("Update channel: %s"),
                        self:getUpdateChannel()
                    )
                end,
                callback = function(touchmenu_instance)
                    self:showUpdateChannelDialog(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return string.format(
                        _("Installed: %s"),
                        self.updater:getInstalledBuildLabel()
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

end

return M
