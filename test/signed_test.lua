--- Тесты подписанных ссылок: вид подписи, срок, подмена, смена ключа, слой.

local t = require('luatest')

local hash = require('tnt.hash')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.signed')

--- Который час по стенным часам в проверках, если не сказано иного.
local NOW = 1700000000

--- Другой ключ той же длины: подписанное им чужим ключом и остаётся.
local OTHER = string.rep('o', 32)

--- Ставит стенные часы подписи.
---@param now number
local function at(now)
    helper.part('tnt.router.signed')._set_source({
        now = function()
            return now
        end,
    })
end

--- Роутер с ключом подписи и маршрутом счёта под слоем сверки.
---@param signing table|nil Настройка `signing`; по умолчанию — ключ `helper.KEY`
---@param extra table|nil Прочие настройки роутера
---@return any
local function web_of(signing, extra)
    local opts = { signing = signing or { key = helper.KEY } }

    for name, value in pairs(extra or {}) do
        opts[name] = value
    end

    local web = g.router.new(opts)

    web.get('/invoices/:id', function(request)
        return g.router.text('счёт ' .. request.params.id)
    end, { name = 'invoice', middleware = { web.signed() } })

    return web
end

--- Подпись, какой её ставит пакет: метка, путь и строка запроса.
---@param data string Путь и строка запроса без подписи, через «?»
---@param key string|nil
---@return string
local function signature_of(data, key)
    return hash.hmac('sha256', key or helper.KEY, 'tnt.router.signed\n' .. data, 'base64url')
end

--- Ответ роутера на адрес.
---@param web any
---@param address string
---@param method string|nil
---@return table
local function opened(web, address, method)
    return web.dispatch({ method = method or 'GET', url = address })
end

--- Отказ, которым ответил роутер: тело ответа по умолчанию.
---@param answer table
---@return table
local function refusal_of(answer)
    return helper.decoded(answer).error
end

g.before_each(function()
    at(NOW)
end)

-- ── Вид подписи ──────────────────────────────────────────────────────

g.test_link_without_term_and_query_is_the_path_and_the_signature = function()
    local web = web_of()
    local link = web.signed_url('invoice', { id = 7 })

    t.assert_equals(link, '/invoices/7?signature=' .. signature_of('/invoices/7?'))
    t.assert_equals(#signature_of('/invoices/7?'), 43)

    local answer = opened(web, link)

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.body, 'счёт 7')
end

g.test_term_and_query_are_signed_together_and_the_signature_goes_last = function()
    local web = web_of()
    local link = web.signed_url(
        'invoice',
        { id = 7 },
        { expires = 60, query = { tag = { 'a', 'b' }, q = 'а б', n = 5 } }
    )
    local search = 'expires=1700000060&n=5&q=%D0%B0%20%D0%B1&tag=a&tag=b'

    t.assert_equals(link, ('/invoices/7?%s&signature=%s'):format(search, signature_of('/invoices/7?' .. search)))
    t.assert_equals(opened(web, link).status, 200)
end

g.test_term_is_rounded_up_to_a_whole_second = function()
    at(NOW + 0.25)

    local link = web_of().signed_url('invoice', { id = 7 }, { expires = 60 })

    t.assert_str_contains(link, '?expires=1700000061&signature=')
end

g.test_link_can_be_full_with_the_address_of_the_application = function()
    local web = web_of(nil, { url = 'https://shop.example.org' })
    local link = web.signed_url('invoice', { id = 7 }, { full = true })

    t.assert_equals(link, 'https://shop.example.org/invoices/7?signature=' .. signature_of('/invoices/7?'))
    t.assert_equals(
        web.signed_url('invoice', { id = 7 }, { full = false }),
        '/invoices/7?signature=' .. signature_of('/invoices/7?')
    )
    t.assert_equals(opened(web, link).status, 200)
end

g.test_missing_route_and_missing_parameter_are_refusals_as_for_the_path = function()
    local web = web_of()

    t.assert_equals(
        { web.signed_url('нет.такого') },
        { nil, 'нет маршрута с именем «нет.такого»' }
    )
    t.assert_equals({ web.signed_url('invoice', {}) }, { nil, 'не задан параметр «id»' })
end

-- ── Срок ─────────────────────────────────────────────────────────────

g.test_link_opens_until_its_term_inclusive_and_then_expires = function()
    local web = web_of()
    local link = web.signed_url('invoice', { id = 7 }, { expires = 60 })

    at(NOW + 60)
    t.assert_equals(opened(web, link).status, 200)

    at(NOW + 60.5)

    local answer = opened(web, link)

    t.assert_equals(answer.status, 403)
    t.assert_equals(refusal_of(answer).code, 'router_signature_expired')
    t.assert_equals(refusal_of(answer).message, 'срок действия ссылки истёк')
end

