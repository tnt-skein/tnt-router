--- Форма из тела запроса: поля, присланные файлы, пределы и уборка.

local t = require('luatest')

local fio = require('fio')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.form')

--- Модуль формы.
---@return table
local function form()
    return helper.part('tnt.router.form')
end

--- Модуль запроса: у него живут проверенные пределы.
---@return table
local function request()
    return helper.part('tnt.router.request')
end

--- Метка границы, одна на все проверки.
local BOUNDARY = 'ГРАНИЦА-42'

g.before_each(function()
    g.root = fio.tempdir()
end)

g.after_each(function()
    fio.rmtree(g.root)
end)

--- Пределы проверки: временные файлы ложатся в свой каталог.
---@param opts table|nil
---@return table
local function limits(opts)
    local given = { temp_dir = g.root }

    for name, value in pairs(opts or {}) do
        given[name] = value
    end

    return request().limits(given)
end

--- Запрос с телом названного вида.
---@param kind string Значение заголовка `Content-Type`
---@param body string
---@return table
local function sent(kind, body)
    return { headers = { ['content-type'] = kind }, body = body }
end

--- Запрос с многочастным телом из описанных частей.
---@param parts table[]
---@return table
local function posted(parts)
    return sent('multipart/form-data; boundary=' .. BOUNDARY, helper.multipart(BOUNDARY, parts))
end

--- Разобранная форма; отказа быть не должно.
---@param input table
---@param opts table|nil Пределы
---@return table
local function parsed(input, opts)
    local ready, failure = form().of(input, limits(opts))

    t.assert_equals(failure, nil)

    return ready
end

--- Отказ разбора формы.
---@param input table
---@param opts table|nil Пределы
---@return table
local function refused(input, opts)
    local ready, failure = form().of(input, limits(opts))

    -- Форма всё равно есть, просто пустая: обработчик до неё не дойдёт,
    -- а слой входа не должен спотыкаться о `nil`.
    t.assert_equals(ready, { fields = {}, files = {} })
    t.assert_not_equals(failure, nil)

    return failure
end

g.test_pairs_come_apart_with_percent_and_plus = function()
    t.assert_equals(form().pairs_of('name=%D1%84&city=Нижний+Новгород'), {
        name = 'ф',
        city = 'Нижний Новгород',
    })

    -- Повторённое имя — список, пустое имя — не поле вовсе.
    t.assert_equals(form().pairs_of('tag=a&tag=b&tag=c&=x&&y='), {
        tag = { 'a', 'b', 'c' },
        y = '',
    })
end

g.test_query_has_no_limits_of_its_own = function()
    local many = {}

    for index = 1, 1000 do
        table.insert(many, ('n%d=%d'):format(index, index))
    end

    local fields = form().pairs_of(table.concat(many, '&'))

    t.assert_equals(fields.n1000, '1000')
end

g.test_browser_form_becomes_fields = function()
    local ready = parsed(sent('application/x-www-form-urlencoded', 'name=Иван&tag=a&tag=b'))

    t.assert_equals(ready.fields, { name = 'Иван', tag = { 'a', 'b' } })
    t.assert_equals(ready.files, {})
end

g.test_browser_form_with_a_charset_is_still_a_form = function()
    -- Браузер дописывает к виду параметры, и вид от этого не меняется.
    local ready = parsed(sent('application/x-www-form-urlencoded; charset=UTF-8', 'name=Иван'))

    t.assert_equals(ready.fields, { name = 'Иван' })
end

g.test_form_over_the_number_of_fields_is_refused = function()
    local failure = refused(sent('application/x-www-form-urlencoded', 'a=1&b=2&c=3'), { max_fields = 2 })

    t.assert_equals(failure, { status = 413, reason = 'полей в форме больше предела в 2' })

    -- Ровно предел проходит.
    t.assert_equals(
        parsed(sent('application/x-www-form-urlencoded', 'a=1&b=2'), { max_fields = 2 }).fields,
        { a = '1', b = '2' }
    )
end

g.test_field_exactly_at_its_size_passes = function()
    -- Считается пара целиком: имя, знак равенства и значение.
    local pair = 'a=' .. string.rep('x', 14)

    t.assert_equals(
        parsed(sent('application/x-www-form-urlencoded', pair), { max_field_size = 16 }).fields.a,
        string.rep('x', 14)
    )
end

g.test_field_over_its_size_is_refused = function()
    local failure =
        refused(sent('application/x-www-form-urlencoded', 'a=' .. string.rep('x', 20)), { max_field_size = 16 })

    t.assert_equals(
        failure,
        { status = 413, reason = 'поле формы больше предела в 16 байт' }
    )
end

g.test_text_part_exactly_at_its_size_passes = function()
    local value = string.rep('x', 16)

    t.assert_equals(parsed(posted({ { name = 'note', body = value } }), { max_field_size = 16 }).fields.note, value)
end

g.test_files_exactly_at_their_number_pass = function()
    local ready = parsed(
        posted({
            { name = 'a', filename = 'a.png', body = '1' },
            { name = 'b', filename = 'b.png', body = '2' },
        }),
        { max_files = 2 }
    )

    t.assert_equals(ready.files.a.size, 1)
    t.assert_equals(ready.files.b.size, 1)
