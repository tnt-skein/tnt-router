--- Присланный файл: безопасное имя, временный файл, перенос и уборка.
---
--- Проверки идут на настоящем диске, в своём временном каталоге: модуль —
--- тонкий слой над `tnt-fs`, и двойник диска показал бы только то, что мы
--- правильно разговариваем сами с собой. Двойник берётся там, где
--- исправный диск отказа не даст: файл не открылся, не записался,
--- не закрылся, не переименовался, кончилось место. Подменяется `fio`
--- под `tnt-fs`, а не фасад: отказ проходит тот же разбор, что и в бою.

local t = require('luatest')

local errno = require('errno')
local fio = require('fio')

--- Длина в знаках: средство то же, что у самого пакета.
---@type any
local letters = rawget(_G, 'utf8')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.router.upload')

--- Модуль присланных файлов.
---@return table
local function upload()
    return helper.part('tnt.router.upload')
end

g.before_each(function()
    g.root = fio.tempdir()
end)

g.after_each(function()
    fio.rmtree(g.root)
end)

--- Приёмник части с настройками проверки.
---@param opts table|nil Что поменять в настройках по умолчанию
---@return table
local function sink(opts)
    local given = {
        field = 'avatar',
        filename = 'кот.png',
        type = 'image/png',
        charset = nil,
        in_memory = 32,
        max_size = 1024,
        temp_dir = g.root,
    }

    for name, value in pairs(opts or {}) do
        given[name] = value
    end

    return upload().sink(given)
end

--- Принимает часть целиком и отдаёт готовый файл.
---@param body string
---@param opts table|nil
---@return TntRouterUpload
local function taken(body, opts)
    local sunk = sink(opts)

    t.assert_equals(sunk.write(body), true)

    local file, failure = sunk.close()

    t.assert_equals(failure, nil)

    return file --[[@as TntRouterUpload]]
end

--- Номер строки, с которой позвали: на неё обязан указать бросок.
---@return integer
local function here()
    return (debug.getinfo(2, 'l') --[[@as { currentline: integer }]]).currentline
end

--- Место, которое бросок обязан назвать: этот файл проверок и строка.
---@param line integer
---@return string
local function at(line)
    return ('%s:%d: '):format((debug.getinfo(2, 'S') --[[@as { short_src: string }]]).short_src, line)
end

--- Подменяет названные действия `fio` под файловой системой роутера.
local faked = helper.faked_fio

--- Род и текст отказа `tnt-fs`: по ним сверяются отказы переноса,
--- чтения и уборки.
---@param err TntFsFailure|nil
---@return table
local function told(err)
    local failure = err --[[@as TntFsFailure]]

    return { failure.kind, failure.message }
end

--- Отказ, каким его отдают простые действия `fio`: объект с кодом.
---@param code integer
---@return table
local function refusal(code)
    return { errno = code }
end

--- Открытие, отдающее дескриптор с подменёнными действиями.
---
--- Обёртка пуста, и любое действие — подменённое или настоящее — зовётся
--- с настоящим дескриптором первым аргументом. Дескриптор `fio` при
--- закрытии помечает себя закрытым; позванный на обёртке, он пометил бы
--- её, а у настоящего остался бы прежний номер, и сборщик мусора потом
--- закрыл бы этот номер у чужого файла, уже получившего его от системы.
---
--- Каталог открывается настоящим: его открывает сброс каталога после
--- подмены, а проверки здесь ломают запись файла.
---@param overrides table Действия дескриптора; прочие — у настоящего
---@return fun(path: string, flags: table, mode: integer|nil): any
local function opening(overrides)
    return function(path, flags, mode)
        local handle, err = fio.open(path, flags, mode)

        if handle == nil or fio.path.is_dir(path) then
            return handle, err
        end

        return setmetatable({}, {
            __index = function(_, name)
                local action = overrides[name] or handle[name]

                return function(_, ...)
                    return action(handle, ...)
                end
            end,
        })
    end
end

--- Права файла: младшие девять бит.
---@param path string
---@return integer
local function rights(path)
    local mode = fio.lstat(path).mode --[[@as integer]]

    return bit.band(mode, tonumber('777', 8) --[[@as integer]])
end