g.test_expired_refusal_names_the_term_for_the_journal = function()
    local web = web_of()

    at(NOW + 100.75)

    local ok, refusal = web.verify({
        path = '/invoices/7',
        query = { expires = '1700000060', signature = signature_of('/invoices/7?expires=1700000060') },
    })

    t.assert_equals(ok, nil)
    t.assert_equals(refusal.status, 403)
    t.assert_equals(refusal.reason, 'ссылка действовала до 1700000060, а сейчас 1700000100')
    t.assert_equals(
        tostring(refusal),
        'срок действия ссылки истёк: ссылка действовала до 1700000060, а сейчас 1700000100'
    )
end

g.test_link_without_term_opens_whenever = function()
    local web = web_of()
    local link = web.signed_url('invoice', { id = 7 })

    at(NOW + 9 * 365 * 24 * 60 * 60)

    t.assert_equals(opened(web, link).status, 200)
end

g.test_term_moved_forward_is_a_forgery_and_not_a_fresh_link = function()
    local web = web_of()
    local link = web.signed_url('invoice', { id = 7 }, { expires = 60 })

    at(NOW + 120)

    local answer = opened(web, (link:gsub('expires=1700000060', 'expires=1700009999')))

    t.assert_equals(answer.status, 403)
    t.assert_equals(refusal_of(answer).code, 'router_signature_invalid')
end

g.test_signed_term_that_is_not_seconds_is_refused_as_foreign = function()
    local web = web_of()

    for _, term in ipairs({ 'abc', '12a', ' 5', '5.5', '0x10', '1e3', '05', '' }) do
        local data = '/invoices/7?' .. helper.part('tnt.router.request').build_query({ expires = term })
        local ok, refusal =
            web.verify({ path = '/invoices/7', query = { expires = term, signature = signature_of(data) } })

        t.assert_equals(ok, nil)
        t.assert_equals(refusal.code, 'router_signature_invalid')
        t.assert_equals(
            refusal.reason,
            ('подписанный срок записан не так, как его пишет подпись: «%s»'):format(
                term
            )
        )
    end

    local listed = '/invoices/7?expires=1&expires=2'
    local ok, refusal =
        web.verify({ path = '/invoices/7', query = { expires = { '1', '2' }, signature = signature_of(listed) } })

    t.assert_equals(ok, nil)
    t.assert_equals(
        refusal.reason,
        'подписанный срок записан не так, как его пишет подпись: таблица'
    )
end

-- ── Подмена ──────────────────────────────────────────────────────────

g.test_changed_address_is_refused_as_invalid = function()
    local web = web_of()
    local link = web.signed_url('invoice', { id = 7 }, { expires = 60, query = { tag = 'a' } })

    for _, forged in ipairs({
        (link:gsub('invoices/7', 'invoices/8')),
        (link:gsub('tag=a', 'tag=b')),
        (link:gsub('tag=a', 'tag=a&tag=b')),
        (link:gsub('tag=a&', '')),
        (link:gsub('%?', '?admin=1&')),
        (link:gsub('signature=.', 'signature=A')),
        (link:gsub('&signature=.*$', '')),
    }) do
        local answer = opened(web, forged)

        t.assert_equals(answer.status, 403, forged)
        t.assert_equals(refusal_of(answer).code, 'router_signature_invalid', forged)
        t.assert_equals(refusal_of(answer).message, 'ссылка недействительна', forged)
    end
end

g.test_refusal_tells_the_journal_why = function()
    local web = web_of()
    local link = web.signed_url('invoice', { id = 7 })
    local _, forged = web.verify({ path = '/invoices/8', query = { signature = link:match('signature=(.*)$') } })
    local _, bare = web.verify({ path = '/invoices/7', query = {} })
    local _, doubled = web.verify({ path = '/invoices/7', query = { signature = { 'a', 'b' } } })

    t.assert_equals(
        forged.reason,
        'подпись не сошлась: адрес изменён либо подписан другим ключом'
    )
    t.assert_equals(bare.reason, 'в ссылке нет подписи')
    t.assert_equals(doubled.reason, 'в ссылке нет подписи')
    t.assert_equals(
        tostring(bare),
        'ссылка недействительна: в ссылке нет подписи'
    )
end

g.test_rewritten_record_of_the_same_address_still_opens = function()
    local web = web_of()

    web.get('/счета/:name', helper.answering('счёт'), { name = 'account', middleware = { web.signed() } })

    local link = web.signed_url(
        'account',
        { name = 'Иван Петров' },
        { query = { q = 'а б', sort = 'name' } }
    )

    t.assert_equals(opened(web, link).status, 200)

    -- Шестнадцатеричные строчными, плюс вместо пробела, другой порядок
    -- полей, лишние косые черты — запись другая, адрес тот же.
    local rewritten = ('//%s//%s/?sort=name&q=%%d0%%b0+%%d0%%b1&signature=%s'):format(
        link:match('^/([^/]+)'):lower(),
        link:match('^/[^/]+/([^?]+)'):lower(),
        link:match('signature=(.*)$')
    )

    t.assert_equals(opened(web, rewritten).status, 200)
