--- Подписанная ссылка: адрес и срок, подписанные ключом приложения.
---
--- Ссылка в письме с подтверждением, ссылка на скачивание со сроком,
--- ссылка «отписаться» — это право на действие, выданное адресом. Без
--- подписи адрес переписывает кто угодно: `?user=7` меняется на `?user=8`,
--- срок — на год вперёд. Подпись делает адрес неизменяемым: собрать её
--- к подменённому адресу без ключа нельзя, а срок входит в подписанное
--- и отодвинуть его нечем.
---
--- Подписывается то, что читает обработчик, а не запись адреса: путь
--- одной записью (`path.canonical`) и строка запроса, собранная заново
--- из разобранных полей (`request.build_query`) — без самой подписи,
--- со сроком. Прокси, почтовый клиент и браузер вправе переписать запись
--- (`%7e` и `~`, `+` и `%20`, порядок полей), и подпись, посчитанная
--- по записи, отказывала бы честной ссылке; а подмена того, что видит
--- обработчик, меняет и подписанное.
---
--- Не подписываются схема, узел и способ. Узел за обратным прокси видит
--- свой адрес, а не тот, что в ссылке, — сверить узел ему не с чем.
--- Способ не подписан, чтобы одна ссылка служила и странице, и кнопке
--- на ней: ссылку «отписаться» из заголовка письма почтовый клиент
--- открывает POST, а человек — GET (RFC 8058). Где способ важен, подпись
--- сверяет слой на маршруте нужного способа, а не на группе.
---
--- Подпись — HMAC-SHA256 из `tnt-hash`, в base64url без набивки: 43 знака,
--- которые ложатся в адрес без кодирования. Перед подписанным стоит метка
--- назначения: значение, подписанное тем же ключом для другого дела
--- (подписанная кука), подписью ссылки не станет. Сверка идёт
--- за постоянное время (`hash.hmac_verify`) нынешним ключом и прежними
--- по очереди — так ключ меняют, не ломая разосланных ссылок.
---
--- Срок — секунды эпохи по стенным часам (`tnt-clock.realtime`), а не
--- монотонным: ссылку выдаёт один узел, а открывают на другом и после
--- перезапуска. Поэтому часы узлов обязаны идти вместе (NTP): узел,
--- спешащий на минуту, закрывает ссылки на минуту раньше.
---
--- Сверка отказывает парой — отказом границы HTTP со статусом 403:
--- ссылка приходит снаружи, и подделка — это не ошибка программиста.
--- Подделка и истёкший срок различаются кодом, а не номером: человеку
--- с устаревшей ссылкой говорят «попросите новую», а с подменённой —
--- ничего подробного.

local clock = require('tnt.clock')
local external = require('tnt.external')
local hash = require('tnt.hash')
local must = require('tnt.must')
local fail = require('tnt.must.fail')

local path = require('tnt.router.path')
local request_of = require('tnt.router.request')

local Module = {}

--- Средства снаружи: стенные часы, по которым считается срок ссылки.
local DEFAULTS = {
    now = clock.realtime,
}

local source = external.install(Module, DEFAULTS)

--- Поле строки запроса со сроком ссылки: секунды эпохи.
Module.EXPIRES = 'expires'

--- Поле строки запроса с подписью.
Module.SIGNATURE = 'signature'

--- Короче какого ключа подпись не ставится, байт.
---
--- Ключ HMAC короче свёртки ослабляет подпись (RFC 2104, §3), а короткий
--- ключ в настройках — почти всегда `secret` или пароль, набранный
--- руками. Ключ — случайные байты: `crypto.key()` либо
--- `crypto.derive(секрет, назначение)` из `tnt-crypto`.
Module.MIN_KEY = 32

--- Самый долгий срок ссылки, секунд: десять лет.
---
--- Срок длиннее — это почти всегда миллисекунды вместо секунд либо
--- бесконечность, а ссылке, которой срок не нужен, его не ставят вовсе.
Module.MAX_EXPIRES = 10 * 365 * 24 * 60 * 60

--- Метка назначения перед подписанным.
---
--- Перевод строки не бывает ни в значении куки, ни в пути, поэтому
--- подписанное другим пакетом тем же ключом с меткой не совпадёт. Смена
--- вида подписанного — это и смена метки: разосланные ссылки прежнего
--- вида откажут подделкой, а не откроются по ошибке.
local LABEL = 'tnt.router.signed\n'