end

g.test_chosen_file_is_a_file_even_when_it_is_empty_or_nameless = function()
    -- Пропускается только часть, у которой и имени нет, и тела нет:
    -- пустой выбранный файл — это файл, и решать за приложение,
    -- что с ним делать, роутеру не по чину.
    local ready = parsed(posted({
        { name = 'empty', filename = 'пустой.txt', body = '' },
        { name = 'nameless', filename = '', body = 'байты' },
    }))

    t.assert_equals(ready.files.empty.size, 0)
    t.assert_equals(ready.files.empty.client_name, 'пустой.txt')
    t.assert_equals(ready.files.nameless.size, #'байты')
    -- Имени клиент не назвал — безопасное имя всё равно есть.
    t.assert_equals(ready.files.nameless.name, 'file')
end

g.test_body_that_is_not_a_form_stays_a_body = function()
    -- Тело JSON разбирать по догадке нельзя: однажды оно окажется формой,
    -- которой не было.
    t.assert_equals(parsed(sent('application/json', '{"name":"Иван"}')), {
        fields = {},
        files = {},
    })

    t.assert_equals(parsed({ headers = {} }), { fields = {}, files = {} })
end

g.test_form_written_by_hand_passes_through = function()
    local file = { field = 'avatar', name = 'кот.png' }
    local ready = parsed({ headers = {}, form = { name = 'Иван' }, files = { avatar = file } })

    t.assert_equals(ready.fields, { name = 'Иван' })
    t.assert_is(ready.files.avatar, file)

    -- Форма без файлов — тоже форма.
    t.assert_equals(parsed({ headers = {}, form = { name = 'Иван' } }).files, {})
end

g.test_multipart_body_becomes_fields_and_files = function()
    local ready = parsed(posted({
        { name = 'title', body = 'отчёт' },
        { name = 'avatar', filename = 'кот.png', type = 'image/png', body = 'PNG-данные' },
    }))

    t.assert_equals(ready.fields, { title = 'отчёт' })

    local file = ready.files.avatar --[[@as TntRouterUpload]]

    t.assert_equals(file.client_name, 'кот.png')
    t.assert_equals(file.name, 'кот.png')
    t.assert_equals(file.type, 'image/png')
    t.assert_equals(file.size, #'PNG-данные')
    t.assert_equals(file:read(), 'PNG-данные')
    -- Маленький файл на диск не уезжает вовсе.
    t.assert_equals(file.path, nil)
end

g.test_multipart_body_is_eaten_by_the_parse = function()
    local input = posted({ { name = 'title', body = 'отчёт' } })

    t.assert_equals(parsed(input).fields.title, 'отчёт')
    -- Второй копии формы в памяти нет: тело разобрано.
    t.assert_equals(input.body, '')
end

g.test_files_written_by_hand_are_not_swept_but_do_not_break_the_sweep = function()
    -- Под именем поля приложение вправе написать в запрос свою таблицу —
    -- и списком тоже. Уборка обязана её пережить: ответ клиенту уже ушёл.
    form().cleanup({ shots = { { name = 'один.png' }, { name = 'два.png' } } })
end

g.test_repeated_names_become_lists_of_fields_and_files = function()
    local ready = parsed(posted({
        { name = 'tag', body = 'a' },
        { name = 'tag', body = 'b' },
        { name = 'shots', filename = 'один.png', body = '1' },
        { name = 'shots', filename = 'два.png', body = '2' },
    }))

    t.assert_equals(ready.fields.tag, { 'a', 'b' })
    t.assert_equals(#ready.files.shots, 2)
    t.assert_equals(ready.files.shots[1].client_name, 'один.png')
    t.assert_equals(ready.files.shots[2].client_name, 'два.png')
end

g.test_empty_file_field_is_not_a_file = function()
    -- Поле, в котором ничего не выбрали, браузер всё равно шлёт.
    local ready = parsed(posted({
        { name = 'title', body = 'отчёт' },
        { name = 'avatar', filename = '', body = '' },
    }))

    t.assert_equals(ready.files, {})
    t.assert_equals(ready.fields, { title = 'отчёт' })
end

g.test_big_part_lands_in_a_temporary_file = function()
    local body = string.rep('x', 200)
    local ready = parsed(
        posted({
            { name = 'doc', filename = 'отчёт.pdf', body = body },
        }),
        { in_memory = 64 }
    )

    local file = ready.files.doc --[[@as TntRouterUpload]]

    t.assert_equals(fio.dirname(file.path --[[@as string]]), g.root)
    t.assert_equals(file:read(), body)
    t.assert_equals(file.temporary, true)

    form().cleanup(ready.files)

    t.assert_equals(fio.listdir(g.root), {})
end

g.test_cleanup_walks_lists_and_files_alike = function()
    local ready = parsed(
        posted({
            { name = 'doc', filename = 'один.pdf', body = string.rep('x', 200) },
            { name = 'shots', filename = 'два.png', body = string.rep('y', 200) },
            { name = 'shots', filename = 'три.png', body = string.rep('z', 200) },
        }),
        { in_memory = 64 }
    )

    t.assert_equals(#fio.listdir(g.root), 3)

    form().cleanup(ready.files)

    t.assert_equals(fio.listdir(g.root), {})

    -- Убирать нечего — тоже обычное дело: форма без файлов.
    form().cleanup(nil)
end

g.test_cleanup_that_failed_leaves_a_record_and_not_a_fall = function()
    local ready = parsed(
        posted({
            { name = 'doc', filename = 'один.pdf', body = string.rep('x', 200) },
        }),
        { in_memory = 64 }
    )

    local journal = helper.capture_log()
    local path = ready.files.doc.path

    helper.faked_fio({
        unlink = function()
            return false, { errno = require('errno').EACCES }
        end,
    })

    journal.forget()
    form().cleanup(ready.files)

    local found = journal.find('WARN [tnt.router] временный файл не убран')

    t.assert_not_equals(found, nil)
    t.assert_str_contains(found.line, ('%s не удалён: Permission denied'):format(path))
    journal.release()
end

g.test_file_that_did_not_close_is_refused_by_the_form = function()
    helper.faked_fio({
        open = function(path, flags, mode)
            local handle = fio.open(path, flags, mode)

            return setmetatable({
                close = function()
                    handle:close()

                    return false
                end,
            }, { __index = handle })
        end,
    })

    local failure = refused(
        posted({
            { name = 'doc', filename = 'отчёт.pdf', body = string.rep('x', 200) },
        }),
        { in_memory = 16 }
    )

    -- Закрытие отказало без причины: отказ всё равно пара, а не бросок.
    t.assert_equals(failure.status, 500)
    t.assert_str_matches(
        failure.reason,
        'временный файл .* не закрыт: причина неизвестна'
    )
    t.assert_equals(fio.listdir(g.root), {})
end

g.test_file_cut_off_by_the_end_of_the_body_leaves_no_temporary_file = function()
    -- Тело кончилось посреди части: до `close` она не дошла, в форме её
    -- нет, и уборка запроса о ней не знает — убрать её обязан разбор.
    local whole = helper.multipart(BOUNDARY, {
        { name = 'doc', filename = 'отчёт.pdf', body = string.rep('x', 200) },
    })
    local cut = whole:sub(-#whole, #whole - 60)
    local failure = refused(sent('multipart/form-data; boundary=' .. BOUNDARY, cut), { in_memory = 16 })

    t.assert_equals(failure, { status = 400, reason = 'часть оборвалась до границы' })
    t.assert_equals(fio.listdir(g.root), {})
end

g.test_files_over_their_number_are_refused = function()
    local failure = refused(
        posted({
            { name = 'a', filename = 'a.png', body = '1' },
            { name = 'b', filename = 'b.png', body = '2' },
            { name = 'c', filename = 'c.png', body = '3' },
        }),
        { max_files = 2 }
    )

    t.assert_equals(failure, { status = 413, reason = 'файлов в форме больше предела в 2' })
end

g.test_text_part_over_its_size_is_refused = function()
    -- Байтом больше предела: отказ начинается ровно за границей.
    local failure = refused(
        posted({
            { name = 'note', body = string.rep('x', 17) },
        }),
        { max_field_size = 16 }
    )

    t.assert_equals(failure, {
        status = 413,
        reason = 'поле «note» больше предела в 16 байт',
    })
end

g.test_file_over_its_size_is_refused_and_leaves_no_temporary_file = function()
    local failure = refused(
        posted({
            { name = 'doc', filename = 'отчёт.pdf', body = string.rep('x', 200) },
        }),
        { in_memory = 16, max_file_size = 64 }
    )

    t.assert_equals(failure, {
        status = 413,
        reason = 'файл в поле «doc» больше предела в 64 байт',
    })

    -- Отказ не оставляет за собой мусора: до него часть уже уехала
    -- на диск, а ответ пойдёт мимо уборки.
    t.assert_equals(fio.listdir(g.root), {})
end

g.test_multipart_without_a_boundary_is_refused = function()
    local failure = refused(sent('multipart/form-data', 'что угодно'))

    t.assert_equals(failure, {
        status = 400,
        reason = 'в multipart/form-data нет метки границы',
    })
end

g.test_broken_boundary_is_refused = function()
    local failure = refused(sent('multipart/form-data; boundary=' .. BOUNDARY, 'тело без границ'))

    t.assert_equals(failure, { status = 400, reason = 'границы нет в теле вовсе' })
end

g.test_kind_of_reads_the_content_type = function()
    local kind, params = form().kind_of({ ['content-type'] = 'multipart/form-data; boundary=x' })

    t.assert_equals(kind, form().MULTIPART)
    t.assert_equals(params.boundary, 'x')
    t.assert_equals(form().kind_of(nil), '')
end

g.test_string_source_gives_the_body_once = function()
    local read = form().from_string('тело')

    t.assert_equals(read(), 'тело')
    t.assert_equals(read(), '')
end
