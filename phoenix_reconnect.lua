script_name('Phoenix FBI Guard')
script_author('Codex')
script_version('3.4.0')
script_description('Phoenix reconnect, Farm spawn recovery, wallet statistics and standing AFK')

-- Calibrated from an official Arizona Launcher / Phoenix trace, 2026-09-14.
-- The launcher performs account login. This file never reads credentials.

local CURRENT_VERSION='3.4.0'
local DEFAULT_UPDATE_MANIFEST_URL='https://raw.githubusercontent.com/dankiq/phoenix-fbi-guard-updates/main/PhoenixFBIGuard.manifest.txt'

local S = {
    poll_ms=50, retry_delay=30, max_retry_delay=300, restart_grace=120,
    join_timeout=180, stable_reset=60, login_attention_timeout=120,
    spawn_screen_delay=1.45, spawn_timeout=50, spawn_settle=1,
    key_step=.28, farm_watch_interval=1800, wait_connect_grace=45,
    stats_poll_interval=2, update_check_interval=21600, update_timeout=45
}
local FARM_SPAWN_INDEX=4
local VK_RETURN,VK_UP,VK_DOWN,VK_F10=0x0D,0x26,0x28,0x79

local sf,clock,ready,fatal
local cfg={enabled=true,reconnect_enabled=true,stats_enabled=true,update_enabled=true,
 update_manifest_url=DEFAULT_UPDATE_MANIFEST_URL,update_channel_initialized=false,
 stats_farm_only=true,farm_protection=true,farm_calibrated=false,farm_x=0,farm_y=0,farm_z=0,farm_interior=0,farm_radius=15}
local config_path,log_path,stats_path,target,deadline,last_state,connected_since
local attempts,queued,blocked,announced=0,false,nil,false
local login_attention_reported=false
local temporary_password_lock,password_retry_due=false,nil
local transport_closed,transport_retry_due,transport_close_reason=false,nil,nil
local keys,held={},{}
local ui={spawn_scheduled=false}
local flow={phase='BOOT',desired=nil,since=0,due=nil,spawned=false,spawn_at=nil,
 farm_check_at=0,farm_retry_at=nil,
 farm_spawn_requested=false,farm_relog_attempts=0}
local gui_ok,imgui=pcall(require,'mimgui')
local gui_open,gui_values,gui_frame,sync_gui
local recent_logs={}
local earnings={days={},session_earned=0,session_spent=0,last_money=nil,candidate_money=nil,candidate_count=0,context_since=0,next_poll=0}
local updater={status='NOT CONFIGURED',busy=false,stage=nil,temp=nil,started=0,next_check=nil,available=false,
 latest=nil,notes=nil,last_error=nil}

local function trim(v) return tostring(v or ''):match('^%s*(.-)%s*$') end
local function bool(v,d)
 v=trim(v):lower()
 if v=='true' or v=='1' or v=='on' or v=='yes' then return true end
 if v=='false' or v=='0' or v=='off' or v=='no' then return false end
 return d
end
local function clamp(v,low,high,default)
 v=tonumber(v); if not v then return default end
 return math.max(low,math.min(high,math.floor(v+.5)))
