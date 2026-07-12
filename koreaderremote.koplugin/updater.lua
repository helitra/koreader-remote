-- KOReader Remote self-updater.
--
-- Checks the latest stable GitHub release only after an explicit user action.
-- Downloads the plugin ZIP and checksum, validates the archive with KOReader's
-- bundled libarchive wrapper, installs through a sibling staging directory,
-- and preserves the previous plugin directory until the new version starts.

local Archiver = require("ffi/archiver")
local ffi = require("ffi")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketurl = require("socket.url")
local socketutil = require("socketutil")
local sha256 = require("ffi/sha2").sha256
local http = require("socket.http")
local _ = require("gettext")

local unpack = table.unpack or unpack

require("ffi/posix_h")

local Updater = {}
Updater.__index = Updater

local GITHUB_API_URL =
    "https://api.github.com/repos/helitra/koreader-remote/releases/latest"
local PLUGIN_FOLDER_NAME = "koreaderremote.koplugin"
local UPDATE_WORK_DIR =
    DataStorage:getDataDir() .. "/koreaderremote-update"
local PENDING_MARKER =
    DataStorage:getDataDir() .. "/koreaderremote-update.pending"

local MAX_REDIRECTS = 5
local MAX_API_BYTES = 1024 * 1024
local MAX_ASSET_BYTES = 5 * 1024 * 1024
local MAX_ARCHIVE_ENTRIES = 128
local MAX_EXTRACTED_BYTES = 10 * 1024 * 1024
local MAX_SINGLE_FILE_BYTES = 5 * 1024 * 1024

