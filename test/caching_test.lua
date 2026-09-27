--- Тесты кэша раздачи: метка, время правки, срок жизни копии.
---
--- Раздача проверяется запросом целиком (`files_test`), а здесь —
--- договор самого модуля: он отвечает `true` либо `false`, а не «что-то
--- ложное». Пустота вместо `false` неотличима в развилке, но в договоре
--- это разные вещи: по ней нельзя отличить «копия устарела» от «спросить
--- было нечем», и первый же вызывающий, сравнивший ответ с `false`,
--- получил бы не то, что ждал.

local t = require('luatest')

local date = require('tnt.date')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.files.caching')

--- Кэш раздачи.
---@return any
local function caching()
    return helper.part('tnt.router.files.caching')
end

--- Время правки образца и оно же HTTP-датой.
local CHANGED_AT = 1789869592

--- Настройки раздачи в той части, что нужна кэшу.
---@param overrides table|nil
---@return table
local function settings(overrides)
    local built = { cache = 'no-cache', immutable = false, fingerprint = caching().FINGERPRINT }

    for name, value in pairs(overrides or {}) do
        built[name] = value
    end

    return built
end

g.test_the_mark_is_matched_or_not_and_the_answer_is_always_a_boolean = function()
    t.assert_equals(caching().matched('"своя"', '"своя"'), true)
    t.assert_equals(caching().matched('*', '"своя"'), true)
    t.assert_equals(caching().matched('W/"своя"', '"своя"'), true)
    t.assert_equals(caching().matched('"чужая", "своя"', '"своя"'), true)
    t.assert_equals(caching().matched('"чужая"', '"своя"'), false)
    t.assert_equals(caching().matched('', '"своя"'), false)
end

g.test_the_time_of_change_is_compared_and_the_answer_is_always_a_boolean = function()
    local named = date.http(CHANGED_AT)

    -- Копия не старше файла — 304; копия старше — 200 с телом.
    t.assert_equals(caching().unchanged_since(named, CHANGED_AT), true)
    t.assert_equals(caching().unchanged_since(named, CHANGED_AT - 10), true)
    t.assert_equals(caching().unchanged_since(named, CHANGED_AT + 1), false)

    -- Заголовка нет, дата не разобрана, времени правки нет вовсе —
    -- свежести не подтвердить, и это `false`, а не пустота.
    t.assert_equals(caching().unchanged_since(nil, CHANGED_AT), false)
    t.assert_equals(caching().unchanged_since('вчера', CHANGED_AT), false)
    t.assert_equals(caching().unchanged_since(named, nil), false)
end

g.test_freshness_asks_the_mark_first_and_the_time_after_it = function()
    local file = { tag = '"своя"', modified = CHANGED_AT }
    local named = date.http(CHANGED_AT)

    t.assert_equals(caching().fresh({ headers = { ['if-none-match'] = '"своя"' } }, file), true)

    -- Метка главнее времени: пришла чужая метка — время не спрашивают.
    t.assert_equals(
        caching().fresh({ headers = { ['if-none-match'] = '"чужая"', ['if-modified-since'] = named } }, file),
        false
    )

    t.assert_equals(caching().fresh({ headers = { ['if-modified-since'] = named } }, file), true)
    t.assert_equals(caching().fresh({ headers = {} }, file), false)
end

g.test_a_fingerprint_is_eight_or_more_letters_and_digits_of_base64url = function()
    local pattern = caching().FINGERPRINT

    -- Ровно восемь знаков — уже отпечаток, семь — ещё нет.
    t.assert_equals(caching().fingerprinted('app-BX7Yy2Qk.css', pattern), true)
    t.assert_equals(caching().fingerprinted('app-BX7Yy2Q.css', pattern), false)

    -- Длиннее восьми — тоже отпечаток: сборщики берут и по двенадцать.
    t.assert_equals(caching().fingerprinted('app-BX7Yy2Qk9fc1.css', pattern), true)

    -- Точка вместо черты — тот же отпечаток: сборщики пишут и так.
    t.assert_equals(caching().fingerprinted('app.9f1c2ad3.js', pattern), true)

    -- Черта и подчёркивание входят в азбуку base64url, и отпечаток
    -- с ними внутри остаётся отпечатком целиком.
    t.assert_equals(caching().fingerprinted('app-BX7-Yy2Qk9.css', pattern), true)
    t.assert_equals(caching().fingerprinted('app-BX7_Yy2Qk9.css', pattern), true)

    -- Имя без расширения отпечатка не несёт: точка в конце расширения
    -- не называет.
    t.assert_equals(caching().fingerprinted('app-BX7Yy2Qk.', pattern), false)
    t.assert_equals(caching().fingerprinted('app-BX7Yy2Qk', pattern), false)

    -- Слово подходящей длины без черты и точки перед ним — не отпечаток.
    t.assert_equals(caching().fingerprinted('bootstrap.css', pattern), false)
end

g.test_the_forever_cache_is_given_only_to_a_fingerprinted_name = function()
    local forever = caching().IMMUTABLE

    t.assert_equals(forever, 'public, max-age=31536000, immutable')
    t.assert_equals(caching().control(settings({ immutable = true }), 'app-BX7Yy2Qk.css'), forever)
    t.assert_equals(caching().control(settings({ immutable = true }), 'app.css'), 'no-cache')
    t.assert_equals(caching().control(settings(), 'app-BX7Yy2Qk.css'), 'no-cache')
    t.assert_equals(caching().control(settings({ cache = 'max-age=60' }), 'app.css'), 'max-age=60')
end

g.test_the_headers_of_an_answer_carry_the_mark_the_time_and_the_term = function()
    local file = { tag = '"своя"', modified = CHANGED_AT }

    t.assert_equals(caching().headers(settings(), file, 'app.css'), {
        etag = '"своя"',
        ['cache-control'] = 'no-cache',
        ['last-modified'] = date.http(CHANGED_AT),
    })

    -- У файла из памяти процесса времени правки нет, и заголовка тоже.
    t.assert_equals(caching().headers(settings(), { tag = '"своя"' }, 'app.css'), {
        etag = '"своя"',
        ['cache-control'] = 'no-cache',
    })
end
