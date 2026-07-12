-- KOReader Remote interaction bridge.
--
-- Adds remote note editing to KOReader's highlight dialog and exposes a
-- conservative "open next footnote" action for reflowable documents.

local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local mime = require("mime")
local _ = require("gettext")

local Interaction = {}
Interaction.__index = Interaction

local MAX_NOTE_BYTES = 12 * 1024
local MAX_BOOKMARK_ITEMS = 300
local MAX_BOOKMARK_EXCERPT_BYTES = 1200
local MAX_BOOKMARK_NOTE_BYTES = 3000
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

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function annotationIdentity(index, ui, annotation)
    local source = table.concat({
        tostring(index),
        tostring(annotation.datetime or ""),
        tostring(annotation.datetime_updated or ""),
        tostring(annotation.page or ""),
        tostring(annotation.pos0 or ""),
        tostring(annotation.pos1 or ""),
        annotationType(ui, annotation),
    }, "\0")

    -- This token only detects that the list changed between loading and
    -- tapping an item; it is not an authentication token.
    local hash = 5381
    for position = 1, #source do
        hash = (hash * 33 + source:byte(position)) % 4294967296
    end

    return string.format("%d-%08x", index, hash)
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
    instance.bookmark_return = nil
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
        bookmarks = notes,
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

            return self:startNoteSession(
                highlight,
                saved_index,
                true
            )
        end)
    end

    -- Older and development KOReader builds may still expose the optional
    -- highlight prompt callback. KOReader 2026.03 saves highlights directly,
    -- so support both interfaces.
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
                            local started = bridge:startNoteSession(
                                highlight,
                                index,
                                false
                            )

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

function Interaction:refreshSessionDraft(session_id)
    local session = self.session

    if not session or (session_id and session.id ~= session_id) then
        return nil, "NO_NOTE_SESSION", "No note is selected on the reader."
    end

    local dialog = session.input_dialog
    if not dialog or type(dialog.getInputText) ~= "function" then
        return nil,
            "NOTE_DIALOG_CLOSED",
            "The Kindle note editor is no longer open."
    end

    local ok, draft = pcall(dialog.getInputText, dialog)
    if not ok then
        return nil,
            "NOTE_DIALOG_CLOSED",
            "The Kindle note editor could not be read."
    end

    draft = tostring(draft or "")

    if draft ~= session.last_draft then
        session.last_draft = draft
        session.revision = session.revision + 1
        session.updated_at = os.time()
        session.expires_at = session.updated_at + NOTE_SESSION_TTL_SECONDS
    end

    return session
end

function Interaction:closeNoteDialog(session)
    local dialog = session and session.input_dialog
    if not dialog then
        return
    end

    session.input_dialog = nil

    local ok, err = pcall(function()
        UIManager:close(dialog, "flashui")
    end)

    if not ok then
        logger.warn(
            "KOReaderRemote: could not close remote note dialog:",
            err
        )
    end
end

function Interaction:discardNewHighlight(session)
    if not session or not session.is_new_note or session.saved then
        return
    end

    local index = self:findAnnotationIndex(session.ui, session.annotation)
    if not index then
        return
    end

    local bookmark = session.ui and session.ui.bookmark
    if bookmark and type(bookmark.removeItemByIndex) == "function" then
        bookmark:removeItemByIndex(index)
    end
end

function Interaction:cancelNoteSession(reason, close_dialog, discard_new)
    local session = self.session
    if not session then
        return false
    end

    logger.info(
        "KOReaderRemote: closing note session",
        session.id,
        reason or "cancelled"
    )

    self.session = nil

    if close_dialog then
        self:closeNoteDialog(session)
    end

    if discard_new then
        self:discardNewHighlight(session)
    end

    self.last_note_result = {
        result = "cancelled",
        at = os.time(),
    }

    return true
end

function Interaction:onUIClosed(ui)
    if self.session and self.session.ui == ui then
        self:cancelNoteSession(
            "document closed",
            false,
            true
        )
    end

    if self.bookmark_return and self.bookmark_return.ui == ui then
        self.bookmark_return = nil
    end
end

