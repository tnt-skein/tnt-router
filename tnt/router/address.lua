--- Адреса: путь по имени маршрута, полный адрес, подписанная ссылка
--- и канонический адрес страницы.
---
--- Путь по имени (`url`) нужен ссылке внутри страницы. Письму с
--- подтверждением, ссылке в ответе API и канонической ссылке страницы
--- нужен полный адрес — со схемой и узлом, — и берутся они из настройки
--- `url` роутера, а не из запроса.
---
--- Не из запроса — потому что узел своего имени снаружи не знает.
--- За обратным прокси он видит `http://127.0.0.1:8080`, а клиент ходит
--- на `https://shop.example.org`. Заголовок `Host` и заголовки прокси
--- (`X-Forwarded-Host`, `X-Forwarded-Proto`) пишет клиент, если до узла
--- он дошёл напрямую, и ссылка в письме, собранная по ним, уводила бы
--- на узел того, кто прислал запрос: письмо «сбросить пароль» уходит
--- настоящему владельцу, а ссылка в нём — на чужой сайт. Верить этим
--- заголовкам можно, только зная, что перед узлом стоит свой прокси,
--- а это знает развёртывание, не роутер. Адрес из настройки одинаков
--- за прокси и без него, в запросе и вне запроса — в работе очереди,
--- где запроса нет вовсе.
---
--- Способы живут здесь, а не в фасаде: у адресов своя забота — схема,
--- узел, подпись, — и фасад только раздаёт их экземпляру.

local must = require('tnt.must')
local fail = require('tnt.must.fail')

local path = require('tnt.router.path')
local request_of = require('tnt.router.request')
local signed = require('tnt.router.signed')

local Module = {}

--- Адрес приложения: схема, узел и путь — без строки запроса, обрывка
--- и учётных данных.
---
--- Путь разрешён: прокси, отдающий узлу `/shop/…` как `/…`, ставит его
--- в настройку, и полный адрес выходит с ним. Учётные данные в адресе
--- (`user:pass@`) ушли бы в каждое письмо.
---
--- Образец сверяется с адресом, дописанным косой чертой: путь тогда
--- начинается с неё всегда, и за узлом не проскочит ни `@`, ни `?`.
local BASE = '^(https?)://([^/?#@%s]+)(/[^?#%s]*)$'

--- Чего ждут от настройки `url`.
local EXPECTED_BASE =
    'адрес приложения: http или https, узел и по надобности путь — без строки запроса'

--- Настройки подписанной ссылки.
local LINK = {
    query = '?table',
    expires = { '?between', 1, signed.MAX_EXPIRES },
    full = '?boolean',
}

--- Настройки канонического адреса.
local CANONICAL = {
    query = { '?array_of', 'string' },
}

