--- Тесты адресов: полный адрес по имени, адрес приложения, канонический
--- адрес страницы.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.address')

--- Роутер с адресом приложения и парой именованных маршрутов.
---@param url string|nil
---@return any
local function web_of(url)
    local web = g.router.new({ url = url or 'https://shop.example.org' })

    web.get('/', helper.answering('главная'), { name = 'home' })
    web.get('/customers/:id', helper.answering('клиент'), { name = 'customer.show' })

    return web
end

-- ── Полный адрес ─────────────────────────────────────────────────────

g.test_full_address_is_the_application_address_and_the_path = function()
    local web = web_of()

    t.assert_equals(web.full_url('customer.show', { id = 7 }), 'https://shop.example.org/customers/7')
    t.assert_equals(web.full_url('home'), 'https://shop.example.org/')
    t.assert_equals(
        web.full_url('customer.show', { id = 'Иван' }, { tag = { 'a', 'b' }, page = 2 }),
        'https://shop.example.org/customers/%D0%98%D0%B2%D0%B0%D0%BD?page=2&tag=a&tag=b'
    )
end

g.test_application_address_keeps_its_port_and_path_but_not_the_last_slash = function()
    t.assert_equals(web_of('http://127.0.0.1:8080').full_url('home'), 'http://127.0.0.1:8080/')
    t.assert_equals(
        web_of('https://example.org/shop/').full_url('customer.show', { id = 7 }),
        'https://example.org/shop/customers/7'
    )
    t.assert_equals(web_of('https://example.org//').status().url, 'https://example.org')
    t.assert_equals(web_of('https://[::1]:8443/a').status().url, 'https://[::1]:8443/a')
end

g.test_full_address_refuses_as_the_path_does = function()
    local web = web_of()

    t.assert_equals(
        { web.full_url('нет.такого') },
        { nil, 'нет маршрута с именем «нет.такого»' }
    )
    t.assert_equals({ web.full_url('customer.show') }, { nil, 'не задан параметр «id»' })
end

g.test_path_takes_a_list_as_a_repeated_name = function()
    t.assert_equals(web_of().url('customer.show', { id = 7 }, { tag = { 'a', 'b' } }), '/customers/7?tag=a&tag=b')
end

g.test_full_address_without_the_application_address_is_a_mistake = function()
    local web = g.router.new()

    web.get('/', helper.answering('главная'), { name = 'home' })

    helper.assert_blamed({
        {
            function()
                web.full_url('home')
            end,
            'полный адрес не собрать: у роутера нет адреса приложения — настройка url',
        },
    })
end

g.test_application_address_is_checked_where_the_router_is_made = function()
    local expected =
        'url — адрес приложения: http или https, узел и по надобности путь — без строки запроса, а не %s'
    local cases = {}

    for _, wrong in ipairs({
        'ftp://shop.example.org',
        'HTTPS://shop.example.org',
        'https://',
        'shop.example.org',
        'https://shop.example.org?lang=ru',
        'https://shop.example.org/#top',
        'https://user:pass@shop.example.org',
        'https://shop example.org',
        'https://shop.example.org/a b',
    }) do
        table.insert(cases, {
            function()
                g.router.new({ url = wrong })
            end,
            expected:format(('«%s»'):format(wrong)),
        })
    end

    table.insert(cases, {
        function()
            g.router.new({ url = 8080 })
        end,
        expected:format('8080'),
    })

    helper.assert_blamed(cases)
end

g.test_configured_shared_router_is_checked_at_once = function()
    helper.assert_blamed({
        {
            function()
                g.router.configure({ url = 'ftp://x' })
            end,
            'url — адрес приложения: http или https, узел и по надобности путь — без строки запроса, а не «ftp://x»',
        },
        {
            function()
                g.router.configure({ signing = { key = 'short' } })
            end,
            'signing.key — ключ подписи не короче 32 байт, а не ключ из 5 байт',
        },
    })

    g.router.configure({ url = 'https://shop.example.org/', signing = { key = helper.KEY } })

    t.assert_equals(g.router.status().url, 'https://shop.example.org')
    t.assert_equals(g.router.status().signing, true)
end

-- ── Канонический адрес ───────────────────────────────────────────────

g.test_canonical_address_drops_the_query_and_rewrites_the_path_in_one_record = function()
    local web = web_of()
    local request = { path = '//customers/%d0%98%7e/', query = { utm_source = 'mail', page = '2' } }

    t.assert_equals(web.canonical(request), 'https://shop.example.org/customers/%D0%98~')
    t.assert_equals(web.canonical({ path = '/', query = {} }), 'https://shop.example.org/')
end

g.test_canonical_address_keeps_only_the_named_fields_in_order = function()
    local web = web_of('https://example.org/shop')
    local request = { path = '/customers', query = { sort = 'name', page = '2', tag = { 'b', 'a' }, utm = 'x' } }

    t.assert_equals(
        web.canonical(request, { query = { 'tag', 'page', 'missing' } }),
        'https://example.org/shop/customers?page=2&tag=b&tag=a'
    )
    t.assert_equals(web.canonical(request, { query = {} }), 'https://example.org/shop/customers')
end

g.test_canonical_address_of_the_request_the_router_served = function()
    local web = web_of()

    web.get('/articles/:slug', function(request)
        return g.router.text(web.canonical(request, { query = { 'page' } }))
    end)

    local answer = web.dispatch({ method = 'GET', url = 'http://127.0.0.1:8080/articles/a?page=3&utm_source=x' })

    t.assert_equals(answer.body, 'https://shop.example.org/articles/a?page=3')
end

g.test_canonical_address_needs_the_application_address_and_a_request = function()
    local web = web_of()

    helper.assert_blamed({
        {
            function()
                g.router.new().canonical({ path = '/', query = {} })
            end,
            'канонический адрес не собрать: у роутера нет адреса приложения — настройка url',
        },
        {
            function()
                web.canonical(nil)
            end,
            'запрос — таблица, а не nil',
        },
        {
            function()
                web.canonical({ path = 7, query = {} })
            end,
            'запрос.path — строка, а не число',
        },
        {
            function()
                web.canonical({ path = '/', query = 'page=2' })
            end,
            'запрос.query — таблица, а не строка',
        },
        {
            function()
                web.canonical({ path = '/', query = {} }, { query = 'page' })
            end,
            'настройки.query — массив, а не строка',
        },
        {
            function()
                web.canonical({ path = '/', query = {} }, { keep = { 'page' } })
            end,
            'настройки: ключа «keep» нет, есть query',
        },
    })
end

-- ── Состояние ────────────────────────────────────────────────────────

g.test_status_names_the_application_address_and_whether_links_are_signed = function()
    local plain = g.router.new().status()

    t.assert_equals(plain.url, nil)
    t.assert_equals(plain.signing, false)

    local signed = g.router.new({ url = 'https://shop.example.org', signing = { key = helper.KEY } }).status()

    t.assert_equals(signed.url, 'https://shop.example.org')
    t.assert_equals(signed.signing, true)
end
