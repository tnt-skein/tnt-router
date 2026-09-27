--- Разбор многочастного тела: границы, заголовки частей, пределы.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.multipart')

--- Модуль разбора.
---@return table
local function multipart()
    return helper.part('tnt.router.multipart')
end

--- Метка границы, одна на все проверки.
local BOUNDARY = 'ГРАНИЦА-42'

--- Разделитель строк: им отделены и границы, и заголовки частей.
local CRLF = '\r\n'

--- Граница целиком — та, которую разбор ищет в теле.
local DELIMITER = CRLF .. '--' .. BOUNDARY

--- Собирает части, как их видит разбор.
---@return table seen Части по порядку: описание и собранное тело
---@return fun(part: table): table open
local function collecting()
    local seen = {}

    local function open(part)
        local chunks = {}
        local entry = { part = part, chunks = chunks, aborted = false }

        table.insert(seen, entry)

        return {
            write = function(chunk)
                table.insert(chunks, chunk)

                return true
            end,

            close = function()
                return true
            end,

            abort = function()
                entry.aborted = true
            end,
        }
    end

    return seen, open
end

--- Тело части, собранное из кусков.
---@param seen table
---@param index integer
---@return string
local function bodied(seen, index)
    return table.concat(seen[index].chunks)
end

--- Разбирает тело, поданное кусками.
---@param parts table[] Части для `helper.multipart`
---@param ... string Куски, на которые резать тело; без них — одним куском
---@return table seen
local function parsed(parts, ...)
    local body = helper.multipart(BOUNDARY, parts)
    local seen, open = collecting()
    local source = select('#', ...) > 0 and helper.sourced(...) or helper.sourced(body)
    local ok, failure = multipart().parse(source, BOUNDARY, 64, open)

    t.assert_equals({ ok, failure }, { true, nil })

    return seen
end

--- Отказ разбора: код и подробность.
---@param body string
---@param max_parts integer|nil
---@return table
local function refused(body, max_parts)
    local _, open = collecting()
    local ok, failure = multipart().parse(helper.sourced(body), BOUNDARY, max_parts or 64, open)

    t.assert_equals(ok, nil)

    return failure
end

--- Разбор тела, которое после первого куска кончилось отказом источника.
---@param first string Первый и последний кусок, который источник отдал
---@param torn table Отказ источника
---@return any ok
---@return any failure
local function torn_after(first, torn)
    local given = false
    local _, open = collecting()

    return multipart().parse(function()
        if given then
            return nil, torn
        end

        given = true

        return first
    end, BOUNDARY, 64, open)
end

g.test_content_type_comes_apart_into_kind_and_parameters = function()
    local kind, params = multipart().media('Multipart/Form-Data; Boundary=ABC; charset=UTF-8')

    t.assert_equals(kind, 'multipart/form-data')
    -- Имена параметров в нижнем регистре, значения — как прислали:
    -- имя файла регистр различает, имя параметра — нет.
    t.assert_equals(params, { boundary = 'ABC', charset = 'UTF-8' })
end

g.test_quoted_parameter_keeps_the_semicolon_inside = function()
    local _, params = multipart().media('form-data; name="a;b"; filename="отчёт \\"за год\\".pdf"')

    t.assert_equals(params.name, 'a;b')
    t.assert_equals(params.filename, 'отчёт "за год".pdf')
end

g.test_spaces_around_the_kind_and_parameters_are_dropped = function()
    local kind, params = multipart().media('  multipart/form-data ;  boundary = x  ')

    t.assert_equals(kind, 'multipart/form-data')
    t.assert_equals(params.boundary, 'x')
end

g.test_parameter_without_a_name_is_no_parameter = function()
    -- Имя параметра — хотя бы один знак: кусок, у которого его нет,
    -- в параметры не попадает вовсе.
    local _, params = multipart().media('form-data; =x; name=y')

    t.assert_equals(params, { name = 'y' })
end

g.test_parameter_without_a_space_after_the_semicolon_is_read_too = function()
    -- Пробел за точкой с запятой не обязателен, и клиенты его не ставят.
    local _, params = multipart().media('multipart/form-data;boundary=x')

    t.assert_equals(params, { boundary = 'x' })