--- Свёртка подписи и её вид.
local ALGORITHM = 'sha256'
local VIEW = 'base64url'

--- Отказ: подписи нет, она не сошлась либо подписан не срок.
Module.INVALID =
    { status = 403, message = 'ссылка недействительна', code = 'router_signature_invalid' }

--- Отказ: подпись сошлась, а срок ссылки вышел.
Module.EXPIRED =
    { status = 403, message = 'срок действия ссылки истёк', code = 'router_signature_expired' }

--- Отказ строкой — для журнала: роутер пишет причину `tostring`,
--- и таблица без этого ушла бы в запись как `table: 0x…`.
local REFUSAL = {
    __tostring = function(refusal)
        return ('%s: %s'):format(refusal.message, refusal.reason)
    end,
}

--- Описание настройки `signing`.
local OPTIONS = {
    key = 'string',
    previous = { '?array_of', 'string' },
}

--- Имена, которые ставит сама подпись: их в строке запроса вызывающего
--- быть не может. Своё `expires` без срока сверка прочла бы сроком.
local RESERVED = {
    [Module.EXPIRES] = true,
    [Module.SIGNATURE] = true,
}

--- Отказ сверки.
---@param kind table Род отказа: `Module.INVALID` либо `Module.EXPIRED`
---@param reason string Подробность для журнала; наружу не уходит
---@return nil
---@return table refusal
local function refused(kind, reason)
    return nil,
        setmetatable({
            status = kind.status,
            message = kind.message,
            code = kind.code,
            reason = reason,
        }, REFUSAL)
end

--- Что подписывается: метка, путь одной записью и строка запроса.
---@param target string Путь
---@param fields table<string, any> Поля строки запроса без подписи
---@return string
local function canonical(target, fields)
    return LABEL .. path.canonical(target) .. '?' .. request_of.build_query(fields)
end

