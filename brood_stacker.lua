--[[
    Brood Stacker v1.5 — автостак лесных кемпов паучками Broodmother
    Umbrella / UCZone API v2.0

    Установка: положить этот файл в %cheat_dir%/scripts
    Последняя версия: https://github.com/m03g1983/brood-stacker
    Меню: Heroes -> Hero List -> Broodmother -> Автостак

    * Каждый паучок выходит к кемпу в своё время в зависимости от расстояния
      (дальние раньше, ближние позже), но не раньше :40 (настраивается).
    * Направление отвода у каждого кемпа своё: подальше от других кемпов
      и от точек отвода соседних паучков, чтобы крипы не перецеплялись.
    * Паучок ждёт у края кемпа, в нужную секунду бьёт крипа и уводит его,
      чтобы к xx:00 спавн-бокс был пуст. После стака паучок снова свободен.
    * Кемп, застаканный максимум раз (по умолчанию 3), больше не стакается.
    * Если паучок умрёт раньше, чем закончится стак (modifier_kill),
      на кемп доводится ещё один — тот, кому жить дольше.
    * Приказы только паучкам (PASSED_UNIT_ONLY) — герой и выделение не трогаются.
      Приказ игрока паучку отпускает его на время из настроек.
    * Напоминание про Spawn Spiderlings — только после прокачки ульты.
    * Выделенных игроком паучков скрипт не берёт (настройка).
    * Панель на экране: состояние стаков и когда создавать паучков.
      Перетаскивается мышью, пока открыто меню, и прилипает к краям экрана.

    История версий:
      1.0 — первая версия
      1.1 — меню во вкладке Broodmother, тайминги по типам, удар по факту урона
      1.2 — старт с :40, лимит стаков, кнопка и бинд вкл/выкл,
            замена паучков по времени жизни, версия в названии
      1.3 — большой кемп агрится позже (:54.8), средний ждёт дальше от кемпа,
            выход паучков по расстоянию, разные точки отвода,
            кнопка выключения первой строкой меню и на панели
      1.4 — автообновление через brood_loader.lua (GitHub), на панели видно,
            запущен ли скрипт через загрузчик
      1.5 — автозагрузчик убран; вернулась настройка «не брать выделенных
            паучков»; новая панель: только стаки по кемпам и напоминание,
            прилипание к краям экрана; иконки в меню
]]

local script = {}

---------------------------------------------------------------------------
-- Константы
---------------------------------------------------------------------------
local VERSION         = "1.5"
local ORDER_ID        = "brood_stacker"
local HERO_NAME       = "npc_dota_hero_broodmother"
local SPIDERLING_NAME = "npc_dota_broodmother_spiderling"
local SPIDERITE_NAME  = "npc_dota_broodmother_spiderite"
local ULT_NAME        = "broodmother_spawn_spiderlings"

-- Индекс = Enum.ECampType (0 small, 1 medium, 2 large, 3 ancient)
local TYPE_NAME  = { [0] = "малый", [1] = "средний", [2] = "большой", [3] = "древний" }
local TYPE_ITEMS = { "Малые", "Средние", "Большие", "Древние" }

local WAIT_GAP       = 220   -- насколько ждать за краем спавн-бокса
local AGGRO_SLACK    = 250   -- насколько дальше точки ожидания можно быть в момент агра
local ORDER_INTERVAL = 0.35
local DEFAULT_SPEED  = 380
local REMIND_FROM    = 30    -- с какой секунды минуты напоминать
local ARRIVE_BUFFER  = 3.0   -- паучок приходит к точке ожидания за столько сек до удара
local SAFE_UNTIL     = 59.5  -- паучок должен дожить до этой секунды минуты
local KILL_MODIFIER  = "modifier_kill"
local AUTO_RADIUS    = 3500
local SNAP           = 24    -- на таком расстоянии панель прилипает к краю экрана
local POS_MAX_X      = 3840  -- X = максимум -> панель прижата к правому краю
local POS_MAX_Y      = 2160  -- Y = максимум -> панель прижата к нижнему краю

local FOUNTAIN = {
    radiant = Vector(-7100, -6600, 384),
    dire    = Vector(7000, 6400, 384),
}

local ST = {
    IDLE    = "свободен",
    TO_WAIT = "идёт к кемпу",
    WAITING = "ждёт",
    AGGRO   = "агрит",
    RETREAT = "уводит",
    MANUAL  = "у игрока",
}

---------------------------------------------------------------------------
-- Меню (вкладка героя Broodmother)
---------------------------------------------------------------------------
local ui = {}

local hero_tab = Menu.Create("Heroes", "Hero List", "Broodmother")
local stack_tab = hero_tab:Create("Автостак")
local grp = stack_tab:Create("Автостак")
-- Версия в заголовке группы (путь в конфиге не меняется)
pcall(function() grp:ForceLocalization("Автостак v" .. VERSION) end)

local log -- объявлен ниже
local update_toggle_label -- объявлен ниже
local function toggle_script()
    ui.enabled:Set(not ui.enabled:Get())
    if update_toggle_label then update_toggle_label() end
    if log then log(ui.enabled:Get() and "Скрипт включён" or "Скрипт выключен") end
end

-- Большая кнопка выключения — первой строкой группы
ui.toggle_btn = grp:Button("Выключить скрипт", function() toggle_script() end, true, 100)
ui.enabled    = grp:Switch("Включить", true)
ui.toggle_key = grp:Bind("Клавиша вкл/выкл", Enum.ButtonCode.BUTTON_CODE_INVALID)

function update_toggle_label()
    pcall(function()
        ui.toggle_btn:ForceLocalization(ui.enabled:Get() and "Выключить скрипт" or "Включить скрипт")
    end)