function Interaction:openNoteDialog(session)
    local bridge = self
    local session_id = session.id
    local input_dialog

    input_dialog = InputDialog:new{
        title = _("Remote note"),
        description = _(
            "Type here or continue in KOReader Remote on your phone."
        ),
        input = session.last_draft,
        allow_newline = true,
        add_scroll_buttons = true,
        use_available_height = true,
        edited_callback = function()
            bridge:refreshSessionDraft(session_id)
        end,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        bridge:runNoteAction(function()
                            bridge:cancelNoteSession(
                                "cancelled on Kindle",
                                true,
                                true
                            )
                            return true
                        end)
                    end,
                },
                {
                    text = _("Paste"),
                    callback = function()
                        input_dialog:addTextToInput(
                            session.annotation.text or ""
                        )
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        bridge:runNoteAction(function()
                            local ok, result, message =
                                bridge:saveNoteSession(
                                    nil,
                                    session_id,
                                    "kindle"
                                )

                            if not ok then
                                UIManager:show(InfoMessage:new{
                                    text = message
                                        or _("The note could not be saved."),
                                })
                            end

                            return ok
                        end)
                    end,
                },
            },
        },
    }

    session.input_dialog = input_dialog
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function Interaction:startNoteSession(highlight, index, is_new_note)
    if self.session then
        self:cancelNoteSession("replaced", true, true)
    end

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

    self.last_note_result = nil
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
        last_draft = annotation.note or "",
        saved_note = annotation.note or "",
        saved_note_present = annotation.note ~= nil,
        type_before = annotationType(ui, annotation),
        is_new_note = is_new_note == true,
        saved = false,
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

    self:openNoteDialog(self.session)
    return true
end

function Interaction:resolveSession()
    local session = self.session
    if not session then
        return nil, "NO_NOTE_SESSION", "No note is selected on the reader."
    end

    if os.time() > session.expires_at then
        self:cancelNoteSession("expired", true, true)
        return nil, "NOTE_SESSION_EXPIRED", "The note session expired."
    end

    local ui = self:getUI()
    if not ui
        or ui ~= session.ui
        or not ui.document
        or ui.document.file ~= session.document_file then
        self:cancelNoteSession("document changed", false, true)
        return nil,
            "NO_NOTE_SESSION",
            "The selected document is no longer open."
    end

    local index = self:findAnnotationIndex(ui, session.annotation)
    if not index then
        self:cancelNoteSession("annotation removed", true, false)
        return nil, "NO_NOTE_SESSION", "The selected note no longer exists."
    end

    session.index = index

    local refreshed, code, message = self:refreshSessionDraft(session.id)
    if not refreshed then
        self:cancelNoteSession("dialog closed", false, true)
        return nil, code, message
    end

    local current_saved_note = session.annotation.note or ""
    local current_saved_present = session.annotation.note ~= nil

    if current_saved_note ~= session.saved_note
        or current_saved_present ~= session.saved_note_present then
        session.saved_note = current_saved_note
        session.saved_note_present = current_saved_present
        session.revision = session.revision + 1
        session.updated_at = os.time()
    end

    return session
end

function Interaction:sessionState(session)
    if not session then
        local result = self.last_note_result
        if result and os.time() - result.at <= 30 then
            return {
                active = false,
                result = result.result,
            }
        end

        return {
            active = false,
        }
    end

    return {
        active = true,
        id = session.id,
        excerpt = utf8Prefix(session.annotation.text or "", 2200),
        note = session.last_draft,
        draft = session.last_draft,
        saved_note = session.saved_note,
        revision = session.revision,
        has_note = session.last_draft ~= "",
        has_saved_note = session.saved_note_present,
        dirty = session.last_draft ~= session.saved_note
            or (session.last_draft == "" and session.saved_note_present),
        expires_in = math.max(0, session.expires_at - os.time()),
    }
end

function Interaction:getNoteSessionState()
    local session = self:resolveSession()
    return self:sessionState(session)
end

function Interaction:decodeAndValidateNote(encoded)
    if type(encoded) ~= "string" then
        return nil, "MISSING_NOTE", "The note header is missing."
    end

    if #encoded > math.ceil(MAX_NOTE_BYTES / 3) * 4 + 8 then
        return nil, "NOTE_TOO_LARGE", "The note is too large."
    end

    local note, decode_err = decodeBase64(encoded)
    if not note then
        return nil, "INVALID_NOTE", decode_err
    end

    if #note > MAX_NOTE_BYTES then
        return nil,
            "NOTE_TOO_LARGE",
            string.format(
                "Notes are limited to %d bytes.",
                MAX_NOTE_BYTES
            )
    end

    if note:find("%z") then
        return nil,
            "INVALID_NOTE",
            "The note must not contain NUL characters."
    end

    return note
