--[[
 script:  sembat.lua 
 author:  David Semeria
 version: 1.0
 license: GNU General Public License version 2
--]]

local DEBUG = false
local DEBUG_FILE = "/DEBUG/sembat.txt" -- /DEBUG directory must exist unders SD card root

local ERR_CODE_OK        =  100
local ERR_CODE_RUN       =  0 -- the script didn't load, not recoverable
local ERR_CODE_INIT      =  1 -- init() did not complete, not recoverable
local ERR_CODE_VERSION    = 2 -- incompatible version, not recoverable 
local ERR_CODE_IDS        = 3 -- failed to load telemetry ids, recoverable
local ERR_CODE_TELEMETRY  = 4 -- incorrect cell voltages, recoverable 
local ERR_CODE_CELL_COUNT = 5 -- bad cell count, recoverable

local inputs = { {"Cells",     VALUE,  0,    6,   0},
                 {"Thr (%)",   VALUE,  1,  100,  10} }

local outputs = {"code", "vlt", "pct"}

local CELL_ERROR = 3 -- any voltage below this value must be wrong

local BEEP_HIGH = 5000
local BEEP_LOW  =  100
local BEEP_DUR  =  100

local THR_ID  = "thr"
local CELL_ID = "Cels"

local STATE_ERROR        = "SE"
local STATE_WAITING_ACT  = "SWA" 
local STATE_ACTIVATED    = "SA"   
local STATE_CHECKING     = "SCK"
local STATE_SLEEPING     = "SSL"

local state = STATE_ERROR -- reset by init()

local STATE = {}
STATE[STATE_ERROR]        = {txt = "ERROR"}                     --  this is also the initial state 
STATE[STATE_WAITING_ACT]  = {txt = "WAITING_ACT", delay = 5}    --  if not sleeping, check if throttle is below threshold every 50 ms 
STATE[STATE_ACTIVATED]    = {txt = "ACTIVATED",   delay = 0}    --  this state does not persist between inovations of run() therefore delay not used 
STATE[STATE_CHECKING]     = {txt = "CHECKING",    delay = 1}    --  once activated, check cells every 10 ms
STATE[STATE_SLEEPING]     = {txt = "SLEEPING",    delay = 10}   --  check if throttle goes back above threshold every 100ms

local SILENCE  = { {75, 6000},  --  if battery is above 75% limit announcemnets to once every 60 seconds
                   {50, 3000},
                   {40, 1500},
                   {30, 1000},
                   { 0,  500} }  

local LEVELS   = { {3.50,  3},  -- map: votage -> % charge
                   {3.55,  5},
                   {3.60,  7},
                   {3.65,  9},
                   {3.70, 15},
                   {3.75, 22},
                   {3.80, 34},
                   {3.85, 48},
                   {3.90, 60},
                   {3.95, 69},
                   {4.00, 77},
                   {4.05, 83},
                   {4.10, 89},
                   {4.15, 96},
                   {4.20, 100} }

local CHECK_ITERATIONS = 50  -- on activation, check cell voltages 50 times  

local thrId      
local cellId
local checkCtr
local debugf
local lastErrCode    

local delay     = 0 
local silence   = 0 
local announce  = 0 
local lastTime  = 0
local lastCheck = 0
local minCell   = 0

-- output values 
local scaledErrCode  = ERR_CODE_INIT * 10.24  
local scaledMinCell  = 0
local scaledPctCell  = 0

local function debug(...)
  local arg={...}
  if DEBUG then
    if not debugf then 
      debugf = io.open(DEBUG_FILE, 'w')
      io.close(debugf)
    end
    debugf = io.open(DEBUG_FILE, 'a')
    for i,v in ipairs(arg) do io.write(debugf, v) end  
    io.write(debugf, "\n")
    io.close(debugf)
  end
end

local function toInteger(v)
  return math.floor(v + 0.5)
end

local function scale(v)
  return toInteger(v * 10.24)
end

local function changeState(delta, newState)
  delay = STATE[newState].delay
  debug("changeState() ", "Delta: ", delta, " STATE: ", STATE[state].txt, " -> ", STATE[newState].txt, " delay: ", delay,"\n")
  state = newState
end

local function setErrorCode(code)
  if code ~= lastErrCode then
    debug("seErrorCode() ", "lastErrCode: ", lastErrCode, " new: ", code, "\n")
    lastErrCode = code
    scaledErrCode = scale(code)
    return true 
  end 
  return false
end

local function getTelemetryId(name, debugFlag)
  local field = getFieldInfo(name)
  if field then
    if debugFlag then debug("getTelemtetryId() ", "Got telemetry id for ", name, " id: ", field.id) end
    return field.id
  else
    if debugFlag then debug("getTelemtetryId() ", "Failed to get telemetry id for ", name) end
  end
end

local function checkTelemetryIds(debugFlag)
  if not thrId  then thrId  = getTelemetryId(THR_ID, debugFlag) end
  if not cellId then cellId = getTelemetryId(CELL_ID, debugFlag) end   
  if thrId and cellId then return true end
  setErrorCode(ERR_CODE_IDS)
  return false
end

