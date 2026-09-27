--- Тесты готовых ответов.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.response')

--- Готовые ответы.
---@return any
local function response()
    return helper.part('tnt.router.response')
end

g.test_data_go_out_as_json_with_the_encoding_named = function()
    local sent = response().json({ id = 7 })

    t.assert_equals(sent.status, 200)
    t.assert_equals(sent.headers, { ['content-type'] = 'application/json; charset=utf-8' })
    t.assert_equals(helper.decoded(sent), { id = 7 })
end

g.test_answer_about_a_created_thing_carries_its_own_code = function()
    t.assert_equals(response().json({ id = 7 }, 201).status, 201)
end

g.test_extra_headers_are_added_with_their_names_lowered = function()
    local sent = response().json({}, 200, { ['X-Request-Id'] = 'семь' })

    t.assert_equals(sent.headers['x-request-id'], 'семь')
    t.assert_equals(sent.headers['content-type'], 'application/json; charset=utf-8')
end

g.test_text_goes_out_as_text = function()
    local sent = response().text('готово')

    t.assert_equals(sent.headers, { ['content-type'] = 'text/plain; charset=utf-8' })
    t.assert_equals(sent.body, 'готово')
end

g.test_number_answered_as_text_becomes_a_string = function()
    -- Тело ответа — байты, и число в нём сервер не отправит.
    t.assert_equals(response().text(7, 202).body, '7')
    t.assert_equals(response().text(7, 202).status, 202)
end

g.test_page_goes_out_as_a_page = function()
    local sent = response().html('<h1>панель</h1>')

    t.assert_equals(sent.headers, { ['content-type'] = 'text/html; charset=utf-8' })
    t.assert_equals(sent.body, '<h1>панель</h1>')
end

g.test_nothing_to_show_has_neither_body_nor_content_type = function()
    t.assert_equals(response().no_content(), { status = 204, headers = {} })
end

g.test_nothing_to_show_still_carries_the_headers_it_was_given = function()
    t.assert_equals(response().no_content({ Location = '/customers/7' }), {
        status = 204,
        headers = { location = '/customers/7' },
    })
end

g.test_redirect_names_the_place_and_does_not_stay_forever = function()
    -- 302, а не 301: постоянное перенаправление браузер запоминает
    -- навсегда, и ошибка в нём чинится у каждого клиента по отдельности.
    t.assert_equals(response().redirect('/customers'), {
        status = 302,
        headers = { location = '/customers' },
        body = '',
    })
end

g.test_permanent_redirect_is_asked_for_out_loud = function()
    t.assert_equals(response().redirect('/customers', 308).status, 308)
end

g.test_redirect_to_nowhere_falls_where_it_is_written = function()
    t.assert_error_msg_contains('перенаправлению нужен адрес', function()
        response().redirect('')
    end)

    t.assert_error_msg_contains('перенаправлению нужен адрес', function()
        response().redirect(nil)
    end)
end

-- ── Поток ────────────────────────────────────────────────────────────

--- Сколько источник думает над каждым куском, секунд.
---
--- Круглое и не целое: длительность в отказавшей проверке читается
--- глазом, а сложение с половинками показывает, что кусков было столько,
--- сколько задумано.
local PAUSE = 2.5

--- Источник, отдающий заготовленные значения по одному, парами.
---@param steps table[] Что вернуть на каждый вызов: { кусок, отказ }
---@param clock table|nil Часы, которые источник двигает на `PAUSE` перед каждым ответом
---@return fun(): any, any
local function producing(steps, clock)
    local index = 0

    return function()
        index = index + 1

        if clock ~= nil then
            clock.advance(PAUSE)
        end

        local step = steps[index] or {}

        return step[1], step[2]
    end
end

--- Часы потока, которые двигает только проверка.
---@return table
local function clocked()
    local clock = helper.clock()

    response()._set_source({ monotonic = clock.monotonic })

    return clock
end

--- Контекст файбера — тот же экземпляр, что видит модуль ответов.
---@return any
local function context()
    return helper.part('tnt.context')
end

--- Обходит тело потока так же, как его обходит сервер.
local drained = helper.drained

g.test_stream_gives_out_its_pieces_in_order = function()
    local sent = response().stream(producing({ { 'один\n' }, { 'два\n' } }))

    t.assert_equals(sent.status, 200)
    t.assert_equals(sent.headers, { ['content-type'] = 'application/octet-stream' })
    t.assert_equals(drained(sent), { 'один\n', 'два\n' })
end

g.test_stream_carries_its_code_and_headers = function()
    local sent = response().stream(producing({}), 206, { ['Content-Type'] = 'application/x-ndjson' })

    t.assert_equals(sent.status, 206)
    t.assert_equals(sent.headers, { ['content-type'] = 'application/x-ndjson' })
    t.assert_equals(drained(sent), {})
end

g.test_empty_pieces_are_skipped_and_do_not_end_the_body = function()
    -- Пустой кусок сервер отправил бы завершающим, и остальное ушло бы
    -- клиенту началом следующего ответа.
    local sent = response().stream(producing({ { '' }, { 'а' }, { '' }, { '' }, { 'б' } }))

    t.assert_equals(drained(sent), { 'а', 'б' })
end

--- Обход собранного потока, который обязан оборваться: текст броска
--- и записи журнала.
---@param sent table Ответ потоком
---@return any thrown
---@return any records
local function cut(sent)
    local journal = helper.capture_log()

    journal.forget()

    local ok, thrown = pcall(drained, sent)

    t.assert_equals(ok, false)

    return thrown, journal.records()
end

--- Обход потока из источника, который обязан оборваться.
---@param produce fun(): any, any
---@return any thrown
---@return any records
local function broken(produce)
    return cut(response().stream(produce))