end

g.test_signed_value_given_as_a_number_opens_from_the_request_table = function()
    local web = web_of()
    local link = web.signed_url('invoice', { id = 7 }, { query = { n = 5 } })
    local answer = web.dispatch({
        method = 'GET',
        path = '/invoices/7',
        query = { n = 5, signature = link:match('signature=(.*)$') },
    })

    t.assert_equals(answer.status, 200)
end

g.test_head_of_a_signed_get_route_is_checked_too = function()
    local web = web_of()
    local link = web.signed_url('invoice', { id = 7 })

    t.assert_equals(opened(web, link, 'HEAD').status, 200)
    t.assert_equals(opened(web, link, 'HEAD').body, '')
    t.assert_equals(opened(web, '/invoices/7', 'HEAD').status, 403)
end

g.test_same_link_serves_every_method_of_its_address = function()
    local web = web_of()

    web.post('/invoices/:id', helper.answering('', 204), { middleware = { web.signed() } })

    local link = web.signed_url('invoice', { id = 7 })

    t.assert_equals(opened(web, link, 'POST').status, 204)
end

g.test_refusal_goes_to_the_error_handler_of_the_application = function()
    local seen = {}
    local web = web_of(nil, {
        on_error = function(failure)
            seen.failure = failure

            return { status = failure.status, headers = {}, body = failure.code }
        end,
    })

    local answer = opened(web, '/invoices/7')

    t.assert_equals(answer.body, 'router_signature_invalid')
    t.assert_equals(seen.failure.status, 403)
    t.assert_equals(seen.failure.message, 'ссылка недействительна')
    t.assert_equals(
        tostring(seen.failure.reason),
        'ссылка недействительна: в ссылке нет подписи'
    )
end

-- ── Ключи ────────────────────────────────────────────────────────────

g.test_link_of_another_key_is_invalid = function()
    local link = web_of({ key = OTHER }).signed_url('invoice', { id = 7 })

    t.assert_equals(opened(web_of(), link).status, 403)
end

g.test_previous_key_still_opens_links_and_new_ones_get_the_current = function()
    local old = web_of({ key = OTHER })
    local rotated = web_of({ key = helper.KEY, previous = { string.rep('p', 32), OTHER } })
    local fresh = web_of()
    local issued = old.signed_url('invoice', { id = 7 })
    local renewed = rotated.signed_url('invoice', { id = 7 })

    t.assert_equals(opened(rotated, issued).status, 200)
    t.assert_equals(opened(fresh, renewed).status, 200)
    t.assert_equals(opened(fresh, issued).status, 403)
end

g.test_key_is_at_least_thirty_two_bytes = function()
    t.assert_equals(g.router.new({ signing = { key = helper.KEY } }).status().signing, true)

    helper.assert_blamed({
        {
            function()
                g.router.new({ signing = { key = string.rep('k', 31) } })
            end,
            'signing.key — ключ подписи не короче 32 байт, а не ключ из 31 байт',
        },
        {
            function()
                g.router.new({ signing = { key = helper.KEY, previous = { helper.KEY, 'short' } } })
            end,
            'signing.previous[2] — ключ подписи не короче 32 байт, а не ключ из 5 байт',
        },
        {
            function()
                g.router.new({ signing = 'ключ' })
            end,
            'signing — таблица, а не строка',
        },
        {
            function()
                g.router.new({ signing = { keys = helper.KEY } })
            end,
            'signing: ключа «keys» нет, есть key, previous',
        },
        {
            function()
                g.router.new({ signing = { key = helper.KEY, previous = { 7 } } })
            end,
            'signing.previous[1] — строка, а не число',
        },
    })
end

g.test_key_never_shows_in_status_nor_in_the_router = function()
    local web = web_of({ key = helper.KEY, previous = { OTHER } })
    local seen = {}

    --- Обходит всё, что достижимо из таблицы полями.
    ---@param value any
    local function walk(value)
        if type(value) ~= 'table' or seen[value] then
            return
        end

        seen[value] = true

        for name, field in pairs(value) do
            t.assert_not_equals(name, helper.KEY)
            t.assert_not_equals(field, helper.KEY)
            t.assert_not_equals(field, OTHER)
            walk(field)
        end
    end

    walk(web)
    walk(web.status())
    t.assert_equals(web.status().signing, true)
end

-- ── Ошибки программиста ──────────────────────────────────────────────

