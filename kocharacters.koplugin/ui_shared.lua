-- ui_shared.lua
-- Shared UI helpers used by ui_character.lua and ui_codex.lua

local UIManager = require("ui/uimanager")
local Screen    = require("device").screen

local UIShared = {}

-- Build and show an HTML viewer dialog.
-- opts fields:
--   inner_w       (number)    available content width (after outer borders)
--   html_body     (string)
--   html_css      (string)
--   resource_dir  (string)    base path for embedded images
--   make_buttons  (function)  receives close_fn, returns ButtonTable rows array
--   link_callback (function)  receives link object/string on tap (optional)
-- Returns true on success, false if ScrollHtmlWidget is unavailable (caller falls back).
function UIShared.showHtmlViewer(opts)
    local ok_s, ScrollHtmlWidget = pcall(require, "ui/widget/scrollhtmlwidget")
    local ok_f, FrameContainer   = pcall(require, "ui/widget/container/framecontainer")
    local ok_c, CenterContainer  = pcall(require, "ui/widget/container/centercontainer")
    local ok_v, VerticalGroup    = pcall(require, "ui/widget/verticalgroup")
    local ok_b, ButtonTable      = pcall(require, "ui/widget/buttontable")
    if not (ok_s and ok_f and ok_c and ok_v and ok_b) then return false end

    local Size       = require("ui/size")
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom       = require("ui/geometry")
    local LineWidget = require("ui/widget/linewidget")

    local border  = 2
    local inner_w = opts.inner_w
    local inner_h = Screen:getHeight() - 8 - 2*border

    local dialog_ref = {}
    local function close_fn()
        if dialog_ref[1] then UIManager:close(dialog_ref[1]) end
        local Device = require("device")
        UIManager:scheduleIn(0.1, function()
            Device.screen:refreshFull(0, 0, Device.screen:getWidth(), Device.screen:getHeight())
        end)
    end
    if opts.close_ref then opts.close_ref.close = close_fn end

    local rows   = opts.make_buttons(close_fn)
    local btable = ButtonTable:new{ width = inner_w, buttons = rows }

    local html_widget = ScrollHtmlWidget:new{
        html_body                 = opts.html_body,
        css                       = opts.html_css,
        html_resource_directory   = opts.resource_dir,
        width                     = inner_w,
        height                    = inner_h - btable:getSize().h,
        html_link_tapped_callback = opts.link_callback,
    }

    local frame = FrameContainer:new{
        radius     = Size.radius.window,
        padding    = 0,
        bordersize = border,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            html_widget,
            LineWidget:new{
                dimen      = Geom:new{ w = inner_w, h = Size.line.thick },
                background = Blitbuffer.COLOR_DARK_GRAY,
            },
            btable,
        },
    }

    local center = CenterContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
        frame,
    }

    html_widget.dialog = center
    dialog_ref[1]      = center
    UIManager:show(center)
    UIManager:scheduleIn(0.3, function()
        local Device = require("device")
        Device.screen:refreshFull(0, 0, Device.screen:getWidth(), Device.screen:getHeight())
    end)
    return true
end

-- Show a simple single-field text edit dialog.
-- on_save(value) is called with the raw input text on save.
function UIShared.editTextField(label, current, multiline, on_save)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title         = "Edit " .. label,
        input         = current or "",
        input_type    = multiline and "text" or "string",
        allow_newline = multiline,
        buttons       = {{
            { text = "Cancel", callback = function() UIManager:close(dialog) end },
            {
                text             = "Save",
                is_enter_default = not multiline,
                callback         = function()
                    UIManager:close(dialog)
                    on_save(dialog:getInputText() or "")
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return UIShared
