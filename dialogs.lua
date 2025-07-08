local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local Trapper = require("ui/trapper")
local Prompts = require("prompts")

-- main dialog class
local AssitantDialog = {
  input_dialog = nil,
}
AssitantDialog.__index = AssitantDialog

function AssitantDialog:new(assitant, config)
  local self = setmetatable({}, AssitantDialog)
  self.assitant = assitant
  self.querier = assitant.querier
  self.config = config
  return self
end

function AssitantDialog:_close()
  if self.input_dialog then
    UIManager:close(self.input_dialog)
    self.input_dialog = nil
  end
end

-- Helper function to truncate text based on configuration
function AssitantDialog:_truncateUserPrompt(text)
  local CONFIGURATION = self.config
  if not CONFIGURATION or not CONFIGURATION.features.max_display_user_prompt_length then
    return text
  end
  
  local max_length = CONFIGURATION.features.max_display_user_prompt_length
  if max_length <= 0 then
    return text
  end
  
  if text and #text > max_length then
    return text:sub(1, max_length) .. "..."
  end
  return text
end

function AssitantDialog:_formatUserPrompt(user_prompt, highlightedText)
  local CONFIGURATION = self.config
  local book = self:_getBookContext()
  
  -- Handle case where no text is highlighted (gesture-triggered)
  local text_to_use = highlightedText and highlightedText ~= "" and highlightedText or ""
  local language = (CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.response_language) or "English"
  
  -- replace placeholders in the user prompt
  return user_prompt:gsub("{(%w+)}", {
    title = book.title,
    author = book.author,
    language = language,
    highlight = text_to_use,
  })
end

