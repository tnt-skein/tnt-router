--- Тесты отказов роутера: что уходит наружу и чего там быть не должно.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.errors')

--- Отказы роутера.
---@return any
local function errors()
    return helper.part('tnt.router.errors')
end

--- Опознаватель, собранный из заданных байтов случайности.
---
--- Запрошенное число байтов запоминается: код обязан взять ровно восемь,
--- и лишний байт, отброшенный молча, иначе не заметить.
---@param bytes string
---@return string incident
---@return integer asked Сколько байтов попросили
local function incident_of(bytes)
    local asked = 0

    errors()._set_source({
        random = function(count)
            asked = count

            return bytes
        end,
    })

    return errors().incident(), asked
end

g.test_incident_is_spelled_from_randomness_of_the_outside_world = function()
    -- Байты 0, 1, 2 … подряд дают первые знаки азбуки подряд: видно, что
    -- ни один байт не потерян и не сдвинут, а группы — по четыре через дефис.
    t.assert_equals({ incident_of('\0\1\2\3\4\5\6\7') }, { '0123-4567', 8 })
    t.assert_equals(incident_of('\26\27\28\29\30\31\10\11'), 'TVWX-YZAB')
end

g.test_incident_takes_five_low_bits_of_every_byte = function()
    -- Байтов 256, знаков 32: на каждый знак приходится ровно восемь
    -- значений байта, и старшие биты знака не меняют.
    t.assert_equals(incident_of('\32\33\64\255\224\191\127\63'), '010Z-0ZZZ')
end

g.test_incident_is_readable_aloud_and_different_every_time = function()
    -- Без подмены: проверить надо настоящую случайность ядра. Один
    -- опознаватель на два происшествия склеил бы в журнале два разных
    -- запроса, а знаков `I`, `L`, `O` и `U` в азбуке нет — их путают вслух.
    local first = errors().incident()
    local second = errors().incident()
    local letter = '[0-9A-HJKMNP-TV-Z]'

    t.assert_str_matches(first, letter:rep(4) .. '%-' .. letter:rep(4))
    t.assert_str_matches(second, letter:rep(4) .. '%-' .. letter:rep(4))
    t.assert_not_equals(first, second)
end

g.test_missing_address_is_answered_with_a_settled_phrase = function()
    local sent = errors().respond({ status = 404, incident = 'семь' })

    t.assert_equals(sent.status, 404)
    t.assert_equals(sent.headers, { ['content-type'] = 'application/json; charset=utf-8' })
    t.assert_equals(helper.decoded(sent), {
        error = { status = 404, message = 'нет такого адреса', incident = 'семь' },
    })
end

g.test_wrong_method_names_the_right_ones_in_a_header = function()
    -- Заголовок Allow при 405 обязателен по RFC 9110: без него клиент
    -- знает только, что так нельзя, и не знает, как можно. Едет он
    -- в самом отказе, а не собирается здесь: собрать ответ может и чужой
    -- обработчик, и тогда собранное здесь до клиента не доедет.
    local sent = errors().respond({
        status = 405,
        incident = 'семь',
        headers = { allow = 'GET, HEAD' },
    })

    t.assert_equals(sent.headers.allow, 'GET, HEAD')
    -- Подпись ответа перебить нечем: тело собрано здесь, и описывает
    -- его подпись отсюда же.
    t.assert_equals(sent.headers['content-type'], 'application/json; charset=utf-8')
    t.assert_equals(
        helper.decoded(sent).error.message,
        'этот способ здесь не поддерживается'
    )
end

g.test_a_word_given_with_the_failure_is_said_instead_of_the_settled_one = function()
    -- Слово кладёт сам роутер, по статусу; но отказ, собранный не им,
    -- вправе сказать своё, и переписывать его здесь нечем.
    local sent = errors().respond({ status = 404, message = 'панели тут нет', incident = 'семь' })

    t.assert_equals(helper.decoded(sent).error.message, 'панели тут нет')
end

g.test_the_word_of_a_status_is_asked_by_its_number = function()
    t.assert_equals(errors().message_of(400), 'запрос не разобран')
    t.assert_equals(errors().message_of(404), 'нет такого адреса')
    t.assert_equals(errors().message_of(405), 'этот способ здесь не поддерживается')
    t.assert_equals(errors().message_of(408), 'тело запроса не пришло вовремя')
    t.assert_equals(
        errors().message_of(411),
        'запросу с телом нужен заголовок Content-Length'
    )
    t.assert_equals(errors().message_of(413), 'тело запроса слишком велико')
    t.assert_equals(errors().message_of(500), 'внутренняя ошибка')
    -- Незнакомый статус описывается поломкой: код не из своих означает,
    -- что отказ собрал не роутер.
    t.assert_equals(errors().message_of(418), 'внутренняя ошибка')