end

g.test_refusal_of_the_source_breaks_the_body_instead_of_ending_it = function()
    -- Кончившийся цикл сервер закрыл бы завершающим куском, и обрезанная
    -- выгрузка ушла бы клиенту целой. Бросок же рвёт соединение.
    local clock = clocked()
    local thrown, records =
        broken(producing({ { 'а' }, { nil, 'курсор потерян: token=hunter2' } }, clock))

    t.assert_equals(thrown, 'поток ответа оборван')
    t.assert_equals(#records, 1)
    t.assert_equals(records[1].level, 'error')
    t.assert_equals(records[1].module, 'tnt.router')
    t.assert_equals(records[1].record.message, 'поток ответа оборван')
    -- Сколько шёл и сколько успел отдать: два шага по PAUSE и одна
    -- кириллическая буква — два байта, а не один знак.
    t.assert_equals(records[1].record.fields, {
        reason = 'курсор потерян: token=[скрыто]',
        seconds = 2 * PAUSE,
        bytes = 2,
    })
end

g.test_thrown_source_breaks_the_body_and_its_text_stays_in_the_journal = function()
    local thrown, records = broken(function()
        error('таблицы нет', 0)
    end)

    t.assert_equals(thrown, 'поток ответа оборван')
    t.assert_equals(records[1].record.fields.reason, 'таблицы нет')
end

g.test_source_thrown_without_a_reason_still_breaks_the_body = function()
    local _, records = broken(function()
        error()
    end)

    t.assert_equals(records[1].record.fields.reason, 'nil')
end

g.test_piece_that_is_not_a_string_breaks_the_body = function()
    local _, records = broken(producing({ { 42 } }))

    t.assert_equals(records[1].record.fields.reason, 'кусок ответа не строка, а number')
end

g.test_piece_with_a_reason_attached_is_a_refusal = function()
    local _, records = broken(producing({ { '', 'не дочитано' } }))

    t.assert_equals(records[1].record.fields.reason, 'не дочитано')
end

g.test_stream_given_out_to_the_end_leaves_its_time_and_size = function()
    -- Запись слоя журнала кончается с возвратом обработчика, и выгрузка
    -- длиной в минуты числилась бы там запросом в микросекунды. Итог
    -- потока пишет фасад, по концу потока.
    local clock = clocked()
    local journal = helper.capture_log()

    journal.forget()

    local sent = response().stream(producing({ { 'один\n' }, { '' }, { 'два\n' } }, clock))

    -- Время идёт от сборки ответа: голову сервер пишет до первого куска,
    -- и медленный клиент задерживает уже её.
    clock.advance(1)

    t.assert_equals(drained(sent), { 'один\n', 'два\n' })

    local records = journal.records()

    t.assert_equals(#records, 1)
    t.assert_equals(records[1].level, 'info')
    t.assert_equals(records[1].module, 'tnt.router')
    t.assert_equals(records[1].record.message, 'поток ответа отдан')
    t.assert_equals(records[1].record.fields, { seconds = 1 + 4 * PAUSE, bytes = 16 })
end

g.test_empty_stream_is_given_out_with_nothing_sent = function()
    local journal = helper.capture_log()

    journal.forget()

    t.assert_equals(drained(response().stream(producing({}))), {})
    t.assert_equals(journal.records()[1].record.fields.bytes, 0)
end

g.test_source_and_its_outcome_speak_for_the_request_that_built_the_answer = function()
    -- Тело сервер обходит, когда слои входа уже вышли из своих областей:
    -- без снимка запись об обрыве не связать было бы с запросом.
    -- Счёт шагов — свой, а не длиной списка: без снимка в список легли бы
    -- пустоты, длина осталась бы нулём, и источник не кончился бы никогда.
    local calls = 0
    local seen = {}
    local sent = context().run({ request_id = 'r-7' }, function()
        return response().stream(function()
            calls = calls + 1
            seen[calls] = context().get('request_id') or 'нет'

            if calls > 1 then
                return nil, 'курсор потерян'
            end

            return 'а'
        end)
    end)

    local thrown, records = cut(sent)

    t.assert_equals(thrown, 'поток ответа оборван')
    t.assert_equals(seen, { 'r-7', 'r-7' })
    t.assert_equals(records[1].record.message, 'поток ответа оборван')
    t.assert_equals(records[1].record.request_id, 'r-7')
    -- Снимок стоит только на время шага: файбер соединения обслуживает
    -- следующий запрос keep-alive, и тот не должен унести чужой номер.
    t.assert_equals(context().get('request_id'), nil)
end

g.test_stream_given_out_to_the_end_names_its_request = function()
    local journal = helper.capture_log()

    journal.forget()

    local sent = context().run({ request_id = 'r-8' }, response().stream, producing({ { 'а' } }))

    t.assert_equals(drained(sent), { 'а' })
    t.assert_equals(journal.records()[1].record.message, 'поток ответа отдан')
    t.assert_equals(journal.records()[1].record.request_id, 'r-8')
end

g.test_stream_belongs_to_the_request_that_built_it_not_to_the_one_that_walks_it = function()
    -- Ответ, собранный вне запроса, не присваивает номер того, кто его
    -- обходит: снимок берётся при сборке.
    local seen = {}
    local sent = response().stream(function()
        table.insert(seen, context().get('request_id') or 'нет')

        return nil
    end)

    context().run({ request_id = 'r-9' }, drained, sent)

    t.assert_equals(seen, { 'нет' })
end

g.test_stream_needs_a_source = function()
    t.assert_error_msg_content_equals(
        'потоку ответа нужна функция, отдающая куски, а не table',
        function()
            response().stream({ 'а' })
        end
    )
end
