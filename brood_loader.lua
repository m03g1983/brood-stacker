--[[
    Brood Stacker Loader v1.0 — автообновление Brood Stacker
    Umbrella / UCZone API v2.0

    Ставится один раз в %cheat_dir%/scripts вместо brood_stacker.lua.
    При запуске чита скачивает последнюю версию скрипта с GitHub и запускает её.
    Сам brood_stacker.lua в папке scripts держать НЕ нужно (иначе запустятся две копии).

    Если загрузка не удалась — ошибка пишется в консоль чита и на экран.
]]

local LOADER_VERSION = "1.0"
local URL = "https://raw.githubusercontent.com/m03g1983/brood-stacker/main/brood_stacker.lua"
local MAX_ATTEMPTS = 3
local RETRY_FRAMES = 600   -- ~10 секунд между попытками

-- Скачанный скрипт видит, что его запустил загрузчик (покажет это на панели)
BROOD_STACKER_LOADER = LOADER_VERSION

local inner = nil          -- таблица колбэков скачанного скрипта
local pending_code = nil   -- код, скачанный, но ещё не запущенный
local status = "загрузка..."
local failed = false
local attempts = 0
local wait_frames = 0
local requesting = false
local font = nil

local function report(msg)
    status = msg
    Log.Write("[Brood Loader] " .. msg)
end

local function request()
    attempts = attempts + 1
    requesting = true
    -- параметр в конце обходит кэш raw.githubusercontent.com
    local url = URL .. "?nocache=" .. tostring(math.random(1, 1000000000))
    local ok = HTTP.Request("GET", url, { headers = { ["User-Agent"] = "Umbrella/1.0" } }, function(res)
        requesting = false
        local code = tostring(res and res.code or "")
        if code == "200" and res.response and #res.response > 0 then
            pending_code = res.response
        else
            report(string.format("ошибка загрузки (код %s, попытка %d/%d)", code, attempts, MAX_ATTEMPTS))
            wait_frames = RETRY_FRAMES
        end
    end, "brood_stacker")
    if not ok then
        requesting = false
        report(string.format("запрос не отправлен (попытка %d/%d)", attempts, MAX_ATTEMPTS))
        wait_frames = RETRY_FRAMES
    end
end

-- Запуск скачанного кода в основном потоке
local function run_pending()
    local code = pending_code
    pending_code = nil
    local compile = load or loadstring
    if not compile then
        failed = true
        report("в этом Umbrella недоступны load/loadstring — автообновление не работает, ставьте brood_stacker.lua вручную")
        return
    end
    local fn, err = compile(code, "=brood_stacker")
    if not fn then
        failed = true
        report("ошибка в скачанном скрипте: " .. tostring(err))
        return
    end
    local ok, result = pcall(fn)
    if not ok or type(result) ~= "table" then
        failed = true
        report("скрипт не запустился: " .. tostring(result))
        return
    end
    inner = result
    report("загружен с GitHub")
end

local function tick()
    if inner or failed then return end
    if pending_code then run_pending() return end
    if requesting then return end
    if wait_frames > 0 then wait_frames = wait_frames - 1 return end
    if attempts >= MAX_ATTEMPTS then
        failed = true
        report("не удалось скачать скрипт с GitHub")
        return
    end
    request()
end

local loader = {}

-- Колбэки, которые пробрасываются в скачанный скрипт
local FORWARD = {
    "OnUpdate", "OnUpdateEx", "OnDraw", "OnFrame", "OnPrepareUnitOrders",
    "OnGameEnd", "OnNpcDying", "OnEntityCreate", "OnEntityDestroy", "OnKeyEvent",
}

for _, name in ipairs(FORWARD) do
    loader[name] = function(...)
        if inner and inner[name] then return inner[name](...) end
        if name == "OnPrepareUnitOrders" or name == "OnKeyEvent" then return true end
    end
end

-- OnFrame работает и в меню, и в игре — в нём и грузимся
loader.OnFrame = function(...)
    tick()
    if inner and inner.OnFrame then return inner.OnFrame(...) end
end

-- Ошибку показываем на экране, пока скрипт не загружен
loader.OnDraw = function(...)
    if inner then
        if inner.OnDraw then return inner.OnDraw(...) end
        return
    end
    if not failed then return end
    if not font then font = Render.LoadFont("MuseoSansEx", Enum.FontCreate.FONTFLAG_ANTIALIAS) end
    Render.Text(font, 14, "Brood Loader: " .. status, Vec2(21, 221), Color(0, 0, 0, 200))
    Render.Text(font, 14, "Brood Loader: " .. status, Vec2(20, 220), Color(255, 120, 90))
end

return loader