function AssitantDialog:_createResultText(highlightedText, message_history, previous_text, title)
  local CONFIGURATION = self.config

  -- Helper function to format a single message (user or assistant)
  local function formatSingleMessage(message, title)
    if not message then return "" end
    if message.role == "user" then
      local user_message
      if title and title ~= "" then
        -- shows "User: <title>" if title is provided
        user_message = string.format("%s\n\n", title)
      else
        -- shows user input prompt
        user_message = string.format("\n\n%s\n\n", self:_truncateUserPrompt(message.content or _("(Empty message)")))
      end
      return "### ⮞ User: " .. user_message
    elseif message.role == "assistant" then
      local assistant_content = message.content or _("(No response)")
      return string.format("### ⮞ Assistant:\n\n%s\n\n", assistant_content)
    end
    return "" -- Should not happen for valid roles
  end

  -- first response message
  if not previous_text then
    local result_text = ""
    local show_highlighted_text = true

    -- if highlightedText is nil or empty, don't show highlighted text
    if not highlightedText or highlightedText == "" then
      show_highlighted_text = false
    end

    -- won't show if `hide_highlighted_text` is set to false
    if CONFIGURATION.features and CONFIGURATION.features.hide_highlighted_text then
      show_highlighted_text = false
    end

    -- won't show if highlighted text is longer than threshold `long_highlight_threshold`
    if show_highlighted_text and CONFIGURATION.features
          and CONFIGURATION.features.hide_long_highlights and CONFIGURATION.features.long_highlight_threshold and
          highlightedText and #highlightedText > CONFIGURATION.features.long_highlight_threshold then
        show_highlighted_text = false
    end

    local result_parts = {}
    if show_highlighted_text then
      table.insert(result_parts, string.format("__%s__\"%s\"\n\n", _("Highlighted text:"), highlightedText))
    end
    
    -- skips the first message (system prompt)
    for i = 2, #message_history do
      local message = message_history[i]
      if not message.is_context then
        table.insert(result_parts, formatSingleMessage(message, title))
      end
    end
    return table.concat(result_parts)
  end

  local last_user_message = message_history[#message_history - 1]
  local last_assistant_message = message_history[#message_history]

  return previous_text .. "------------\n\n" ..
      formatSingleMessage(last_user_message, title) .. formatSingleMessage(last_assistant_message, title)
end

-- Helper function to create and show ChatGPT viewer
function AssitantDialog:_createAndShowViewer(highlightedText, message_history, title)
  local CONFIGURATION = self.config
  local result_text = self:_createResultText(highlightedText, message_history, nil, title)
  local render_markdown = (CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.render_markdown) or true
  local markdown_font_size = (CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.markdown_font_size) or 20
  
  local chatgpt_viewer = ChatGPTViewer:new {
    title = title,
    text = result_text,
    ui = self.assitant.ui,
    onShowSwitchModel = function() -- callback for switch model button
      self.assitant:showProviderSwitch()
    end,
    onAskQuestion = function(viewer, user_question) -- callback for user entered question
        -- Use viewer's own highlighted_text value
        local current_highlight = viewer.highlighted_text or highlightedText
        local viewer_title = ""

        if type(user_question) == "string" then
          -- Use user entered question
          self:_prepareMessageHistoryForUserQuery(message_history, current_highlight, user_question)
        elseif type(user_question) == "table" then
          -- Use custom prompt from configuration
          viewer_title = user_question.text or "Custom Prompt"
          table.insert(message_history, {
            role = "user",
            content = self:_formatUserPrompt(user_question.user_prompt, current_highlight)
          })
        end

        Trapper:wrap(function()
          -- Use viewer's own highlighted_text value
          local answer, err = self.querier:query(message_history)
          
          -- Check if we got a valid response
          if not answer or answer == "" or err ~= nil then
            UIManager:show(InfoMessage:new{
              icon = "notice-warning",
              text = err or "",
            })
            return
          end
          
          table.insert(message_history, {
            role = "assistant",
            content = answer
          })
          viewer:update(self:_createResultText(current_highlight, message_history, viewer.text, viewer_title))
          
          if viewer.scroll_text_w then
            viewer.scroll_text_w:resetScroll()
          end
        end)
      end,
    highlighted_text = highlightedText,
    message_history = message_history,
    render_markdown = render_markdown,
    markdown_font_size = markdown_font_size,
  }
  
  UIManager:show(chatgpt_viewer)
  
  -- Refresh the screen after displaying the results
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.refresh_screen_after_displaying_results then
    UIManager:setDirty(nil, "full")
  end
end


function AssitantDialog:_prepareMessageHistoryForUserQuery(message_history, highlightedText, user_question)
  local book = self:_getBookContext()
  local context = {}
  if highlightedText and highlightedText ~= "" then
    context = {
      role = "user",
      is_context = true,
      content = string.format([[I'm reading something titled '%s' by %s.
I have a question about the following highlighted text: ```%s```.
If the question is not clear enough, analyze the highlighted text.]],
      book.title, book.author, highlightedText),
    }
  else
    context = {
      role = "user",
      is_context = true,
      content = string.format([[I'm reading something titled '%s' by %s.
I have a question about this book.]], book.title, book.author),
    }
  end

  table.insert(message_history, context)
  local question_message = {
    role = "user",
    content = user_question
  }
  table.insert(message_history, question_message)
end

function AssitantDialog:_getBookContext()
  local prop = self.assitant.ui.document:getProps()
  return {
    title = prop.title or _("Unknown Title"),
    author = prop.authors or _("Unknown Author")
  }
end

-- When clicked [Assistant] button in main select popup,
-- Or when activated from guesture (no text highlighted)
function AssitantDialog:show(highlightedText)

  local is_highlighted = highlightedText and highlightedText ~= ""
  
  -- close any existing input dialog
  self:_close()

  local CONFIGURATION = self.config

  -- Handle regular dialog (user input prompt, other buttons)
  local book = self:_getBookContext()
  local system_prompt = CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.system_prompt or Prompts.assitant_prompts.default.system_prompt
  local message_history = {{
    role = "system",
    content = system_prompt
  }}

  -- Create button rows (3 buttons per row)
  local button_rows = {}
  local all_buttons = {
    {
      text = _("Cancel"),
      id = "close",
      callback = function()
        self:_close()
      end
    },
    {
      text = _("Ask"),
      is_enter_default = true,
      callback = function()
        local user_question = self.input_dialog and self.input_dialog:getInputText() or ""
        if not user_question or user_question == "" then
          UIManager:show(InfoMessage:new{
            text = _("Enter a question before proceeding."),
            timeout = 3
          })
          return
        end
            -- self:_close() -- Moved this call to after a successful API response
        self:_prepareMessageHistoryForUserQuery(message_history, highlightedText, user_question)
        Trapper:wrap(function()
          local answer, err = self.querier:query(message_history)
          
          -- Check if we got a valid response
          if err then
            UIManager:show(InfoMessage:new{
              icon = "notice-warning",
              text = "Error: " .. (err or ""),
              timeout = 3
            })
            return
          end
          
          table.insert(message_history, {
            role = "assistant",
            content = answer,
          })
          
          -- Create a contextual title
          local viewer_title = highlightedText and highlightedText ~= "" and _("Book Analysis")
          self:_createAndShowViewer(highlightedText, message_history, viewer_title)
        end)
      end
    }
  }
  
  -- Only add additional buttons if there's highlighted text
  if is_highlighted then
    -- Add Dictionary button
    if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.dictionary_translate_to then
      table.insert(all_buttons, {
        text = _("Dictionary"),
        callback = function()
              -- self:_close() -- Don't close here, let the dictionary dialog handle it
          local showDictionaryDialog = require("dictdialog")
          Trapper:wrap(function()
                showDictionaryDialog(self.assitant, highlightedText, self) -- Pass self to allow closing parent
          end)
        end
      })  
    end

    local sorted_prompts = Prompts.getSortedCustomPrompts() or {}
    -- Add buttons in sorted order
    for _, tab in ipairs(sorted_prompts) do
      table.insert(all_buttons, {
        text = tab.text,
        callback = function()
              -- self:_close() -- Don't close here, let showCustomPrompt handle it
          Trapper:wrap(function()
                self:showCustomPrompt(highlightedText, tab.idx, true) -- Pass true to indicate it should close parent
          end)
        end
      })
    end
  end
  
  -- Organize buttons into rows of three
  local current_row = {}
  for _, button in ipairs(all_buttons) do
    table.insert(current_row, button)
    if #current_row == 3 then
      table.insert(button_rows, current_row)
      current_row = {}
    end
  end
  
  if #current_row > 0 then
    table.insert(button_rows, current_row)
  end

  -- Show the dialog with the button rows
  local dialog_title = is_highlighted and 
    _("Ask a question about the highlighted text") or 
    string.format(_("Ask a question about this book:\n%s by %s"), book.title, book.author)
  
  local input_hint = is_highlighted and 
    _("Type your question here...") or 
    _("Ask anything about this book...")
  
  self.input_dialog = InputDialog:new{
    title = _("AI Assistant"),
    description = dialog_title,
    input_hint = input_hint,
    buttons = button_rows,
    title_bar_left_icon = "appbar.settings",
    title_bar_left_icon_tap_callback = function ()
        self.input_dialog:onCloseKeyboard()
        self.assitant:showProviderSwitch()
    end,
    close_callback = function () self:_close() end,
    dismiss_callback = function () self:_close() end
  }
  self.input_dialog.title_bar.title_multilines = false
  
  UIManager:show(self.input_dialog)
  self.input_dialog:onShowKeyboard() -- Show keyboard immediately
end

-- Process main select popup buttons
-- ( custom prompts from configuration )
    function AssitantDialog:showCustomPrompt(highlightedText, prompt_index, should_close_parent)

      if should_close_parent then
        self:_close()
      end

  local prompt_config = Prompts.getMergedCustomPrompts()[prompt_index]

  local title = prompt_config.text or prompt_index
  local user_content = self:_formatUserPrompt(prompt_config.user_prompt, highlightedText)
  local message_history = {
    {
      role = "system",
      content = prompt_config.system_prompt or Prompts.assitant_prompts.default.system_prompt,
    },
    {
      role = "user",
      content = user_content,
      is_context = true
    }
  }
  
  local answer, err = self.querier:query(message_history, string.format("🌐 Loading for %s ...", title or prompt_index))
  if err then
    UIManager:show(InfoMessage:new{text = err, icon = "notice-warning"})
        -- If parent was closed, and this fails, we need to re-show or handle appropriately.
        -- For now, just showing error. If this came from the main dialog, it will remain open.
        if should_close_parent then
            -- Potentially re-open the input dialog here if needed, or provide a way back.
            -- For now, the user would have to re-trigger the main dialog.
        end
    return
  end
  if answer then
    table.insert(message_history, {
      role = "assistant",
      content = answer
    })
  end

  if not message_history or #message_history < 1 then
    UIManager:show(InfoMessage:new{text = _("Error: No response received"), icon = "notice-warning"})
    return
  end

  self:_createAndShowViewer(highlightedText, message_history, title)
end

return AssitantDialog