end

function Interaction:pushEncodedNote(encoded, expected_revision)
    local note, decode_code, decode_message =
        self:decodeAndValidateNote(encoded)

    if note == nil then
        return false, decode_code, decode_message
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
            "The Kindle draft changed. Pull the latest version first.",
            self:sessionState(session)
    end

    local dialog = session.input_dialog
    local ok, set_err = pcall(
        dialog.setInputText,
        dialog,
        note,
        true,
        false
    )

    if not ok then
        return false,
            "NOTE_DIALOG_CLOSED",
            "The Kindle note editor could not be updated: "
                .. tostring(set_err)
    end

    session.last_draft = note
    session.revision = session.revision + 1
    session.updated_at = os.time()
    session.expires_at = session.updated_at + NOTE_SESSION_TTL_SECONDS

    return true, self:sessionState(session)
end

function Interaction:commitNoteSession(session, source)
    local ui = session.ui
    local annotation = session.annotation
    local value = session.last_draft ~= "" and session.last_draft or nil
    local type_before = session.type_before

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

    session.saved = true
    session.saved_note = value or ""
    session.saved_note_present = value ~= nil
    self.session = nil
    self.last_note_result = {
        result = "saved",
        at = os.time(),
    }

    self:closeNoteDialog(session)

    UIManager:show(Notification:new{
        text = source == "phone"
            and _("Note saved from phone.")
            or _("Note saved."),
    })

    return {
        active = false,
        result = "saved",
    }
end

function Interaction:saveNoteSession(
    expected_revision,
    session_id,
    source
)
    local session, code, message = self:resolveSession()
    if not session then
        return false, code, message
    end

    if session_id and session.id ~= session_id then
        return false,
            "NOTE_CONFLICT",
            "A different note is now open on the reader.",
            self:sessionState(session)
    end

    if expected_revision ~= nil then
        expected_revision = tonumber(expected_revision)

        if not expected_revision
            or expected_revision ~= session.revision then
            return false,
                "NOTE_CONFLICT",
                "The Kindle draft changed. Pull the latest version first.",
                self:sessionState(session)
        end
    end

    return true, self:commitNoteSession(session, source)
end


function Interaction:getBookTitle(ui)
    if ui and ui.doc_props and ui.doc_props.display_title then
        return tostring(ui.doc_props.display_title)
    end

    return basename(ui and ui.document and ui.document.file)
end

function Interaction:getBookmarkPageLabel(ui, annotation)
    if annotation.pageref ~= nil and annotation.pageref ~= "" then
        return tostring(annotation.pageref)
    end

    if annotation.pageno ~= nil and annotation.pageno ~= "" then
        return tostring(annotation.pageno)
    end

    if ui.bookmark
        and type(ui.bookmark.getBookmarkPageString) == "function" then
        local ok, page = pcall(
            ui.bookmark.getBookmarkPageString,
            ui.bookmark,
            annotation.page
        )

        if ok and page ~= nil then
            return tostring(page)
        end
    end

    return tostring(annotation.page or "")
end

function Interaction:getCurrentReadingPage(ui, location)
    if ui.paging and type(location) == "table"
        and location[1] and location[1].page ~= nil then
        return tostring(location[1].page)
    end

    if ui.rolling and type(location) == "table"
        and location.xpointer
        and ui.document
        and type(ui.document.getPageFromXPointer) == "function" then
        local ok, page = pcall(
            ui.document.getPageFromXPointer,
            ui.document,
            location.xpointer
        )

        if ok and page ~= nil then
            return tostring(page)
        end
    end

    local ok, page = pcall(function()
        return ui.document:getCurrentPage()
    end)

    return ok and page ~= nil and tostring(page) or ""
end

function Interaction:validateBookmarkUI()
    local ui = self:getUI()

    if not ui
        or not ui.document
        or not ui.annotation
        or type(ui.annotation.annotations) ~= "table"
        or not ui.bookmark then
        return nil,
            "NO_DOCUMENT_OPEN",
            "Open a book on the reader first."
    end

    return ui