g.test_safe_name_drops_the_path_and_keeps_the_letters = function()
    local named = {
        ['кот.png'] = 'кот.png',
        ['кот-1_2.png'] = 'кот-1_2.png',
        ['../../etc/passwd'] = 'passwd',
        ['C:\\Users\\Иван\\отчёт.pdf'] = 'отчёт.pdf',
        ['/tmp/../x.png'] = 'x.png',
        ['мой файл.png'] = 'мой_файл.png',
        ['a"b`c;d.png'] = 'a_b_c_d.png',
        ['.env'] = 'env',
        ['..'] = 'file',
        ['app.js\0.png'] = 'app.js_.png',
        [''] = 'file',
    }

    for given, expected in pairs(named) do
        t.assert_equals(upload().safe_name(given), expected, given)
    end

    -- Имени нет вовсе — предмету всё равно нужно имя.
    t.assert_equals(upload().safe_name(nil), 'file')
end

g.test_safe_name_is_cut_by_letters_and_not_by_bytes = function()
    -- Срез по байтам разрубил бы кириллическую букву пополам, и обрывок
    -- сорвал бы сборку JSON в ответе.
    local long = upload().safe_name(string.rep('и', 200) .. '.png')

    t.assert_equals(letters.len(long), 100)
    t.assert_equals(long, string.rep('и', 100))

    -- Имя не в UTF-8 режется байтами: знаков у него нет вовсе.
    local broken = upload().safe_name(string.rep('\200', 200) .. '.png')

    t.assert_equals(#broken, 100)
end

g.test_small_part_stays_in_memory = function()
    local file = taken('маленький')

    t.assert_equals(file.path, nil)
    t.assert_equals(file.temporary, false)
    t.assert_equals(file.size, #'маленький')
    t.assert_equals(file.field, 'avatar')
    t.assert_equals(file.client_name, 'кот.png')
    t.assert_equals(file.name, 'кот.png')
    t.assert_equals(file.type, 'image/png')
    t.assert_equals(file:read(), 'маленький')
    -- Убирать нечего: временного файла не заводили.
    t.assert_equals(file:remove(), true)
end

g.test_part_exactly_at_the_limit_stays_in_memory = function()
    local file = taken(string.rep('x', 32))

    t.assert_equals(file.path, nil)

    -- А на байт больше — уже файл.
    t.assert_equals(taken(string.rep('x', 33)).path ~= nil, true)
end

g.test_big_part_goes_to_a_temporary_file = function()
    local sunk = sink()

    -- Куски идут по одному, и до предела всё копится строкой: на диск
    -- уходит только то, что в неё уже не влезло.
    t.assert_equals(sunk.write(string.rep('a', 20)), true)
    t.assert_equals(sunk.write(string.rep('b', 20)), true)
    t.assert_equals(sunk.write(string.rep('c', 20)), true)

    local file = sunk.close()

    t.assert_equals(file.size, 60)
    -- Имя скрытое и случайное, а лежит файл в названном каталоге.
    -- Знаков в случайной части ровно столько, сколько байт: имя не угадать
    -- заранее и не подсунуть на его место свой файл.
    t.assert_equals(fio.dirname(file.path), g.root)
    t.assert_str_matches(fio.basename(file.path), '%.tnt%-upload%-' .. ('%x'):rep(24) .. '%.tmp')
    t.assert_equals(file.temporary, true)
    t.assert_equals(file:read(), string.rep('a', 20) .. string.rep('b', 20) .. string.rep('c', 20))
    -- Во временном файле лежит присланное посторонним: читает его один
    -- владелец узла.
    t.assert_equals(rights(file.path), tonumber('600', 8))

    t.assert_equals(file:remove(), true)
    t.assert_equals(fio.path.exists(file.path), false)
    -- Убирать дважды нечего: уборка идёт по всем файлам запроса разом.
    t.assert_equals(file:remove(), true)
end

g.test_part_over_the_limit_is_refused_without_a_file = function()
    local sunk = sink({ max_size = 20, in_memory = 4 })

    -- Начало части успело уехать на диск, и предел застаёт её уже там:
    -- временный файл убирается вместе с отказом.
    t.assert_equals(sunk.write(string.rep('x', 8)), true)
    t.assert_equals(#fio.listdir(g.root), 1)

    local ok, failure = sunk.write(string.rep('x', 13))

    t.assert_equals(ok, false)
    t.assert_equals(failure, {
        status = 413,
        reason = 'файл в поле «avatar» больше предела в 20 байт',
    })
    t.assert_equals(fio.listdir(g.root), {})

    -- Ровно предел проходит.
    t.assert_equals(sink({ max_size = 20 }).write(string.rep('x', 20)), true)
end

g.test_part_over_the_limit_while_in_memory_is_refused_all_the_same = function()
    -- Предел застаёт часть ещё в памяти: убирать на диске нечего,
    -- и отказ не спотыкается о писателя, которого нет.
    local sunk = sink({ max_size = 20, in_memory = 64 })
    local ok, failure = sunk.write(string.rep('x', 21))

    t.assert_equals(ok, false)
    t.assert_equals(failure.status, 413)
    t.assert_equals(fio.listdir(g.root), {})
end

g.test_abandoned_part_leaves_no_temporary_file = function()
    -- Тело оборвалось посреди части: до `close` она не доходит, и её
    -- недописанный файл убирает `abort`.
    local sunk = sink()

    t.assert_equals(sunk.write(string.rep('x', 100)), true)
    t.assert_equals(#fio.listdir(g.root), 1)

    sunk.abort()

    t.assert_equals(fio.listdir(g.root), {})

    -- Бросать можно сколько угодно раз, и часть в памяти тоже.
    sunk.abort()
    sink().abort()
end

g.test_file_in_memory_is_moved_by_writing_it = function()
    local file = taken('маленький')
    local destination = fio.pathjoin(g.root, 'аватар.png')

    t.assert_equals(file:move(destination), true)
    t.assert_equals(file.path, destination)
    t.assert_equals(file.temporary, false)
    t.assert_equals(file:read(), 'маленький')
    t.assert_equals(rights(destination), tonumber('600', 8))

    -- Перенесённый файл уборка не трогает: он уже не наш.
    t.assert_equals(file:remove(), true)
    t.assert_equals(fio.path.exists(destination), true)
end

g.test_file_in_memory_replaces_the_old_one_whole = function()
    -- Запись из памяти — подмена, как и переименование: прежний файл
    -- на месте уступает новому целиком, и права у места — свои, `0600`.
    local destination = fio.pathjoin(g.root, 'аватар.png')
    local old = fio.open(destination, { 'O_WRONLY', 'O_CREAT' }, tonumber('644', 8))

    old:write('прежний, куда длиннее нового')
    old:close()

    t.assert_equals(taken('новый'):move(destination), true)
    t.assert_equals(fio.listdir(g.root), { 'аватар.png' })
    t.assert_equals(rights(destination), tonumber('600', 8))

    local handle = fio.open(destination, { 'O_RDONLY' })

    t.assert_equals(handle:read(), 'новый')
    handle:close()
end

g.test_file_on_disk_is_moved_by_renaming_it = function()
    local file = taken(string.rep('x', 100))
    local was = file.path --[[@as string]]
    local destination = fio.pathjoin(g.root, 'аватар.png')

    t.assert_equals(file:move(destination), true)
    t.assert_equals(fio.path.exists(was), false)
    t.assert_equals(file.path, destination)
    t.assert_equals(file.temporary, false)
    t.assert_equals(file:read(), string.rep('x', 100))
end

--- Переименование временного файла отказывает «Cross-device link»:
--- временный каталог на боевой машине — отдельный том. Прочие
--- переименования — писателя, кладущего копию на место, — настоящие.
---@param was string Путь временного файла
---@param overrides table|nil Что подменить в `fio` ещё
local function across_volumes(was, overrides)
    local replaced = overrides or {}

    replaced.rename = function(from, to)
        if from == was then
            return false, refusal(errno.EXDEV)
        end

        return fio.rename(from, to)
    end

    faked(replaced)
end

g.test_move_across_volumes_falls_back_to_a_copy = function()
    local file = taken(string.rep('x', 100))
    local was = file.path --[[@as string]]

    across_volumes(was)

    local destination = fio.pathjoin(g.root, 'аватар.png')

    t.assert_equals(file:move(destination), true)
    t.assert_equals(fio.path.exists(was), false)
    t.assert_equals(file.path, destination)
    t.assert_equals(file.temporary, false)
    t.assert_equals(file:read(), string.rep('x', 100))
    -- Копия несёт те же права, что и переименованный файл, и следов
    -- ни от исходника, ни от писателя копии не остаётся.
    t.assert_equals(rights(destination), tonumber('600', 8))
    t.assert_equals(fio.listdir(g.root), { 'аватар.png' })
end

g.test_move_across_volumes_that_ran_out_of_space_is_a_pair_with_its_kind = function()
    local file = taken(string.rep('x', 100))
    local was = file.path --[[@as string]]
    local destination = fio.pathjoin(g.root, 'аватар.png')

    across_volumes(was, {
        open = opening({
            write = function()
                return false, refusal(errno.ENOSPC)
            end,
        }),
    })

    local ok, err = file:move(destination)

    -- Кончившееся место — род `full`, а не разбор текста.
    t.assert_equals(ok, nil)
    t.assert_equals(
        told(err),
        { 'full', ('файл %s не записан: %s'):format(destination, errno.strerror(errno.ENOSPC)) }
    )
    -- Исходник на месте и всё ещё временный: перенос не удался, но файл
    -- не потерян и будет убран после ответа.
    t.assert_equals(file.path, was)
    t.assert_equals(file.temporary, true)
    t.assert_equals(fio.listdir(g.root), { fio.basename(was) })
end

g.test_move_across_volumes_of_a_file_that_is_gone_is_a_pair = function()
    local file = taken(string.rep('x', 100))
    local was = file.path --[[@as string]]

    across_volumes(was)
    fio.unlink(was)

    local ok, err = file:move(fio.pathjoin(g.root, 'аватар.png'))

    t.assert_equals(ok, nil)
    t.assert_equals(
        told(err),
        { 'missing', ('файл %s не открыт на чтение: No such file or directory'):format(was) }
    )
    t.assert_equals(fio.listdir(g.root), {})
end

g.test_move_that_failed_altogether_is_a_pair = function()
    -- Каталога нет: переименование отказывает, копия — тоже, и приходит
    -- её отказ, с родом.
    local file = taken(string.rep('x', 100))
    local destination = '/нет/такого/каталога/аватар.png'
    local ok, err = file:move(destination)

    t.assert_equals(ok, nil)
    t.assert_equals(
        told(err),
        { 'missing', ('файл %s не записан: No such file or directory'):format(destination) }
    )
    -- Исходник на месте: перенос не удался, но файл не потерян.
    t.assert_equals(file.temporary, true)
    t.assert_equals(fio.path.exists(file.path --[[@as string]]), true)
end

g.test_move_of_a_file_in_memory_that_cannot_be_written_is_a_pair = function()
    local file = taken('маленький')
    local destination = '/нет/такого/каталога/аватар.png'
    local ok, err = file:move(destination)

    t.assert_equals(ok, nil)
    t.assert_equals(
        told(err),
        { 'missing', ('файл %s не заменён: No such file or directory'):format(destination) }
    )
    t.assert_equals(file.path, nil)
end

g.test_move_that_broke_on_writing_is_a_pair = function()
    local file = taken('маленький')

    faked({
        open = opening({
            write = function()
                return false, refusal(errno.ENOSPC)
            end,
        }),
    })

    local destination = fio.pathjoin(g.root, 'аватар.png')
    local ok, err = file:move(destination)

    t.assert_equals(ok, nil)
    t.assert_equals({
        told(err)[1],
        (err --[[@as TntFsFailure]]).path,
    }, { 'full', destination })
    t.assert_equals(fio.listdir(g.root), {})
end
g.test_move_without_a_path_blames_the_caller = function()
    local file = taken('маленький')

    for _, wrong in ipairs({ '', 7 }) do
        t.assert_error_msg_contains(
            'переносить присланный файл надо в названный путь',
            function()
                file:move(wrong --[[@as string]])
            end
        )
    end

    -- Место у броска одно — строка вызывающего: промах в пути делает тот,
    -- кто зовёт перенос, и искать его надо у себя, а не внутри пакета.
    local line
    local _, err = pcall(function()
        line = here() + 1
        file:move('')
    end)

    t.assert_equals(
        err,
        at(line --[[@as integer]])
            .. 'переносить присланный файл надо в названный путь'
    )
end

g.test_unread_file_is_a_pair_and_not_a_fall = function()
    local file = taken(string.rep('x', 100))
    local path = file.path --[[@as string]]

    faked({
        open = function()
            return nil, refusal(errno.EACCES)
        end,
    })

    local body, err = file:read()

    t.assert_equals(body, nil)
    t.assert_equals(told(err), { 'denied', ('файл %s не прочитан: Permission denied'):format(path) })

    faked({
        open = opening({
            read = function()
                return nil, refusal(errno.EIO)
            end,
        }),
    })

    local again, problem = file:read()

    t.assert_equals(again, nil)
    t.assert_equals({
        told(problem)[1],
        (problem --[[@as TntFsFailure]]).errno,
    }, { 'failed', errno.EIO })
end

g.test_temporary_file_that_did_not_open_is_a_refusal = function()
    local root = fio.pathjoin(g.root, 'нет-такого-каталога')
    local sunk = sink({ temp_dir = root })
    local ok, failure = sunk.write(string.rep('x', 100))

    t.assert_equals(ok, false)
    t.assert_equals(failure.status, 500)
    t.assert_str_matches(
        failure.reason,
        'временный файл '
            .. root:gsub('%p', '%%%0')
            .. '/%.tnt%-upload%-%x+%.tmp для части не заведён: No such file or directory'
    )
end

g.test_temporary_file_that_did_not_write_is_a_refusal = function()
    local opened = 0

    faked({
        open = function()
            opened = opened + 1

            return {
                write = function()
                    return false, refusal(errno.ENOSPC)
                end,

                close = function()
                    return true
                end,
            }
        end,
    })

    -- Первый отказ — на сбросе накопленного, второй — на очередном куске,
    -- который пишется уже прямо в файл.
    local sunk = sink()
    local ok, failure = sunk.write(string.rep('x', 100))

    t.assert_equals(ok, false)
    t.assert_str_matches(
        failure.reason,
        'временный файл .* не записан: ' .. errno.strerror(errno.ENOSPC)
    )
    t.assert_equals(failure.status, 500)

    local second = sink()

    t.assert_equals(second.write(string.rep('x', 100)), false)
    t.assert_equals(opened, 2)
end

g.test_temporary_file_that_broke_on_a_later_piece_is_a_refusal = function()
    local written = 0

    faked({
        open = opening({
            -- Первая запись — сброс накопленного, дальше куски идут
            -- прямо в файл: ломается как раз такой кусок.
            write = function(handle, data)
                written = written + 1

                if written == 1 then
                    return handle:write(data)
                end

                return false, refusal(errno.EIO)
            end,
        }),
    })

    local sunk = sink()

    t.assert_equals(sunk.write(string.rep('x', 100)), true)

    local ok, failure = sunk.write('ещё')

    t.assert_equals(ok, false)
    t.assert_str_matches(
        failure.reason,
        'временный файл .* не записан: ' .. errno.strerror(errno.EIO)
    )
    t.assert_equals(failure.status, 500)
    -- Недописанный файл убирается сразу: до общей уборки запроса
    -- отказавшая часть не доходит.
    t.assert_equals(fio.listdir(g.root), {})
    -- Брошенная после отказа часть убирать уже ничего не должна.
    sunk.abort()
end

g.test_temporary_file_that_did_not_close_is_a_refusal = function()
    faked({
        open = opening({
            close = function(handle)
                handle:close()

                return false, refusal(errno.EIO)
            end,
        }),
    })

    local sunk = sink()

    t.assert_equals(sunk.write(string.rep('x', 100)), true)

    local file, failure = sunk.close()

    t.assert_equals(file, nil)
    t.assert_str_matches(
        failure.reason,
        'временный файл .* не закрыт: ' .. errno.strerror(errno.EIO)
    )
    t.assert_equals(failure.status, 500)
    -- Не закрывшийся файл записан не весь: обрывок не достаётся никому.
    t.assert_equals(fio.listdir(g.root), {})
end

g.test_temporary_file_whose_directory_did_not_flush_is_removed_too = function()
    -- Файл уже встал на место, а каталог не сбросился: отдавать такой
    -- файл нельзя, и убрать его, кроме приёмника, некому.
    faked({
        open = function(path, flags, mode)
            if path == g.root then
                return nil, refusal(errno.EIO)
            end

            return fio.open(path, flags, mode)
        end,
    })

    local sunk = sink()

    t.assert_equals(sunk.write(string.rep('x', 100)), true)

    local file, failure = sunk.close()

    t.assert_equals(file, nil)
    t.assert_equals(failure.status, 500)
    t.assert_str_matches(
        failure.reason,
        'временный файл .* не закрыт: ' .. errno.strerror(errno.EIO)
    )
    t.assert_equals(fio.listdir(g.root), {})
end

g.test_removal_that_failed_is_a_pair = function()
    local file = taken(string.rep('x', 100))
    local path = file.path --[[@as string]]

    faked({
        unlink = function()
            return false, refusal(errno.EACCES)
        end,
    })

    local ok, err = file:remove()

    t.assert_equals(ok, nil)
    t.assert_equals(told(err), { 'denied', ('%s не удалён: Permission denied'):format(path) })
    -- Второй уборки нет: неудачу видит тот, кто убирал, и копить повторы
    -- на каждом проходе незачем.
    t.assert_equals(file:remove(), true)
end

g.test_temporary_directory_is_named_by_the_settings = function()
    t.assert_equals(upload().root_of('/var/tmp'), '/var/tmp')

    -- Окружение пакет не читает: каталог называет приложение, а без него
    -- остаётся системный.
    t.assert_equals(upload().root_of(nil), '/tmp')

    -- Пустая строка — тоже «не назван», а не корень файловой системы.
    t.assert_equals(upload().root_of(''), '/tmp')
end

g.test_temporary_names_do_not_repeat = function()
    local first = taken(string.rep('x', 100))
    local second = taken(string.rep('y', 100))

    t.assert_not_equals(first.path, second.path)
end