g.test_names_of_the_signature_are_not_given_by_the_caller = function()
    local web = web_of()

    helper.assert_blamed({
        {
            function()
                web.signed_url('invoice', { id = 7 }, { query = { expires = 1 } })
            end,
            'настройки ссылки.query.expires — имя занято подписью: срок задаёт настройка expires',
        },
        {
            function()
                web.signed_url('invoice', { id = 7 }, { query = { signature = 'x' } })
            end,
            'настройки ссылки.query.signature — имя занято подписью: срок задаёт настройка expires',
        },
    })
end

g.test_query_of_a_link_is_names_with_strings_numbers_or_their_lists = function()
    local web = web_of()

    helper.assert_blamed({
        {
            function()
                web.signed_url('invoice', { id = 7 }, { query = { 'x' } })
            end,
            'настройки ссылки.query — поля с именем-строкой, а не поле 1',
        },
        {
            function()
                web.signed_url('invoice', { id = 7 }, { query = { [''] = 'x' } })
            end,
            'настройки ссылки.query — поля с именем-строкой, а не поле «»',
        },
        {
            function()
                web.signed_url('invoice', { id = 7 }, { query = { flag = true } })
            end,
            'настройки ссылки.query.flag — строка или число или таблица, а не true',
        },
        {
            function()
                web.signed_url('invoice', { id = 7 }, { query = { n = 1ULL } })
            end,
            'настройки ссылки.query.n — строка или число или таблица, а не 1ULL',
        },
        {
            function()
                web.signed_url('invoice', { id = 7 }, { query = { tag = { a = 1 } } })
            end,
            'настройки ссылки.query.tag — массив, а не таблица с ключом «a»',
        },
        {
            function()
                web.signed_url('invoice', { id = 7 }, { query = { tag = { 'a', false } } })
            end,
            'настройки ссылки.query.tag[2] — строка или число, а не false',
        },
    })
end

g.test_settings_of_a_link_are_checked = function()
    local web = web_of()

    helper.assert_blamed({
        {
            function()
                web.signed_url('invoice', { id = 7 }, { expires = 0 })
            end,
            'настройки ссылки.expires — число от 1 до 315360000, а не 0',
        },
        {
            function()
                web.signed_url('invoice', { id = 7 }, { expires = 315360001 })
            end,
            'настройки ссылки.expires — число от 1 до 315360000, а не 315360001',
        },
        {
            function()
                web.signed_url('invoice', { id = 7 }, { expires = math.huge })
            end,
            'настройки ссылки.expires — число от 1 до 315360000, а не inf',
        },
        {
            function()
                web.signed_url('invoice', { id = 7 }, { query = 'a=1' })
            end,
            'настройки ссылки.query — таблица, а не строка',
        },
        {
            function()
                web.signed_url('invoice', { id = 7 }, { full = 1 })
            end,
            'настройки ссылки.full — логическое значение, а не число',
        },
        {
            function()
                web.signed_url('invoice', { id = 7 }, { ttl = 60 })
            end,
            'настройки ссылки: ключа «ttl» нет, есть expires, full, query',
        },
        {
            function()
                web.signed_url('invoice', { id = 7 }, { full = true })
            end,
            'полную подписанную ссылку не собрать: у роутера нет адреса приложения — настройка url',
        },
    })

    t.assert_str_contains(web.signed_url('invoice', { id = 7 }, { expires = 1 }), 'expires=1700000001&')
    t.assert_str_contains(web.signed_url('invoice', { id = 7 }, { expires = 315360000 }), 'expires=2015360000&')
end

g.test_router_without_a_key_neither_signs_nor_checks = function()
    local web = g.router.new()

    web.get('/invoices/:id', g.router.text, { name = 'invoice' })

    helper.assert_blamed({
        {
            function()
                web.signed_url('invoice', { id = 7 })
            end,
            'подписанную ссылку не собрать: у роутера нет ключа подписи — настройка signing',
        },
        {
            function()
                web.verify({ path = '/invoices/7', query = {} })
            end,
            'подпись ссылки не сверить: у роутера нет ключа подписи — настройка signing',
        },
        {
            function()
                web.signed()
            end,
            'слой подписи не собрать: у роутера нет ключа подписи — настройка signing',
        },
    })
end

g.test_verify_takes_the_request_of_the_router = function()
    local web = web_of()
    local link = web.signed_url('invoice', { id = 7 })

    t.assert_equals(web.verify({ path = '/invoices/7', query = { signature = link:match('signature=(.*)$') } }), true)

    helper.assert_blamed({
        {
            function()
                web.verify('/invoices/7')
            end,
            'запрос — таблица, а не строка',
        },
        {
            function()
                web.verify({ query = {} })
            end,
            'запрос.path — строка, а не nil',
        },
        {
            function()
                web.verify({ path = '/invoices/7', query = 'signature=x' })
            end,
            'запрос.query — таблица, а не строка',
        },
    })
end
