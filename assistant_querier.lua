--- Querier module for handling AI queries with dynamic provider loading
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("assistant_viewer")
local InputText = require("ui/widget/inputtext")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local koutil = require("util")
local logger = require("logger")
local rapidjson = require('rapidjson')
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local Device = require("device")
local Screen = Device.screen

local Querier = {
    assistant = nil, -- reference to the main assistant object
    settings = nil,
    handler = nil,
    handler_name = nil,
    provider_settings = nil,
    provider_name = nil,
    interrupt_stream = nil,      -- function to interrupt the stream query
    user_interrupted = false,  -- flag to indicate if the stream was interrupted
    stream_buffer = nil,
    stream_last_render_ts = nil,
    stream_timer_handle = nil,
    stream_active_viewer = nil,
}

function Querier:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Querier:is_inited()
    return self.handler ~= nil
end

--- Load provider model for the Querier
function Querier:load_model(provider_name)
    -- If the provider is already loaded, do nothing.
    if provider_name == self.provider_name and self:is_inited() then
        return true
    end

    local CONFIGURATION = self.assistant.CONFIGURATION
    local provider_settings = koutil.tableGetValue(CONFIGURATION, "provider_settings", provider_name)
    if not provider_settings then
        local err = T(_("Provider settings not found for: %1. Please check your configuration.lua file."),
         provider_name)
        logger.warn("Querier initialization failed: " .. err)
        return false, err
    end

    local handler_name
    local underscore_pos = provider_name:find("_")
    if underscore_pos and underscore_pos > 0 then
        -- Extract `openai` from `openai_o4mimi`
        handler_name = provider_name:sub(1, underscore_pos - 1)
    else
        handler_name = provider_name -- original name
    end

    -- Load the handler based on the provider name
    local success, handler = pcall(function()
        return require("api_handlers." .. handler_name)
    end)
    if success then
        self.handler = handler
        self.handler_name = handler_name
        self.provider_settings = provider_settings
        self.provider_name = provider_name
        return true
    else
        local err = T(_("The handler for %1 was not found. Please ensure the handler exists in api_handlers directory."),
                handler_name)
        logger.warn("Querier initialization failed: " .. err)
        return false, err
    end
end

-- InputText class for showing streaming responses
function Querier:showError(err)
    local dialog
    if self.user_interrupted then
        dialog = InfoMessage:new{ timeout = 3, text = err }
    else
        dialog = ConfirmBox:new{
            text = T(_("API Error:\n%1\n\nTry another provider in the settings dialog."), err or _("Unknown error")),
            ok_text = _("Settings"),
            ok_callback = function() self.assistant:showSettings() end,
            cancel_text = _("Close"),
        }
    end
    UIManager:show(dialog)

    -- clear the text selection when plugin is called without a highlight dialog
    if not self.assistant.ui.highlight.highlight_dialog then
        self.assistant.ui.highlight:clear()
    end
end

--- Query the AI with the provided message history
--- return: answer, error (if any)
function Querier:query(message_history, title)
    if not self:is_inited() then
        return nil, _("Plugin is not configured.")
    end

    local use_stream_mode = self.settings:readSetting("use_stream_mode", true)
    koutil.tableSetValue(self.provider_settings, use_stream_mode, "additional_parameters", "stream")

    local infomsg = InfoMessage:new{
      icon = "book.opened",
      text = string.format("%s\n️☁️ %s\n⚡ %s", title or _("Querying AI ..."), self.provider_name,
            koutil.tableGetValue(self.provider_settings, "model")),
    }

    UIManager:show(infomsg)
    self.handler:setTrapWidget(infomsg)
    local res, err = self.handler:query(message_history, self.provider_settings)
    self.handler:resetTrapWidget()
    UIManager:close(infomsg)

    if type(res) == "function" then
        self.user_interrupted = false
        self.stream_buffer = {}
        self.stream_last_render_ts = 0
        self.stream_timer_handle = nil

        local description = T("☁ %1 ⚡ %2", self.provider_name, koutil.tableGetValue(self.provider_settings, "model"))
        self.stream_active_viewer = ChatGPTViewer:new{
            assistant = self.assistant,
            title = _("AI is responding"),
            text = description .. "\n\n" .. _("Generating..."),
            render_markdown = true,
            is_streaming = true,
            close_callback = function()
                if self.interrupt_stream then self.interrupt_stream() end
                if self.stream_timer_handle then
                    UIManager:unschedule(self.stream_timer_handle)
                    self.stream_timer_handle = nil
                end
            end,
        }
        UIManager:show(self.stream_active_viewer)

        local ok, content, err = pcall(self.processStream, self, res)
        if not ok then
            logger.warn("Error processing stream: " .. tostring(content))
            err = content
        end

        if self.stream_timer_handle then
            UIManager:unschedule(self.stream_timer_handle)
            self.stream_timer_handle = nil
        end

        if self.stream_active_viewer and self.stream_active_viewer:isShown() then
            if err then
                self.stream_active_viewer:update(description .. "\n\n" .. "```\n" .. err .. "\n```")
            else
                self.stream_active_viewer:update(description .. "\n\n" .. content)
                self.stream_active_viewer:onStreamComplete()
            end
        end

        self.stream_buffer = nil
        self.stream_active_viewer = nil

        if self.user_interrupted then
            return nil, _("Request cancelled by user.")
        end

        if err then
            return nil, err:gsub("^[\n%s]*", "")
        end

        res = content
    end

    if err == self.handler.CODE_CANCELLED then
        self.user_interrupted = true
        return nil, _("Request cancelled by user.")
    end

    if type(res) ~= "string" or err ~= nil then
        return nil, tostring(err)
    elseif #res == 0 then
        return nil, _("No response received.") .. (err and tostring(err) or "")
    end
    return res