end

function Interaction:resolveBookmark(id)
    if type(id) ~= "string" or id == "" then
        return nil,
            nil,
            nil,
            nil,
            "MISSING_BOOKMARK",
            "The bookmark identifier is missing."
    end

    local ui, code, message = self:validateBookmarkUI()
    if not ui then
        return nil, nil, nil, nil, code, message
    end

    for index, annotation in ipairs(ui.annotation.annotations) do
        if annotationIdentity(index, ui, annotation) == id then
            return ui,
                annotation,
                index,
                annotationType(ui, annotation)
        end
    end

    return nil,
        nil,
        nil,
        nil,
        "BOOKMARK_CHANGED",
        "The bookmark list changed. Refresh it and try again."
end

function Interaction:getBookmarkReturnState(ui)
    local saved = self.bookmark_return

    if not saved then
        return {
            available = false,
        }
    end

    if not ui
        or saved.ui ~= ui
        or not ui.document
        or ui.document.file ~= saved.document_file then
        self.bookmark_return = nil
        return {
            available = false,
        }
    end

    return {
        available = true,
        page = saved.page or "",
        created_at = saved.created_at,
    }
end

function Interaction:beginBookmarkExcursion(ui)
    local current_state = self:getBookmarkReturnState(ui)
    if current_state.available then
        return true, current_state
    end

    if not ui.link or type(ui.link.getCurrentLocation) ~= "function" then
        return false,
            "RETURN_NOT_SUPPORTED",
            "KOReader could not capture the current reading position."
    end

    local ok, location = pcall(
        ui.link.getCurrentLocation,
        ui.link
    )

    if not ok or type(location) ~= "table" then
        return false,
            "RETURN_NOT_SUPPORTED",
            "KOReader could not capture the current reading position."
    end

    local saved = {
        ui = ui,
        document_file = ui.document.file,
        location = location,
        page = self:getCurrentReadingPage(ui, location),
        created_at = os.time(),
        added_to_history = false,
    }

    if type(ui.link.addCurrentLocationToStack) == "function" then
        local stack_ok, stack_err = pcall(
            ui.link.addCurrentLocationToStack,
            ui.link,
            location
        )

        if stack_ok then
            saved.added_to_history = true
        else
            logger.warn(
                "KOReaderRemote: could not add return point to history:",
                stack_err
            )
        end
    end

    self.bookmark_return = saved
    return true, self:getBookmarkReturnState(ui)
end

function Interaction:removeBookmarkReturnFromHistory(ui, saved)
    if not saved.added_to_history
        or not ui.link
        or type(ui.link.location_stack) ~= "table" then
        return
    end

    for index = #ui.link.location_stack, 1, -1 do
        if ui.link.location_stack[index] == saved.location then
            table.remove(ui.link.location_stack, index)
            return
        end
    end
end

function Interaction:returnToReadingPosition()
    local ui, code, message = self:validateBookmarkUI()
    if not ui then
        return false, code, message
    end

    local saved = self.bookmark_return
    local state = self:getBookmarkReturnState(ui)

    if not saved or not state.available then
        return false,
            "NO_RETURN_POSITION",
            "No reading position is currently saved."
    end

    local controller
    if ui.rolling
        and type(ui.rolling.onRestoreBookLocation) == "function" then
        controller = ui.rolling
    elseif ui.paging
        and type(ui.paging.onRestoreBookLocation) == "function" then
        controller = ui.paging
    end

    if not controller then
        return false,
            "RETURN_NOT_SUPPORTED",
            "KOReader cannot restore this reading position."
    end

    local ok, err = pcall(
        controller.onRestoreBookLocation,
        controller,
        saved.location
    )

    if not ok then
        logger.err(
            "KOReaderRemote: return to reading position failed:",
            err
        )
        return false,
            "RETURN_FAILED",
            "KOReader could not restore the saved reading position."
    end

    self:removeBookmarkReturnFromHistory(ui, saved)
    self.bookmark_return = nil

    return true, {
        action = "reading_position_restored",
        page = saved.page or "",
        return_position = {
            available = false,
        },
    }
end

