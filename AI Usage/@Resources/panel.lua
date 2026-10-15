-- AI 用量面板：讀 panel-data.txt（collector.py 每分鐘產生）畫三個圓環
-- 外圈＝剩餘額度，內圈細線＝距離重置的剩餘時間
local path
local CY, R_OUT, R_IN = 72, 31, 23
local CX = { 60, 180, 300 }
local WEEK, FIVE_H = 7 * 86400, 5 * 3600

function Initialize()
    path = SKIN:GetVariable('@') .. 'panel-data.txt'
    if SKIN:GetVariable('UpdatesPaused', '0') == '1' then
        SKIN:Bang('!DisableMeasure', 'MeasurePoll')
        SKIN:Bang('!DisableMeasure', 'MeasureCollector')
    end
end

local function set(meter, value) SKIN:Bang('!SetOption', meter, 'Text', value) end

local function taipei(stamp) return os.date('!%m/%d %H:%M', stamp + 28800) end
local function clock(stamp) return os.date('!%H:%M', stamp + 28800) end

local function left(reset, now)
    local d = reset - now
    if d <= 0 then return '' end
    local days, hours, mins = math.floor(d / 86400), math.floor(d % 86400 / 3600), math.floor(d % 3600 / 60)
    if days > 0 then return string.format('剩 %d天%d時', days, hours) end
    if hours > 0 then return string.format('剩 %d時%d分', hours, mins) end
    return string.format('剩 %d分', mins)
end

-- 剩餘 >=50% 品牌色，20~50% 琥珀，<20% 紅
local function level(remaining, color)
    if remaining >= 50 then return color end
    if remaining >= 20 then return '232,170,40' end
    return '225,72,60'
end

-- 從 12 點鐘方向順時針畫 pct% 的圓弧
local function arc(meter, cx, r, pct, style)
    if not pct or pct <= 0 then
        SKIN:Bang('!SetOption', meter, 'Shape', 'Line 0,0,0,0 | StrokeWidth 0')
        return
    end
    local shape
    if pct >= 99.9 then
        shape = string.format('Ellipse %d,%d,%d | Fill Color 0,0,0,0 | %s', cx, CY, r, style)
    else
        local a = math.rad(360 * pct / 100)
        local ex, ey = cx + r * math.sin(a), CY - r * math.cos(a)
        shape = string.format('Arc %d,%d,%.2f,%.2f,%d,%d,0,0,%d | Fill Color 0,0,0,0 | StrokeStartCap Round | StrokeEndCap Round | %s',
            cx, CY - r, ex, ey, r, r, pct > 50 and 1 or 0, style)
    end
    SKIN:Bang('!SetOption', meter, 'Shape', shape)
end

-- 一個圓環：remaining=剩餘額度%，reset=重置時間，period=週期秒數
local function ring(i, remaining, reset, period, color, now, resetText)
    arc('MeterRing' .. i, CX[i], R_OUT, remaining,
        string.format('Stroke Color %s,240 | StrokeWidth 6', remaining and level(remaining, color) or color))
    local timeleft = (reset > now) and math.min(100, (reset - now) / period * 100) or nil
    arc('MeterRing' .. i .. 'Time', CX[i], R_IN, timeleft, 'Stroke Color 255,255,255,150 | StrokeWidth 2')
    set('MeterPct' .. i, remaining and string.format('%d%%', math.floor(remaining + 0.5)) or '--')
    set('MeterReset' .. i, reset > now and resetText(reset) or '重置 --')
    set('MeterLeft' .. i, reset > now and left(reset, now) or '')
end

local function read()
    local data = {}
    local f = io.open(path, 'r')
    if f then
        for line in f:lines() do
            local k, v = line:match('^([%w_]+)=(.-)%s*$')
            if k then data[k] = v end
        end
        f:close()
    end
    return data
end

function Update()
    local data, now = read(), os.time()
    local flag = io.open(SKIN:GetVariable('@') .. 'paused.flag', 'r')
    local paused = flag ~= nil or SKIN:GetVariable('UpdatesPaused', '0') == '1'
    if flag then flag:close() end
    local green, coral = SKIN:GetVariable('CodexColor'), SKIN:GetVariable('ClaudeColor')

    -- CODEX 週額度
    local remaining = tonumber(data.weekly_remaining)
    local observed = tonumber(data.observed_at) or 0
    local reset = tonumber(data.weekly_reset) or 0
    local fresh = remaining and data.fetch_ok == '1' and not paused and observed > 0 and now - observed <= 180
    ring(1, remaining, reset, WEEK, green, now, function(t) return '重置 ' .. taipei(t) end)
    if remaining and not fresh then set('MeterPct1', string.format('%d%%*', math.floor(remaining + 0.5))) end

    -- CLAUDE 5 小時 / 本週
    local five, week = tonumber(data.claude_five), tonumber(data.claude_week)
    local cobs = tonumber(data.claude_observed) or 0
    local age = now - cobs
    local stale = not five or cobs <= 0 or age > 43200
    ring(2, (five and not stale) and (100 - five) or nil, tonumber(data.claude_five_reset) or 0, FIVE_H, coral, now,
        function(t) return '重置 ' .. clock(t) end)
    ring(3, (week and not stale) and (100 - week) or nil, tonumber(data.claude_reset) or 0, WEEK, coral, now,
        function(t) return '重置 ' .. taipei(t) end)
    if (tonumber(data.claude_five_reset) or 0) <= now then
        set('MeterReset2', data.claude_source == 'api' and '未開始計時' or '需登入 CLI')
    end

    -- 標題列：更新時間 + Claude 資料新鮮度
    local refreshed = tonumber(data.refreshed_at) or 0
    local status = ''
    if not five then status = ' · Claude 待取得'
    elseif stale then status = ' · Claude 資料過期'
    elseif data.claude_source ~= 'api' or age >= 180 then
        status = age < 3600 and string.format(' · Claude %d分前', math.floor(math.max(0, age) / 60))
            or string.format(' · Claude %d時前', math.floor(age / 3600))
    end
    set('MeterTitle', paused and 'AI 用量 · 已暫停' or 'AI 用量')
    set('MeterUpdated', (refreshed > 0 and ('更新 ' .. clock(refreshed)) or '更新 --:--') .. status)

    SKIN:Bang('!UpdateMeter', '*')
    return 0
end

function Audit()
    local f = io.open(SKIN:GetVariable('@') .. 'native-text-after.bin', 'wb')
    if not f then return end
    for _, name in ipairs({'Title', 'Updated', 'Pct1', 'Pct2', 'Pct3', 'Reset1', 'Reset2', 'Reset3', 'Left1', 'Left2', 'Left3'}) do
        f:write(name .. '=' .. SKIN:GetMeter('Meter' .. name):GetOption('Text', '') .. '\n')
    end
    for _, name in ipairs({'Ring1', 'Ring1Time', 'Ring2', 'Ring2Time', 'Ring3', 'Ring3Time'}) do
        f:write(name .. '=' .. SKIN:GetMeter('Meter' .. name):GetOption('Shape', '') .. '\n')
    end
    f:close()
end