end

function Querier:processStream(bgQuery)
    local pid, parent_read_fd = ffiutil.runInSubProcess(bgQuery, true)

    if not pid then
        logger.warn("Failed to start background query process.")
        return nil, _("Failed to start subprocess for request")
    end

    local _coroutine = coroutine.running()
    self.interrupt_stream = function()
        coroutine.resume(_coroutine, false)
    end

    local non200 = false
    local check_interval_sec = 0.125
    local chunksize = 1024 * 16
    local buffer = ffi.new('char[?]', chunksize, {0})
    local buffer_ptr = ffi.cast('void*', buffer)
    local completed = false
    local partial_data = ""
    local result_buffer = {}
    local reasoning_content_buffer = {}

    local render_interval_ms = self.settings:readSetting("stream_render_interval_ms", 750)

    local function render_scheduled()
        if not self.stream_active_viewer or not self.stream_active_viewer:isShown() then
            return
        end

        if #self.stream_buffer == 0 then return end

        local description = T("☁ %1 ⚡ %2", self.provider_name, koutil.tableGetValue(self.provider_settings, "model"))
        table.insert(result_buffer, table.concat(self.stream_buffer))
        self.stream_buffer = {}
        local full_text = table.concat(result_buffer)
        self.stream_active_viewer:updateStreamingMarkdown(description .. "\n\n" .. full_text)
        self.stream_last_render_ts = os.time()
    end

    while true do
        if completed then break end

        local go_on_func = function() coroutine.resume(_coroutine, true) end
        UIManager:scheduleIn(check_interval_sec, go_on_func)
        local go_on = coroutine.yield()
        if not go_on then
            self.user_interrupted = true
            logger.info("User interrupted the stream processing")
            UIManager:unschedule(go_on_func)
            break
        end

        local readsize = ffiutil.getNonBlockingReadSize(parent_read_fd)
        if readsize > 0 then
            local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer_ptr, chunksize))
            if bytes_read < 0 then
                local err = ffi.errno()
                logger.warn("readAllFromFD() error: " .. ffi.string(ffi.C.strerror(err)))
                break
            elseif bytes_read == 0 then
                completed = true
                break
            else
                local data_chunk = ffi.string(buffer, bytes_read)
                partial_data = partial_data .. data_chunk

                while true do
                    local line_end = partial_data:find("[\r\n]")
                    if not line_end then break end
                    local line = partial_data:sub(1, line_end - 1)
                    partial_data = partial_data:sub(line_end + 1)

                    if line:sub(1, 6) == "data: " then
                        local json_str = koutil.trim(line:sub(7))
                        if json_str == '[DONE]' then break end

                        local ok, event = pcall(rapidjson.decode, json_str, {null = nil})
                        if ok and event then
                            local reasoning_content, content
                            local choice = koutil.tableGetValue(event, "choices", 1)
                            if choice then
                                if koutil.tableGetValue(choice, "finish_reason") then content = "\n" end
                                local delta = koutil.tableGetValue(choice, "delta")
                                if delta then
                                    reasoning_content = koutil.tableGetValue(delta, "reasoning_content")
                                    content = koutil.tableGetValue(delta, "content")
                                    if not content and not reasoning_content then reasoning_content = "." end
                                end
                            else
                                content = koutil.tableGetValue(event, "candidates", 1, "content", "parts", 1, "text") or
                                          koutil.tableGetValue(event, "delta", "text") or
                                          koutil.tableGetValue(event, "content", 1, "text")
                            end

                            if type(content) == "string" and #content > 0 then
                                table.insert(self.stream_buffer, content)
                            elseif type(reasoning_content) == "string" and #reasoning_content > 0 then
                                table.insert(reasoning_content_buffer, reasoning_content)
                            elseif content == nil and reasoning_content == nil then
                                logger.warn("Unexpected SSE data:", json_str)
                            end
                        else
                            logger.warn("Failed to parse JSON from SSE data:", json_str)
                        end
                    elseif line:sub(1, 1) == "{" then
                        local ok, j = pcall(rapidjson.decode, line, {null = nil})
                        if ok and j then
                            local err_message = koutil.tableGetValue(j, "error", "message")
                            if err_message then table.insert(result_buffer, err_message) end
                        else
                            table.insert(result_buffer, line)
                        end
                    elseif line:sub(1, #(self.handler.PROTOCOL_NON_200)) == self.handler.PROTOCOL_NON_200 then
                        non200 = true
                        table.insert(result_buffer, "\n\n" .. line:sub(#(self.handler.PROTOCOL_NON_200) + 1))
                        break
                    elseif #koutil.trim(line) > 0 and line:sub(1, 7) ~= "event: " and line:sub(1, 1) ~= ":" then
                        table.insert(result_buffer, line)
                        logger.warn("Unrecognized line format:", line)
                    end
                end

                if #self.stream_buffer > 0 and not self.stream_timer_handle then
                    local render_callback
                    render_callback = function()
                        render_scheduled()
                        self.stream_timer_handle = nil
                        if self.stream_buffer and #self.stream_buffer > 0 then
                            self.stream_timer_handle = UIManager:scheduleIn(render_interval_ms / 1000, render_callback)
                        end
                    end
                    self.stream_timer_handle = UIManager:scheduleIn(render_interval_ms / 1000, render_callback)
                end
            end
        elseif readsize == 0 then
            completed = ffiutil.isSubProcessDone(pid)
        else
            local err = ffi.errno()
            logger.warn("Error reading from parent_read_fd:", err, ffi.string(ffi.C.strerror(err)))
            break
        end
    end

    ffiutil.terminateSubProcess(pid)
    self.interrupt_stream = nil

    local collect_interval_sec = 5
    local function collect_and_clean()
        if ffiutil.isSubProcessDone(pid) then
            if parent_read_fd then ffiutil.readAllFromFD(parent_read_fd) end
            logger.dbg("collected previously dismissed subprocess")
        else
            if parent_read_fd and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0 then
                ffiutil.readAllFromFD(parent_read_fd)
                parent_read_fd = nil
            end
            UIManager:scheduleIn(collect_interval_sec, collect_and_clean)
            logger.dbg("previously dismissed subprocess not yet collectable")
        end
    end
    UIManager:scheduleIn(collect_interval_sec, collect_and_clean)

    if #self.stream_buffer > 0 then
        table.insert(result_buffer, table.concat(self.stream_buffer))
        self.stream_buffer = {}
    end

    local ret = koutil.trim(table.concat(result_buffer))
    if non200 then
        if ret:sub(1, 1) == '{' then
            local endPos = ret:reverse():find("}")
            if endPos and endPos > 0 then
                local ok, j = pcall(rapidjson.decode, ret:sub(1, #ret - endPos + 1), {null=nil})
                if ok then
                    local err = koutil.tableGetValue(j, "error", "message") or koutil.tableGetValue(j, "message")
                    if err then return nil, err end
                end
            end
        end
        return nil, ret
    else
        local reasoning = table.concat(reasoning_content_buffer):gsub("^%.+", "", 1)
        if #reasoning > 0 then
            ret = T("<dl><dt>%1</dt><dd>%2</dd></dl>\n\n%3", _("Deeply Thought"), reasoning, ret)
        elseif ret:sub(1, 7) == "<think>" then
            ret = ret:gsub("<think>", T("<dl><dt>%1</dt><dd>", _("Deeply Thought")), 1):gsub("</think>", "</dd></dl>", 1)
        end
    end
    return ret, nil
end

return Querier