local REQUIRED_FILES = {
    "_meta.lua",
    "devicecontrols.lua",
    "interaction.lua",
    "main.lua",
    "updater.lua",
    "web/index.html",
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function formatDownloadSize(bytes)
    bytes = tonumber(bytes)

    if not bytes or bytes <= 0 then
        return "Unknown"
    end

    if bytes < 1024 then
        return string.format("%d B", bytes)
    end

    if bytes < 1024 * 1024 then
        return string.format("%.1f KiB", bytes / 1024)
    end

    return string.format("%.2f MiB", bytes / (1024 * 1024))
end

local function currentProcessId()
    local ok, pid = pcall(function()
        return tonumber(ffi.C.getpid())
    end)

    if ok and pid then
        return tostring(pid)
    end

    return "unknown"
end

local function parsePendingMarker(content)
    if type(content) ~= "string" then
        return nil
    end

    local version, process_id = content:match(
        "^%s*(%d+%.%d+%.%d+)%s*\n%s*([^%s]+)"
    )

    if not version then
        return nil
    end

    return {
        version = version,
        process_id = process_id or "unknown",
    }
end

local function readFile(path)
    local handle, err = io.open(path, "rb")
    if not handle then
        return nil, err
    end

    local content = handle:read("*a")
    handle:close()
    return content
end

local function writeFile(path, content)
    local handle, err = io.open(path, "wb")
    if not handle then
        return nil, err
    end

    local ok, write_err = handle:write(content)
    local close_ok, close_err = handle:close()

    if not ok then
        return nil, write_err
    end

    if close_ok == nil then
        return nil, close_err
    end

    return true
end

local function pathMode(path)
    local attributes = lfs.symlinkattributes
        and lfs.symlinkattributes(path)
        or lfs.attributes(path)

    return attributes and attributes.mode or nil
end

local function parentPath(path)
    return path:match("^(.*)/[^/]+$")
end

local function ensureDirectory(path)
    if path == nil or path == "" then
        return true
    end

    if pathMode(path) == "directory" then
        return true
    end

    local parent = parentPath(path)
    if parent and parent ~= path then
        local ok, err = ensureDirectory(parent)
        if not ok then
            return nil, err
        end
    end

    local ok, err = lfs.mkdir(path)

    if ok or pathMode(path) == "directory" then
        return true
    end

    return nil, err
end

local function removeTree(path)
    local mode = pathMode(path)

    if mode == nil then
        return true
    end

    if mode ~= "directory" then
        local ok, err = os.remove(path)
        if ok then
            return true
        end
        return nil, err
    end

    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local ok, err = removeTree(path .. "/" .. name)
            if not ok then
                return nil, err
            end
        end
    end

    local ok, err = lfs.rmdir(path)
    if ok then
        return true
    end
    return nil, err
end

local function parseVersion(value)
    local major, minor, patch = tostring(value or ""):match(
        "^v?(%d+)%.(%d+)%.(%d+)$"
    )

    if not major then
        return nil
    end

    return {
        tonumber(major),
        tonumber(minor),
        tonumber(patch),
    }
end

local function compareVersions(left, right)
    local left_parts = parseVersion(left)
    local right_parts = parseVersion(right)

    if not left_parts or not right_parts then
        return nil
    end

    for index = 1, 3 do
        if left_parts[index] < right_parts[index] then
            return -1
        elseif left_parts[index] > right_parts[index] then
            return 1
        end
    end

    return 0
end

local function isRedirect(code)
    code = tonumber(code)
    return code == 301
        or code == 302
        or code == 303
        or code == 307
        or code == 308
end

local function responseLocation(headers)
    if type(headers) ~= "table" then
        return nil
    end

    return headers.location or headers.Location
end

local function requestHeaders(accept)
    return {
        ["Accept"] = accept or "application/octet-stream",
        ["User-Agent"] = "KOReader-Remote-Updater",
        ["X-GitHub-Api-Version"] = "2022-11-28",
        ["Connection"] = "close",
    }
end

local function requestMemory(url, maximum_bytes, accept)
    local current_url = url

    for redirect = 0, MAX_REDIRECTS do
        local chunks = {}
        local total = 0
        local sink_error

        local sink = function(chunk, err)
            if chunk then
                total = total + #chunk

                if total > maximum_bytes then
                    sink_error = "response is too large"
                    return nil, sink_error
                end

                chunks[#chunks + 1] = chunk
            end

            return 1
        end

        socketutil:set_timeout()
        local ok, code, headers, status = pcall(function()
            return socket.skip(1, http.request{
                url = current_url,
                method = "GET",
                headers = requestHeaders(accept),
                sink = sink,
            })
        end)
        socketutil:reset_timeout()

        if not ok then
            return nil, tostring(code)
        end

        if sink_error then
            return nil, sink_error
        end

        if tonumber(code) == 200 then
            return table.concat(chunks), nil, headers
        end

        if isRedirect(code) then
            local location = responseLocation(headers)

            if not location then
                return nil, "redirect without a Location header"
            end

            current_url = socketurl.absolute(current_url, location)
        else
            return nil, status or ("HTTP " .. tostring(code)), headers, code
        end
    end

    return nil, "too many redirects"
end

local function requestFile(url, path, maximum_bytes)
    local current_url = url

    for redirect = 0, MAX_REDIRECTS do
        local handle, open_err = io.open(path, "wb")
        if not handle then
            return nil, open_err
        end

        local total = 0
        local sink_error

        local sink = function(chunk, err)
            if chunk then
                total = total + #chunk

                if total > maximum_bytes then
                    sink_error = "download is too large"
                    return nil, sink_error
                end

                local ok, write_err = handle:write(chunk)
                if not ok then
                    sink_error = write_err or "could not write download"
                    return nil, sink_error
                end
            end

            return 1
        end

        socketutil:set_timeout(
            socketutil.FILE_BLOCK_TIMEOUT,
            socketutil.FILE_TOTAL_TIMEOUT
        )

        local ok, code, headers, status = pcall(function()
            return socket.skip(1, http.request{
                url = current_url,
                method = "GET",
                headers = requestHeaders("application/octet-stream"),
                sink = sink,
            })
        end)

        socketutil:reset_timeout()
        handle:close()

        if not ok then
            os.remove(path)
            return nil, tostring(code)
        end

        if sink_error then
            os.remove(path)
            return nil, sink_error
        end

        if tonumber(code) == 200 then
            return true, total
        end

        os.remove(path)

        if isRedirect(code) then
            local location = responseLocation(headers)

            if not location then
                return nil, "redirect without a Location header"
            end

            current_url = socketurl.absolute(current_url, location)
        else
            return nil, status or ("HTTP " .. tostring(code))
        end
    end

    return nil, "too many redirects"
end

local function showInfo(text)
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

local function showProgress(text)
    local widget = InfoMessage:new{
        text = text,
        timeout = 0,
    }

    UIManager:show(widget)
    UIManager:forceRePaint()
    return widget
end

local function closeWidget(widget)
    if widget then
        UIManager:close(widget)
    end
end

function Updater:new(options)
    options = options or {}

    local instance = setmetatable({}, self)
    instance.installed_version = assert(options.installed_version)
    instance.plugin_dir = assert(options.plugin_dir)
    instance.prepare_install = options.prepare_install
    instance.restore_after_failure = options.restore_after_failure
    instance.busy = false
    instance.backup_dir = instance.plugin_dir .. ".previous"
    instance.staging_dir = instance.plugin_dir .. ".update"

    return instance
end

function Updater:getInstalledVersion()
    return self.installed_version
end

function Updater:findReleaseAssets(release, version)
    local archive_name = "koreaderremote-v" .. version .. ".zip"
    local checksum_name = archive_name .. ".sha256"
    local archive_asset
    local checksum_asset

    for _, asset in ipairs(release.assets or {}) do
        if asset.name == archive_name then
            archive_asset = asset
        elseif asset.name == checksum_name then
            checksum_asset = asset
        end
    end

    if not archive_asset or not checksum_asset then
        return nil, string.format(
            "The v%s release is missing its plugin ZIP or checksum.",
            version
        )
    end

    if type(archive_asset.browser_download_url) ~= "string"
        or type(checksum_asset.browser_download_url) ~= "string" then
        return nil, "The release contains invalid download links."
    end

    if tonumber(archive_asset.size)
        and tonumber(archive_asset.size) > MAX_ASSET_BYTES then
        return nil, "The plugin ZIP is unexpectedly large."
    end

    if tonumber(checksum_asset.size)
        and tonumber(checksum_asset.size) > 4096 then
        return nil, "The checksum file is unexpectedly large."
    end

    return {
        archive_name = archive_name,
        checksum_name = checksum_name,
        archive_url = archive_asset.browser_download_url,
        checksum_url = checksum_asset.browser_download_url,
        archive_size = tonumber(archive_asset.size),
    }
end

function Updater:fetchLatestRelease()
    local body, err, headers, code = requestMemory(
        GITHUB_API_URL,
        MAX_API_BYTES,
        "application/vnd.github+json"
    )

    if not body then
        if tonumber(code) == 403 or tonumber(code) == 429 then
            return nil, "GitHub's update limit was reached. Try again later."
        end

        return nil, "Could not contact GitHub: " .. tostring(err)
    end

    local ok, release = pcall(JSON.decode, body)

    if not ok or type(release) ~= "table" then
        return nil, "GitHub returned an invalid update response."
    end

    local version = tostring(release.tag_name or ""):match(
        "^v(%d+%.%d+%.%d+)$"
    )

    if not version then
        return nil, "The latest release does not use a stable version number."
    end

    local comparison = compareVersions(self.installed_version, version)
    if comparison == nil then
        return nil, "The installed version number could not be compared."
    end

    local candidate = {
        version = version,
        tag = "v" .. version,
        comparison = comparison,
        release = release,
    }

    if comparison < 0 then
        local assets, asset_err = self:findReleaseAssets(release, version)
        if not assets then
            return nil, asset_err
        end

        for key, value in pairs(assets) do
            candidate[key] = value
        end
    end

    return candidate
end

function Updater:checkForUpdates()
    NetworkMgr:runWhenOnline(function()
        if self.busy then
            showInfo(_("An update operation is already running."))
            return
        end

        self.busy = true
        local progress = showProgress(_("Checking for updates…"))

        UIManager:scheduleIn(0.1, function()
            local ok, candidate, err = pcall(
                self.fetchLatestRelease,
                self
            )

            closeWidget(progress)
            self.busy = false

            if not ok then
                logger.err("KOReaderRemote updater check failed:", candidate)
                showInfo(
                    _("Could not check for updates.\n\n")
                        .. tostring(candidate)
                )
                return
            end

            if not candidate then
                showInfo(
                    _("Could not check for updates.\n\n")
                        .. tostring(err)
                )
                return
            end

            if candidate.comparison == 0 then
                showInfo(string.format(
                    _(
                        "KOReader Remote is up to date.\n\n"
                        .. "Installed version: v%s\n"
                        .. "Latest release: v%s\n"
                        .. "Update channel: Stable"
                    ),
                    self.installed_version,
                    candidate.version
                ))
                return
            end

            if candidate.comparison > 0 then
                showInfo(string.format(
                    _(
                        "The installed version is newer than the latest "
                        .. "public release.\n\n"
                        .. "Installed version: v%s\n"
                        .. "Latest release: v%s\n"
                        .. "Update channel: Stable"
                    ),
                    self.installed_version,
                    candidate.version
                ))
                return
            end

            UIManager:show(ConfirmBox:new{
                text = string.format(
                    _(
                        "A KOReader Remote update is available.\n\n"
                        .. "Installed version: v%s\n"
                        .. "Available version: v%s\n"
                        .. "Update channel: Stable\n"
                        .. "Download size: %s\n\n"
                        .. "The current plugin will be backed up before "
                        .. "installation.\n\n"
                        .. "Download and install the update?"
                    ),
                    self.installed_version,
                    candidate.version,
                    formatDownloadSize(candidate.archive_size)
                ),
                ok_text = _("Update"),
                ok_callback = function()
                    self:downloadAndInstall(candidate)
                end,
            })
        end)
    end)
end

function Updater:parseChecksum(content, expected_filename)
    local digest, filename = tostring(content or ""):match(
        "^%s*([0-9a-fA-F]+)%s+%*?([^%s]+)"
    )

    if not digest or #digest ~= 64 then
        return nil, "The checksum file is invalid."
    end

    if filename ~= expected_filename then
        return nil, "The checksum refers to a different file."
    end

    if not digest:match("^[0-9a-fA-F]+$") then
        return nil, "The checksum contains invalid characters."
    end

    return digest:lower()
end

function Updater:validateArchivePath(path)
    if type(path) ~= "string"
        or path == ""
        or path:find("\\", 1, true)
        or path:find("%z")
        or path:sub(1, 1) == "/"
        or path:match("^%a:") then
        return nil, "The archive contains an unsafe path."
    end

    for component in path:gmatch("[^/]+") do
        if component == "." or component == ".." or component == "" then
            return nil, "The archive contains path traversal."
        end
    end

    if path ~= PLUGIN_FOLDER_NAME
        and path:sub(1, #PLUGIN_FOLDER_NAME + 1)
            ~= PLUGIN_FOLDER_NAME .. "/" then
        return nil, "The archive contains files outside the plugin folder."
    end

    return true
end

function Updater:indexArchive(archive_path)
    local archive = Archiver.Reader:new()

    if not archive:open(archive_path) then
        return nil, archive.err or "The plugin ZIP could not be opened."
    end

    local entries = {}
    local seen = {}
    local entry_count = 0
    local extracted_bytes = 0

    for entry in archive:iterate() do
        entry_count = entry_count + 1

        if entry_count > MAX_ARCHIVE_ENTRIES then
            archive:close()
            return nil, "The archive contains too many files."
        end

        local ok, path_err = self:validateArchivePath(entry.path)
        if not ok then
            archive:close()
            return nil, path_err
        end

        if seen[entry.path] then
            archive:close()
            return nil, "The archive contains duplicate paths."
        end
        seen[entry.path] = true

        if entry.mode ~= "file" and entry.mode ~= "directory" then
            archive:close()
            return nil, "The archive contains unsupported file types."
        end

        local size = tonumber(entry.size) or 0

        if size < 0 or size > MAX_SINGLE_FILE_BYTES then
            archive:close()
            return nil, "The archive contains an unexpectedly large file."
        end

        if entry.mode == "file" then
            extracted_bytes = extracted_bytes + size

            if extracted_bytes > MAX_EXTRACTED_BYTES then
                archive:close()
                return nil, "The extracted update would be too large."
            end
        end

        entries[#entries + 1] = {
            path = entry.path,
            mode = entry.mode,
            size = size,
        }
    end

    archive:close()

    if entry_count == 0 then
        return nil, "The archive is empty."
    end

    return entries
end

function Updater:extractArchive(archive_path, entries)
    local ok, err = removeTree(self.staging_dir)
    if not ok then
        return nil, "Could not clean the staging directory: " .. tostring(err)
    end

    ok, err = ensureDirectory(self.staging_dir)
    if not ok then
        return nil, "Could not create the staging directory: " .. tostring(err)
    end

    local archive = Archiver.Reader:new()
    if not archive:open(archive_path) then
        removeTree(self.staging_dir)
        return nil, archive.err or "The plugin ZIP could not be reopened."
    end

    -- Build the archive's path index once.
    for _ in archive:iterate() do
    end
    archive:close(true)
    archive:open(archive_path)

    for _, entry in ipairs(entries) do
        local relative = entry.path == PLUGIN_FOLDER_NAME
            and ""
            or entry.path:sub(#PLUGIN_FOLDER_NAME + 2)

        if relative ~= "" then
            local destination = self.staging_dir .. "/" .. relative

            if entry.mode == "directory" then
                ok, err = ensureDirectory(destination)
                if not ok then
                    archive:close()
                    removeTree(self.staging_dir)
                    return nil,
                        "Could not create an update directory: " .. tostring(err)
                end
            else
                ok, err = ensureDirectory(parentPath(destination))
                if not ok then
                    archive:close()
                    removeTree(self.staging_dir)
                    return nil,
                        "Could not create an update directory: " .. tostring(err)
                end

                local content = archive:extractToMemory(entry.path)

                if content == nil or #content ~= entry.size then
                    local archive_err = archive.err
                    archive:close()
                    removeTree(self.staging_dir)
                    return nil,
                        archive_err
                        or "A file could not be extracted completely."
                end

                ok, err = writeFile(destination, content)
                if not ok then
                    archive:close()
                    removeTree(self.staging_dir)
                    return nil,
                        "Could not write an update file: " .. tostring(err)
                end
            end
        end
    end

    archive:close()
    return true
end

function Updater:validateStaging(expected_version)
    for _, relative in ipairs(REQUIRED_FILES) do
        local path = self.staging_dir .. "/" .. relative

        if pathMode(path) ~= "file" then
            return nil, "The update is missing " .. relative .. "."
        end
    end

    local main_content, read_err = readFile(
        self.staging_dir .. "/main.lua"
    )

    if not main_content then
        return nil, "Could not read the staged plugin: " .. tostring(read_err)
    end

    local staged_version = main_content:match(
        'local%s+VERSION%s*=%s*"(%d+%.%d+%.%d+)"'
    )

    if staged_version ~= expected_version then
        return nil, string.format(
            "The downloaded plugin reports v%s instead of v%s.",
            tostring(staged_version or "unknown"),
            expected_version
        )
    end

    local function checkLuaDirectory(directory)
        for name in lfs.dir(directory) do
            if name ~= "." and name ~= ".." then
                local path = directory .. "/" .. name
                local mode = pathMode(path)

                if mode == "directory" then
                    local ok, err = checkLuaDirectory(path)
                    if not ok then
                        return nil, err
                    end
                elseif mode == "file" and name:match("%.lua$") then
                    local chunk, compile_err = loadfile(path)
                    if not chunk then
                        return nil, string.format(
                            "Lua syntax check failed for %s: %s",
                            name,
                            tostring(compile_err)
                        )
                    end
                end
            end
        end

        return true
    end

    return checkLuaDirectory(self.staging_dir)
end

function Updater:restoreSession(snapshot)
    if self.restore_after_failure then
        local ok, err = pcall(self.restore_after_failure, snapshot)

        if not ok then
            logger.err(
                "KOReaderRemote updater could not restore server session:",
                err
            )
        end
    end
end

function Updater:installStaging(version)
    if pathMode(self.backup_dir) ~= nil then
        return nil,
            "A previous update backup still exists. "
            .. "Restart KOReader or restore that backup before updating again."
    end

    local snapshot

    if self.prepare_install then
        local ok, result = pcall(self.prepare_install)

        if not ok then
            return nil,
                "Could not prepare KOReader Remote for the update: "
                .. tostring(result)
        end

        snapshot = result
    end

    local renamed_old, rename_old_err = os.rename(
        self.plugin_dir,
        self.backup_dir
    )

    if not renamed_old then
        self:restoreSession(snapshot)
        return nil,
            "Could not create the plugin backup: "
            .. tostring(rename_old_err)
    end

    local renamed_new, rename_new_err = os.rename(
        self.staging_dir,
        self.plugin_dir
    )

    if not renamed_new then
        os.rename(self.backup_dir, self.plugin_dir)
        self:restoreSession(snapshot)
        return nil,
            "Could not activate the downloaded plugin: "
            .. tostring(rename_new_err)
    end

    local marker_ok, marker_err = writeFile(
        PENDING_MARKER,
        version .. "\n" .. currentProcessId() .. "\n"
    )

    if not marker_ok then
        removeTree(self.plugin_dir)
        os.rename(self.backup_dir, self.plugin_dir)
        self:restoreSession(snapshot)
        return nil,
            "Could not record the pending update: "
            .. tostring(marker_err)
    end

    os.execute("sync")
    return true
end

function Updater:downloadCandidate(candidate)
    local ok, err = removeTree(UPDATE_WORK_DIR)
    if not ok then
        return nil, "Could not clean old update files: " .. tostring(err)
    end

    ok, err = ensureDirectory(UPDATE_WORK_DIR)
    if not ok then
        return nil, "Could not create the update directory: " .. tostring(err)
    end

    local archive_path =
        UPDATE_WORK_DIR .. "/" .. candidate.archive_name
    local checksum_path =
        UPDATE_WORK_DIR .. "/" .. candidate.checksum_name

    ok, err = requestFile(
        candidate.archive_url,
        archive_path,
        MAX_ASSET_BYTES
    )
    if not ok then
        return nil, "Could not download the plugin ZIP: " .. tostring(err)
    end

    ok, err = requestFile(
        candidate.checksum_url,
        checksum_path,
        4096
    )
    if not ok then
        return nil, "Could not download the checksum: " .. tostring(err)
    end

    local checksum_content, checksum_read_err = readFile(checksum_path)
    if not checksum_content then
        return nil,
            "Could not read the checksum: " .. tostring(checksum_read_err)
    end

    local expected_digest, checksum_err = self:parseChecksum(
        checksum_content,
        candidate.archive_name
    )
    if not expected_digest then
        return nil, checksum_err
    end

    local archive_content, archive_read_err = readFile(archive_path)
    if not archive_content then
        return nil,
            "Could not read the downloaded ZIP: "
            .. tostring(archive_read_err)
    end

    local actual_digest = sha256(archive_content):lower()
    archive_content = nil
    collectgarbage("collect")

    if actual_digest ~= expected_digest then
        return nil, "The downloaded ZIP failed its SHA-256 check."
    end

    local entries, index_err = self:indexArchive(archive_path)
    if not entries then
        return nil, index_err
    end

    ok, err = self:extractArchive(archive_path, entries)
    if not ok then
        return nil, err
    end

    ok, err = self:validateStaging(candidate.version)
    if not ok then
        removeTree(self.staging_dir)
        return nil, err
    end

    return true
end

function Updater:downloadAndInstall(candidate)
    if self.busy then
        showInfo(_("An update operation is already running."))
        return
    end

    self.busy = true
    local progress = showProgress(string.format(
        _("Downloading and checking KOReader Remote v%s…"),
        candidate.version
    ))

    UIManager:scheduleIn(0.1, function()
        local standby_prevented = false

        if UIManager.preventStandby then
            UIManager:preventStandby()
            standby_prevented = true
        end

        local ok, result, err = pcall(function()
            local downloaded, download_err =
                self:downloadCandidate(candidate)

            if not downloaded then
                return nil, download_err
            end

            return self:installStaging(candidate.version)
        end)

        if standby_prevented then
            UIManager:allowStandby()
        end

        closeWidget(progress)
        self.busy = false

        if not ok then
            logger.err("KOReaderRemote updater crashed:", result)
            removeTree(self.staging_dir)
            showInfo(
                _("The update could not be installed.\n\n")
                    .. tostring(result)
            )
            return
        end

        if not result then
            logger.warn("KOReaderRemote update failed:", err)
            removeTree(self.staging_dir)
            showInfo(
                _("The update could not be installed.\n\n")
                    .. tostring(err)
            )
            return
        end

        removeTree(UPDATE_WORK_DIR)

        UIManager:askForRestart(string.format(
            _(
                "KOReader Remote v%s was installed.\n\n"
                .. "KOReader must restart before the new version can be used."
            ),
            candidate.version
        ))
    end)
end

function Updater:getPendingInstall()
    local marker_content = readFile(PENDING_MARKER)
    return parsePendingMarker(marker_content)
end

function Updater:isRestartRequired()
    local pending = self:getPendingInstall()

    return pending ~= nil
        and pending.process_id == currentProcessId()
end

function Updater:finalizePendingInstall()
    local pending = self:getPendingInstall()

    if not pending then
        return
    end

    if pending.process_id == currentProcessId() then
        logger.info(
            "KOReaderRemote updater: restart still required for",
            pending.version
        )
        return
    end

    if pending.version ~= self.installed_version then
        logger.warn(
            "KOReaderRemote updater: pending version mismatch",
            pending.version,
            self.installed_version
        )
        return
    end

    for _, relative in ipairs(REQUIRED_FILES) do
        if pathMode(self.plugin_dir .. "/" .. relative) ~= "file" then
            logger.warn(
                "KOReaderRemote updater: keeping backup because file is missing",
                relative
            )
            return
        end
    end

    local backup_ok, backup_err = removeTree(self.backup_dir)

    if not backup_ok then
        logger.warn(
            "KOReaderRemote updater: could not remove backup:",
            backup_err
        )
        return
    end

    os.remove(PENDING_MARKER)
    removeTree(UPDATE_WORK_DIR)
    removeTree(self.staging_dir)

    logger.info(
        "KOReaderRemote updater: finalized successful update to",
        self.installed_version
    )
end

return Updater
