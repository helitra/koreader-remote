-- Saved reading presets for KOReader Remote.
-- Values are kept in G_reader_settings so they follow the reader, not a phone.

local Event = require("ui/event")

local ReadingPresets = {}
ReadingPresets.__index = ReadingPresets

local SETTINGS_KEY = "koreaderremote_reading_presets_v1"
local ORDER = { "brightness", "warmth", "night_mode", "font_size", "top_margin", "bottom_margin", "font_weight" }
local LIMITS = {
    brightness = { 0, 100 }, warmth = { 0, 100 }, font_size = { 8, 96 },
    top_margin = { 0, 200 }, bottom_margin = { 0, 200 }, font_weight = { 100, 900 },
}

local DEFAULTS = {
    { id = "day", name = "Day", brightness = 50, warmth = 0, night_mode = false, font_size = 22, top_margin = 15, bottom_margin = 15, font_weight = 400 },
    { id = "night", name = "Night", brightness = 15, warmth = 35, night_mode = true, font_size = 22, top_margin = 15, bottom_margin = 15, font_weight = 400 },
    { id = "large", name = "Large text", brightness = 50, warmth = 0, night_mode = false, font_size = 30, top_margin = 10, bottom_margin = 10, font_weight = 500 },
}

local function copy(preset)
    local result = {}
    for key, value in pairs(preset) do result[key] = value end
    return result
end

local function normalise(preset, fallback)
    local result = copy(fallback or DEFAULTS[1])
    if type(preset) == "table" then
        result.name = tostring(preset.name or result.name):sub(1, 40)
        for _, key in ipairs(ORDER) do
            if key == "night_mode" then
                if type(preset[key]) == "boolean" then result[key] = preset[key] end
            else
                local value = tonumber(preset[key])
                if value then
                    result[key] = math.floor(math.max(LIMITS[key][1], math.min(LIMITS[key][2], value)) + 0.5)
                end
            end
        end
    end
    result.id = tostring(preset and preset.id or result.id)
    return result
end

function ReadingPresets:new(options)
    options = options or {}
    setmetatable(options, self)
    options.presets = options.presets or self:load()
    return options
end

function ReadingPresets:load()
    local saved = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(saved) ~= "table" or #saved == 0 then
        local defaults = {}
        for _, preset in ipairs(DEFAULTS) do table.insert(defaults, copy(preset)) end
        return defaults
    end
    local result = {}
    for index, preset in ipairs(saved) do
        table.insert(result, normalise(preset, DEFAULTS[index] or DEFAULTS[1]))
    end
    return result
end

function ReadingPresets:save()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.presets)
end

function ReadingPresets:list()
    local result = {}
    for _, preset in ipairs(self.presets) do table.insert(result, copy(preset)) end
    return result
end

function ReadingPresets:update(index, values)
    index = tonumber(index)
    if not index or not self.presets[index] then return false, "MISSING_PRESET", "Preset not found." end
    self.presets[index] = normalise(values, self.presets[index])
    self.presets[index].id = self.presets[index].id or ("preset-" .. index)
    self:save()
    return true, self.presets[index]
end

function ReadingPresets:apply(index)
    index = tonumber(index)
    local preset = index and self.presets[index]
    if not preset then return false, "MISSING_PRESET", "Preset not found." end
    local ui = self.get_ui and self.get_ui()
    if not ui then return false, "UI_UNAVAILABLE", "KOReader user interface is unavailable." end

    local controls = self.device_controls
    if controls then
        if controls:getCapabilities().brightness then controls:setBrightness(preset.brightness) end
        if controls:getCapabilities().warmth then controls:setWarmth(preset.warmth) end
        controls:setNightMode(preset.night_mode)
    end

    -- ReaderUI handles these events and persists the values for the current book.
    local events = {
        { "SetFontSize", preset.font_size }, { "SetTopMargin", preset.top_margin },
        { "SetBottomMargin", preset.bottom_margin }, { "SetFontWeight", preset.font_weight },
    }
    for _, entry in ipairs(events) do ui:handleEvent(Event:new(entry[1], entry[2])) end
    return true, self:getState(preset)
end

function ReadingPresets:getState(preset)
    return { active = preset and preset.id or nil, presets = self:list() }
end

return ReadingPresets