end
local function log(m)
 local line=os.date('%Y-%m-%d %H:%M:%S')..' '..tostring(m)
 recent_logs[#recent_logs+1]=line; if #recent_logs>8 then table.remove(recent_logs,1) end
 print('[PhoenixFBI] '..tostring(m))
 if log_path then local f=io.open(log_path,'a'); if f then f:write(line,'\n'); f:close() end end
end
local function tell(m,c) log(m); if ready then sampAddChatMessage('[PhoenixFBI] '..m,c or 0x80D8FF) end end

local function load_config()
 local f=io.open(config_path,'r'); if not f then return end
 for line in f:lines() do
  local k,v=line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
  if k=='enabled' then cfg.enabled=bool(v,cfg.enabled)
  elseif k=='reconnect_enabled' then cfg.reconnect_enabled=bool(v,cfg.reconnect_enabled)
  elseif k=='stats_enabled' then cfg.stats_enabled=bool(v,cfg.stats_enabled)
  elseif k=='update_enabled' then cfg.update_enabled=bool(v,cfg.update_enabled)
  elseif k=='update_manifest_url' then cfg.update_manifest_url=trim(v)
  elseif k=='update_channel_initialized' then cfg.update_channel_initialized=bool(v,cfg.update_channel_initialized)
  elseif k=='stats_farm_only' then cfg.stats_farm_only=bool(v,cfg.stats_farm_only)
  elseif k=='farm_protection' then cfg.farm_protection=bool(v,cfg.farm_protection)
  elseif k=='farm_calibrated' then cfg.farm_calibrated=bool(v,cfg.farm_calibrated)
  elseif k=='farm_x' then cfg.farm_x=tonumber(v) or cfg.farm_x
  elseif k=='farm_y' then cfg.farm_y=tonumber(v) or cfg.farm_y
  elseif k=='farm_z' then cfg.farm_z=tonumber(v) or cfg.farm_z
  elseif k=='farm_interior' then cfg.farm_interior=tonumber(v) or cfg.farm_interior
  elseif k=='farm_radius' then cfg.farm_radius=clamp(v,5,100,cfg.farm_radius)
  end
  if k=='retry_delay' then S.retry_delay=clamp(v,15,300,S.retry_delay) end
  if k=='max_retry_delay' then S.max_retry_delay=clamp(v,60,900,S.max_retry_delay) end
  if k=='restart_grace' then S.restart_grace=clamp(v,30,600,S.restart_grace) end
  if k=='wait_connect_grace' then S.wait_connect_grace=clamp(v,15,300,S.wait_connect_grace) end
  if k=='join_timeout' then S.join_timeout=clamp(v,30,600,S.join_timeout) end
  if k=='farm_watch_interval' then S.farm_watch_interval=clamp(v,300,14400,S.farm_watch_interval) end
 end
 f:close()
end
local function save_config()
 local f,e=io.open(config_path,'w'); if not f then log('Cannot save config: '..tostring(e)); return false end
 f:write('[settings]\n','enabled=',tostring(cfg.enabled),
  '\n','reconnect_enabled=',tostring(cfg.reconnect_enabled),
  '\n','stats_enabled=',tostring(cfg.stats_enabled),
  '\n','update_enabled=',tostring(cfg.update_enabled),'\n','update_manifest_url=',cfg.update_manifest_url,
  '\n','update_channel_initialized=',tostring(cfg.update_channel_initialized),
  '\n','stats_farm_only=',tostring(cfg.stats_farm_only),
  '\n','farm_protection=',tostring(cfg.farm_protection),
  '\n','farm_calibrated=',tostring(cfg.farm_calibrated),
  '\n','farm_x=',tostring(cfg.farm_x),'\n','farm_y=',tostring(cfg.farm_y),'\n','farm_z=',tostring(cfg.farm_z),
  '\n','farm_interior=',tostring(cfg.farm_interior),'\n','farm_radius=',tostring(cfg.farm_radius),
  '\n','retry_delay=',S.retry_delay,'\n','max_retry_delay=',S.max_retry_delay,
  '\n','restart_grace=',S.restart_grace,'\n','wait_connect_grace=',S.wait_connect_grace,
  '\n','join_timeout=',S.join_timeout,'\n','farm_watch_interval=',S.farm_watch_interval,'\n')
 f:close(); return true
end

local is_inside_farm

local function load_stats()
 earnings.days={}
 local f=io.open(stats_path,'r'); if not f then return end
 for line in f:lines() do
  local day,gained,spent=line:match('^(%d%d%d%d%-%d%d%-%d%d),(%d+),(%d+)$')
  if day then earnings.days[day]={earned=tonumber(gained) or 0,spent=tonumber(spent) or 0} end
 end
 f:close()
end

local function save_stats()
 local f,e=io.open(stats_path,'w'); if not f then log('Cannot save earnings statistics: '..tostring(e)); return false end
 f:write('date,earned,spent\n')
 local days={}; for day in pairs(earnings.days) do days[#days+1]=day end; table.sort(days)
 for _,day in ipairs(days) do local v=earnings.days[day]; f:write(day,',',math.floor(v.earned),',',math.floor(v.spent),'\n') end
 f:close(); return true
end

local function day_time(day)
 local y,m,d=day:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$'); if not y then return nil end
 return os.time({year=tonumber(y),month=tonumber(m),day=tonumber(d),hour=12})
end

local function stats_totals()
 local now=os.time(); local today=os.date('%Y-%m-%d',now); local t=os.date('*t',now)
 local midnight=os.time({year=t.year,month=t.month,day=t.day,hour=0})
 local monday=midnight-((t.wday+5)%7)*86400; local month=os.date('%Y-%m',now)
 local out={session={earned=earnings.session_earned,spent=earnings.session_spent},today={earned=0,spent=0},
  week={earned=0,spent=0},month={earned=0,spent=0},all={earned=0,spent=0}}
 for day,v in pairs(earnings.days) do
  out.all.earned=out.all.earned+v.earned; out.all.spent=out.all.spent+v.spent
  if day==today then out.today.earned,out.today.spent=v.earned,v.spent end
  if day:sub(1,7)==month then out.month.earned=out.month.earned+v.earned; out.month.spent=out.month.spent+v.spent end
  local stamp=day_time(day); if stamp and stamp>=monday and stamp<monday+7*86400 then
   out.week.earned=out.week.earned+v.earned; out.week.spent=out.week.spent+v.spent
  end
 end
 return out
end

local function money(v)
 local sign=v<0 and '-' or ''; local s=tostring(math.floor(math.abs(v))); local out=''
 while #s>3 do out=' '..s:sub(-3)..out; s=s:sub(1,-4) end
 return sign..s..out..' $'
end

local function stats_tick(now,state)
 if not cfg.stats_enabled or state~=sf.GAMESTATE_CONNECTED or not sampIsLocalPlayerSpawned() then
  earnings.last_money,earnings.candidate_money,earnings.candidate_count=nil,nil,0; earnings.context_since=now; earnings.next_poll=now+S.stats_poll_interval; return
 end
 if cfg.stats_farm_only and not is_inside_farm() then
  earnings.last_money,earnings.candidate_money,earnings.candidate_count=nil,nil,0; earnings.context_since=now; earnings.next_poll=now+S.stats_poll_interval; return
 end
 if now<earnings.next_poll then return end; earnings.next_poll=now+S.stats_poll_interval
 local ok,current=pcall(getPlayerMoney,PLAYER_HANDLE); current=ok and tonumber(current) or nil
 if not current then earnings.last_money=nil; return end
 current=math.floor(current)
 if earnings.candidate_money==current then earnings.candidate_count=earnings.candidate_count+1
 else earnings.candidate_money,earnings.candidate_count=current,1; return end
 if earnings.candidate_count<2 then return end
 if earnings.last_money==nil then
  if current==0 and now-(earnings.context_since or now)<15 then return end
  earnings.last_money=current; return
 end
 if current~=earnings.last_money then
  local delta=current-earnings.last_money
  if delta~=0 then
   local day=os.date('%Y-%m-%d'); local v=earnings.days[day] or {earned=0,spent=0}; earnings.days[day]=v
   if delta>0 then v.earned=v.earned+delta; earnings.session_earned=earnings.session_earned+delta
   else v.spent=v.spent-delta; earnings.session_spent=earnings.session_spent-delta end
   save_stats(); log(string.format('Wallet change tracked: %+d (balance %d).',delta,current))
  end
  earnings.last_money=current
 end
end

local function show_stats()
 local s=stats_totals()
 tell('AFK wallet statistics (earned / spent / net):')
 for _,v in ipairs({{'Session',s.session},{'Today',s.today},{'This week',s.week},{'This month',s.month},{'All time',s.all}}) do
  tell(string.format('%s: %s / %s / %s',v[1],money(v[2].earned),money(v[2].spent),money(v[2].earned-v[2].spent)))
 end
 tell('CSV: '..tostring(stats_path))
end

local function reset_money_baseline()
 earnings.last_money,earnings.candidate_money,earnings.candidate_count=nil,nil,0
 earnings.context_since=clock and clock() or 0
end

local bit_ok,bit=pcall(require,'bit')
local SHA256_K={
 0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
 0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
 0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
 0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
 0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
 0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
 0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
 0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2}
local function u32(v) v=bit.tobit(v); return v<0 and v+4294967296 or v end
local function be32(v) return string.char(bit.band(bit.rshift(v,24),255),bit.band(bit.rshift(v,16),255),bit.band(bit.rshift(v,8),255),bit.band(v,255)) end
local function sha256(data)
 if not bit_ok then return nil end
 local len=#data; local lo=(len*8)%4294967296; local hi=math.floor(len/536870912)
 data=data..string.char(128)..string.rep('\0',(55-len)%64)..be32(hi)..be32(lo)
 local h={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
 for pos=1,#data,64 do
  local w={}
  for i=0,15 do local p=pos+i*4; w[i]=u32(data:byte(p)*16777216+data:byte(p+1)*65536+data:byte(p+2)*256+data:byte(p+3)) end
  for i=16,63 do
   local x,y=w[i-15],w[i-2]
   local s0=bit.bxor(bit.ror(x,7),bit.ror(x,18),bit.rshift(x,3))
   local s1=bit.bxor(bit.ror(y,17),bit.ror(y,19),bit.rshift(y,10))
   w[i]=(w[i-16]+u32(s0)+w[i-7]+u32(s1))%4294967296
  end
  local a,b,c,d,e,f,g,hh=unpack(h)
  for i=0,63 do
   local s1=bit.bxor(bit.ror(e,6),bit.ror(e,11),bit.ror(e,25))
   local ch=bit.bxor(bit.band(e,f),bit.band(bit.bnot(e),g))
   local t1=(hh+u32(s1)+u32(ch)+SHA256_K[i+1]+w[i])%4294967296
   local s0=bit.bxor(bit.ror(a,2),bit.ror(a,13),bit.ror(a,22))
   local maj=bit.bxor(bit.band(a,b),bit.band(a,c),bit.band(b,c))
   local t2=(u32(s0)+u32(maj))%4294967296
   hh,g,f,e,d,c,b,a=g,f,e,(d+t1)%4294967296,c,b,a,(t1+t2)%4294967296
  end
  local v={a,b,c,d,e,f,g,hh}; for i=1,8 do h[i]=(h[i]+v[i])%4294967296 end
 end
 local out=''; for i=1,8 do out=out..string.format('%08x',h[i]) end; return out
end

local function read_all(path)
 local f=io.open(path,'rb'); if not f then return nil end; local data=f:read('*a'); f:close(); return data
end

local function version_newer(remote,localv)
 local a,b={},{}; for n in tostring(remote):gmatch('%d+') do a[#a+1]=tonumber(n) end; for n in tostring(localv):gmatch('%d+') do b[#b+1]=tonumber(n) end
 for i=1,math.max(#a,#b) do local x,y=a[i] or 0,b[i] or 0; if x~=y then return x>y end end; return false
end

local function parse_manifest(data)
 local m={}; for line in tostring(data):gmatch('[^\r\n]+') do local k,v=line:match('^([%w_]+)=(.*)$'); if k then m[k]=trim(v) end end
 if not m.version or not m.script_url or not m.sha256 then return nil,'manifest requires version, script_url and sha256' end
 if not m.script_url:match('^https://') then return nil,'script_url must use HTTPS' end
 if not m.sha256:match('^[0-9a-fA-F]+$') or #m.sha256~=64 then return nil,'manifest sha256 is invalid' end
 return m
end

local update_token=0
local function updater_fail(message,manual)
 updater.busy=false; updater.stage=nil; updater.status='ERROR'; updater.last_error=tostring(message)
 updater.next_check=clock and clock()+3600 or nil; log('Update error: '..tostring(message))
 if manual and ready then tell('Update error: '..tostring(message),0xFF9090) end
end

local function start_download(url,path,stage,manual,done)
 if not updater.available then updater_fail('MoonLoader download API or SHA-256 support is unavailable.',manual); return false end
 update_token=update_token+1; local token=update_token; local finished=false
 updater.busy,updater.stage,updater.temp,updater.started=true,stage,path,clock(); updater.status='DOWNLOADING '..stage:upper()
 pcall(os.remove,path)
 local ok,result=pcall(downloadUrlToFile,url,path,function(_,status)
  if token~=update_token or finished then return end
  if status==6 then
   finished=true; updater.busy=false
   local call_ok,call_error=pcall(done,path,manual)
   if not call_ok then updater_fail(call_error,manual) end
  elseif status==58 and not doesFileExist(path) then finished=true; updater_fail(stage..' download ended without a file.',manual) end
 end)
 if not ok or result==false then updater_fail('could not start '..stage..' download: '..tostring(result),manual); return false end
 return true
end

local start_update_check
local function install_downloaded_update(path,manual)
 local data=read_all(path); if not data then updater_fail('downloaded script cannot be read.',manual); return end
 local actual=sha256(data); local expected=tostring(updater.manifest.sha256):lower()
 if not actual or actual:lower()~=expected then pcall(os.remove,path); updater_fail('SHA-256 mismatch; update rejected.',manual); return end
 local declared=data:match("script_version%s*%(%s*['\"]([^'\"]+)['\"]%s*%)")
 if declared~=updater.manifest.version then pcall(os.remove,path); updater_fail('downloaded script version does not match the manifest.',manual); return end
 if not data:find("script_name('Phoenix FBI Guard')",1,true) and not data:find('script_name("Phoenix FBI Guard")',1,true) then
  pcall(os.remove,path); updater_fail('downloaded file is not Phoenix FBI Guard.',manual); return
 end
 local compiled,syntax=loadstring(data,'@PhoenixFBIGuard.update'); if not compiled then pcall(os.remove,path); updater_fail('downloaded Lua failed syntax validation: '..tostring(syntax),manual); return end
 local script=thisScript(); local destination=script and script.path
 if type(destination)~='string' or destination=='' then pcall(os.remove,path); updater_fail('current script path is unavailable.',manual); return end
 local backup=destination..'.bak'; pcall(os.remove,backup)
 local moved_old,move_error=os.rename(destination,backup)
 if not moved_old then pcall(os.remove,path); updater_fail('could not create update backup: '..tostring(move_error),manual); return end
 local moved_new,new_error=os.rename(path,destination)
 if not moved_new then os.rename(backup,destination); updater_fail('could not install update: '..tostring(new_error),manual); return end
 updater.busy=false; updater.status='UPDATED TO '..declared; updater.latest=declared; updater.last_error=nil
 tell('Updated to v'..declared..'. Backup: '..backup..'. Reloading script.',0x90FF90)
 lua_thread.create(function() wait(1200); thisScript():reload() end)
end

local function process_update_manifest(path,manual)
 local data=read_all(path); pcall(os.remove,path)
 local manifest,e=parse_manifest(data); if not manifest then updater_fail(e,manual); return end
 updater.manifest,updater.latest,updater.notes=manifest,manifest.version,manifest.notes
 if not version_newer(manifest.version,CURRENT_VERSION) then
  updater.status='UP TO DATE'; updater.last_error=nil; updater.next_check=clock()+S.update_check_interval
  if manual then tell('No update needed. Current version is '..CURRENT_VERSION..'.') end; return
 end
 updater.status='UPDATE FOUND '..manifest.version
 tell('Update '..manifest.version..' found. Downloading and verifying it.',0xFFD280)
 local temp=getWorkingDirectory()..'\\config\\PhoenixFBIGuard.update.lua'
 local separator=manifest.script_url:find('?',1,true) and '&' or '?'
 start_download(manifest.script_url..separator..'t='..tostring(os.time()),temp,'script',manual,install_downloaded_update)
end

start_update_check=function(manual)
 if not cfg.update_enabled and not manual then return end
 if updater.busy then if manual then tell('Update check is already running.') end; return end
 if cfg.update_manifest_url=='' then
  updater.status='NOT CONFIGURED'; updater.last_error='Manifest URL is empty.'
  if manual then tell('Auto-update needs an HTTPS manifest URL in the control panel.',0xFFD280) end; return
 end
 if not cfg.update_manifest_url:match('^https://') then updater_fail('manifest URL must use HTTPS.',manual); return end
 updater.status='CHECKING'; updater.last_error=nil
 local temp=getWorkingDirectory()..'\\config\\PhoenixFBIGuard.manifest.tmp'
 local separator=cfg.update_manifest_url:find('?',1,true) and '&' or '?'
 start_download(cfg.update_manifest_url..separator..'t='..tostring(os.time()),temp,'manifest',manual,process_update_manifest)
end

local function update_tick(now)
 if updater.busy and now-updater.started>S.update_timeout then
  update_token=update_token+1; pcall(os.remove,updater.temp); updater_fail(updater.stage..' download timed out.',false); return
 end
 if cfg.update_enabled and updater.next_check and now>=updater.next_check then
  updater.next_check=now+S.update_check_interval; start_update_check(false)
 end
end
local function valid_address(ip,port)
 return type(ip)=='string' and ip~='' and ip~='0.0.0.0' and type(port)=='number' and port>=1 and port<=65535
end
local function retry_delay() return math.min(S.max_retry_delay,S.retry_delay*2^math.min(attempts,10)) end

local function set_key(k,d)
 if held[k]==d then return end
 setVirtualKeyDown(k,d); held[k]=d
end
local function release_keys()
 for k,d in pairs(held) do if d then setVirtualKeyDown(k,false) end; held[k]=false end
 keys={}
end
local function pulse(k,at,d)
 d=math.max(d or .16,.16)
 keys[#keys+1]={at=at,key=k,down=true}; keys[#keys+1]={at=at+d,key=k,down=false}
end
local function tick_keys(now)
 if #keys>0 and now>=keys[1].at then local v=table.remove(keys,1); set_key(v.key,v.down) end
end

local function phase(name,now,msg)
 if flow.phase~=name then log('workflow '..flow.phase..' -> '..name) end
 flow.phase,flow.since,flow.due=name,now,nil
 if msg then tell(msg) end
end
local function clear_ui()
 ui.spawn_scheduled=false
 flow.spawned,flow.spawn_at=false,nil
end
local function default_destination()
 flow.desired='farm'
end

local function schedule_spawn(now)
 if ui.spawn_scheduled or sampIsLocalPlayerSpawned() or not cfg.enabled then return end
 ui.spawn_scheduled=true
 local index=FARM_SPAWN_INDEX
 flow.farm_spawn_requested=true
 local at=now+S.spawn_screen_delay
 for _=1,8 do pulse(VK_UP,at,.16); at=at+S.key_step end
 for _=2,index do pulse(VK_DOWN,at,.16); at=at+S.key_step end
 pulse(VK_RETURN,at,.20)
 phase('WAIT_SPAWN',now,string.format('Selecting Farm spawn (menu item %d).',index))
end

local function read_arizona(bs,sub)
 if not bs then return nil end
 local offset=raknetBitStreamGetReadOffset(bs)
 local ok,result=pcall(function()
  raknetBitStreamSetReadOffset(bs,0)
  if raknetBitStreamReadInt8(bs)~=220 or raknetBitStreamReadInt8(bs)~=sub then return nil end
  if sub==17 then
   raknetBitStreamReadInt32(bs)
   local len=raknetBitStreamReadInt16(bs); local enc=raknetBitStreamReadInt8(bs)
   if not len or len<1 or len>65535 then return nil end
   if enc and enc~=0 then return raknetBitStreamDecodeString(bs,len+enc) end
   return raknetBitStreamReadString(bs,len)
  end
  local len=raknetBitStreamReadInt16(bs); if not len or len<1 or len>65535 then return nil end
  return raknetBitStreamReadString(bs,len)
 end)
 raknetBitStreamSetReadOffset(bs,offset)
 if ok then return result end; log('CEF packet read error: '..tostring(result)); return nil
end

is_inside_farm=function()
 if not cfg.farm_calibrated or getCharActiveInterior(PLAYER_PED)~=cfg.farm_interior then return false end
 local x,y,z=getCharCoordinates(PLAYER_PED)
 local dx,dy,dz=x-cfg.farm_x,y-cfg.farm_y,z-cfg.farm_z
 return dx*dx+dy*dy+dz*dz<=cfg.farm_radius*cfg.farm_radius
end
local function reconnect_to_farm(now,reason)
 if flow.farm_relog_attempts>=2 then
  release_keys(); flow.farm_retry_at=now+S.farm_watch_interval
  phase('WAIT_FARM_RETRY',now,string.format('Farm was not reached after two relogs. Retrying in %d minutes; check menu item #4.',math.floor(S.farm_watch_interval/60)))
  return
 end
 flow.farm_relog_attempts=flow.farm_relog_attempts+1
 release_keys(); clear_ui(); flow.farm_spawn_requested=false; flow.desired='farm'
 phase('RECONNECTING_FARM',now,string.format('%s Relog to Farm (%d/2 before cooldown).',reason,flow.farm_relog_attempts))
 local ok,e=pcall(sampProcessChatInput,'/reconnect')
 if not ok then phase('FAILED',now,'Could not execute /reconnect: '..tostring(e)) end
end

local function farm_tick(now)
 if not sampIsLocalPlayerSpawned() then
  if flow.phase=='DONE' then
   clear_ui(); flow.farm_spawn_requested=false
   phase('WAIT_LOGIN',now,'Character disappeared; waiting to restore Farm spawn.')
  elseif flow.phase=='WAIT_SPAWN' and now-flow.since>S.spawn_timeout then
   release_keys(); phase('FAILED',now,'Farm spawn selection timed out. Check for a login code or changed menu.')
  end
  return
 end
 if not flow.spawned then
  temporary_password_lock,password_retry_due=false,nil
  flow.spawned,flow.spawn_at=true,now; release_keys(); ui.spawn_scheduled=false
  phase('SPAWN_SETTLE',now,'Character appeared; checking Farm position.'); return
 end
 if flow.phase=='SPAWN_SETTLE' and now-flow.spawn_at>=S.spawn_settle then
  if not cfg.farm_calibrated and flow.farm_spawn_requested then
   local x,y,z=getCharCoordinates(PLAYER_PED)
   cfg.farm_x,cfg.farm_y,cfg.farm_z=x,y,z
   cfg.farm_interior=getCharActiveInterior(PLAYER_PED); cfg.farm_calibrated=true; save_config()
   tell(string.format('Menu item #4 spawn recorded at %.1f / %.1f / %.1f, interior %d. Confirm on screen that this is Farm.',x,y,z,cfg.farm_interior),0xFFD280)
  end
  if is_inside_farm() then
   flow.farm_relog_attempts=0; flow.farm_spawn_requested=false; flow.farm_retry_at=nil; flow.farm_check_at=now+S.farm_watch_interval
   phase('DONE',now,'Recorded Farm zone reached. Character is standing AFK.'); return
  end
  reconnect_to_farm(now,'Character is outside the recorded Farm spawn.'); return
 end
 if flow.phase=='WAIT_FARM_RETRY' and flow.farm_retry_at and now>=flow.farm_retry_at then
  flow.farm_relog_attempts=0; flow.farm_retry_at=nil
  reconnect_to_farm(now,'Scheduled Farm recovery retry.'); return
 end
 if flow.phase=='DONE' and cfg.farm_protection and now>=flow.farm_check_at then
  flow.farm_check_at=now+S.farm_watch_interval
  if not is_inside_farm() then reconnect_to_farm(now,'Character left the Farm spawn zone.') end
 end
end

local function flow_tick(now,state)
 tick_keys(now)
 if not cfg.enabled or state~=sf.GAMESTATE_CONNECTED then return end
 farm_tick(now)
end

local function reset_connection(now)
 release_keys(); clear_ui(); flow.farm_spawn_requested=false; flow.since=now
 earnings.last_money,earnings.candidate_money,earnings.candidate_count=nil,nil,0; earnings.context_since=now; earnings.next_poll=now+3
 if not flow.desired then default_destination() end
 flow.phase='WAIT_LOGIN'
end

local function perform_reconnect(now,reason)
 attempts=attempts+1
 deadline=now+retry_delay()
 tell(string.format('Reconnect attempt %d%s.',attempts,reason and (' ('..reason..')') or ''))
 -- Arizona has provided /reconnect as a built-in client command since 2025.
 -- It is used first because it also resets launcher-side login state.
 local ok,e=pcall(sampProcessChatInput,'/reconnect')
 if not ok then
  log('Official /reconnect call failed, using address fallback: '..tostring(e))
  if target then sampConnectToServer(target.ip,target.port) end
 end
 if transport_closed then transport_retry_due=now+retry_delay() end
 if temporary_password_lock then password_retry_due=now+retry_delay() end
end

local function reconnect_tick(now,state)
 local ip,port=sampGetCurrentServerAddress()
 if transport_closed then
  if blocked or not cfg.enabled or not cfg.reconnect_enabled or not target then return end
  if transport_retry_due and now>=transport_retry_due then
   perform_reconnect(now,transport_close_reason or 'server closed the connection')
  end
  return
 end
 if temporary_password_lock and password_retry_due and now>=password_retry_due and target then
  password_retry_due=nil; perform_reconnect(now,'server is still locked for restart'); return
 end
 if target and valid_address(ip,port) and (target.ip~=ip or target.port~=port) then
  tell('Server address changed; waiting for a fresh Phoenix connection.')
  target,deadline,connected_since=nil,nil,nil; attempts,queued,announced=0,false,false
  default_destination(); reset_connection(now); return
 end
 if state~=last_state then
  log(string.format('state %s -> %s',tostring(last_state),tostring(state)))
  local was=last_state==sf.GAMESTATE_CONNECTED
  last_state,deadline,connected_since=state,nil,nil
  if was or state==sf.GAMESTATE_CONNECTED then reset_connection(now) end
 end
 if state==sf.GAMESTATE_CONNECTED then
  local name=(sampGetCurrentServerName() or ''):gsub('{%x%x%x%x%x%x}',''):lower()
  if not name:find('phoenix',1,true) then return end
  if not target and valid_address(ip,port) then target={ip=ip,port=port} end
  if target and not announced then tell('Phoenix detected. Farm spawn and reconnect automation is ready.'); announced=true end
  deadline,queued=nil,false; connected_since=connected_since or now
  if sampIsLocalPlayerSpawned() then temporary_password_lock,password_retry_due=false,nil end
  if now-connected_since>=S.stable_reset then attempts=0 end
  if not sampIsLocalPlayerSpawned() and not login_attention_reported and now-connected_since>=S.login_attention_timeout then
   login_attention_reported=true; tell('Login is still waiting after 120s. Check for a rare verification code.',0xFF9090)
  end
  return
 end
 login_attention_reported=false
 if not cfg.enabled or not cfg.reconnect_enabled or blocked or not target then return end
 local delay
 if state==sf.GAMESTATE_WAIT_CONNECT then delay=math.max(S.wait_connect_grace,retry_delay())
 elseif state==sf.GAMESTATE_AWAIT_JOIN then if queued then deadline=nil; return end; delay=math.max(S.join_timeout,retry_delay())
 elseif state==sf.GAMESTATE_RESTARTING then delay=math.max(S.restart_grace,retry_delay())
 elseif state==sf.GAMESTATE_DISCONNECTED or state==sf.GAMESTATE_NONE then delay=retry_delay()
 else fatal='Unsupported connection state: '..tostring(state); cfg.enabled,deadline=false,nil; tell(fatal,0xFF9090); return end
 if not deadline then deadline=now+delay; tell(string.format('Connection unavailable. Grace period: %ds.',delay)) end
 if now<deadline then return end
 perform_reconnect(now,temporary_password_lock and 'temporary restart password' or nil)
end

local function state_name(state)
 if not sf then return tostring(state or 'unknown') end
 local names={{'CONNECTED','GAMESTATE_CONNECTED'},{'WAIT_CONNECT','GAMESTATE_WAIT_CONNECT'},{'AWAIT_JOIN','GAMESTATE_AWAIT_JOIN'},
  {'RESTARTING','GAMESTATE_RESTARTING'},{'DISCONNECTED','GAMESTATE_DISCONNECTED'},{'NONE','GAMESTATE_NONE'}}
 for _,v in ipairs(names) do if state==sf[v[2]] then return v[1] end end
 return tostring(state or 'unknown')
end

local function status()
 tell(string.format('%s | state=%s | workflow=%s | destination=Farm (#4) | calibrated=%s | relog=%d/2 | restart-lock=%s | transport-close=%s',
  cfg.enabled and 'ON' or 'OFF',state_name(last_state),flow.phase,
  cfg.farm_calibrated and 'YES' or 'NO',flow.farm_relog_attempts,
  temporary_password_lock and 'WAITING' or 'NO',transport_closed and 'WAITING' or 'NO'))
 if blocked then tell('Stopped: '..blocked) end
 local next_due=transport_retry_due or password_retry_due or deadline or flow.farm_retry_at
 if next_due then tell('Next reconnect check in '..math.ceil(math.max(0,next_due-clock()))..'s.') end
 tell(string.format('Features: reconnect=%s Farm-protection=%s wallet=%s Farm-only=%s',
  cfg.reconnect_enabled and 'ON' or 'OFF',cfg.farm_protection and 'ON' or 'OFF',
  cfg.stats_enabled and 'ON' or 'OFF',cfg.stats_farm_only and 'ON' or 'OFF'))
end

local function feature(field,value,label)
 cfg[field]=value
 save_config(); if sync_gui then sync_gui() end
 tell(label..' is '..(value and 'ON.' or 'OFF.'))
end

local function command(args)
 args=trim(args):lower()
 if args=='off' then cfg.enabled,deadline=false,nil; transport_closed,transport_retry_due=false,nil; release_keys(); save_config(); if sync_gui then sync_gui() end; tell('Automation is OFF.')
 elseif args=='on' then cfg.enabled,blocked,deadline,fatal=true,nil,nil,nil; transport_closed,transport_retry_due=false,nil; attempts=0; save_config(); if sync_gui then sync_gui() end; tell('Automation is ON.')
 elseif args=='run' or args=='retry' then
  cfg.enabled,blocked,fatal=true,nil,nil; release_keys(); clear_ui()
  flow.farm_relog_attempts=0; flow.farm_spawn_requested=false; flow.farm_retry_at=nil
  if sampIsLocalPlayerSpawned() then flow.spawned,flow.spawn_at=true,clock(); phase('SPAWN_SETTLE',clock(),'Manual workflow retry started.')
  else default_destination(); phase('WAIT_LOGIN',clock(),'Waiting for login screen.') end
  save_config(); if sync_gui then sync_gui() end
 elseif args=='reconnect on' then feature('reconnect_enabled',true,'Network reconnect')
 elseif args=='reconnect off' then feature('reconnect_enabled',false,'Network reconnect')
 elseif args=='farm on' then feature('farm_protection',true,'Farm position protection')
 elseif args=='farm off' then feature('farm_protection',false,'Farm position protection')
 elseif args=='stats on' then feature('stats_enabled',true,'Earnings tracking')
 elseif args=='stats off' then feature('stats_enabled',false,'Earnings tracking'); reset_money_baseline()
 else status(); tell('Commands: /phrec on/off/run/status | reconnect/farm/stats on/off | /phfarm | /phmenu') end
end

local function stats_command(args)
 args=trim(args):lower()
 if args=='on' then feature('stats_enabled',true,'Earnings tracking'); reset_money_baseline()
 elseif args=='off' then feature('stats_enabled',false,'Earnings tracking'); reset_money_baseline()
 elseif args=='farm' then cfg.stats_farm_only=true; reset_money_baseline(); save_config(); if sync_gui then sync_gui() end; tell('Earnings tracking is limited to the Farm spawn zone.')
 elseif args=='all' then cfg.stats_farm_only=false; reset_money_baseline(); save_config(); if sync_gui then sync_gui() end; tell('Earnings tracking now includes every location.')
 elseif args=='baseline' then reset_money_baseline(); tell('Wallet baseline will be captured again without counting a change.')
 else show_stats() end
end

local function farm_command(args)
 args=trim(args):lower()
 if args=='calibrate' then
  if not sampIsLocalPlayerSpawned() then tell('Spawn at Farm before calibration.',0xFFD280); return end
  local x,y,z=getCharCoordinates(PLAYER_PED)
  cfg.farm_x,cfg.farm_y,cfg.farm_z=x,y,z; cfg.farm_interior=getCharActiveInterior(PLAYER_PED)
  cfg.farm_calibrated=true; flow.farm_relog_attempts=0; flow.farm_retry_at=nil
  flow.farm_check_at=clock()+S.farm_watch_interval; phase('DONE',clock()); save_config(); reset_money_baseline()
  tell(string.format('Farm position saved: %.1f / %.1f / %.1f, interior %d.',x,y,z,cfg.farm_interior))
 elseif args=='forget' then cfg.farm_calibrated=false; save_config(); reset_money_baseline(); tell('Farm position forgotten; next selected Farm spawn will be recorded.')
 elseif args:match('^radius %d+$') then
  cfg.farm_radius=clamp(args:match('%d+'),5,100,cfg.farm_radius)
  save_config(); if sync_gui then sync_gui() end; reset_money_baseline()
  tell('Farm radius set to '..cfg.farm_radius..' game units.')
 elseif args:match('^interval %d+$') then
  S.farm_watch_interval=clamp(tonumber(args:match('%d+'))*60,300,14400,S.farm_watch_interval)
  flow.farm_check_at=clock()+S.farm_watch_interval
  if flow.farm_retry_at then flow.farm_retry_at=clock()+S.farm_watch_interval end
  save_config(); if sync_gui then sync_gui() end
  tell('Farm position check every '..math.floor(S.farm_watch_interval/60)..' minutes.')
 else
  tell(string.format('Farm menu #%d | calibrated=%s | center=%.1f / %.1f / %.1f | interior=%d | radius=%d | check=%d min',
   FARM_SPAWN_INDEX,cfg.farm_calibrated and 'YES' or 'NO',cfg.farm_x,cfg.farm_y,cfg.farm_z,cfg.farm_interior,cfg.farm_radius,math.floor(S.farm_watch_interval/60)))
  tell('Commands: /phfarm calibrate | forget | radius 15 | interval 30 | status')
 end
end

local function update_command(args)
 local raw=trim(args); local lower=raw:lower()
 if lower=='on' then cfg.update_enabled=true; save_config(); updater.next_check=clock()+2; if sync_gui then sync_gui() end; tell('Automatic updates are ON.')
 elseif lower=='off' then cfg.update_enabled=false; save_config(); if sync_gui then sync_gui() end; tell('Automatic updates are OFF.')
 elseif lower=='check' or lower=='' or lower=='status' then
  if lower=='check' then start_update_check(true)
  else tell(string.format('Updater: %s | current=%s | latest=%s',updater.status,CURRENT_VERSION,tostring(updater.latest or 'unknown'))); if updater.last_error then tell(updater.last_error,0xFFD280) end end
 elseif lower=='url clear' then
  cfg.update_manifest_url=''; cfg.update_channel_initialized=true; updater.status='NOT CONFIGURED'; save_config(); if sync_gui then sync_gui() end
  tell('Update channel URL cleared.')
 elseif lower:sub(1,4)=='url ' then
  local url=trim(raw:sub(5)); if url~='' and not url:match('^https://') then tell('Update URL must use HTTPS.',0xFF9090); return end
  cfg.update_manifest_url=url; cfg.update_channel_initialized=true; updater.status=url=='' and 'NOT CONFIGURED' or 'READY'; save_config(); if sync_gui then sync_gui() end
  tell(url=='' and 'Update channel URL cleared.' or 'Update channel saved. Use /phupdate check.')
 else tell('Commands: /phupdate check | status | on | off | url https://... | url clear') end
end

local function setup_gui()
 if not gui_ok or type(imgui)~='table' or type(wasKeyPressed)~='function' then
  gui_ok=false; log('Visual panel unavailable: install mimgui v1.7.1+ into moonloader\\lib. Chat controls remain available.'); return false
 end
 local new=imgui.new
 local ffi=require 'ffi'
 gui_open=new.bool(false)
 gui_values={enabled=new.bool(false),reconnect=new.bool(false),farm=new.bool(false),
  stats=new.bool(false),stats_farm=new.bool(false),update=new.bool(false),update_url=new.char[512](),
  retry=new.int(30),max_retry=new.int(300),restart=new.int(120),wait_connect=new.int(45),join=new.int(180),
  farm_minutes=new.int(30),farm_radius=new.int(15)}
 local function set_url_buffer(value)
  value=tostring(value or ''); ffi.fill(gui_values.update_url,512,0); ffi.copy(gui_values.update_url,value,math.min(#value,511))
 end
 sync_gui=function()
  gui_values.enabled[0]=cfg.enabled; gui_values.reconnect[0]=cfg.reconnect_enabled
  gui_values.farm[0]=cfg.farm_protection
  gui_values.stats[0]=cfg.stats_enabled; gui_values.stats_farm[0]=cfg.stats_farm_only; gui_values.update[0]=cfg.update_enabled
  gui_values.retry[0]=S.retry_delay; gui_values.max_retry[0]=S.max_retry_delay
  gui_values.restart[0]=S.restart_grace; gui_values.wait_connect[0]=S.wait_connect_grace
  gui_values.join[0]=S.join_timeout
  gui_values.farm_minutes[0]=math.floor(S.farm_watch_interval/60); gui_values.farm_radius[0]=cfg.farm_radius
  set_url_buffer(cfg.update_manifest_url)
 end
 sync_gui()
 local function apply_toggles()
  if cfg.enabled~=gui_values.enabled[0] then command(gui_values.enabled[0] and 'on' or 'off') end
  local stats_changed=cfg.stats_enabled~=gui_values.stats[0] or cfg.stats_farm_only~=gui_values.stats_farm[0]
  cfg.reconnect_enabled=gui_values.reconnect[0]; cfg.farm_protection=gui_values.farm[0]
  cfg.stats_enabled=gui_values.stats[0]; cfg.stats_farm_only=gui_values.stats_farm[0]; cfg.update_enabled=gui_values.update[0]
  if stats_changed then reset_money_baseline() end; save_config()
 end
 local function apply_timings()
  S.retry_delay=clamp(gui_values.retry[0],15,300,30)
  S.max_retry_delay=math.max(S.retry_delay,clamp(gui_values.max_retry[0],60,900,300))
  S.restart_grace=clamp(gui_values.restart[0],30,600,120)
  S.wait_connect_grace=clamp(gui_values.wait_connect[0],15,300,45)
  S.join_timeout=clamp(gui_values.join[0],30,600,180)
  S.farm_watch_interval=clamp(gui_values.farm_minutes[0]*60,300,14400,1800)
  cfg.farm_radius=clamp(gui_values.farm_radius[0],5,100,15)
  flow.farm_check_at=clock()+S.farm_watch_interval
  if flow.farm_retry_at then flow.farm_retry_at=clock()+S.farm_watch_interval end
  save_config(); sync_gui(); tell('Control panel timings saved.')
 end
 gui_frame=imgui.OnFrame(function() return gui_open[0] end,function()
  local io=imgui.GetIO()
  imgui.SetNextWindowPos(imgui.ImVec2(io.DisplaySize.x/2,io.DisplaySize.y/2),imgui.Cond.FirstUseEver,imgui.ImVec2(.5,.5))
  imgui.SetNextWindowSize(imgui.ImVec2(620,720),imgui.Cond.FirstUseEver)
  imgui.Begin('Phoenix Farm Guard 3.4.0',gui_open,imgui.WindowFlags.NoCollapse)
  imgui.Text('LIVE STATUS')
  imgui.Separator()
  imgui.Text('Connection state: '..state_name(last_state))
  imgui.Text('Workflow: '..tostring(flow.phase)..'   Destination: '..tostring(flow.desired or 'auto'))
  imgui.Text('Reconnect attempts: '..tostring(attempts)..'   Queue: '..(queued and 'YES' or 'NO'))
  imgui.Text('Farm: menu item #4   Calibration: '..(cfg.farm_calibrated and 'YES' or 'NO'))
  imgui.Text(string.format('Farm center: %.1f / %.1f / %.1f   Interior: %d',cfg.farm_x,cfg.farm_y,cfg.farm_z,cfg.farm_interior))
  if sampIsLocalPlayerSpawned() then
   local ok,x,y,z=pcall(getCharCoordinates,PLAYER_PED)
   local iok,interior=pcall(getCharActiveInterior,PLAYER_PED)
   if ok then imgui.Text(string.format('Position: %.1f / %.1f / %.1f   Interior: %s',x,y,z,iok and tostring(interior) or '?')) end
  end
  local next_due=transport_retry_due or password_retry_due or deadline or flow.farm_retry_at
  imgui.Text('Next reconnect: '..(next_due and (tostring(math.ceil(math.max(0,next_due-clock())))..' sec') or 'none'))
  if blocked then imgui.TextWrapped('STOPPED: '..tostring(blocked)) end
  imgui.Separator()
  imgui.Text('FEATURES')
  local changed=false
  if imgui.Checkbox('Master automation',gui_values.enabled) then changed=true end
  if imgui.Checkbox('Recover network disconnects',gui_values.reconnect) then changed=true end
  if imgui.Checkbox('Keep character at Farm spawn',gui_values.farm) then changed=true end
  if imgui.Checkbox('Track wallet changes',gui_values.stats) then changed=true end
  if imgui.Checkbox('Count earnings only near Farm spawn',gui_values.stats_farm) then changed=true end
  if imgui.Checkbox('Install verified updates automatically',gui_values.update) then changed=true end
  if changed then apply_toggles() end
  imgui.Separator()
  imgui.Text('AFK WALLET STATISTICS (earned / spent / net)')
  local totals=stats_totals()
  for _,v in ipairs({{'Session',totals.session},{'Today',totals.today},{'This week',totals.week},{'This month',totals.month},{'All time',totals.all}}) do
   imgui.Text(string.format('%s: %s / %s / %s',v[1],money(v[2].earned),money(v[2].spent),money(v[2].earned-v[2].spent)))
  end
  imgui.Text('CSV: '..tostring(stats_path or 'not initialized'))
  if imgui.Button('Reset wallet baseline') then reset_money_baseline(); tell('Wallet baseline reset.') end
  if imgui.Button('Calibrate current position as Farm') then farm_command('calibrate') end
  imgui.Separator()
  imgui.Text('TIMINGS (seconds)')
  imgui.InputInt('Base reconnect delay (15-300)',gui_values.retry)
  imgui.InputInt('Maximum reconnect delay (60-900)',gui_values.max_retry)
  imgui.InputInt('Restart grace (30-600)',gui_values.restart)
  imgui.InputInt('WAIT_CONNECT grace (15-300)',gui_values.wait_connect)
  imgui.InputInt('Join timeout (30-600)',gui_values.join)
  imgui.InputInt('Farm position check, minutes (5-240)',gui_values.farm_minutes)
  imgui.InputInt('Farm radius, game units (5-100)',gui_values.farm_radius)
  if imgui.Button('Save timings') then apply_timings() end
  imgui.SameLine()
  if imgui.Button('Restore timing defaults') then
   gui_values.retry[0],gui_values.max_retry[0],gui_values.restart[0],gui_values.wait_connect[0]=30,300,120,45
   gui_values.join[0]=180; gui_values.farm_minutes[0]=30; gui_values.farm_radius[0]=15; apply_timings()
  end
  imgui.Separator()
  if imgui.Button('Retry Farm recovery now') then command('run') end
  imgui.SameLine()
  if imgui.Button('Emergency stop') then command('off') end
  imgui.Separator()
  imgui.Text('AUTO UPDATE')
  imgui.Text('Status: '..updater.status..'   Current: '..CURRENT_VERSION..'   Latest: '..tostring(updater.latest or 'unknown'))
  imgui.InputText('Manifest HTTPS URL',gui_values.update_url,512)
  if imgui.Button('Save update channel') then
   local url=trim(ffi.string(gui_values.update_url)); if url=='' or url:match('^https://') then
    cfg.update_manifest_url=url; cfg.update_channel_initialized=true; updater.status=url=='' and 'NOT CONFIGURED' or 'READY'; save_config(); tell('Update channel saved.')
   else tell('Update manifest URL must use HTTPS.',0xFF9090) end
  end
  imgui.SameLine()
  if imgui.Button('Check update now') then start_update_check(true) end
  if updater.last_error then imgui.TextWrapped('Last update error: '..updater.last_error) end
  imgui.Separator()
  imgui.Text('RECENT EVENTS')
  for _,line in ipairs(recent_logs) do imgui.TextWrapped(line) end
  imgui.End()
 end)
 gui_frame.LockPlayer=true; gui_frame.HideCursor=false
 return true
end

local function toggle_gui()
 if not gui_ok or not gui_open then tell('Visual panel needs mimgui v1.7.1+ in moonloader\\lib. Use /phrec for chat controls.',0xFFD280); return end
 sync_gui(); gui_open[0]=not gui_open[0]
end

function onReceivePacket(id,bs)
 if not ready then return end
 if id==220 then
  local m=read_arizona(bs,17)
  if m then
   if not sampIsLocalPlayerSpawned() and
      (m:find('event.auth.initializeSpawnPoints',1,true) or m:find('event.auth.updateVideoBackgroundVisible',1,true)) then
    schedule_spawn(clock())
   end
  end
  return
 end
 if not target then return end
 if id==sf.PACKET_DISCONNECTION_NOTIFICATION or id==sf.PACKET_CONNECTION_LOST then
  if not transport_closed then
   local now=clock()
   transport_closed=true
   transport_close_reason=id==sf.PACKET_DISCONNECTION_NOTIFICATION and 'server closed the connection' or 'connection was lost'
   transport_retry_due=now+retry_delay(); deadline=transport_retry_due; connected_since=nil; queued=false
   release_keys(); clear_ui(); reset_connection(now)
   tell(string.format('Detected: %s (packet %d). Official /reconnect will run in %ds.',transport_close_reason,id,math.ceil(transport_retry_due-now)),0xFFD280)
  end
 elseif id==sf.PACKET_CONNECTION_BANNED then
  transport_closed,transport_retry_due=false,nil
  blocked,deadline='Server reported a network/connection block. Check the launcher message.',nil
  release_keys(); tell(blocked,0xFF9090)
 elseif id==sf.PACKET_INVALID_PASSWORD then
  -- Phoenix temporarily protects the server with a password while restart is
  -- still closed. This is a retryable state, not an account-password failure.
  transport_closed,transport_retry_due=false,nil
  temporary_password_lock,blocked=true,nil
  release_keys()
  password_retry_due=clock()+retry_delay(); deadline=password_retry_due
  tell('Server is temporarily password-locked during restart. Will keep retrying with backoff.',0xFFD280)
 elseif id==sf.PACKET_NO_FREE_INCOMING_CONNECTIONS then transport_closed,transport_retry_due=false,nil; queued,deadline=true,nil
 elseif id==sf.PACKET_CONNECTION_REQUEST_ACCEPTED then
   transport_closed,transport_retry_due,transport_close_reason=false,nil,nil
   queued=false; temporary_password_lock,password_retry_due=false,nil
 end
end

local function validate_runtime()
 for _,n in ipairs({'GAMESTATE_CONNECTED','GAMESTATE_WAIT_CONNECT','GAMESTATE_AWAIT_JOIN','GAMESTATE_RESTARTING',
  'GAMESTATE_DISCONNECTED','GAMESTATE_NONE','PACKET_DISCONNECTION_NOTIFICATION','PACKET_CONNECTION_LOST',
  'PACKET_CONNECTION_BANNED','PACKET_INVALID_PASSWORD',
  'PACKET_NO_FREE_INCOMING_CONNECTIONS','PACKET_CONNECTION_REQUEST_ACCEPTED'}) do
  if type(sf[n])~='number' then return false,'sampfuncs.lua is missing '..n end
 end
 local required={'isSampAvailable','sampGetGamestate','sampGetCurrentServerAddress','sampGetCurrentServerName',
  'sampConnectToServer','sampRegisterChatCommand','sampAddChatMessage','sampIsLocalPlayerSpawned',
  'setVirtualKeyDown','getCharCoordinates','getCharActiveInterior','getPlayerMoney',
  'sampProcessChatInput','getWorkingDirectory',
  'doesDirectoryExist','createDirectory','raknetBitStreamGetReadOffset',
  'raknetBitStreamSetReadOffset','raknetBitStreamReadInt8','raknetBitStreamReadInt16','raknetBitStreamReadInt32',
  'raknetBitStreamReadString','raknetBitStreamDecodeString'}
 for _,n in ipairs(required) do if type(_G[n])~='function' then return false,'runtime function is missing: '..n end end
 return true
end

local function init_clock()
 local ok,ffi=pcall(require,'ffi'); if not ok then return false,'LuaJIT FFI is unavailable.' end
 return pcall(function()
  ffi.cdef('unsigned long __stdcall GetTickCount(void);'); local kernel=ffi.load('kernel32')
  local previous,elapsed=tonumber(kernel.GetTickCount()),0
  clock=function() local current=tonumber(kernel.GetTickCount()); elapsed=elapsed+(current-previous)%4294967296; previous=current; return elapsed/1000 end
 end)
end

function main()
 local ok,result=pcall(require,'sampfuncs'); if not ok then print('[PhoenixFBI] Missing sampfuncs.lua: '..tostring(result)); return end
 sf=result
 if type(isSampfuncsLoaded)~='function' or not isSampfuncsLoaded() then
  print('[PhoenixFBI] A launcher-compatible SAMPFUNCS installation is required.'); return
 end
 local vok,ve=validate_runtime(); if not vok then print('[PhoenixFBI] Incompatible MoonLoader: '..ve); return end
 local cok,ce=init_clock(); if not cok then print('[PhoenixFBI] Clock initialization failed: '..tostring(ce)); return end
 local dir=getWorkingDirectory()..'\\config'; if not doesDirectoryExist(dir) then createDirectory(dir) end
 config_path=dir..'\\PhoenixFBIGuard.ini'; stats_path=dir..'\\PhoenixFarmGuard_stats.csv'; log_path=getWorkingDirectory()..'\\PhoenixFBIGuard.log'
 load_config()
 -- Old FBI, house and guard settings are ignored; only Farm settings are saved below.
 if not cfg.update_channel_initialized then
  cfg.update_manifest_url=DEFAULT_UPDATE_MANIFEST_URL
  cfg.update_channel_initialized=true
 end
 load_stats(); save_config(); save_stats(); default_destination()
 local hash_ok=bit_ok and sha256('abc')=='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
 if bit_ok and not hash_ok then log('Updater disabled: internal SHA-256 self-test failed.') end
 updater.available=hash_ok and type(downloadUrlToFile)=='function' and type(doesFileExist)=='function' and type(thisScript)=='function' and type(lua_thread)=='table'
 updater.next_check=clock()+10
 while not isSampAvailable() do wait(500) end
 ready=true
 if not sampRegisterChatCommand('phrec',command) then
  tell('Command /phrec is already registered. Remove the older Phoenix script and restart the game.',0xFF9090); return
 end
 if not sampRegisterChatCommand('phmenu',toggle_gui) then
  tell('Command /phmenu is already registered. The F10 panel hotkey remains available.',0xFFD280)
 end
 if not sampRegisterChatCommand('phstats',stats_command) then tell('Command /phstats is already registered.',0xFFD280) end
 if not sampRegisterChatCommand('phfarm',farm_command) then tell('Command /phfarm is already registered.',0xFFD280) end
 if not sampRegisterChatCommand('phupdate',update_command) then tell('Command /phupdate is already registered.',0xFFD280) end
 setup_gui()
 tell('v3.4.0 loaded. Farm spawn #4, wallet statistics and verified updater are ready. /phrec status')
 while true do
  if isSampAvailable() then
   local step_ok,step_error=pcall(function()
    if gui_ok and wasKeyPressed(VK_F10) then toggle_gui() end
    local now=clock(); local state=sampGetGamestate(); reconnect_tick(now,state); flow_tick(now,state); stats_tick(now,state); update_tick(now)
   end)
   if not step_ok then
    fatal='Runtime error; automation stopped. See PhoenixFBIGuard.log and moonloader.log.'
    cfg.enabled,deadline=false,nil; release_keys(); tell(fatal,0xFF9090); log(tostring(step_error)); break
   end
  end
  wait(S.poll_ms)
 end
 release_keys(); wait(-1)
end