end

g.test_value_that_is_all_parameters_has_no_kind = function()
    -- Вид снимается первым куском, а не читается обходом с двойки:
    -- значение, начинающееся с точки с запятой, вида не называет вовсе.
    local kind, params = multipart().media('; boundary=x')

    t.assert_equals(kind, '')
    t.assert_equals(params.boundary, 'x')
end

g.test_header_without_a_value_is_no_content_type_at_all = function()
    local kind, params = multipart().media(nil)

    t.assert_equals(kind, '')
    t.assert_equals(params, {})
end

g.test_boundary_is_demanded_by_the_body_that_cannot_be_split_without_it = function()
    t.assert_equals(multipart().boundary_of({ boundary = 'x' }), 'x')

    for _, params in ipairs({ {}, { boundary = '' } }) do
        local _, failure = multipart().boundary_of(params)

        t.assert_equals(failure, {
            status = 400,
            reason = 'в multipart/form-data нет метки границы',
        })
    end
end

g.test_fields_and_files_come_out_of_the_body_in_order = function()
    local seen = parsed({
        { name = 'title', body = 'отчёт' },
        { name = 'avatar', filename = 'ф.png', type = 'image/png', body = 'PNG\r\nданные' },
    })

    t.assert_equals(#seen, 2)
    t.assert_equals(seen[1].part, { name = 'title', filename = nil, type = '', charset = nil })
    t.assert_equals(bodied(seen, 1), 'отчёт')
    t.assert_equals(seen[2].part, {
        name = 'avatar',
        filename = 'ф.png',
        type = 'image/png',
        charset = nil,
    })
    -- Перевод строки внутри тела части — это её байты, а не граница.
    t.assert_equals(bodied(seen, 2), 'PNG\r\nданные')
end

g.test_colon_inside_the_header_value_stays_there = function()
    -- Строка заголовка делится по первому двоеточию и только по нему:
    -- в имени файла двоеточие — обычный знак.
    local body = table.concat({
        '--' .. BOUNDARY,
        'content-disposition: form-data; name="doc"; filename="отчёт: за год.pdf"',
        '',
        'x',
        '--' .. BOUNDARY .. '--',
        '',
    }, CRLF)

    local seen, open = collecting()

    t.assert_equals(multipart().parse(helper.sourced(body), BOUNDARY, 64, open), true)
    t.assert_equals(seen[1].part.filename, 'отчёт: за год.pdf')
end

g.test_charset_of_the_part_reaches_the_sink = function()
    local body = table.concat({
        '--' .. BOUNDARY,
        'content-disposition: form-data; name="note"',
        'content-type: text/plain; charset=koi8-r',
        '',
        'текст',
        '--' .. BOUNDARY .. '--',
        '',
    }, '\r\n')

    local seen, open = collecting()

    t.assert_equals(multipart().parse(helper.sourced(body), BOUNDARY, 64, open), true)
    t.assert_equals(seen[1].part.charset, 'koi8-r')
    t.assert_equals(seen[1].part.type, 'text/plain')
end

g.test_body_cut_between_chunks_is_parsed_as_one = function()
    -- Граница, разрезанная на два куска, — обычное дело для сокета:
    -- хвост короче границы приёмнику не отдаётся, а ждёт продолжения.
    local body = helper.multipart(BOUNDARY, { { name = 'title', body = 'отчёт за год' } })

    for _, at in ipairs({ 1, 7, #body - 9, #body - 1 }) do
        local seen =
            parsed({ { name = 'title', body = 'отчёт за год' } }, body:sub(-#body, at), body:sub(at + 1))

        t.assert_equals(bodied(seen, 1), 'отчёт за год')
    end
end

--- Куски, доставшиеся приёмнику, когда тело разрезано после `taken`
--- байтов значения.
---@param taken integer
---@return string[]
local function chunked_at(taken)
    local value = string.rep('x', 100)
    local body = helper.multipart(BOUNDARY, { { name = 'a', body = value } })
    local at = body:find(value, 1, true) + taken - 1
    local seen, open = collecting()

    t.assert_equals(multipart().parse(helper.sourced(body:sub(-#body, at), body:sub(at + 1)), BOUNDARY, 64, open), true)

    return seen[1].chunks
end

g.test_pieces_given_to_the_sink_stop_short_of_the_boundary = function()
    -- Приёмнику уходит всё, кроме хвоста длиной с границу без одного
    -- знака: он ещё может оказаться её началом, разрезанным на два куска.
    t.assert_equals(chunked_at(30), { string.rep('x', 30 - #DELIMITER + 1), string.rep('x', 70 + #DELIMITER - 1) })
    -- Ровно граница: приёмнику уходит один байт.
    t.assert_equals(chunked_at(#DELIMITER), { 'x', string.rep('x', 99) })
    -- Меньше границы: приёмнику не уходит ничего, даже пустого куска.
    t.assert_equals(chunked_at(#DELIMITER - 1), { string.rep('x', 100) })
end

g.test_body_given_byte_by_byte_is_parsed_as_one = function()
    local body = helper.multipart(BOUNDARY, { { name = 'a', body = 'значение' } })
    local index = 0
    local seen, open = collecting()

    -- По байту за раз: так тело приходит от капельного клиента.
    local ok = multipart().parse(function()
        index = index + 1

        return body:sub(index, index)
    end, BOUNDARY, 64, open)

    t.assert_equals(ok, true)
    t.assert_equals(bodied(seen, 1), 'значение')
end

g.test_body_that_ends_right_after_the_closing_boundary_is_whole = function()
    -- Эпилога и завершающего конца строки в теле может не быть вовсе:
    -- тело кончается на самой закрывающей границе.
    local body = helper.multipart(BOUNDARY, { { name = 'a', body = 'значение' } })
    local seen, open = collecting()
    local cut = body:sub(-#body, #body - #CRLF)

    t.assert_equals(multipart().parse(helper.sourced(cut), BOUNDARY, 64, open), true)
    t.assert_equals(bodied(seen, 1), 'значение')
end

g.test_failure_of_the_source_at_the_boundary_keeps_its_own_words = function()
    local torn = { status = 408, reason = 'на границе оборвалось' }
    local body = helper.multipart(BOUNDARY, { { name = 'a', body = 'x' } })
    -- Кусок кончается ровно закрывающей границей: за ней разбор ждёт
    -- ещё два знака, и вместо них приходит отказ.
    local at = body:find(DELIMITER .. '--', 1, true) + #DELIMITER - 1

    -- Отказ источника доезжает как есть: 408 обрыва не должен стать 400
    -- «тело оборвалось на границе».
    t.assert_equals({ torn_after(body:sub(-#body, at), torn) }, { nil, torn })
end

g.test_preamble_and_epilogue_are_read_and_dropped = function()
    local body = 'пояснение для старых клиентов\r\n'
        .. helper.multipart(BOUNDARY, { { name = 'title', body = 'отчёт' } })
        .. 'хвост, которого в форме быть не должно'

    local seen, open = collecting()

    t.assert_equals(multipart().parse(helper.sourced(body), BOUNDARY, 64, open), true)
    t.assert_equals(#seen, 1)
    t.assert_equals(bodied(seen, 1), 'отчёт')
end

g.test_broken_part_line_is_skipped_and_the_part_is_parsed = function()
    local body = table.concat({
        '--' .. BOUNDARY,
        'складка продолжения, которой в форме не бывает',
        'content-disposition: form-data; name="title"',
        '',
        'отчёт',
        '--' .. BOUNDARY .. '--',
        '',
    }, '\r\n')

    local seen, open = collecting()

    t.assert_equals(multipart().parse(helper.sourced(body), BOUNDARY, 64, open), true)
    t.assert_equals(seen[1].part.name, 'title')
end

g.test_body_without_a_boundary_is_refused = function()
    t.assert_equals(refused('просто текст без единой границы'), {
        status = 400,
        reason = 'границы нет в теле вовсе',
    })
end

g.test_part_cut_before_the_next_boundary_is_refused = function()
    local body = '--' .. BOUNDARY .. '\r\ncontent-disposition: form-data; name="a"\r\n\r\nначало'

    t.assert_equals(refused(body), { status = 400, reason = 'часть оборвалась до границы' })
end

g.test_part_cut_before_its_boundary_is_abandoned_and_whole_ones_are_not = function()
    -- До `close` оборванная часть не доходит, и без `abort` её
    -- недописанный временный файл остался бы в каталоге навсегда.
    local body = helper.multipart(BOUNDARY, { { name = 'a', body = 'целое' } })
    local cut = body:sub(-#body, #body - #('--' .. CRLF))
        .. CRLF
        .. 'content-disposition: form-data; name="b"\r\n\r\nначало'
    local seen, open = collecting()
    local ok, failure = multipart().parse(helper.sourced(cut), BOUNDARY, 64, open)

    t.assert_equals(
        { ok, failure },
        { nil, { status = 400, reason = 'часть оборвалась до границы' } }
    )
    t.assert_equals({ seen[1].aborted, seen[2].aborted }, { false, true })

    -- Целое тело не бросает ни одной части.
    local whole, all = collecting()

    t.assert_equals(multipart().parse(helper.sourced(body), BOUNDARY, 64, all), true)
    t.assert_equals(whole[1].aborted, false)
end

g.test_part_without_the_end_of_headers_is_refused = function()
    local body = '--' .. BOUNDARY .. '\r\ncontent-disposition: form-data; name="a"\r\n'

    t.assert_equals(refused(body), { status = 400, reason = 'часть без конца заголовков' })
end

g.test_body_cut_right_after_the_boundary_is_refused = function()
    t.assert_equals(
        refused('--' .. BOUNDARY),
        { status = 400, reason = 'тело оборвалось на границе' }
    )
end

g.test_rubbish_after_the_boundary_is_refused = function()
    local body = '--'
        .. BOUNDARY
        .. ' \r\ncontent-disposition: form-data; name="a"\r\n\r\nx\r\n--'
        .. BOUNDARY
        .. '--\r\n'

    t.assert_equals(refused(body), {
        status = 400,
        -- `%q` пишет управляющий байт числом: в подробности для журнала
        -- он так и останется, зато не разорвёт строку записи.
        reason = 'за границей стоит " \\13", а не конец части',
    })
end

g.test_part_without_form_data_disposition_is_refused = function()
    local body = table.concat({
        '--' .. BOUNDARY,
        'content-disposition: attachment; name="a"',
        '',
        'x',
        '--' .. BOUNDARY .. '--',
        '',
    }, '\r\n')

    t.assert_equals(refused(body), {
        status = 400,
        reason = 'часть без «Content-Disposition: form-data», а с "attachment"',
    })
end

g.test_part_without_a_field_name_is_refused = function()
    local body = table.concat({
        '--' .. BOUNDARY,
        'content-disposition: form-data',
        '',
        'x',
        '--' .. BOUNDARY .. '--',
        '',
    }, '\r\n')

    t.assert_equals(refused(body), { status = 400, reason = 'часть без имени поля' })
end

g.test_encoded_part_is_refused_instead_of_being_taken_for_bytes = function()
    local body = table.concat({
        '--' .. BOUNDARY,
        'content-disposition: form-data; name="a"; filename="a.png"',
        'Content-Transfer-Encoding: Base64',
        '',
        'UE5H',
        '--' .. BOUNDARY .. '--',
        '',
    }, '\r\n')

    t.assert_equals(refused(body), {
        status = 400,
        reason = 'часть закодирована "base64", а такое в форме не принимается',
    })
end

g.test_plain_encodings_are_taken_as_bytes = function()
    for _, encoding in ipairs({ 'binary', '7bit', '8bit' }) do
        local body = table.concat({
            '--' .. BOUNDARY,
            'content-disposition: form-data; name="a"',
            'content-transfer-encoding: ' .. encoding,
            '',
            'x',
            '--' .. BOUNDARY .. '--',
            '',
        }, '\r\n')

        local seen, open = collecting()

        t.assert_equals(multipart().parse(helper.sourced(body), BOUNDARY, 64, open), true)
        t.assert_equals(bodied(seen, 1), 'x')
    end
end

g.test_parts_over_the_limit_are_refused = function()
    local body = helper.multipart(BOUNDARY, {
        { name = 'a', body = '1' },
        { name = 'b', body = '2' },
        { name = 'c', body = '3' },
    })

    t.assert_equals(
        refused(body, 2),
        { status = 413, reason = 'частей в теле больше предела в 2' }
    )

    -- Ровно предел проходит: отказ начинается со следующей части.
    local _, open = collecting()

    t.assert_equals(multipart().parse(helper.sourced(body), BOUNDARY, 3, open), true)
end

--- Тело, у которого блок заголовков части ровно в нужное число байт.
---
--- В блок входит и пустая первая строка — тот конец строки, что стоит
--- за границей.
---@param size integer
---@return string
local function with_headers(size)
    local line = 'content-disposition: form-data; name="%s"'
    local padding = size - #CRLF - #line:format('')

    return table.concat({
        '--' .. BOUNDARY,
        line:format(string.rep('a', padding)),
        '',
        'x',
        '--' .. BOUNDARY .. '--',
        '',
    }, CRLF)
end

g.test_headers_of_a_part_have_their_own_limit = function()
    local seen, open = collecting()

    -- Ровно предел проходит.
    t.assert_equals(multipart().parse(helper.sourced(with_headers(8192)), BOUNDARY, 64, open), true)
    t.assert_equals(#seen[1].part.name, 8192 - #CRLF - #'content-disposition: form-data; name=""')

    -- А байтом больше — отказ.
    t.assert_equals(refused(with_headers(8193)), {
        status = 413,
        reason = 'заголовки части больше 8192 байт',
    })
end

g.test_failure_of_the_source_stops_the_parse = function()
    local torn = { status = 408, reason = 'тело пришло не целиком' }
    local head = '--' .. BOUNDARY .. CRLF .. 'content-disposition: form-data; name="a"' .. CRLF .. CRLF

    -- Отказ источника доезжает как есть: 408 обрыва не должен стать 400
    -- битого тела.
    t.assert_equals({ torn_after(head .. 'начало', torn) }, { nil, torn })
end

g.test_failure_of_the_source_in_the_epilogue_stops_the_parse = function()
    local torn = { status = 408, reason = 'эпилог не дочитан' }
    local body = helper.multipart(BOUNDARY, { { name = 'a', body = 'x' } })

    t.assert_equals({ torn_after(body, torn) }, { nil, torn })
end

g.test_refusal_of_the_sink_stops_the_parse = function()
    local body = helper.multipart(BOUNDARY, { { name = 'a', body = 'слишком длинное значение' } })
    local full = { status = 413, reason = 'поле больше предела' }

    --- Приёмник, отказывающий на названном действии.
    ---@param at string
    ---@return fun(part: table): table|nil, table|nil
    local function failing(at)
        return function()
            if at == 'open' then
                return nil, full
            end

            return {
                write = function()
                    return at ~= 'write', at == 'write' and full or nil
                end,

                close = function()
                    return at ~= 'close', at == 'close' and full or nil
                end,

                abort = function() end,
            }
        end
    end

    for _, at in ipairs({ 'open', 'write', 'close' }) do
        local ok, failure = multipart().parse(helper.sourced(body), BOUNDARY, 64, failing(at))

        t.assert_equals({ ok, failure }, { nil, full }, at)
    end

    -- Тело, пришедшее кусками, отдаётся приёмнику до того, как граница
    -- нашлась: отказ на таком куске кончает разбор так же. Кусок режется
    -- посреди длинного значения — так, чтобы в буфере оказалось больше
    -- байтов, чем длина границы, и приёмнику досталась их часть.
    local value = string.rep('x', 100)
    local long = helper.multipart(BOUNDARY, { { name = 'a', body = value } })
    local at = long:find(value, 1, true) + 40
    local ok, failure =
        multipart().parse(helper.sourced(long:sub(-#long, at), long:sub(at + 1)), BOUNDARY, 64, failing('write'))

    t.assert_equals({ ok, failure }, { nil, full })
end
