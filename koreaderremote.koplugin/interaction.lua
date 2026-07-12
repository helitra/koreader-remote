-- KOReader Remote interaction bridge.
--
-- Adds remote note editing to KOReader's highlight dialog and exposes a
-- conservative "open next footnote" action for reflowable documents.

local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local mime = require("mime")
local _ = require("gettext")

local Interaction = {}
Interaction.__index = Interaction

local MAX_NOTE_BYTES = 12 * 1024
local NOTE_SESSION_TTL_SECONDS = 30 * 60
local HIGHLIGHT_ACTION_ID = "04a_koreader_remote_note"
local session_counter = 0

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function utf8Prefix(value, maximum_bytes)
    value = tostring(value or "")

    if #value <= maximum_bytes then
        return value
    end

    local boundary = maximum_bytes
    while boundary > 0 do
        local byte = value:byte(boundary)
        if not byte or byte < 0x80 or byte >= 0xC0 then
            break
        end
        boundary = boundary - 1
    end

    if boundary <= 0 then
        return "…"
    end

    return value:sub(1, boundary - 1) .. "…"
end

local function annotationType(ui, annotation)
    if ui.bookmark and ui.bookmark.getBookmarkType then
        return ui.bookmark.getBookmarkType(annotation)
    end

    if annotation.drawer then
        return annotation.note and "note" or "highlight"
    end

    return "bookmark"
end