end
ui.enabled:SetCallback(function() update_toggle_label() end, true)

do -- шестерёнка с тонкими настройками
    local gear = ui.enabled:Gear("Настройки")
    ui.max_stacks = gear:Slider("Макс. стаков на кемп", 1, 5, 3)
    -- Названия новые ("Удар"), чтобы подтянулись новые значения по умолчанию,
    -- а не сохранённые в конфиге старые
    ui.t_small    = gear:Slider("Удар: малый (сек)", 50.0, 58.0, 55.0, "%.1f")
    ui.t_medium   = gear:Slider("Удар: средний (сек)", 50.0, 58.0, 53.5, "%.1f")
    ui.t_large    = gear:Slider("Удар: большой (сек)", 50.0, 58.0, 54.8, "%.1f")
    ui.t_ancient  = gear:Slider("Удар: древний (сек)", 50.0, 58.0, 53.0, "%.1f")
    ui.gap_medium = gear:Slider("Ожидание: средний (отступ)", 100, 700, 420)
    ui.earliest   = gear:Slider("Выходить не раньше (сек)", 20, 50, 40)
    ui.retreat    = gear:Slider("Дистанция увода", 500, 1500, 900)
    ui.release    = gear:Slider("Отдать паучка игроку (сек)", 3, 30, 10)
    ui.spiderites = gear:Switch("Использовать спайдеритов", false)
end

ui.mode       = grp:Combo("Режим", { "Авто: ближайшие кемпы", "Выбранные кемпы" }, 0)
ui.camps      = grp:MultiCombo("Кемпы", { "(список появится в игре)" }, {})
ui.types      = grp:MultiCombo("Типы кемпов", TYPE_ITEMS, TYPE_ITEMS)
ui.own_only   = grp:Switch("Только свой лес", true)
ui.max_camps  = grp:Slider("Кемпов максимум", 1, 8, 3)
ui.per_camp   = grp:Slider("Паучков на кемп", 1, 3, 1)
ui.skip_sel   = grp:Switch("Не брать выделенных паучков", true)
ui.skip_sel:ToolTip("Паучков, которых вы выделили, скрипт не трогает; выделили уже идущего на стак — он отпускается")
ui.show       = grp:MultiCombo("Показывать", { "Панель", "Метки на кемпах", "Напоминание" },
                                              { "Панель", "Метки на кемпах", "Напоминание" })
do -- позиция панели (меняется и перетаскиванием)
    local gear = ui.show:Gear("Позиция панели")
    ui.panel_x = gear:Slider("X", 0, POS_MAX_X, 20)
    ui.panel_y = gear:Slider("Y", 0, POS_MAX_Y, 260)
end

-- Иконки Font Awesome (если версия меню их не поддерживает — просто без них)
local function icon(widget, glyph)
    if widget then pcall(function() widget:Icon(glyph) end) end
end
icon(stack_tab,     "\u{f717}")  -- spider
icon(ui.toggle_btn, "\u{f011}")  -- power
icon(ui.enabled,    "\u{f00c}")  -- check
icon(ui.toggle_key, "\u{f11c}")  -- keyboard
icon(ui.mode,       "\u{f0e8}")  -- sitemap
icon(ui.camps,      "\u{f3c5}")  -- map marker
icon(ui.types,      "\u{f5fd}")  -- layers
icon(ui.own_only,   "\u{f1bb}")  -- tree
icon(ui.max_camps,  "\u{f292}")  -- hashtag
icon(ui.per_camp,   "\u{f0c0}")  -- users
icon(ui.skip_sel,   "\u{f05e}")  -- ban
icon(ui.show,       "\u{f06e}")  -- eye

-- Показываем только то, что относится к выбранному режиму
ui.mode:SetCallback(function()
    local manual = ui.mode:Get() == 1
    ui.camps:Visible(manual)
    ui.types:Visible(not manual)
    ui.own_only:Visible(not manual)
    ui.max_camps:Visible(not manual)
end, true)

local function shown(item) return ui.show:Get(item) == true end

---------------------------------------------------------------------------
-- Состояние
---------------------------------------------------------------------------
local font = nil
local my_hero, my_player, my_pid, my_team = nil, nil, -1, nil

local camps, camp_order = {}, {}
local spiders, released = {}, {}
local logbuf = {}
local reminder = { text = nil, last_minute = -1 }
local spider_counter = 0
local drag = nil
local last_targets = {}

---------------------------------------------------------------------------
-- Утилиты
---------------------------------------------------------------------------
local function now() return GameRules.GetGameTime() end
local function dota_time() return GameRules.GetDOTATime(false, true) end

local function fmt_time(t)
    local s = math.floor(math.abs(t))
    return string.format("%s%d:%02d", t < 0 and "-" or "", math.floor(s / 60), s % 60)
end

function log(msg)
    table.insert(logbuf, 1, { time = dota_time(), text = msg })
    while #logbuf > 30 do table.remove(logbuf) end
end

