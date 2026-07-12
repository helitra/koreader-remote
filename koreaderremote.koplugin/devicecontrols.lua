-- Device controls for KOReader Remote.
-- Keeps hardware-specific logic outside main.lua while using KOReader's
-- public Device and event interfaces.

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local DeviceControls = {}

local function round(value)
    return math.floor(value + 0.5)
end

local function clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end

    if value > maximum then
        return maximum
    end

    return value
end

function DeviceControls:new(options)
    options = options or {}
    setmetatable(options, self)
    self.__index = self
    return options
end

function DeviceControls:getUI()
    if type(self.get_ui) ~= "function" then
        return nil
    end

    local ok, ui = pcall(self.get_ui)
    if ok then
        return ui
    end

    logger.warn("KOReaderRemote: could not resolve current UI:", ui)
    return nil
end

function DeviceControls:getPowerDevice()
    if type(Device.getPowerDevice) ~= "function" then
        return nil
    end

    return Device:getPowerDevice()
end

function DeviceControls:getCapabilities()
    local frontlight = Device:hasFrontlight() == true
    local warmth = Device:hasNaturalLight() == true
    local eink = Device:hasEinkScreen() == true

    return {
        page_turn = true,
        frontlight = frontlight,
        brightness = frontlight,
        warmth = warmth,
        night_mode = true,
        full_refresh = eink,
    }
end

function DeviceControls:nativeBrightnessToPercent(powerd, native_value)
    local minimum = tonumber(powerd.fl_min) or 0
    local maximum = tonumber(powerd.fl_max) or 100

    if maximum <= minimum then
        return 0
    end

    return clamp(
        round((native_value - minimum) * 100 / (maximum - minimum)),
        0,
        100
    )
end

function DeviceControls:percentToNativeBrightness(powerd, percent)
    local minimum = tonumber(powerd.fl_min) or 0
    local maximum = tonumber(powerd.fl_max) or 100
    local native_value = minimum + (maximum - minimum) * percent / 100

    native_value = clamp(round(native_value), minimum, maximum)

    -- Zero is reserved for switching the light off. Any positive percentage
    -- should result in an actual illuminated step where the hardware allows it.
    if percent > 0 and native_value <= minimum and maximum > minimum then
        native_value = minimum + 1
    end

    return native_value
end

function DeviceControls:getState()
    local capabilities = self:getCapabilities()
    local state = {
        capabilities = capabilities,
        night_mode = G_reader_settings:isTrue("night_mode"),
    }

    if capabilities.frontlight then
        local powerd = self:getPowerDevice()
        if powerd then
            local native_brightness = tonumber(powerd.fl_intensity)

            if native_brightness == nil then
                native_brightness = tonumber(powerd:frontlightIntensity()) or 0
            end

            state.frontlight_on = powerd:isFrontlightOn() == true

            local effective_brightness = self:nativeBrightnessToPercent(
                powerd,
                native_brightness
            )
            local displayed_brightness = effective_brightness
            local requested_brightness = tonumber(
                self.requested_brightness
            )

            if requested_brightness ~= nil then
                requested_brightness = clamp(
                    round(requested_brightness),
                    0,
                    100
                )

                local request_is_fresh =
                    tonumber(self.requested_brightness_deadline) ~= nil
                    and os.time() <= self.requested_brightness_deadline

                local requested_matches_hardware = false

                if requested_brightness == 0 then
                    requested_matches_hardware =
                        state.frontlight_on == false
                else
                    local requested_native =
                        self:percentToNativeBrightness(
                            powerd,
                            requested_brightness
                        )

                    requested_matches_hardware =
                        native_brightness == requested_native
                end

                if request_is_fresh or requested_matches_hardware then
                    displayed_brightness = requested_brightness
                else
                    self.requested_brightness = nil
                    self.requested_brightness_deadline = nil
                end
            end

            state.brightness = displayed_brightness
            state.brightness_effective = effective_brightness
            state.brightness_native = native_brightness
            state.brightness_native_min = tonumber(powerd.fl_min) or 0
            state.brightness_native_max = tonumber(powerd.fl_max) or 100
        end
    end

    if capabilities.warmth then
        local powerd = self:getPowerDevice()
        if powerd then
            local effective_warmth = clamp(
                round(tonumber(powerd:frontlightWarmth()) or 0),
                0,
                100
            )
            local displayed_warmth = effective_warmth
            local requested_warmth = tonumber(self.requested_warmth)

            if requested_warmth ~= nil then
                requested_warmth = clamp(
                    round(requested_warmth),
                    0,
                    100
                )

                local request_is_fresh =
                    tonumber(self.requested_warmth_deadline) ~= nil
                    and os.time() <= self.requested_warmth_deadline

                if request_is_fresh
                    or effective_warmth == requested_warmth
                then
                    displayed_warmth = requested_warmth
                else
                    self.requested_warmth = nil
                    self.requested_warmth_deadline = nil
                end
            end

            state.warmth = displayed_warmth
            state.warmth_effective = effective_warmth
        end
    end

    return state
