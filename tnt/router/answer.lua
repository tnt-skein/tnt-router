--- Ответ на разобранный запрос: поиск маршрута, вызов обработчика,
--- отказы и журнал о них.
---
--- Живёт отдельно от фасада, потому что у ответа своя забота — довести
--- запрос до обработчика и превратить всё, что тот вернул или бросил,
--- в ответ с кодом, — а у фасада своя: раздать способы экземпляру
--- и общему роутеру. Журнал у ответа под именем `tnt.router`: дежурный
--- ищет записи роутера по одному имени, из какого бы файла они ни шли.

local errors = require('tnt.router.errors')
local series = require('tnt.router.series')
local tree = require('tnt.router.tree')
local view = require('tnt.router.view')

local log = require('tnt.log').new('tnt.router')

local Module = {}

--- С какого статуса отказ становится поломкой узла.
---
--- 5xx — поломка, и её место в журнале ошибок. А 4xx — обычная жизнь
--- открытого в сеть узла: поднимать тревогу по каждому сканеру значит
--- утопить в ней настоящие ошибки.
local BROKEN_STATUS = 500

--- Каким уровнем писать про отказ.
---
--- Правилом, а не перечнем своих кодов: статус приходит и от обработчика,
--- назвавшего свой отказ своим кодом, — перечислить все коды HTTP заранее
--- нечем, а отказ с неперечисленным ронял бы запрос на записи в журнал.
---@param status integer
---@return fun(message: string, fields: table|nil)
local function level_of(status)
    if status >= BROKEN_STATUS then
        return log.error
    end

    return log.warn
end

--- Что записать в журнал, когда обработчик отмолчался.
---
--- Слово в слово как у прохода слоёв (`tnt.middleware`): пустота значит
--- одно и то же по обе стороны, и дежурный, ищущий запись, не должен
--- знать, обёрнут маршрут слоями или нет.
local SILENT = 'обработчик не вернул ни ответа, ни причины отказа'

--- Стек, который причина принесла с собой.
---
--- Соседний конвейер слоёв (`tnt.middleware`) ловит бросок сам и отдаёт
--- его отказом-таблицей: слово в `message`, стек места броска
--- в `traceback`. Снять стек роутеру уже нечем — его размотал чужой
--- перехват, — и без принесённого запись говорила бы, что сломалось,
--- но не как туда пришли. Признак один и явный: строка в поле
--- `traceback`, и ничего сверх неё не угадывается.
---
--- Поле читается мимо метатаблицы: о причине пишут там, где поломка уже
--- случилась, и чужой `__index`, бросив, унёс бы с собой запись о ней.
---@param reason any
---@return string|nil
local function carried(reason)
    if type(reason) ~= 'table' then
        return nil
    end

    local traceback = rawget(reason, 'traceback')

    if type(traceback) ~= 'string' then
        return nil
    end

    return traceback
end

--- Стек для записи об отказе.
---
--- Снятый ловушкой роутера идёт первым: он стек заведомо, а поле чужой
--- таблицы — стек только по договору. Стек отказа, пришедшего со своим
--- опознавателем, не выписывается: о поломке уже написал тот, кто её
--- завёл, и вторая копия стека — вдвое больше строк без нового смысла.
---@param failure table
---@param traceback string|nil Стек, снятый ловушкой роутера
---@return string|nil
local function stack_of(failure, traceback)
    if traceback ~= nil then
        return traceback
    end

    if failure.incident ~= nil then
        return nil
    end

    return carried(failure.reason)
end

--- Отвечает отказом: журнал, обработчик отказов, последний аргумент.
---
--- Стек ложится в запись журнала отдельным полем `traceback`, а не
--- в отказ: отказ уходит обработчику отказов, и тот, собирая ответ
--- из отказа целиком, унёс бы устройство узла клиенту.
---@param self table
---@param request table|nil
---@param failure table
---@param traceback string|nil Стек места броска, снятый ловушкой роутера
---@return table response
function Module.refuse(self, request, failure, traceback)
    -- До опознавателя: по чужому номеру видно, что о поломке уже написано.
    local stack = stack_of(failure, traceback)

    -- Своё дописывается только там, где чужого нет. Второй опознаватель
    -- на один запрос увёл бы человека к записи, в которой ничего нет:
    -- отказ, пришедший с номером, уже описан в журнале тем, кто отказал.
    failure.incident = failure.incident or errors.incident()
    -- Слово кладётся в отказ, а не только в ответ роутера: обработчик
    -- отказов бывает чужим, и своих слов на 404 и 405 у него нет —
    -- каталог приложения о них ничего не знает.
    failure.message = failure.message or errors.message_of(failure.status)

    local record = { incident = failure.incident, status = failure.status }

    if request ~= nil then
        record.method = request.method
        record.path = request.path
    end

    if failure.reason ~= nil then
        -- Подробности живут в журнале, а не в ответе: в журнале их читает
        -- дежурный, в ответе — кто угодно.
        record.reason = tostring(failure.reason)
    end

    -- Стек — своим полем рядом с причиной: причина остаётся прежней
    -- строкой, по которой запись и ищут, а стек нужен тому, кто её нашёл.
    record.traceback = stack

    level_of(failure.status)('запрос отклонён', record)

    local ok, built = pcall(self.settings.on_error, failure, request)

    -- Упавший или отмолчавшийся обработчик отказов не повод оставить
    -- клиента без ответа: молчание здесь ушло бы к нему как пустой
    -- ответ с кодом 200, то есть как успех.
    if not ok or type(built) ~= 'table' then
        log.error('обработчик отказов не дал ответа', {
            incident = failure.incident,
            reason = tostring(built),
        })

        return errors.last_resort(failure.incident)
    end

    return built