local function dist2d(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function towards(from, to, len)
    local dx, dy = to.x - from.x, to.y - from.y
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 1 then return Vector(from.x, from.y, from.z) end
    return Vector(from.x + dx / l * len, from.y + dy / l * len, from.z)
end

local function safe(fn, ...)
    if not fn then return nil end
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function my_fountain()
    if my_team == Enum.TeamNum.TEAM_DIRE then return FOUNTAIN.dire end
    return FOUNTAIN.radiant
end

local function hit_second(ctype)
    if ctype == 0 then return ui.t_small:Get() end
    if ctype == 2 then return ui.t_large:Get() end
    if ctype == 3 then return ui.t_ancient:Get() end
    return ui.t_medium:Get()
end

---------------------------------------------------------------------------
-- Кемпы
---------------------------------------------------------------------------
local function rebuild_camps()
    local list = Camps.GetAll() or {}
    if #list == 0 then return end
    local own_radiant = my_team ~= Enum.TeamNum.TEAM_DIRE

    local fresh = {}
    for _, c in ipairs(list) do
        local box = Camp.GetCampBox(c)
        if box and box.min and box.max then
            local center = Vector((box.min.x + box.max.x) / 2, (box.min.y + box.max.y) / 2, (box.min.z + box.max.z) / 2)
            local ctype = safe(Camp.GetType, c)
            if TYPE_NAME[ctype] == nil then ctype = 1 end
            local radiant_side = center.x + center.y < 0  -- река по диагонали y = -x
            table.insert(fresh, {
                handle = c,
                center = center,
                half   = math.max(box.max.x - box.min.x, box.max.y - box.min.y) / 2,
                ctype  = ctype,
                own    = radiant_side == own_radiant,
            })
        end
    end

    table.sort(fresh, function(a, b)
        if a.own ~= b.own then return a.own end
        if a.ctype ~= b.ctype then return a.ctype < b.ctype end
        if math.abs(a.center.x - b.center.x) > 1 then return a.center.x < b.center.x end
        return a.center.y < b.center.y
    end)

    local counters, names = {}, {}
    camps, camp_order = {}, {}
    for _, rec in ipairs(fresh) do
        local side = rec.own and "Свой" or "Вражеский"
        local key = side .. rec.ctype
        counters[key] = (counters[key] or 0) + 1
        rec.id = string.format("%s %s #%d", side, TYPE_NAME[rec.ctype], counters[key])
        rec.spiders = {}
        rec.stacks = 0
        camps[rec.id] = rec
        table.insert(camp_order, rec.id)
        table.insert(names, rec.id)
    end

    -- Названия относительные (свой/вражеский), выбор сохраняется между играми
    local enabled = {}
    for _, n in ipairs(ui.camps:ListEnabled() or {}) do
        if camps[n] then table.insert(enabled, n) end
    end
    ui.camps:Update(names, enabled)
    log(string.format("Найдено кемпов: %d", #camp_order))
end

local atan2 = math.atan2 or math.atan

local function wait_gap(camp)
    if camp.ctype == 1 then return ui.gap_medium:Get() end
    return WAIT_GAP
end

local function polar(center, ang, len)
    return Vector(center.x + math.cos(ang) * len, center.y + math.sin(ang) * len, center.z)
end

-- Направление отвода выбирается раз в минуту для каждого кемпа:
-- подальше от других кемпов и от точек отвода соседних паучков,
-- но по возможности в сторону своего фонтана.
local function choose_dir(camp, minute)
    if camp.dir and camp.dir_minute == minute then return camp.dir end

    local f = my_fountain()
    local base = atan2(f.y - camp.center.y, f.x - camp.center.x)
    local len = camp.half + wait_gap(camp) + ui.retreat:Get()
    local best_ang, best_score = base, -math.huge

    for k = -6, 6 do  -- ±120° с шагом 20°
        local ang = base + math.rad(k * 20)
        local p = polar(camp.center, ang, len)
        local mid = polar(camp.center, ang, len / 2)
        local clear = 1500  -- дальше этого «запас» уже не важен
        for _, id in ipairs(camp_order) do
            local oc = camps[id]
            if oc ~= camp then
                -- путь отвода не должен проходить через чужой кемп
                local d = math.min(dist2d(p, oc.center), dist2d(mid, oc.center)) - oc.half
                if d < clear then clear = d end
                -- и не должен пересекаться с отводом соседей в эту минуту
                if oc.ret_pt and oc.dir_minute == minute then
                    local d2 = math.min(dist2d(p, oc.ret_pt), dist2d(mid, oc.ret_pt))
                    if d2 < clear then clear = d2 end
                end
            end
        end
        local score = clear - math.abs(k) * 20 * 4  -- штраф 4 ед. за градус от фонтана
        if score > best_score then best_ang, best_score = ang, score end
    end

    camp.dir, camp.dir_minute = best_ang, minute
    camp.ret_pt = polar(camp.center, best_ang, len)
    return best_ang
end

-- Точка ожидания и отвода лежат на одной линии: паучок тянет крипов «на себя»
local function camp_points(camp, minute)
    local ang = choose_dir(camp, minute)
    local wait = polar(camp.center, ang, camp.half + wait_gap(camp))
    return wait, camp.ret_pt
end

local function spider_speed(npc)
    local s = safe(NPC.GetMoveSpeed, npc)
    if type(s) == "number" and s > 100 then return s end
    return DEFAULT_SPEED
end

local function camp_selected(id) return ui.camps:Get(id) == true end

local function count_camp_spiders(camp)
    local n = 0
    for _ in pairs(camp.spiders) do n = n + 1 end
    return n
end

-- Сколько раз кемп застакан: данные игры, иначе свой счётчик
local function camp_stacks(camp)
    local known = safe(Camp.GetKnownStackCount, camp.handle)
    if known ~= nil then return known end
    if safe(Camp.IsKnownClear, camp.handle) then camp.stacks = 0 end
    return camp.stacks
end

local function camp_full(camp)
    local full = camp_stacks(camp) >= ui.max_stacks:Get()
    if full and not camp.full_logged then
        camp.full_logged = true
        log(string.format("%s: %d стака, больше не стакаю", camp.id, camp_stacks(camp)))
    elseif not full then
        camp.full_logged = false
    end
    return full
end

---------------------------------------------------------------------------
-- Паучки
---------------------------------------------------------------------------
local function is_our_spider(npc)
    if not npc or not Entity.IsAlive(npc) then return false end
    local name = NPC.GetUnitName(npc)
    if name ~= SPIDERLING_NAME and not (ui.spiderites:Get() and name == SPIDERITE_NAME) then
        return false
    end
    return NPC.IsControllableByPlayer(npc, my_pid)
end

-- Сколько паучку осталось жить (сек). Без modifier_kill — бесконечно.
local function life_left(npc)
    local mod = NPC.GetModifier(npc, KILL_MODIFIER)
    if not mod then return math.huge end
    local die = safe(Modifier.GetDieTime, mod)
    if not die or die <= 0 then return math.huge end
    return die - now()
end

-- Доживёт ли паучок до конца стака в этой минуте
local function survives(sp, sec)
    return life_left(sp.npc) >= SAFE_UNTIL - sec
end

local function selected_set()
    local set = {}
    for _, u in ipairs(Player.GetSelectedUnits(my_player) or {}) do
        set[Entity.GetIndex(u)] = true
    end
    return set
end

local function issue(sp, order, target, pos)
    local t = now()
    if t - (sp.last_order or 0) < ORDER_INTERVAL then return end
    if Humanizer then
        local n = safe(Humanizer.OrdersCanBeCastedThisTick)
        if n ~= nil and n <= 0 then return end
    end
    Player.PrepareUnitOrders(
        my_player, order, target, pos, nil,
        Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
        sp.npc, false, false, false, false, ORDER_ID
    )
    sp.last_order = t
    sp.last_pos = pos
end

local function move(sp, pos)
    if sp.last_pos and dist2d(sp.last_pos, pos) < 30 and now() - (sp.last_order or 0) < 2.5 then return end
    issue(sp, Enum.UnitOrder.DOTA_UNIT_ORDER_MOVE_TO_POSITION, nil, pos)
end

local function unassign(sp, reason)
    local camp = sp.camp and camps[sp.camp]
    if camp then camp.spiders[sp.idx] = nil end
    sp.camp, sp.state, sp.last_pos, sp.target = nil, ST.IDLE, nil, nil
    if reason then log(string.format("Паучок #%d: %s", sp.num, reason)) end
end

local function refresh_spiders()
    local alive = {}
    for _, npc in ipairs(NPCs.GetAll(is_our_spider) or {}) do
        local idx = Entity.GetIndex(npc)
        alive[idx] = true
        if not spiders[idx] then
            spider_counter = spider_counter + 1
            spiders[idx] = { idx = idx, npc = npc, num = spider_counter, state = ST.IDLE }
        else
            spiders[idx].npc = npc
        end
    end
    for idx, sp in pairs(spiders) do
        if not alive[idx] then
            if sp.camp then log(string.format("Паучок #%d погиб (%s)", sp.num, sp.camp)) end
            unassign(sp)
            spiders[idx] = nil
        end
    end
end

---------------------------------------------------------------------------
-- Цели и распределение
---------------------------------------------------------------------------
local function target_camps()
    local res = {}
    if ui.mode:Get() == 1 then
        for _, id in ipairs(camp_order) do
            if camp_selected(id) and not camp_full(camps[id]) then table.insert(res, camps[id]) end
        end
        return res
    end

    local cx, cy, n = 0, 0, 0
    for _, sp in pairs(spiders) do
        local p = Entity.GetAbsOrigin(sp.npc)
        cx, cy, n = cx + p.x, cy + p.y, n + 1
    end
    if n == 0 then return res end
    local centroid = Vector(cx / n, cy / n, 0)

    local cand = {}
    for _, id in ipairs(camp_order) do
        local c = camps[id]
        local type_ok = ui.types:Get(TYPE_ITEMS[c.ctype + 1]) == true
        local side_ok = (c.own or not ui.own_only:Get()) and not camp_full(c)
        if count_camp_spiders(c) > 0 and type_ok and side_ok then
            table.insert(cand, { camp = c, d = -1 })
        elseif type_ok and side_ok and not safe(Camp.IsKnownClear, c.handle) then
            local d = dist2d(c.center, centroid)
            if d <= AUTO_RADIUS then table.insert(cand, { camp = c, d = d }) end
        end
    end
    table.sort(cand, function(a, b) return a.d < b.d end)
    for i = 1, math.min(#cand, ui.max_camps:Get()) do
        table.insert(res, cand[i].camp)
    end
    return res
end

local function pick_nearest(pool, camp, sec)
    -- Ближайший из тех, кто доживёт; если таких нет — самый долгоживущий
    local best_i, best_d = nil, math.huge
    for i, sp in ipairs(pool) do
        if survives(sp, sec) then
            local d = dist2d(Entity.GetAbsOrigin(sp.npc), camp.center)
            if d < best_d then best_i, best_d = i, d end
        end
    end
    if best_i then return best_i end
    local best_l = -math.huge
    for i, sp in ipairs(pool) do
        local l = life_left(sp.npc)
        if l > best_l then best_i, best_l = i, l end
    end
    return best_i
end

local function pick_longest(pool)
    local best_i, best_l = nil, -math.huge
    for i, sp in ipairs(pool) do
        local l = life_left(sp.npc)
        if l > best_l then best_i, best_l = i, l end
    end
    return best_i, best_l
end

-- Сколько секунд паучку идти до точки ожидания кемпа
local function travel_time(sp, camp, minute)
    local wait = camp_points(camp, minute)
    return dist2d(Entity.GetAbsOrigin(sp.npc), wait) / spider_speed(sp.npc)
end

local function attach(sp, camp, minute, travel, note)
    sp.camp, sp.state, sp.last_pos = camp.id, ST.TO_WAIT, nil
    camp.spiders[sp.idx] = true
    log(string.format("Паучок #%d → %s (путь %d с%s)", sp.num, camp.id, math.ceil(travel), note or ""))
end

local function assign_spiders(targets, sec, minute)
    if sec < ui.earliest:Get() then
        -- до :40 (настройка) паучки свободны, кроме тех, кто ещё уводит крипов
        for _, sp in pairs(spiders) do
            if sp.camp and sp.state ~= ST.AGGRO and sp.state ~= ST.RETREAT then unassign(sp) end
        end
        return
    end

    local target_set = {}
    for _, c in ipairs(targets) do target_set[c.id] = true end
    for _, sp in pairs(spiders) do
        if sp.camp and not target_set[sp.camp] and sp.state ~= ST.AGGRO and sp.state ~= ST.RETREAT then
            unassign(sp, "кемп снят с цели")
        end
    end

    local t = now()
    local sel = ui.skip_sel:Get() and selected_set() or {}
    local pool = {}
    for idx, sp in pairs(spiders) do
        if sp.camp == nil and (released[idx] or 0) < t and not sel[idx] then table.insert(pool, sp) end
    end

    local need = ui.per_camp:Get()
    for _, camp in ipairs(targets) do
        -- Кто на кемпе доживёт до конца стака, а кто нет
        local total, alive_ok, dying_life = 0, 0, -math.huge
        for idx in pairs(camp.spiders) do
            local sp = spiders[idx]
            if sp then
                total = total + 1
                if survives(sp, sec) then
                    alive_ok = alive_ok + 1
                else
                    dying_life = math.max(dying_life, life_left(sp.npc))
                end
            end
        end

        local hit = hit_second(camp.ctype)

        -- 1) Основной набор: до N паучков. Каждый выходит в своё время:
        --    выход = удар - запас - время пути. Дальние уходят раньше,
        --    ближние остаются у игрока дольше. Не успевает — не берём.
        while total < need and #pool > 0 do
            local i = pick_nearest(pool, camp, sec)
            local sp = pool[i]
            local travel = travel_time(sp, camp, minute)
            local depart = hit - ARRIVE_BUFFER - travel
            if sec < depart then break end                 -- ещё рано выходить
            if sec + travel > hit - 0.5 then break end      -- уже не успеет
            table.remove(pool, i)
            attach(sp, camp, minute, travel)
            total = total + 1
            if survives(sp, sec) then
                alive_ok = alive_ok + 1
            else
                dying_life = math.max(dying_life, life_left(sp.npc))
            end
        end

        -- 2) Замена: кто-то умрёт до конца стака — доводим ещё одного,
        --    у кого больше времени, если он успевает дойти
        if alive_ok < need and dying_life > -math.huge and #pool > 0 then
            local i, l = pick_longest(pool)
            if i and l > dying_life then
                local travel = travel_time(pool[i], camp, minute)
                if sec + travel <= hit - 0.5 then
                    local sp = table.remove(pool, i)
                    attach(sp, camp, minute, travel, string.format(", замена, живёт ещё %s",
                        l == math.huge and "∞" or string.format("%d с", math.floor(l))))
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Логика стака
---------------------------------------------------------------------------
local function find_neutral(camp)
    local units = NPCs.InRadius(camp.center, camp.half + 350, my_team, Enum.TeamType.TEAM_BOTH, true, true) or {}
    local best, best_d = nil, math.huge
    for _, u in ipairs(units) do
        if Entity.IsAlive(u) and NPC.IsNeutral(u) then
            local d = dist2d(Entity.GetAbsOrigin(u), camp.center)
            if d < best_d then best, best_d = u, d end
        end
    end
    return best
end

local function process_spider(sp, t, minute, sec)
    local camp = sp.camp and camps[sp.camp]
    if not camp then return end
    local pos = Entity.GetAbsOrigin(sp.npc)
    local dist_center = dist2d(pos, camp.center)
    -- во время отвода через :00 минута меняется — точку берём запомненную
    local wait, retreat
    if sp.state == ST.AGGRO or sp.state == ST.RETREAT then
        retreat = sp.retreat_pt
    else
        wait, retreat = camp_points(camp, minute)
    end

    if sp.state == ST.TO_WAIT or sp.state == ST.WAITING then
        -- момент отправки = секунда удара - время подхода - замах атаки
        local send_at = hit_second(camp.ctype) - math.max(0, dist_center - 150) / spider_speed(sp.npc) - 0.4
        if sec >= send_at and sec < 58 and sp.done_minute ~= minute then
            if dist_center > camp.half + wait_gap(camp) + AGGRO_SLACK then
                sp.done_minute = minute
                log(string.format("Паучок #%d не успел к %s", sp.num, camp.id))
                return
            end
            sp.state = ST.AGGRO
            sp.aggro_start = t
            sp.aggro_minute = minute
            sp.retreat_pt = retreat
            sp.attack_time = nil
            sp.target, sp.target_hp = nil, nil
            sp.stack_before = safe(Camp.GetKnownStackCount, camp.handle)
            sp.last_order = 0
            log(string.format("Паучок #%d агрит %s", sp.num, camp.id))
        else
            if dist2d(pos, wait) > 60 then
                sp.state = ST.TO_WAIT
                move(sp, wait)
            else
                sp.state = ST.WAITING
            end
            return
        end
    end

    if sp.state == ST.AGGRO then
        -- Удар засчитан только когда у крипа реально упало HP
        -- (раньше уходили на замахе — крипы не агрились)
        local hit_landed = sp.target and sp.target_hp
            and Entity.IsAlive(sp.target) and Entity.GetHealth(sp.target) < sp.target_hp
        if NPC.IsAttacking(sp.npc) then
            sp.attack_time = sp.attack_time or t
        end
        local swung_long = sp.attack_time and (t - sp.attack_time) > 0.8
        local timeout = (t - sp.aggro_start) > 2.5 or sec >= 58.5

        if hit_landed or swung_long or timeout then
            sp.state = ST.RETREAT
            sp.last_order, sp.last_pos = 0, nil
            if timeout and not hit_landed then
                log(string.format("Паучок #%d: удар не прошёл, уводит", sp.num))
            end
            move(sp, retreat)
            return
        end

        if not sp.target or not Entity.IsAlive(sp.target) then
            sp.target = find_neutral(camp)
            if sp.target then
                sp.target_hp = Entity.GetHealth(sp.target)
                sp.last_order = 0
            end
        end
        if sp.target then
            issue(sp, Enum.UnitOrder.DOTA_UNIT_ORDER_ATTACK_TARGET, sp.target, Entity.GetAbsOrigin(sp.target))
        else
            move(sp, camp.center)
        end
        return
    end

    if sp.state == ST.RETREAT then
        move(sp, retreat)
        if minute > (sp.aggro_minute or minute) and sec >= 1.5 then
            sp.done_minute = sp.aggro_minute
            local after = safe(Camp.GetKnownStackCount, camp.handle)
            if sp.stack_before ~= nil and after ~= nil then
                if after > sp.stack_before then
                    camp.stacks = after
                    log(string.format("✔ %s застакан (%d)", camp.id, after))
                else
                    log(string.format("✖ %s: стак не засчитан", camp.id))
                end
            else
                camp.stacks = camp.stacks + 1
                log(string.format("%s: увод завершён", camp.id))
            end
            unassign(sp)  -- свободен до следующей :40
        end
    end
end

---------------------------------------------------------------------------
-- Напоминание
---------------------------------------------------------------------------
local function update_reminder(targets, sec, minute)
    reminder.text = nil
    if not shown("Напоминание") then return end
    local ult = NPC.GetAbility(my_hero, ULT_NAME)
    if not ult or Ability.GetLevel(ult) < 1 then return end  -- до прокачки ульты молчим
    if sec < REMIND_FROM or sec >= 52 then return end

    local need
    if ui.mode:Get() == 1 then
        if #targets == 0 then return end
        need = ui.per_camp:Get() * #targets
    else
        need = ui.per_camp:Get() * ui.max_camps:Get()
    end

    local have, t = 0, now()
    for idx in pairs(spiders) do
        if (released[idx] or 0) < t then have = have + 1 end
    end
    if have >= need then return end

    -- До какого времени нужны паучки: самый ранний удар минус ~10 с на дорогу
    local first_hit = 53
    for i, c in ipairs(targets) do
        local h = hit_second(c.ctype)
        if i == 1 or h < first_hit then first_hit = h end
    end
    local deadline = math.max(sec, first_hit - 10)

    local cd = Ability.GetCooldown(ult) or 0
    if cd > 0 then
        reminder.text = string.format("Ульта откатится через %d с", math.ceil(cd))
    else
        reminder.text = "Создай паучков до " .. fmt_time(minute * 60 + deadline)
    end
end

---------------------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------------------
local function reset()
    camps, camp_order, spiders, released, logbuf = {}, {}, {}, {}, {}
    my_hero, my_player, my_pid, my_team = nil, nil, -1, nil
    reminder = { text = nil, last_minute = -1 }
    spider_counter = 0
    last_targets = {}
end

local function is_brood()
    return my_hero ~= nil and NPC.GetUnitName(my_hero) == HERO_NAME
end

function script.OnUpdate()
    if not Engine.IsInGame() then return end

    if not my_hero then
        my_hero, my_player = Heroes.GetLocal(), Players.GetLocal()
        if not my_hero or not my_player then my_hero = nil return end
        my_pid = Player.GetPlayerID(my_player)
        my_team = Entity.GetTeamNum(my_hero)
    end
    if not is_brood() then return end
    if #camp_order == 0 then rebuild_camps() end

    if ui.toggle_key:IsPressed() then toggle_script() end

    if not ui.enabled:Get() then
        for _, sp in pairs(spiders) do
            if sp.camp then unassign(sp) end
            sp.state = ST.IDLE
        end
        reminder.text = nil
        return
    end
    if GameRules.IsPaused() then return end

    local dt = dota_time()
    if dt < 0 then return end
    local minute = math.floor(dt / 60)
    local sec = dt - minute * 60
    local t = now()

    refresh_spiders()
    -- Выделенные игроком паучки — его, скрипт их отпускает
    if ui.skip_sel:Get() then
        local sel = selected_set()
        for idx, sp in pairs(spiders) do
            if sel[idx] and sp.camp then unassign(sp, "выделен игроком, отпущен") end
        end
    end

    local targets = target_camps()
    last_targets = targets
    assign_spiders(targets, sec, minute)
    update_reminder(targets, sec, minute)

    for idx, sp in pairs(spiders) do
        if (released[idx] or 0) > t then
            sp.state = ST.MANUAL
        elseif sp.state == ST.MANUAL then
            sp.state = ST.IDLE
        else
            process_spider(sp, t, minute, sec)
        end
    end
end

-- Игрок сам отдал приказ паучку — отпускаем его
function script.OnPrepareUnitOrders(data)
    if not my_player or data.identifier == ORDER_ID then return true end
    if data.player and Player.GetPlayerID(data.player) ~= my_pid then return true end

    local affected = {}
    local issuer = data.orderIssuer
    if issuer == Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY then
        if data.npc then affected[Entity.GetIndex(data.npc)] = true end
    elseif issuer == Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_SELECTED_UNITS then
        affected = selected_set()
    elseif issuer == Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_CURRENT_UNIT_ONLY then
        local q = Player.GetQueryUnit(my_player)
        if q then affected[Entity.GetIndex(q)] = true end
    end

    local until_t = now() + ui.release:Get()
    for idx in pairs(affected) do
        local sp = spiders[idx]
        if sp then
            released[idx] = until_t
            if sp.camp then unassign(sp, "приказ игрока, отпущен") end
            sp.state = ST.MANUAL
        end
    end
    return true
end

function script.OnGameEnd()
    reset()
end

---------------------------------------------------------------------------
-- Отрисовка
---------------------------------------------------------------------------
local C_BG    = Color(15, 15, 20, 200)
local C_TITLE = Color(255, 200, 90)
local C_TEXT  = Color(230, 230, 230)
local C_DIM   = Color(150, 150, 150)
local C_GOOD  = Color(110, 220, 110)
local C_WARN  = Color(255, 210, 80)
local C_BAD   = Color(255, 90, 90)
local C_SHADE = Color(0, 0, 0, 200)

local function text(size, str, x, y, col)
    Render.Text(font, size, str, Vec2(x + 1, y + 1), C_SHADE)
    Render.Text(font, size, str, Vec2(x, y), col)
end

-- Цвета панели
local P_BG     = Color(18, 18, 24, 225)
local P_HEAD   = Color(30, 30, 40, 240)
local P_ACCENT = Color(160, 110, 255)
local P_ROW    = Color(255, 255, 255, 10)
local P_PIP    = Color(70, 70, 85)
local P_ON     = Color(60, 170, 90, 235)
local P_OFF    = Color(190, 60, 60, 235)

-- Состояние кемпа по его паучкам (самое «продвинутое»)
local STATE_RANK = { [ST.TO_WAIT] = 1, [ST.WAITING] = 2, [ST.AGGRO] = 3, [ST.RETREAT] = 4 }
local STATE_VIEW = {
    [0] = { "нет паучков", C_DIM },
    [1] = { "в пути",      C_TEXT },
    [2] = { "ждёт",        C_GOOD },
    [3] = { "агр",         C_BAD },
    [4] = { "увод",        C_WARN },
}

local function camp_state(camp)
    local rank = 0
    for idx in pairs(camp.spiders) do
        local sp = spiders[idx]
        local r = sp and STATE_RANK[sp.state] or 0
        if r > rank then rank = r end
    end
    return rank
end

-- Какие кемпы показывать: цели, кемпы с паучками, выбранные вручную
local function panel_camps()
    local list, seen = {}, {}
    local function push(c) if c and not seen[c.id] then seen[c.id] = true table.insert(list, c) end end
    for _, c in ipairs(last_targets) do push(c) end
    local manual = ui.mode:Get() == 1
    for _, id in ipairs(camp_order) do
        local c = camps[id]
        if count_camp_spiders(c) > 0 or (manual and camp_selected(id)) then push(c) end
    end
    return list
end

-- Позиция с учётом прилипания: максимум слайдера = прижата к правому/нижнему краю
local function panel_pos(w, h)
    local scr = Render.ScreenSize()
    local x, y = ui.panel_x:Get(), ui.panel_y:Get()
    if x >= POS_MAX_X then x = scr.x - w end
    if y >= POS_MAX_Y then y = scr.y - h end
    x = math.max(0, math.min(x, scr.x - w))
    y = math.max(0, math.min(y, scr.y - h))
    return x, y
end

-- Перетаскивание ЛКМ, пока открыто меню; у краёв экрана панель прилипает
local function handle_drag(x, y, w, h, btn)
    local mouse = Input.IsKeyDown(Enum.ButtonCode.KEY_MOUSE1, true)
    if not Menu.Opened() or not mouse then drag = nil return end
    local cx, cy = Input.GetCursorPos()
    if not drag then
        if btn and Input.IsCursorInRect(btn.x, btn.y, btn.w, btn.h) then return end
        if Input.IsCursorInRect(x, y, w, h) then drag = { dx = cx - x, dy = cy - y } end
        return
    end
    local scr = Render.ScreenSize()
    local nx, ny = cx - drag.dx, cy - drag.dy
    if nx < SNAP then nx = 0 elseif nx + w > scr.x - SNAP then nx = POS_MAX_X end
    if ny < SNAP then ny = 0 elseif ny + h > scr.y - SNAP then ny = POS_MAX_Y end
    ui.panel_x:Set(math.floor(nx))
    ui.panel_y:Set(math.floor(ny))
end

local function draw_pips(x, cy, filled, max)
    for i = 1, max do
        local col = i <= filled and P_ACCENT or P_PIP
        Render.FilledCircle(Vec2(x + (i - 1) * 11 + 4, cy), 4, col)
    end
    return max * 11
end

local function draw_panel()
    local on = ui.enabled:Get()
    local pad, head_h, row_h = 10, 28, 22
    local max = ui.max_stacks:Get()

    -- Содержимое
    local rows = {}
    local note = nil
    if reminder.text then note = reminder.text end
    if ui.mode:Get() == 1 and #(ui.camps:ListEnabled() or {}) == 0 then
        note = note or "Выберите кемпы в меню"
    end
    for _, c in ipairs(panel_camps()) do
        local stacks = camp_stacks(c)
        local view = stacks >= max and { "готово", P_ACCENT } or STATE_VIEW[camp_state(c)]
        table.insert(rows, { name = c.id, stacks = math.min(stacks, max), state = view[1], col = view[2] })
    end

    -- Ширина по самому длинному
    local title = "Brood Stacker"
    local ver = "v" .. VERSION
    local clock = fmt_time(dota_time())
    local tw = Render.TextSize(font, 15, title).x + Render.TextSize(font, 12, ver).x
    local pill_w = 46
    local w = math.max(250, tw + Render.TextSize(font, 13, clock).x + pill_w + pad * 4 + 6)
    local name_w, state_w = 0, 0
    for _, r in ipairs(rows) do
        name_w = math.max(name_w, Render.TextSize(font, 13, r.name).x)
        state_w = math.max(state_w, Render.TextSize(font, 13, r.state).x)
    end
    w = math.max(w, pad * 2 + name_w + 14 + max * 11 + 14 + state_w)
    if note then w = math.max(w, pad * 2 + 16 + Render.TextSize(font, 13, note).x) end
    if #rows == 0 then rows = nil end

    local h = head_h + (note and row_h + 4 or 0) + (rows and #rows * row_h or row_h) + pad
    local x, y = panel_pos(w, h)

    -- Кнопка вкл/выкл (клик, пока открыто меню)
    local pill = { x = x + w - pad - pill_w, y = y + 6, w = pill_w, h = head_h - 12 }
    if Menu.Opened() and Input.IsKeyDownOnce(Enum.ButtonCode.KEY_MOUSE1, true)
        and Input.IsCursorInRect(pill.x, pill.y, pill.w, pill.h) then
        toggle_script()
        on = ui.enabled:Get()
    end
    handle_drag(x, y, w, h, pill)

    -- Фон и шапка
    Render.FilledRect(Vec2(x, y), Vec2(x + w, y + h), P_BG, 8)
    Render.FilledRect(Vec2(x, y), Vec2(x + w, y + head_h), P_HEAD, 8)
    Render.FilledRect(Vec2(x, y + head_h - 2), Vec2(x + w, y + head_h), on and P_ACCENT or P_PIP)

    local ty = y + (head_h - 15) / 2 - 1
    text(15, title, x + pad, ty, on and C_TEXT or C_DIM)
    local title_w = Render.TextSize(font, 15, title).x
    text(12, ver, x + pad + title_w + 5, ty + 3, C_DIM)
    local cw = Render.TextSize(font, 13, clock).x
    text(13, clock, pill.x - 8 - cw, ty + 1, C_DIM)

    Render.FilledRect(Vec2(pill.x, pill.y), Vec2(pill.x + pill.w, pill.y + pill.h), on and P_ON or P_OFF, pill.h / 2)
    local plabel = on and "ВКЛ" or "ВЫКЛ"
    local ps = Render.TextSize(font, 11, plabel)
    text(11, plabel, pill.x + (pill.w - ps.x) / 2, pill.y + (pill.h - ps.y) / 2, C_TEXT)

    local cy = y + head_h + 4

    -- Напоминание
    if note then
        Render.FilledRect(Vec2(x + 6, cy), Vec2(x + w - 6, cy + row_h), Color(255, 190, 60, 40), 4)
        Render.FilledRect(Vec2(x + 6, cy), Vec2(x + 9, cy + row_h), C_WARN, 1)
        text(13, note, x + pad + 6, cy + (row_h - 13) / 2 - 1, C_WARN)
        cy = cy + row_h + 4
    end

    -- Кемпы
    if not rows then
        text(13, on and "Нет кемпов для стака" or "Скрипт выключен", x + pad, cy + (row_h - 13) / 2 - 1, C_DIM)
        return
    end
    for i, r in ipairs(rows) do
        if i % 2 == 0 then Render.FilledRect(Vec2(x + 4, cy), Vec2(x + w - 4, cy + row_h), P_ROW, 3) end
        local my = cy + row_h / 2
        Render.FilledCircle(Vec2(x + pad + 3, my), 3, r.col)
        text(13, r.name, x + pad + 12, my - 8, C_TEXT)
        local px = x + pad + 12 + name_w + 12
        draw_pips(px, my, r.stacks, max)
        local sw = Render.TextSize(font, 13, r.state).x
        text(13, r.state, x + w - pad - sw, my - 8, r.col)
        cy = cy + row_h
    end
end

local function draw_marks()
    local manual = ui.mode:Get() == 1
    for _, id in ipairs(camp_order) do
        local c = camps[id]
        local n = count_camp_spiders(c)
        local selected = manual and camp_selected(id)
        if n > 0 or selected then
            local sp, vis = Render.WorldToScreen(c.center)
            if vis then
                local stacks, max = camp_stacks(c), ui.max_stacks:Get()
                local col, status
                if stacks >= max then
                    col, status = P_ACCENT, "готово"
                else
                    local view = STATE_VIEW[camp_state(c)]
                    status, col = view[1], view[2]
                    if n == 0 then col = C_WARN end
                end
                local l1 = id
                local l2 = string.format("%s · стаков %d/%d", status, stacks, max)
                local s1 = Render.TextSize(font, 15, l1)
                local s2 = Render.TextSize(font, 13, l2)
                local hw = math.max(s1.x, s2.x) / 2 + 6
                Render.FilledRect(Vec2(sp.x - hw, sp.y - 4), Vec2(sp.x + hw, sp.y + 36), C_BG, 4)
                text(15, l1, sp.x - s1.x / 2, sp.y, col)
                text(13, l2, sp.x - s2.x / 2, sp.y + 18, C_TEXT)
            end
        end
    end
end

function script.OnDraw()
    if not is_brood() then return end
    if not font then font = Render.LoadFont("MuseoSansEx", Enum.FontCreate.FONTFLAG_ANTIALIAS) end
    if shown("Метки на кемпах") then draw_marks() end
    if shown("Панель") then draw_panel() end
end

return script