end

function DeviceControls:setFrontlight(enabled)
    local capabilities = self:getCapabilities()
    if not capabilities.frontlight then
        return false, "NOT_SUPPORTED", "Frontlight is not supported on this device."
    end

    local powerd = self:getPowerDevice()
    if not powerd then
        return false, "DEVICE_UNAVAILABLE", "Frontlight controller is unavailable."
    end

    local is_on = powerd:isFrontlightOn() == true

    if enabled and not is_on then
        powerd:turnOnFrontlight()
    elseif not enabled and is_on then
        powerd:turnOffFrontlight()
    end

    powerd:updateResumeFrontlightState()
    return true, self:getState()
end

function DeviceControls:toggleFrontlight()
    local capabilities = self:getCapabilities()
    if not capabilities.frontlight then
        return false, "NOT_SUPPORTED", "Frontlight is not supported on this device."
    end

    local powerd = self:getPowerDevice()
    if not powerd then
        return false, "DEVICE_UNAVAILABLE", "Frontlight controller is unavailable."
    end

    powerd:toggleFrontlight()
    powerd:updateResumeFrontlightState()
    return true, self:getState()
end

function DeviceControls:setBrightness(percent)
    local capabilities = self:getCapabilities()
    if not capabilities.brightness then
        return false, "NOT_SUPPORTED", "Brightness control is not supported on this device."
    end

    percent = tonumber(percent)
    if not percent or percent < 0 or percent > 100 then
        return false, "INVALID_VALUE", "Brightness must be between 0 and 100."
    end

    local powerd = self:getPowerDevice()
    if not powerd then
        return false, "DEVICE_UNAVAILABLE", "Frontlight controller is unavailable."
    end

    percent = round(percent)

    self.requested_brightness = percent
    self.requested_brightness_deadline = os.time() + 3

    if percent == 0 then
        powerd:turnOffFrontlight()
    else
        powerd:setIntensity(
            self:percentToNativeBrightness(powerd, percent)
        )
    end

    powerd:updateResumeFrontlightState()
    return true, self:getState()
end

function DeviceControls:setWarmth(percent)
    local capabilities = self:getCapabilities()
    if not capabilities.warmth then
        return false, "NOT_SUPPORTED", "Warm light is not supported on this device."
    end

    percent = tonumber(percent)
    if not percent or percent < 0 or percent > 100 then
        return false, "INVALID_VALUE", "Warmth must be between 0 and 100."
    end

    local powerd = self:getPowerDevice()
    if not powerd then
        return false, "DEVICE_UNAVAILABLE", "Warm-light controller is unavailable."
    end

    percent = round(percent)
    self.requested_warmth = percent
    self.requested_warmth_deadline = os.time() + 3

    powerd:setWarmth(percent)
    return true, self:getState()
end

function DeviceControls:setNightMode(enabled)
    if type(enabled) ~= "boolean" then
        return false, "INVALID_VALUE", "Night mode requires true or false."
    end

    local ui = self:getUI()
    if not ui then
        return false, "UI_UNAVAILABLE", "KOReader user interface is unavailable."
    end

    ui:handleEvent(Event:new("SetNightMode", enabled))
    return true, self:getState()
end

function DeviceControls:toggleNightMode()
    return self:setNightMode(not G_reader_settings:isTrue("night_mode"))
end

function DeviceControls:fullRefresh()
    if not Device:hasEinkScreen() then
        return false, "NOT_SUPPORTED", "Full refresh is not supported on this device."
    end

    local ui = self:getUI()
    if ui then
        ui:handleEvent(Event:new("FullRefresh"))
    else
        UIManager:setDirty(nil, "full")
    end

    return true, self:getState()
end

return DeviceControls