end

--- Маршрут не нашёлся: 404, 405 с перечнем способов или ответ на OPTIONS.
---@param self table
---@param request table
---@param allowed string[]
---@return table response
local function unmatched(self, request, allowed)
    if #allowed == 0 then
        return Module.refuse(self, request, { status = 404 })
    end

    local methods = errors.offered(allowed)

    -- Спросили, чем сюда можно ходить. По RFC 9110 на это отвечают
    -- перечнем способов, а не отказом, и отвечать обязан роутер:
    -- обработчика на OPTIONS никто не пишет.
    if request.method == 'OPTIONS' then
        return { status = 204, headers = { allow = table.concat(methods, ', ') } }
    end

    -- Заголовок едет в самом отказе: по RFC 9110 `Allow` при 405
    -- обязателен, а собрать ответ может и чужой обработчик — и тогда
    -- заголовок, оставленный в ответе роутера, потерялся бы молча.
    return Module.refuse(self, request, { status = 405, headers = { allow = table.concat(methods, ', ') } })
end

--- Что вернул обработчик, тем и отвечаем.
---@param self table
---@param request table
---@param result any
---@param failed any
---@return table response
local function answered(self, request, result, failed)
    if type(result) == 'table' then
        return result
    end

    if result ~= nil then
        return Module.refuse(
            self,
            request,
            { status = 500, reason = 'обработчик вернул не ответ' }
        )
    end

    if failed ~= nil then
        -- Отказ, назвавший свой статус, при нём и остаётся: договор
        -- границы HTTP читается в обе стороны, и «клиента больше нет»
        -- с кодом 410 — не поломка узла. Решать это за обработчика
        -- роутеру не по чину, а прежний ответ был именно такой: 500.
        local declared = errors.refusal_of(failed)

        if declared ~= nil then
            return Module.refuse(self, request, declared)
        end

        -- Про всё остальное известно одно: обработчик не справился.
        -- Что из этого показать человеку, решает обработчик отказов.
        return Module.refuse(self, request, { status = 500, reason = failed })
    end

    -- Пустота — поломка, а не «нет такого адреса»: маршрут-то нашёлся,
    -- иначе сюда бы и не дошли. Знает, что искомого нет, только сам
    -- обработчик — он и обязан сказать это ответом.
    return Module.refuse(self, request, { status = 500, reason = SILENT })
end