--- Ключ не короче `MIN_KEY` либо бросок.
---
--- Сам ключ в тексте отказа не показывается: отказ уходит в журнал
--- и в alerts, а ключ — тайна.
---@param key string
---@param name string Как назвать ключ в отказе
---@param level integer Уровень вины, как у `error`: 1 — эта функция
---@return string
local function strong(key, name, level)
    if #key < Module.MIN_KEY then
        local expected = ('ключ подписи не короче %d байт'):format(Module.MIN_KEY)

        error(fail.text(name, expected, ('ключ из %d байт'):format(#key)), level)
    end

    return key
end

--- Подписан ли адрес одним из ключей.
---
--- Сверяются все ключи, а не до первого совпадения: время сверки
--- не выдаёт, каким ключом подписана ссылка — нынешним или прежним.
---@param keys string[] Нынешний ключ, затем прежние
---@param data string Подписанное
---@param given string Присланная подпись
---@return boolean
local function signed_by(keys, data, given)
    local matched = {}

    for _, key in ipairs(keys) do
        if hash.hmac_verify(ALGORITHM, key, data, given, VIEW) then
            table.insert(matched, key)
        end
    end

    return next(matched) ~= nil
end

--- Не вышел ли срок подписанной ссылки.
---
--- Срок, который подписан, но записан не так, как его пишет подпись,
--- подписала не эта сборка: своё `expires` вызывающему поставить
--- не дают. Такая ссылка отказывает подделкой — открывать её по чужому
--- правилу нельзя.
---
--- Запись сверяется обратной сборкой: `tonumber` читает и « 5», и `0x10`,
--- и `1e3`, и `5.0`, а целые секунды подпись пишет одним видом — `%d`.
---@param expires any Поле срока из строки запроса
---@return true|nil
---@return table|nil refusal
local function fresh(expires)
    if expires == nil then
        return true
    end

    local deadline = tonumber(expires)

    if deadline == nil or ('%d'):format(deadline) ~= expires then
        return refused(
            Module.INVALID,
            ('подписанный срок записан не так, как его пишет подпись: %s'):format(
                fail.show(expires)
            )
        )
    end

    local now = source().now()

    if now > deadline then
        return refused(
            Module.EXPIRED,
            ('ссылка действовала до %d, а сейчас %d'):format(deadline, math.floor(now))
        )
    end

    return true
end

--- Поля строки запроса, которые можно подписать, либо бросок.
---
--- Имя — непустая строка: пустое имя разбор отбрасывает, и подпись
--- по нему не сошлась бы никогда. Значение — строка, число либо их
--- список: таблица иного вида в адрес не ложится, а cdata (`1ULL`)
--- превратилась бы в строку «1ULL».
---@param query table<string, any>|nil
---@return table<string, any>
local function fields_of(query)
    -- Вина у того, кто просил ссылку: кадр этой функции, кадр `sign`
    -- и кадр способа роутера.
    local caller = must.at(4)
    local fields = {}

    for name, value in pairs(query or {}) do
        if type(name) ~= 'string' or name == '' then
            local complaint = fail.text(
                'настройки ссылки.query',
                'поля с именем-строкой',
                'поле ' .. fail.show(name)
            )

            error(complaint, 4)
        end

        local label = 'настройки ссылки.query.' .. name

        if RESERVED[name] then
            local complaint = ('%s — имя занято подписью: срок задаёт настройка expires'):format(
                label
            )

            error(complaint, 4)
        end

        caller.kind(value, label, 'string|number|table')

        if type(value) == 'table' then
            caller.array_of(value, label, 'string|number')
        end

        fields[name] = value
    end

    return fields
end

---@class TntRouterSigning
---@field key string Ключ подписи: случайные байты, не короче 32
---@field previous string[]|nil Прежние ключи: ими только сверяют

---@class TntRouterSigner
---@field sign fun(target: string, query: table|nil, expires: number|nil): string Путь и строка запроса с подписью
---@field verify fun(request: table): true|nil, table|nil Сверка запроса: `true` либо отказ 403

--- Подписчик по настройке `signing`; без настройки — ничего.
---
--- Ключи живут в замыкании, а не в полях: роутер, выведенный в консоль
--- `tt connect` или обойдённый `pairs`, показывает две функции, а не ключ.
---@param signing TntRouterSigning|nil
---@param level integer Уровень вины, как у `error`: 1 — эта функция
---@return TntRouterSigner|nil
function Module.new(signing, level)
    if signing == nil then
        return nil
    end

    must.at(level).options(signing, 'signing', OPTIONS)

    local keys = { strong(signing.key, 'signing.key', level + 1) }

    for index, old in ipairs(signing.previous or {}) do
        table.insert(keys, strong(old, ('signing.previous[%d]'):format(index), level + 1))
    end

    --- Подписывает путь со строкой запроса и сроком.
    ---@param target string Путь, собранный по имени маршрута
    ---@param query table|nil Поля строки запроса
    ---@param expires number|nil Сколько секунд ссылка действует; без него — бессрочно
    ---@return string
    local function sign(target, query, expires)
        local fields = fields_of(query)

        -- Вверх, а не вниз: ссылка живёт не меньше обещанного, и срок
        -- в секунду, выданный в конце секунды, не кончается тут же.
        if expires ~= nil then
            fields[Module.EXPIRES] = ('%d'):format(math.ceil(source().now() + expires))
        end

        local signature = hash.hmac(ALGORITHM, keys[1], canonical(target, fields), VIEW)
        local search = request_of.build_query(fields)

        if search == '' then
            return ('%s?%s=%s'):format(target, Module.SIGNATURE, signature)
        end

        return ('%s?%s&%s=%s'):format(target, search, Module.SIGNATURE, signature)
    end

    --- Сверяет подпись и срок запроса.
    ---
    --- Сначала подпись, потом срок: «срок истёк» говорится только о своей
    --- ссылке, а у подделки срок не читается вовсе.
    ---@param request table Запрос роутера: `path` и разобранный `query`
    ---@return true|nil
    ---@return table|nil refusal
    local function verify(request)
        local given = request.query[Module.SIGNATURE]

        if type(given) ~= 'string' then
            return refused(Module.INVALID, 'в ссылке нет подписи')
        end

        local fields = {}

        for name, value in pairs(request.query) do
            if name ~= Module.SIGNATURE then
                fields[name] = value
            end
        end

        if not signed_by(keys, canonical(request.path, fields), given) then
            return refused(
                Module.INVALID,
                'подпись не сошлась: адрес изменён либо подписан другим ключом'
            )
        end

        return fresh(fields[Module.EXPIRES])
    end

    return { sign = sign, verify = verify }
end

return Module