function Interaction:getBookmarks()
    local ui, code, message = self:validateBookmarkUI()
    if not ui then
        return false, code, message
    end

    local annotations = ui.annotation.annotations
    local items = {}
    local counts = {
        all = #annotations,
        bookmark = 0,
        highlight = 0,
        note = 0,
    }

    for index, annotation in ipairs(annotations) do
        local item_type = annotationType(ui, annotation)
        counts[item_type] = (counts[item_type] or 0) + 1

        if #items < MAX_BOOKMARK_ITEMS then
            items[#items + 1] = {
                id = annotationIdentity(index, ui, annotation),
                order = index,
                type = item_type,
                page = self:getBookmarkPageLabel(ui, annotation),
                chapter = utf8Prefix(
                    annotation.chapter or "",
                    400
                ),
                excerpt = utf8Prefix(
                    annotation.text or "",
                    MAX_BOOKMARK_EXCERPT_BYTES
                ),
                note = utf8Prefix(
                    annotation.note or "",
                    MAX_BOOKMARK_NOTE_BYTES
                ),
                datetime = tostring(annotation.datetime or ""),
                datetime_updated = tostring(
                    annotation.datetime_updated or ""
                ),
                can_edit_note = item_type == "highlight"
                    or item_type == "note",
                can_delete = true,
            }
        end
    end

    return true, {
        title = self:getBookTitle(ui),
        count = #annotations,
        returned = #items,
        truncated = #annotations > #items,
        counts = counts,
        return_position = self:getBookmarkReturnState(ui),
        items = items,
    }
end

function Interaction:openBookmark(id)
    local ui, selected, _, selected_type, code, message =
        self:resolveBookmark(id)

    if not ui then
        return false, code, message
    end

    if type(ui.bookmark.gotoBookmark) ~= "function" then
        return false,
            "BOOKMARK_OPEN_FAILED",
            "KOReader cannot open bookmarks in this view."
    end

    local return_ok, return_result, return_message =
        self:beginBookmarkExcursion(ui)

    if not return_ok then
        return false, return_result, return_message
    end

    local ok, err = pcall(
        ui.bookmark.gotoBookmark,
        ui.bookmark,
        selected.page,
        selected.pos0
    )

    if not ok then
        logger.err("KOReaderRemote: bookmark navigation failed:", err)
        return false,
            "BOOKMARK_OPEN_FAILED",
            "KOReader could not open the selected bookmark."
    end

    return true, {
        action = "bookmark_opened",
        type = selected_type,
        page = self:getBookmarkPageLabel(ui, selected),
        return_position = return_result,
    }
end

function Interaction:editBookmarkNote(id)
    local ui, _, index, item_type, code, message =
        self:resolveBookmark(id)

    if not ui then
        return false, code, message
    end

    if item_type == "bookmark" then
        return false,
            "NOTE_NOT_SUPPORTED",
            "Page bookmarks do not have an editable highlight note."
    end

    if self.session then
        return false,
            "NOTE_SESSION_ACTIVE",
            "Save or cancel the currently open remote note first."
    end

    if not ui.highlight then
        return false,
            "NOTE_NOT_SUPPORTED",
            "KOReader cannot edit this note in the current view."
    end

    local started = self:startNoteSession(
        ui.highlight,
        index,
        false
    )

    if not started then
        return false,
            "NOTE_OPEN_FAILED",
            "The note editor could not be opened."
    end

    return true, {
        action = "note_editor_opened",
        session = self:getNoteSessionState(),
    }
end

function Interaction:deleteBookmark(id)
    local ui, selected, index, selected_type, code, message =
        self:resolveBookmark(id)

    if not ui then
        return false, code, message
    end

    if self.session and self.session.annotation == selected then
        self:cancelNoteSession(
            "annotation deleted from phone",
            true,
            false
        )
    end

    if type(ui.bookmark.removeItem) ~= "function" then
        return false,
            "DELETE_NOT_SUPPORTED",
            "KOReader cannot delete this annotation in the current view."
    end

    local ok, err = pcall(
        ui.bookmark.removeItem,
        ui.bookmark,
        selected,
        index
    )

    if not ok then
        logger.err("KOReaderRemote: annotation deletion failed:", err)
        return false,
            "DELETE_FAILED",
            "KOReader could not delete the selected annotation."
    end

    return true, {
        action = "bookmark_deleted",
        type = selected_type,
        return_position = self:getBookmarkReturnState(ui),
    }
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
