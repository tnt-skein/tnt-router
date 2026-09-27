--- Тесты слоя метки версии: ETag по отпечатку тела и 304.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.etag')

--- Метка тела: crc32 тем же видом, что у раздачи.
---@param body string
---@return string
local function tag_of(body)
    return ('"%08x"'):format(require('digest').crc32(body))
end

--- Тело страницы проверок и его метка.
local PAGE = '<h1>Клиенты</h1>'
local TAG = tag_of(PAGE)

--- Роутер со слоем на маршрутах и страницей по адресу `/`.
---@param headers table|nil Заголовки ответа страницы
---@param status integer|nil
---@return any web
local function serving(headers, status)
    local web = g.router.new({ middleware = { g.router.etag() } })

    web.get('/', function()
        return {
            status = status or 200,
            headers = headers or { ['content-type'] = 'text/html; charset=utf-8' },
            body = PAGE,
        }
    end)

    return web
end

--- Ответ роутера на запрос страницы.
---@param web any
---@param method string
---@param headers table|nil
---@return table
local function asked(web, method, headers)
    return web.dispatch(helper.request(method, '/', { headers = headers or {} }))
end

g.test_a_page_gets_the_tag_of_its_body = function()
    local sent = asked(serving(), 'GET')

    t.assert_equals(sent, {
        status = 200,
        headers = { ['content-type'] = 'text/html; charset=utf-8', etag = TAG },
        body = PAGE,
    })
end

g.test_the_same_page_asked_with_its_tag_is_304_without_a_body = function()
    local web = serving({
        ['content-type'] = 'text/html; charset=utf-8',
        ['content-language'] = 'ru',
        ['content-location'] = '/ru/',
        ['cache-control'] = 'no-cache',
        vary = 'x-fragment',
        ['set-cookie'] = 'seen=1',
    })

    -- Тела нет, заголовки — те же, что у 200: чем обновить кэш, тип,
    -- без которого сервер подставил бы свой, и то, что поставил обработчик.
    local expected = {
        status = 304,
        headers = {
            etag = TAG,
            ['content-type'] = 'text/html; charset=utf-8',
            ['content-language'] = 'ru',
            ['content-location'] = '/ru/',
            ['cache-control'] = 'no-cache',
            vary = 'x-fragment',
            ['set-cookie'] = 'seen=1',
        },
    }

    -- Список меток, слабая пометка и звёздочка — по правилу RFC 9110.
    for _, given in ipairs({ TAG, 'W/' .. TAG, '"x", ' .. TAG, '*' }) do
        t.assert_equals(asked(web, 'GET', { ['if-none-match'] = given }), expected, given)
    end

    local changed = asked(web, 'GET', { ['if-none-match'] = '"00000000"' })

    t.assert_equals(changed.status, 200)
    t.assert_equals(changed.body, PAGE)
end

g.test_head_gets_the_tag_of_the_body_get_would_send = function()
    local web = serving()
    local head = asked(web, 'HEAD')

    t.assert_equals(head.headers.etag, TAG)
    t.assert_equals(head.body, '')
    t.assert_equals(asked(web, 'HEAD', { ['if-none-match'] = TAG }).status, 304)
end

g.test_the_tag_set_by_the_handler_is_kept_and_compared = function()
    local web = serving({ etag = '"v7"' })

    t.assert_equals(asked(web, 'GET').headers.etag, '"v7"')
    t.assert_equals(asked(web, 'GET', { ['if-none-match'] = '"v7"' }).status, 304)
    t.assert_equals(asked(web, 'GET', { ['if-none-match'] = TAG }).status, 200)
end

g.test_the_handler_headers_are_not_changed_in_place = function()
    -- Обработчик отдаёт одну таблицу заголовков на каждый запрос: метка,
    -- дописанная в неё, уехала бы в следующий ответ.
    local shared = { ['content-type'] = 'text/html; charset=utf-8' }
    local web = serving(shared)

    asked(web, 'GET')
    t.assert_equals(shared, { ['content-type'] = 'text/html; charset=utf-8' })
end

g.test_what_is_not_a_page_read_goes_untouched = function()
    -- Не 200, не чтение, поток: метки нет, условие не спрашивается.
    t.assert_equals(asked(serving(nil, 201), 'GET', { ['if-none-match'] = '*' }).status, 201)
    t.assert_equals(asked(serving(nil, 201), 'GET').headers.etag, nil)

    local web = g.router.new({ middleware = { g.router.etag() } })

    web.post('/', helper.answering(PAGE))
    web.get('/stream', function()
        return g.router.stream(function() end)
    end)
    web.get('/broken', function()
        return nil, { status = 410 }
    end)

    local posted = web.dispatch(helper.request('POST', '/', { headers = { ['if-none-match'] = '*' } }))

    t.assert_equals(posted, { status = 200, headers = {}, body = PAGE })
    t.assert_equals(web.dispatch(helper.request('GET', '/stream', { headers = {} })).headers.etag, nil)
    t.assert_equals(web.dispatch(helper.request('GET', '/broken', { headers = {} })).status, 410)
end

g.test_on_the_entry_head_is_left_without_a_tag = function()
    -- На входе ответ на HEAD уже без тела: метка пустоты разошлась бы
    -- с меткой ответа на GET. Пустое тело GET метку получает.
    local web = g.router.new({ entry = { g.router.etag() } })

    web.get('/', function()
        return { status = 200, headers = {}, body = PAGE }
    end)
    web.get('/empty', helper.answering(''))

    t.assert_equals(asked(web, 'GET').headers.etag, TAG)
    t.assert_equals(asked(web, 'HEAD').headers, { ['content-length'] = tostring(#PAGE) })
    t.assert_equals(web.dispatch(helper.request('GET', '/empty', { headers = {} })).headers.etag, tag_of(''))
end