end

g.test_internal_failure_says_nothing_about_the_inside = function()
    local sent = errors().respond({
        status = 500,
        incident = 'семь',
        reason = 'attempt to index a nil value (field ~customers~)',
    })

    t.assert_equals(helper.decoded(sent), {
        error = { status = 500, message = 'внутренняя ошибка', incident = 'семь' },
    })
    t.assert_equals(sent.body:find('nil value', 1, true), nil)
end

g.test_unparsed_request_is_answered_with_its_own_phrase = function()
    t.assert_equals(
        helper.decoded(errors().respond({ status = 400, incident = 'с' })).error.message,
        'запрос не разобран'
    )
end

g.test_unknown_code_is_answered_as_an_internal_failure = function()
    -- Код, о котором роутеру нечего сказать, не повод придумывать текст.
    local sent = errors().respond({ status = 418, incident = 'семь' })

    t.assert_equals(sent.status, 418)
    t.assert_equals(helper.decoded(sent).error.message, 'внутренняя ошибка')
end

g.test_a_table_with_a_status_of_a_refusal_is_read_as_one = function()
    -- Договор границы HTTP: признак один и он явный — число в `status`.
    local read = errors().refusal_of({
        status = 410,
        message = 'клиента больше нет',
        code = 'customer.gone',
        incident = 'ЧУЖОЙ-1',
        headers = { ['retry-after'] = '3600' },
    })

    t.assert_equals(read.status, 410)
    t.assert_equals(read.message, 'клиента больше нет')
    t.assert_equals(read.code, 'customer.gone')
    t.assert_equals(read.incident, 'ЧУЖОЙ-1')
    t.assert_equals(read.headers, { ['retry-after'] = '3600' })
end

g.test_the_edges_of_the_range_of_refusals_are_refusals_too = function()
    -- Отказ — это 4xx и 5xx. Успешный ответ отказом не считается: принять
    -- его за отказ значило бы молча превратить промах вызывающего
    -- в готовый ответ клиенту.
    t.assert_not_equals(errors().refusal_of({ status = 400 }), nil)
    t.assert_not_equals(errors().refusal_of({ status = 599 }), nil)
    t.assert_equals(errors().refusal_of({ status = 399 }), nil)
    t.assert_equals(errors().refusal_of({ status = 600 }), nil)
end

g.test_anything_that_did_not_name_a_status_is_not_a_refusal = function()
    t.assert_equals(errors().refusal_of('хранилище молчит'), nil)
    t.assert_equals(errors().refusal_of(nil), nil)
    t.assert_equals(errors().refusal_of(404), nil)
    t.assert_equals(errors().refusal_of({ code = 'STORAGE_DOWN' }), nil)
    t.assert_equals(errors().refusal_of({ status = 'ok' }), nil)
    t.assert_equals(errors().refusal_of({ status = 404.5 }), nil)
end

g.test_a_word_of_the_wrong_kind_is_left_behind = function()
    -- Таблица на месте слова уехала бы клиенту как есть, а сказать
    -- человеку ей нечего.
    local read = errors().refusal_of({ status = 404, message = { 'нет' }, code = 42 })

    t.assert_equals(read.message, nil)
    t.assert_equals(read.code, nil)
    -- Своё слово роутер скажет сам, по статусу.
    t.assert_equals(helper.decoded(errors().respond(read)).error.message, 'нет такого адреса')
end

g.test_the_cause_stays_with_the_failure_and_not_in_the_answer = function()
    local cause = { status = 503, message = 'хранилище занято' }
    local read = errors().refusal_of(cause)

    t.assert_equals(read.reason, cause)
    t.assert_equals(errors().respond(read).body:find('reason', 1, true), nil)
end

g.test_last_resort_carries_the_incident_and_nothing_else = function()
    local sent = errors().last_resort('семь')

    t.assert_equals(sent.status, 500)
    t.assert_equals(sent.headers, { ['content-type'] = 'application/json; charset=utf-8' })
    t.assert_equals(sent.body, '{"error":{"status":500,"incident":"семь"}}')
end