local function decodeBase64(encoded)
    encoded = trim(encoded)

    -- An empty Base64 value represents an empty note. This is needed so a
    -- phone can clear an existing note intentionally.
    if encoded == "" then
        return ""
    end

    if #encoded % 4 ~= 0 then
        return nil, "The encoded note is invalid."
    end

    local data = encoded
    local padding_count = 0
    local first_padding = encoded:find("=", 1, true)

    if first_padding then
        local padding = encoded:sub(first_padding)

        if padding ~= "=" and padding ~= "==" then
            return nil, "The encoded note contains invalid padding."
        end

        data = encoded:sub(1, first_padding - 1)
        padding_count = #padding
    end

    if data:find("[^A-Za-z0-9+/]") then
        return nil, "The encoded note contains invalid characters."
    end

    local ok, decoded = pcall(mime.unb64, encoded)
    if not ok or type(decoded) ~= "string" then
        return nil, "The encoded note could not be decoded."
    end

    local expected_bytes = (#encoded / 4) * 3 - padding_count
    if #decoded ~= expected_bytes then
        return nil, "The encoded note has an invalid length."
    end

    return decoded
end

function Interaction:new(options)
    options = options or {}

    local instance = setmetatable({}, self)
    instance.get_owner = assert(options.get_owner)
    instance.ensure_server = options.ensure_server
    instance.session = nil
    instance.footnote_page_key = nil
    instance.footnote_cursor = 0

    return instance
end

function Interaction:getUI()
    local owner = self.get_owner()
    return owner and owner.ui or nil
end

function Interaction:getCapabilities()
    local ui = self:getUI()
    local notes = ui ~= nil
        and ui.document ~= nil
        and ui.highlight ~= nil
        and ui.annotation ~= nil
        and ui.bookmark ~= nil

    local footnotes = ui ~= nil
        and ui.document ~= nil
        and ui.rolling ~= nil
        and ui.link ~= nil
        and type(ui.document.getPageLinks) == "function"
        and type(ui.link.showAsFootnotePopup) == "function"

    return {
        remote_notes = notes,
        footnotes = footnotes,
    }
end

function Interaction:showNoteActionError(err)
    logger.err(
        "KOReaderRemote: remote note action failed:",
        tostring(err)
    )

    UIManager:show(InfoMessage:new{
        text = _(
            "The remote note could not be prepared.\n\n"
            .. "KOReader Remote stayed active. Please try again after "
            .. "reopening the book."
        ),
    })
end

function Interaction:runNoteAction(callback)
    local ok, result = xpcall(callback, debug.traceback)

    if not ok then
        self:showNoteActionError(result)
        return false
    end

    return result ~= false
end

function Interaction:startNewNoteSession(highlight)
    local function startSavedNote(saved_index)
        return self:runNoteAction(function()
            if not saved_index then
                UIManager:show(InfoMessage:new{
                    text = _(
                        "The selected text could not be saved as a highlight."
                    ),
                })
                return false
            end

            return self:startNoteSession(highlight, saved_index)
        end)
    end

    -- Older and development KOReader builds may still expose the optional
    -- highlight prompt callback. KOReader 2026.03 saves highlights directly
    -- and no longer exposes that method, so support both interfaces.
    if type(highlight.showHighlightPrompt) == "function" then
        highlight:showHighlightPrompt(function(saved_index)
            startSavedNote(saved_index)
        end)
        return true
    end

    if type(highlight.saveHighlight) ~= "function" then
        error("KOReader does not expose a compatible highlight save method.")
    end

    local saved_index = highlight:saveHighlight(true)

    if type(highlight.onClose) == "function" then
        highlight:onClose()
    end

    return startSavedNote(saved_index)
end

function Interaction:attachUI(ui)
    if not ui or not ui.highlight or not ui.highlight.addToHighlightDialog then
        return false
    end

    if ui.highlight._koreader_remote_note_action then
        return true
    end

    local bridge = self

    ui.highlight:addToHighlightDialog(
        HIGHLIGHT_ACTION_ID,
        function(highlight, index)
            local has_selection = highlight.selected_text ~= nil
                and highlight.selected_text.pos0 ~= nil
                and highlight.selected_text.pos1 ~= nil

            return {
                text = index and _("Edit note on phone")
                    or _("Write note on phone"),
                enabled = index ~= nil or has_selection,
                callback = function()
                    bridge:runNoteAction(function()
                        if index then
                            local started =
                                bridge:startNoteSession(highlight, index)

                            if started
                                and type(highlight.onClose) == "function" then
                                highlight:onClose(true)
                            end

                            return started
                        end

                        return bridge:startNewNoteSession(highlight)
                    end)
                end,
            }
        end
    )

    ui.highlight._koreader_remote_note_action = true
    return true
end

function Interaction:findAnnotationIndex(ui, annotation)
    if not ui or not ui.annotation or not ui.annotation.annotations then
        return nil
    end

    for index, candidate in ipairs(ui.annotation.annotations) do
        if candidate == annotation then
            return index
        end
    end
end

function Interaction:cancelNoteSession(reason)
    if self.session then
        logger.info(
            "KOReaderRemote: closing note session",
            self.session.id,
            reason or "cancelled"
        )
    end

    self.session = nil
end

function Interaction:onUIClosed(ui)
    if self.session and self.session.ui == ui then
        self:cancelNoteSession("document closed")
    end
end

function Interaction:startNoteSession(highlight, index)
    local ui = highlight and highlight.ui
    local annotations = ui
        and ui.annotation
        and ui.annotation.annotations
    local annotation = annotations and annotations[index]

    if not annotation then
        UIManager:show(InfoMessage:new{
            text = _("The selected note is no longer available."),
        })
        return false
    end

    session_counter = session_counter + 1
    local now = os.time()

    self.session = {
        id = string.format("%x-%x", now, session_counter),
        ui = ui,
        highlight = highlight,
        annotation = annotation,
        document_file = ui.document and ui.document.file,
        created_at = now,
        updated_at = now,
        expires_at = now + NOTE_SESSION_TTL_SECONDS,
        revision = 1,
        last_note = annotation.note or "",
    }

    if self.ensure_server then
        local ok, err = pcall(self.ensure_server)
        if not ok then
            logger.warn(
                "KOReaderRemote: could not ensure note server:",
                err
            )
        end
    end

    UIManager:show(InfoMessage:new{
        text = _(
            "Remote note is ready.\n\n"
            .. "Open KOReader Remote on your phone and tap the note icon."
        ),
    })

    return true
end

function Interaction:resolveSession()
    local session = self.session
    if not session then
        return nil, "NO_NOTE_SESSION", "No note is selected on the reader."
    end

    if os.time() > session.expires_at then
        self:cancelNoteSession("expired")
        return nil, "NOTE_SESSION_EXPIRED", "The note session expired."
    end

    local ui = self:getUI()
    if not ui
        or ui ~= session.ui
        or not ui.document
        or ui.document.file ~= session.document_file then
        self:cancelNoteSession("document changed")
        return nil, "NO_NOTE_SESSION", "The selected document is no longer open."
    end

    local index = self:findAnnotationIndex(ui, session.annotation)
    if not index then
        self:cancelNoteSession("annotation removed")
        return nil, "NO_NOTE_SESSION", "The selected note no longer exists."
    end

    session.index = index

    local current_note = session.annotation.note or ""
    if current_note ~= session.last_note then
        session.last_note = current_note
        session.revision = session.revision + 1
        session.updated_at = os.time()
    end

    return session
end

function Interaction:sessionState(session)
    session = session or self:resolveSession()

    if type(session) ~= "table" then
        return {
            active = false,
        }
    end

    return {
        active = true,
        id = session.id,
        excerpt = utf8Prefix(session.annotation.text or "", 2200),
        note = session.annotation.note or "",
        revision = session.revision,
        has_note = session.annotation.note ~= nil,
        expires_in = math.max(0, session.expires_at - os.time()),
    }
end

function Interaction:getNoteSessionState()
    local session = self:resolveSession()
    return self:sessionState(session)
end

function Interaction:pushEncodedNote(encoded, expected_revision)
    if type(encoded) ~= "string" then
        return false,
            "MISSING_NOTE",
            "The note header is missing."
    end

    if #encoded > math.ceil(MAX_NOTE_BYTES / 3) * 4 + 8 then
        return false,
            "NOTE_TOO_LARGE",
            "The note is too large."
    end

    local note, decode_err = decodeBase64(encoded)
    if not note then
        return false, "INVALID_NOTE", decode_err
    end

    if #note > MAX_NOTE_BYTES then
        return false,
            "NOTE_TOO_LARGE",
            string.format(
                "Notes are limited to %d bytes.",
                MAX_NOTE_BYTES
            )
    end

    if note:find("%z") then
        return false,
            "INVALID_NOTE",
            "The note must not contain NUL characters."
    end

    local session, code, message = self:resolveSession()
    if not session then
        return false, code, message
    end

    expected_revision = tonumber(expected_revision)
    if not expected_revision
        or expected_revision ~= session.revision then
        return false,
            "NOTE_CONFLICT",
            "The note changed on the reader. Pull the latest version first.",
            self:sessionState(session)
    end

    local ui = session.ui
    local annotation = session.annotation
    local type_before = annotationType(ui, annotation)
    local value = note ~= "" and note or nil

    session.highlight:writePdfAnnotation(
        "content",
        annotation,
        value or ""
    )

    annotation.note = value
    local type_after = annotationType(ui, annotation)
    local event_payload = {
        annotation,
        index_modified = session.index,
    }

    if type_before ~= type_after then
        if type_before == "highlight" then
            event_payload.nb_highlights_added = -1
            event_payload.nb_notes_added = 1
        else
            event_payload.nb_highlights_added = 1
            event_payload.nb_notes_added = -1
        end
    end

    ui:handleEvent(Event:new("AnnotationsModified", event_payload))

    if session.highlight.view
        and session.highlight.view.highlight
        and session.highlight.view.highlight.note_mark then
        UIManager:setDirty(session.highlight.dialog, "ui")
    end

    session.last_note = value or ""
    session.revision = session.revision + 1
    session.updated_at = os.time()
    session.expires_at = session.updated_at + NOTE_SESSION_TTL_SECONDS

    UIManager:show(Notification:new{
        text = _("Note saved from phone."),
    })

    return true, self:sessionState(session)
end

function Interaction:getFootnotePageKey(ui)
    local ok, page = pcall(function()
        return ui.document:getCurrentPage()
    end)

    if ok and page ~= nil then
        return tostring(page)
    end

    local xpointer_ok, xpointer = pcall(function()
        return ui.document:getXPointer()
    end)

    return xpointer_ok and tostring(xpointer) or "current"
end

function Interaction:makeFootnoteCandidate(ui, link)
    if not link or not link.section then
        return nil
    end

    local from_xpointer
    if link.a_xpointer and ui.link.isXpointerCoherent then
        local ok, coherent = pcall(
            ui.link.isXpointerCoherent,
            ui.link,
            link.a_xpointer
        )
        if ok and coherent then
            from_xpointer = link.a_xpointer
        end
    end

    local link_y = link.end_y
    if link.segments and #link.segments > 0 then
        link_y = link.segments[#link.segments].y1
    end

    return {
        xpointer = link.section,
        marker_xpointer = link.section,
        from_xpointer = from_xpointer,
        a_xpointer = link.a_xpointer,
        link_y = link_y,
    }
end

function Interaction:openNextFootnote()
    local capabilities = self:getCapabilities()
    if not capabilities.footnotes then
        return false,
            "NOT_SUPPORTED",
            "Automatic footnote opening is available only for supported reflowable documents."
    end

    local ui = self:getUI()
    local ok, links = pcall(
        ui.document.getPageLinks,
        ui.document,
        true
    )

    if not ok or type(links) ~= "table" or #links == 0 then
        return false,
            "NO_FOOTNOTE_FOUND",
            "No footnote was detected on the current page."
    end

    table.sort(links, function(left, right)
        local left_y = tonumber(left.start_y or left.end_y) or 0
        local right_y = tonumber(right.start_y or right.end_y) or 0
        if left_y == right_y then
            local left_x = tonumber(left.start_x or left.end_x) or 0
            local right_x = tonumber(right.start_x or right.end_x) or 0
            return left_x < right_x
        end
        return left_y < right_y
    end)

    local page_key = self:getFootnotePageKey(ui)
    if page_key ~= self.footnote_page_key then
        self.footnote_page_key = page_key
        self.footnote_cursor = 0
    end

    for offset = 1, #links do
        local index = ((self.footnote_cursor + offset - 1) % #links) + 1
        local candidate = self:makeFootnoteCandidate(ui, links[index])

        if candidate then
            local shown_ok, shown = pcall(
                ui.link.showAsFootnotePopup,
                ui.link,
                candidate,
                false
            )

            if shown_ok and shown then
                self.footnote_cursor = index
                return true, {
                    action = "footnote_opened",
                    candidate = index,
                }
            end
        end
    end

    return false,
        "NO_FOOTNOTE_FOUND",
        "No footnote was detected on the current page."
end

return Interaction