--- Заголовки ответа на HEAD: те же, что у GET, и длина убранного тела.
---
--- По RFC 9110 (9.3.2) ответ на HEAD несёт заголовки ответа на GET:
--- опустить `content-length` можно, соврать нулём — нет. Длину называет
--- тот, у кого она есть: строку роутер меряет сам, а названную
--- обработчиком оставляет как есть — раздача знает размер файла, не
--- открывая его. У потока длины заранее не бывает вовсе, и заголовка
--- у него не будет.
---
--- Заголовки копируются, а не дописываются на месте: таблица
--- принадлежит обработчику, и он вправе отдавать одну и ту же на каждый
--- запрос — приписанная длина уехала бы в следующий ответ.
---@param result table Ответ обработчика GET
---@return table<string, any>|nil
local function measured(result)
    if type(result.body) ~= 'string' then
        return result.headers
    end

    local counted = {}

    for name, value in pairs(result.headers or {}) do
        counted[name] = value
    end

    -- Названную обработчиком длину роутер не перемеряет: мерить ему
    -- нечего — тело у обработчика, а не у него, — и разойтись с ним
    -- значило бы соврать за него.
    counted['content-length'] = counted['content-length'] or tostring(#result.body)

    return counted
end

--- Бросок, пойманный ловушкой роутера.
---@class TntRouterCaught
---@field raised any Что бросили
---@field traceback string Стек места броска: строка `debug.traceback`

--- Ловушка `xpcall`: брошенное вместе со стеком места броска.
---
--- Зовётся она на месте броска, до размотки, — и только там стек ещё
--- есть: после возврата из `xpcall` запись о поломке говорила бы, что
--- сломалось, но не как туда пришли. Брошенное остаётся причиной как
--- есть — его получает обработчик отказов, — а стек едет рядом.
---@param raised any
---@return TntRouterCaught
local function caught(raised)
    -- Уровень 2: первый — сама ловушка, и в стеке она не нужна.
    return { raised = raised, traceback = debug.traceback('', 2) }
end

--- Отказ на брошенное: 500, причина — брошенное, стек — в запись.
---
--- Сорвись сама ловушка — кончилась память, — `xpcall` отдаст вместо
--- пойманного слово Lua строкой. Отвечать надо и тогда, и причиной
--- в записи встаёт это слово: стека нет, но и пустой записи нет.
---@param self table
---@param request table
---@param thrown TntRouterCaught|string Что отдала ловушка
---@return table response
local function fell(self, request, thrown)
    if type(thrown) ~= 'table' then
        return Module.refuse(self, request, { status = 500, reason = thrown })
    end

    return Module.refuse(self, request, { status = 500, reason = thrown.raised }, thrown.traceback)
end

--- Ведёт разобранный запрос к маршруту и обработчику.
---@param self table
---@param request table
---@return table response
function Module.routed(self, request)
    -- Отказ, принятый до маршрута, — тело не в пределах — едет в самом
    -- запросе: слои входа прошли его как всякий другой, а искать маршрут
    -- ему незачем.
    if request.refusal ~= nil then
        return Module.refuse(self, request, request.refusal)
    end

    local route, params, allowed = tree.find(self.root, request.path, request.method)
    local bodiless = false

    -- HEAD — это GET без тела. Объявлять его отдельно не надо, а отвечать
    -- на него надо: им проверяют доступность узла, и 405 в ответ читается
    -- как поломка.
    if route == nil and request.method == 'HEAD' then
        route, params, allowed = tree.find(self.root, request.path, 'GET')
        bodiless = route ~= nil
    end

    if route == nil then
        return unmatched(self, request, allowed)
    end

    request.params = params
    request.route = { name = route.name, pattern = route.pattern, method = route.method }

    -- Обработчик падает так же, как всякий код: один запрос — одна беда,
    -- и остальные обязаны ходить дальше. Обработчик зовёт сам `xpcall`,
    -- без замыкания-обёртки: оно строилось бы на каждый запрос.
    local ok, result, failed = xpcall(route.run, caught, request)

    if not ok then
        return fell(self, request, result)
    end

    if bodiless and type(result) == 'table' then
        -- Заголовки те же, тела нет: этим HEAD и отличается от GET,
        -- и длина тела — часть тех же заголовков (см. `measured`).
        return { status = result.status, headers = measured(result), body = '' }
    end

    return answered(self, request, result, failed)
end

--- Ответ на запрос через слои входа — всегда ответ: всё, что бросает,
--- идёт под ловушку роутера и становится отказом со стеком.
---@param self table
---@param request table Разобранный запрос
---@return table response
local function through_entry(self, request)
    local ok, result, failed = xpcall(self.entered, caught, request)

    if ok then
        return answered(self, request, result, failed)
    end

    return fell(self, request, result)
end

--- Ведёт разобранный запрос через слои входа.
---
--- Слои входа стоят вокруг всего, чем отвечает роутер: и вокруг поиска
--- маршрута, и вокруг отказа, принятого до него. Закрытое на обслуживание
--- приложение отвечает 503 и на путь, которого нет, — иначе по 404
--- снаружи читались бы его маршруты; а журнал и опознаватель запроса
--- достаются и 404, и телу не в пределах — иначе человеку, которому
--- «ответило 404», назвать было бы нечего. Отказ слоя входа рисует тот же
--- обработчик отказов, что и отказ обработчика: клиент не должен
--- различать, кто именно ему отказал.
---
--- Здесь же ответ считается в рядах и запрос держится для общих данных
--- страниц (`tnt.router.view`): через это место идёт всякий разобранный
--- запрос — и по сети, и таблицей в `dispatch`, и отказ по телу,
--- принятый до маршрута.
---@param self table
---@param request table Разобранный запрос
---@return table response
function Module.served(self, request)
    local started = series.started()
    local response = view.served(self, request, through_entry)

    series.answered(request, response, started)

    return response
end

return Module