local function getSilence(pctCell)
  for i, v in ipairs(SILENCE) do
   if pctCell >= v[1] then 
      debug("getSilence() ", "cellPct: ", pctCell, " silence: ", v[2]) 
      return v[2]
    end 
  end
  debug("getSilence() ", "ERROR: Failed to get silence for pctCell: ", pctCell)
end

local function getChargePct(vlt)
  if vlt <= LEVELS[1][1] then return 0 end  
  for i, v in ipairs(LEVELS) do
    if vlt <= v[1] then
      local prevVlt = LEVELS[i-1][1]
      local prevPct = LEVELS[i-1][2]
      local deltaVlt = v[1] - prevVlt 
      local deltaPct = v[2] - prevPct 
      local deltaCel = vlt  - prevVlt
      local pct = prevPct + (deltaPct * (deltaCel / deltaVlt))  
      debug("getChargePCt() ", "i: ", i, " vlt: ", vlt, " pct: ", pct)
      return pct
    end
  end
  debug("getChargePCt() ","ERROR: Failed to calculate % charge for vlt: ", vlt)
end

local function getMinCell(id, cellCount, debugFlag)
  local MAX = 5
  local cellResult = getValue(id)
  local minCell = MAX
  local cells   = 0 
  local code    = ERR_CODE_OK
  if (type(cellResult) == "table") then
    for i, v in ipairs(cellResult) do
      if debugFlag then debug("getMinCellCount() ", "cell: ", i, " value: ", v) end
      cells = cells + 1 
      if not v or v < CELL_ERROR then  
        if debugFlag then debug("getMinCellCount() ", "ERROR: a cell voltage was too low: ", v) end
        return ERR_CODE_TELEMETRY, 0 
      end
      if v < minCell then minCell = v end
    end
  end
  if minCell == MAX then code = ERR_CODE_TELEMETRY end
  if cellCount > 0 and cells ~= cellCount then
    code = ERR_CODE_CELL_COUNT
    if debugFlag then debug("getMinCellCount() ", "ERROR: cellCount ", cells, cellCount) end
  end 
  return code, minCell
end

local function init()
  local date = getDateTime()
  local	version = getVersion()
  local dateStr = date.year.."/"..date.mon.."/"..date.day.." "..date.hour..":"..date.min
  debug(dateStr)
  debug("Version: ", version)
   
  if version < "2.0" then 
    setErrorCode(ERR_CODE_VERSION)
    return -- no recovery   
  end

  if checkTelemetryIds(true) then
    getMinCell(cellId, 0, true) 
  end
     
  setErrorCode(-1) -- set to invalid value to provoke guaranteed change, and therefore announcement, in run()
  changeState(0, STATE_WAITING_ACT)  
end

local function outputVars(now, scaledMinCell, scaledPctCell)
  if now % 100 == 0 then scaledErrCode = scaledErrCode * -1 end -- one second blink
  return scaledErrCode, scaledMinCell, scaledPctCell
end

local function run(cells, minThrottle) 
  local now = getTime()

  if state == STATE_ERROR or not checkTelemetryIds() then return outputVars(now, 0, 0) end

  local delta = now -lastTime
  local scaledMinThrottle = (minThrottle-100) * 10.24
  
  if ( delta >= delay) then
    lastTime = now
    local throttle = getValue(thrId)
    local errCode, vlt = getMinCell(cellId, cells) 
    local errCodeChange = setErrorCode(errCode)

    if (state == STATE_SLEEPING and throttle > scaledMinThrottle) then
      changeState(delta, STATE_WAITING_ACT)
    end

    if throttle <= scaledMinThrottle and state == STATE_WAITING_ACT then 
      changeState(delta, STATE_ACTIVATED)
    end

    if errCodeChange then changeState(delta, STATE_ACTIVATED) end
   
    if state == STATE_ACTIVATED then
      if errCode == ERR_CODE_OK then
        playTone(BEEP_HIGH,BEEP_DUR,0,PLAY_BACKGROUND)
      else 
        scaledMinCell = 0
        scaledPctCell = 0  
        playTone(BEEP_LOW,BEEP_DUR,0,PLAY_BACKGROUND)
      end 
      if errCode == ERR_CODE_OK then 
        changeState(delta, STATE_CHECKING)
        minCell = 0 
        checkCtr = 0
      else 
        changeState(delta, STATE_SLEEPING)
      end 
    end

    if state == STATE_CHECKING then
      checkCtr = checkCtr +1
      if vlt > minCell then minCell = vlt end -- confusing, but correct
      debug("run() ", "delta: ", delta, "\n", "SMT: ", scaledMinThrottle, "\n", "throttle: ", throttle, "\n", "vlt: ", vlt, "\n", "minCell: ", minCell, "\n\n")
      if checkCtr >= CHECK_ITERATIONS then
        local pctCell = getChargePct(minCell)
        scaledMinCell = scale(minCell)
        scaledPctCell = scale(pctCell)  
        lastCheck = now
        changeState(delta, STATE_SLEEPING) 
        if errCode == ERR_CODE_OK then
          local newSilence = getSilence(pctCell)
          if now > announce or silence ~= newSilence then  
            silence = newSilence
            announce = now + silence
            playNumber(pctCell, 13)
          end
        end 
      end
    end
  end
  
  return outputVars(now, scaledMinCell, scaledPctCell)
end

return { init=init, run=run, output=outputs, input=inputs}
