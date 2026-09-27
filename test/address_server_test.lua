--- Живой узел: подписанная ссылка и полный адрес по сети — напрямую
--- и за обратным прокси.
---
--- Прокси — второй `http.server` в том же процессе: он снимает начало
--- пути `/shop`, как прокси, отдающий узлу приложение под своим путём,
--- и дописывает заголовки `X-Forwarded-*`, а `Host` ставит свой. Этого
--- хватает, чтобы увидеть главное: узел за прокси видит не тот адрес,
--- что в ссылке, а подпись и полный адрес от этого не зависят. Докер
--- для этого не нужен, и гейт от него не зависит.

local t = require('luatest')

local http_client = require('http.client')
local http_server = require('http.server')
local json = require('json')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.address.server')

--- Который час по стенным часам подписи.
local NOW = 1700000000

--- Начало пути, под которым прокси отдаёт приложение.
local PREFIX = '/shop'

--- Сервер без журнала запросов, на случайном порту.
---@return table httpd
local function server()
    return http_server.new('127.0.0.1', 0, { log_requests = false, log_errors = false, idle_timeout = 5 })
end

--- Адрес поднятого сервера.
---@param httpd table
---@return string
local function address_of(httpd)
    return ('http://127.0.0.1:%d'):format(httpd.tcp_server:name().port)
end

--- Ставит стенные часы подписи.
---@param now number
local function at(now)
    helper.part('tnt.router.signed')._set_source({
        now = function()
            return now
        end,
    })
end

--- Запрос по сети.
---@param method string
---@param where string Адрес целиком
---@param headers table|nil
---@return table
local function asked(method, where, headers)
    return http_client.new():request(method, where, nil, { timeout = 5, headers = headers })
end

--- Прокси перед узлом: снимает `PREFIX` и называет себя заголовками.
---@param upstream table Где узел: поле `address` дописывается после его подъёма
---@return table proxy
local function proxy_for(upstream)
    local proxy = server()

    proxy.options.handler = function(_, incoming)
        local rest = incoming.path_raw:sub(#PREFIX + 1)
        local search = ''

        if incoming.query ~= nil and incoming.query ~= '' then
            search = '?' .. incoming.query
        end

        local answer = asked(incoming.method, upstream.address .. rest .. search, {
            ['x-forwarded-host'] = 'shop.example.org',
            ['x-forwarded-proto'] = 'https',
            ['x-forwarded-prefix'] = PREFIX,
        })

        return {
            status = answer.status,
            headers = { ['content-type'] = answer.headers['content-type'] },
            body = answer.body,
        }
    end

    proxy:start()

    return proxy
end

g.before_each(function()
    local upstream = {}

    g.proxy = proxy_for(upstream)
    g.public = address_of(g.proxy) .. PREFIX
    g.web = g.router.new({ url = g.public, signing = { key = helper.KEY } })

    -- Обработчик отвечает тем, что узел считает полным и каноническим
    -- адресом: их сверяют и за прокси, и без него.
    g.web.get('/invoices/:id', function(request)
        return g.router.json({
            id = request.params.id,
            full = g.web.full_url('invoice', { id = request.params.id }),
            canonical = g.web.canonical(request),
        })
    end, { name = 'invoice', middleware = { g.web.signed() } })

    g.node = server()
    g.web.attach(g.node)
    g.node:start()

    upstream.address = address_of(g.node)
    at(NOW)
end)

g.after_each(function()
    g.proxy:stop()
    g.node:stop()
end)

--- Та же ссылка напрямую к узлу: без начала пути прокси.
---@param link string Полная ссылка через прокси
---@return string
local function direct(link)
    return address_of(g.node) .. link:sub(#g.public + 1)
end

g.test_signed_link_opens_behind_the_proxy_and_without_it = function()
    local link = g.web.signed_url('invoice', { id = 7 }, { expires = 60, full = true })

    t.assert_equals(link:sub(1, #g.public + 41), g.public .. '/invoices/7?expires=1700000060&signature=')

    local expected = { id = '7', full = g.public .. '/invoices/7', canonical = g.public .. '/invoices/7' }
    local proxied = asked('GET', link)

    t.assert_equals(proxied.status, 200)
    t.assert_equals(json.decode(proxied.body), expected)

    -- Напрямую, с чужим узлом в заголовках: полный адрес — из настройки,
    -- а не из того, что прислал клиент.
    local straight = asked('GET', direct(link), {
        host = 'evil.example',
        ['x-forwarded-host'] = 'evil.example',
        ['x-forwarded-proto'] = 'http',
    })

    t.assert_equals(straight.status, 200)
    t.assert_equals(json.decode(straight.body), expected)
end

g.test_changed_parameter_is_refused_behind_the_proxy_and_without_it = function()
    local link = g.web.signed_url('invoice', { id = 7 }, { expires = 60, full = true })
    local forged = link:gsub('/invoices/7', '/invoices/8')

    for _, where in ipairs({ forged, direct(forged) }) do
        local answer = asked('GET', where)

        t.assert_equals(answer.status, 403, where)
        t.assert_equals(json.decode(answer.body).error.code, 'router_signature_invalid', where)
    end
end

g.test_expired_link_is_refused_behind_the_proxy_and_without_it = function()
    local link = g.web.signed_url('invoice', { id = 7 }, { expires = 60, full = true })

    at(NOW + 61)

    for _, where in ipairs({ link, direct(link) }) do
        local answer = asked('GET', where)

        t.assert_equals(answer.status, 403, where)
        t.assert_equals(json.decode(answer.body).error.code, 'router_signature_expired', where)
        t.assert_equals(
            json.decode(answer.body).error.message,
            'срок действия ссылки истёк',
            where
        )
    end
end