--- Проверенный адрес приложения; без настройки — ничего.
---
--- Косые черты в конце снимаются: путь маршрута начинается со своей,
--- и адрес иначе выходил бы с двумя подряд. Снимаются по одной, а не
--- образцом: у дописанной черты их всегда не меньше одной, и образцы
--- «одна и больше» и «сколько угодно» здесь неотличимы.
---@param value any Настройка `url`
---@param level integer Уровень вины, как у `error`: 1 — эта функция
---@return string|nil
function Module.base(value, level)
    if value == nil then
        return nil
    end

    local scheme, authority, rest

    if type(value) == 'string' then
        scheme, authority, rest = (value .. '/'):match(BASE)
    end

    if scheme == nil then
        error(fail.text('url', EXPECTED_BASE, fail.show(value)), level)
    end

    -- Образец совпал целиком и отдал все три части разом.
    ---@cast authority string
    ---@cast rest string

    while rest:sub(-1) == '/' do
        rest = rest:sub(-#rest, -2)
    end

    return scheme .. '://' .. authority .. rest
end

--- Адрес приложения либо бросок.
---
--- Бросок, а не отказ парой: адрес приложения — настройка, и её нехватка —
--- промах того, кто собирал роутер. Заметить его надо на первом вызове,
--- а не в письме, ушедшем с относительной ссылкой.
---@param self table Роутер
---@param what string Что не собрать
---@return string
local function based(self, what)
    local base = self.settings.url

    if base == nil then
        local complaint = ('%s: у роутера нет адреса приложения — настройка url'):format(
            what
        )

        -- Вина у того, кто позвал способ: кадр этой функции и кадр способа.
        error(complaint, 3)
    end

    return base
end

--- Подписчик роутера либо бросок — по той же причине, что и у адреса.
---@param self table Роутер
---@param what string Чего не сделать
---@return TntRouterSigner
local function signer_of(self, what)
    local signer = self.settings.signer

    if signer == nil then
        error(('%s: у роутера нет ключа подписи — настройка signing'):format(what), 3)
    end

    return signer
end

--- Запрос роутера либо бросок: сверять и собирать адрес не из чего.
---@param request any
local function demand_request(request)
    -- Кадр этой функции и кадр способа.
    local caller = must.at(3)

    caller.table(request, 'запрос')
    caller.string(request.path, 'запрос.path')
    caller.table(request.query, 'запрос.query')
end

--- Путь по имени маршрута.
---@param self table Роутер
---@param name string
---@param params table<string, any>|nil
---@return string|nil address
---@return string|nil err
local function rendered(self, name, params)
    local route = self.named[name]

    if route == nil then
        return nil, ('нет маршрута с именем «%s»'):format(tostring(name))
    end

    return path.render(route.segments, params)
end

--- Способы роутера: раздаются экземпляру фасадом.
local Methods = {}

--- Путь по имени маршрута.
---@param self table
---@param name string
---@param params table<string, any>|nil
---@param query table<string, any>|nil
---@return string|nil address
---@return string|nil err
function Methods.url(self, name, params, query)
    local built, err = rendered(self, name, params)

    if built == nil then
        return nil, err
    end

    if query == nil then
        return built
    end

    return built .. '?' .. request_of.build_query(query)
end

--- Полный адрес по имени маршрута: схема и узел из настройки `url`.
---@param self table
---@param name string
---@param params table<string, any>|nil
---@param query table<string, any>|nil
---@return string|nil address
---@return string|nil err
function Methods.full_url(self, name, params, query)
    local base = based(self, 'полный адрес не собрать')
    local built, err = Methods.url(self, name, params, query)

    if built == nil then
        return nil, err
    end

    return base .. built
end

---@class TntRouterLinkOptions
---@field query table<string, string|number|(string|number)[]>|nil Поля строки запроса; подписываются вместе с путём
---@field expires number|nil Сколько секунд ссылка действует; без него — бессрочно
---@field full boolean|nil Полный адрес со схемой и узлом из настройки `url`

--- Подписанная ссылка по имени маршрута.
---
--- Отказ парой — тот же, что у `url`: маршрута нет, параметра нет.
--- Негодные настройки ссылки и роутер без ключа — бросок.
---@param self table
---@param name string
---@param params table<string, any>|nil
---@param opts TntRouterLinkOptions|nil
---@return string|nil address
---@return string|nil err
function Methods.signed_url(self, name, params, opts)
    local signer = signer_of(self, 'подписанную ссылку не собрать')

    must.at(2).optional.options(opts, 'настройки ссылки', LINK)

    local given = opts or {}
    local base = ''

    if given.full then
        base = based(self, 'полную подписанную ссылку не собрать')
    end

    local built, err = rendered(self, name, params)

    if built == nil then
        return nil, err
    end

    local link = signer.sign(built, given.query, given.expires)

    return base .. link
end

--- Сверяет подпись и срок ссылки, по которой пришёл запрос.
---@param self table
---@param request TntRouterRequest Запрос роутера
---@return true|nil
---@return table|nil refusal Отказ границы HTTP: 403 с кодом `router_signature_invalid` либо `router_signature_expired`
function Methods.verify(self, request)
    local signer = signer_of(self, 'подпись ссылки не сверить')

    demand_request(request)

    local ok, refusal = signer.verify(request)

    return ok, refusal
end

--- Слой, пропускающий к обработчику только подписанную ссылку в срок.
---
--- Отказ — парой, отказом границы HTTP со статусом 403: его рисует
--- обработчик отказов приложения, как и всякий другой.
---@param self table
---@return fun(request: table, nxt: fun(request: table): any): any
function Methods.signed(self)
    local signer = signer_of(self, 'слой подписи не собрать')

    return function(request, nxt)
        local ok, refusal = signer.verify(request)

        if not ok then
            return nil, refusal
        end

        return nxt(request)
    end
end

--- Канонический адрес страницы: адрес приложения, путь одной записью
--- и только названные поля строки запроса.
---
--- Одну страницу открывают по многим адресам — с меткой рассылки
--- (`?utm_source=…`), с порядком сортировки, с `//` в пути, по второму
--- имени узла. Поисковик считает их разными страницами и делит между
--- ними вес; `<link rel="canonical">` называет одну. Поле, которое
--- меняет содержимое страницы (`page`), называют в `query`, остальные
--- отбрасываются.
---@param self table
---@param request TntRouterRequest Запрос роутера
---@param opts { query: string[]|nil }|nil Какие поля строки запроса оставить
---@return string
function Methods.canonical(self, request, opts)
    local base = based(self, 'канонический адрес не собрать')

    demand_request(request)
    must.at(2).optional.options(opts, 'настройки', CANONICAL)

    local kept = {}

    for _, name in ipairs((opts or {}).query or {}) do
        kept[name] = request.query[name]
    end

    local address = base .. path.canonical(request.path)
    local search = request_of.build_query(kept)

    if search == '' then
        return address
    end

    return address .. '?' .. search
end

Module.METHODS = Methods

return Module
