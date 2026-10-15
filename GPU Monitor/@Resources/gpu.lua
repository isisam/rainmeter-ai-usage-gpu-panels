-- gpu.lua - reads gpu_status.txt (written by GPUZ-Reader.ps1) and draws the bars
local path
local BAR_W = 214

function Initialize()
    path = SKIN:GetVariable('@') .. 'gpu_status.txt'
end

local function set(meter, value) SKIN:Bang('!SetOption', meter, 'Text', value) end

local function bar(meter, pct, color)
    if not pct then
        SKIN:Bang('!SetOption', meter, 'Shape', 'Rectangle 0,0,1,5,2.5 | Fill Color 0,0,0,0 | StrokeWidth 0')
        return
    end
    local w = math.max(1, math.floor(BAR_W * math.min(100, math.max(0, pct)) / 100 + 0.5))
    SKIN:Bang('!SetOption', meter, 'Shape', string.format('Rectangle 0,0,%d,5,2.5 | Fill Color %s,235 | StrokeWidth 0', w, color))
end

-- 用量條：<70% 主色，70~90% 琥珀，>=90% 紅
local function heat(pct, base)
    if pct >= 90 then return '225,72,60' end
    if pct >= 70 then return '232,170,40' end
    return base
end

-- 溫度條：<70°C 主色，70~83°C 琥珀，>83°C 紅
local function tempColor(t, base)
    if t > 83 then return '225,72,60' end
    if t >= 70 then return '232,170,40' end
    return base
end

function Update()
    local f = io.open(path, 'r')
    if not f then return 0 end
    local v = {}
    for line in f:lines() do
        local k, val = line:match('^([^=]+)=(.-)%s*$')
        if k then v[k] = val end
    end
    f:close()
    if not v.core_clock then return 0 end

    local accent = SKIN:GetVariable('AccentColor')
    local n = function(key) return tonumber(v[key]) end

    set('MeterName', (v.gpu_name or 'GPU'):gsub('^NVIDIA ', ''):gsub('^GeForce ', ''))

    local load = n('gpu_load')
    set('MeterLoadValue', load and (load .. '%') or '--')
    bar('MeterLoadFill', load, load and heat(load, accent))

    local used, total = n('mem_used'), n('mem_total')
    if used and total and total > 0 then
        local pct = used / total * 100
        set('MeterVramValue', string.format('%.1f / %d GB', used / 1024, math.floor(total / 1024 + 0.5)))
        bar('MeterVramFill', pct, heat(pct, accent))
    else
        set('MeterVramValue', '--'); bar('MeterVramFill', nil)
    end

    local power, limit = n('board_power'), n('power_limit') or 350
    if power then
        local pct = power / limit * 100
        set('MeterPowerValue', string.format('%d W', math.floor(power + 0.5)))
        bar('MeterPowerFill', pct, heat(pct, accent))
    else
        set('MeterPowerValue', '--'); bar('MeterPowerFill', nil)
    end

    local temp = n('gpu_temp')
    set('MeterTempValue', temp and (temp .. '°C') or '--')
    bar('MeterTempFill', temp, temp and tempColor(temp, accent))

    set('MeterInfo', string.format('核心 %s · 顯存 %s MHz   熱點 %s° · 顯存 %s°   風扇 %s%%',
        v.core_clock or '--', v.mem_clock or '--', v.hot_spot or '--', v.mem_temp or '--', v.fan_pct or '--'))
    set('MeterState', string.format('%s · Gen%s x%s · 更新 %s', v.pstate or '--', v.pcie_gen or '-',
        v.pcie_width or '-', SKIN:GetVariable('FreqLabel')))

    SKIN:Bang('!UpdateMeter', '*')
    SKIN:Bang('!Redraw')
    return 1
end

function CycleRate()
    local nextRate = { ['1000'] = '2000', ['2000'] = '5000', ['5000'] = '1000' }
    local ms = nextRate[SKIN:GetVariable('UpdateMs')] or '1000'
    local file = SKIN:GetVariable('@') .. 'variables.ini'
    SKIN:Bang('!WriteKeyValue', 'Variables', 'UpdateMs', ms, file)
    SKIN:Bang('!WriteKeyValue', 'Variables', 'FreqLabel', (tonumber(ms) / 1000) .. 's', file)
    SKIN:Bang('!Refresh')
end

function Audit()
    local out = io.open(SKIN:GetVariable('@') .. 'audit.txt', 'wb')
    if not out then return end
    for _, name in ipairs({'Name', 'State', 'LoadValue', 'VramValue', 'PowerValue', 'TempValue', 'Info'}) do
        out:write(name .. '=' .. SKIN:GetMeter('Meter' .. name):GetOption('Text', '') .. '\n')
    end
    for _, name in ipairs({'LoadFill', 'VramFill', 'PowerFill', 'TempFill'}) do
        out:write(name .. '=' .. SKIN:GetMeter('Meter' .. name):GetOption('Shape', '') .. '\n')
    end
    out:close()
end
