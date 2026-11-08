local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local _ = require("gettext")

local PROVIDERS = {
    { id = "auto", label = _("Auto (fastest)") },
    { id = "cloudflare", label = _("Cloudflare") },
    { id = "google", label = _("Google") },
    { id = "quad9", label = _("Quad9") },
    { id = "adguard", label = _("AdGuard (blocks ads)") },
}

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local KoDNS = WidgetContainer:extend{
    name = "kodns",
    is_doc_only = false,
}

function KoDNS:init()
    self.script = self.path .. "/kodns.sh"
    self.ui.menu:registerToMainMenu(self)
    -- set on the class, not the instance, so it holds across file manager and reader
    if G_reader_settings:isTrue("kodns_autostart") and not KoDNS.autostarted then
        KoDNS.autostarted = true
        UIManager:scheduleIn(3, function()
            if not self:isRunning() then
                self:start(G_reader_settings:readSetting("kodns_provider") or "auto")
            end
        end)
    end
end

-- No shell here: menu callbacks call this often.
function KoDNS:isRunning()
    local pid = (readFile("/tmp/kodns.pid") or ""):match("^%s*(%d+)")
    if not pid then return false end
    local cmdline = readFile("/proc/" .. pid .. "/cmdline")
    return cmdline ~= nil and cmdline:find("dnsproxy", 1, true) ~= nil
end

function KoDNS:activeProvider()
    return (readFile("/tmp/kodns.provider") or ""):match("%S+")
end

function KoDNS:run(args)
    local msg = InfoMessage:new{ text = _("Working...") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local out = ""
    local f = io.popen("sh '" .. self.script .. "' " .. args .. " 2>&1")
    if f then
        out = f:read("*a") or ""
        f:close()
    end
    UIManager:close(msg)
    out = out:gsub("%s+$", "")
    if out == "" then out = _("No output.") end
    return out
end

function KoDNS:popup(args)
    UIManager:show(InfoMessage:new{ text = self:run(args) })
end

function KoDNS:viewer(args, title)
    UIManager:show(TextViewer:new{ title = title, text = self:run(args) })
end

function KoDNS:start(provider, touchmenu_instance)
    self:popup("start " .. provider)
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

function KoDNS:askProvider(touchmenu_instance)
    local dialog
    local buttons = {}
    for idx, p in ipairs(PROVIDERS) do
        buttons[idx] = {{
            text = p.label,
            callback = function()
                UIManager:close(dialog)
                G_reader_settings:saveSetting("kodns_provider", p.id)
                self:start(p.id, touchmenu_instance)
            end,
        }}
    end
    table.insert(buttons, {{
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    }})
    dialog = ButtonDialog:new{ title = _("Choose a DNS provider"), buttons = buttons }
    UIManager:show(dialog)
end

function KoDNS:addToMainMenu(menu_items)
    local provider_items = {}
    for idx, p in ipairs(PROVIDERS) do
        provider_items[idx] = {
            text = p.label,
            radio = true,
            checked_func = function()
                return G_reader_settings:readSetting("kodns_provider") == p.id
            end,
            callback = function()
                G_reader_settings:saveSetting("kodns_provider", p.id)
                if self:isRunning() then self:start(p.id) end
            end,
        }
    end

    menu_items.kodns = {
        text = _("KoDNS"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text_func = function()
                    local p = self:isRunning() and self:activeProvider()
                    if p then return T(_("Enable KoDNS (%1)"), p) end
                    return _("Enable KoDNS")
                end,
                checked_func = function() return self:isRunning() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    if self:isRunning() then
                        self:popup("stop")
                        touchmenu_instance:updateItems()
                        return
                    end
                    local p = G_reader_settings:readSetting("kodns_provider")
                    if not p or G_reader_settings:isTrue("kodns_ask_every_time") then
                        self:askProvider(touchmenu_instance)
                    else
                        self:start(p, touchmenu_instance)
                    end
                end,
            },
            {
                text = _("Provider"),
                sub_item_table = provider_items,
            },
            {
                text = _("Ask which provider every time"),
                checked_func = function() return G_reader_settings:isTrue("kodns_ask_every_time") end,
                callback = function() G_reader_settings:flipNilOrFalse("kodns_ask_every_time") end,
            },
            {
                text = _("Start with KOReader"),
                checked_func = function() return G_reader_settings:isTrue("kodns_autostart") end,
                callback = function() G_reader_settings:flipNilOrFalse("kodns_autostart") end,
                separator = true,
            },
            {
                text = _("Check"),
                keep_menu_open = true,
                callback = function() self:popup("check") end,
            },
            {
                text = _("Run diagnostics"),
                keep_menu_open = true,
                callback = function() self:viewer("doctor", _("KoDNS diagnostics")) end,
            },
            {
                text = _("Benchmark providers"),
                keep_menu_open = true,
                callback = function() self:popup("bench") end,
            },
            {
                text = _("Show log"),
                keep_menu_open = true,
                callback = function() self:viewer("log", _("KoDNS log")) end,
            },
        },
    }
end

return KoDNS
