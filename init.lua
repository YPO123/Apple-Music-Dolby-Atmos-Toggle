-- ================================
--  Uni Studio - Open Source
-- ================================

local ax = require("hs.axuielement")

-- ===== 小工具 =====
local function wait(sec) hs.timer.usleep(sec * 1e6) end
local function alert(msg, t) hs.alert.closeAll(); hs.alert.show(msg, t or 1.6) end

-- Return & Enter（用于自动点“继续”）
local function pressReturnFallback()
  hs.timer.doAfter(0, function()
    hs.eventtap.keyStroke({}, "return")
    hs.eventtap.keyStroke({}, "enter")
  end)
end

-- 获取 Apple Music 应用（不自动启动，只聚焦）
local MUSIC_BUNDLE = "com.apple.Music"
local function getMusicApp()
  local apps = hs.application.applicationsForBundleID(MUSIC_BUNDLE)
  if apps and #apps > 0 then
    local app = apps[1]
    app:activate(true) -- 聚焦前台
    return app
  end
  return nil
end

-- 取 AX 应用对象
local function getAXApp(app, timeout)
  timeout = timeout or 5
  local t0 = hs.timer.secondsSinceEpoch()
  while hs.timer.secondsSinceEpoch() - t0 < timeout do
    local axApp = ax.applicationElement(app)
    if axApp and axApp.AXWindows then return axApp end
    wait(0.1)
  end
  return nil
end

-- 打开偏好设置
local function openPrefsViaMenu(app)
  local paths = {
    {"Music","Settings…"},{"Music","Preferences…"},
    {"音乐","设置…"},{"音乐","偏好设置…"},
  }
  for _, p in ipairs(paths) do
    if app:selectMenuItem(p) then return true end
  end
  -- 兜底：⌘,
  hs.eventtap.keyStroke({"cmd"}, ",", 0, app); wait(0.1)
  hs.eventtap.keyStroke({"cmd"}, ",", 0, app)
  return true
end

-- 遍历
local function walk(elem, fn)
  if not elem then return false end
  for _, ch in ipairs(elem.AXChildren or {}) do
    if fn(ch) then return true end
    if walk(ch, fn) then return true end --Uni Studio
  end
  return false
end

-- 窗口是否像偏好设置
local function looksLikePrefs(win)
  if not win then return false end
  local ok = false
  walk(win, function(ch)
    local r = ch.AXRole
    if r == "AXTabGroup" or r == "AXToolbar" or r == "AXSheet" then ok = true; return true end
    return false
  end)
  return ok
end

-- 切到播放页
local function pressPlaybackTab(win)
  local targets = {"播放","Playback"}
  walk(win, function(ch)
    if ch.AXRole == "AXTabGroup" or ch.AXRole == "AXRadioGroup" then
      for _, t in ipairs(ch.AXChildren or {}) do
        local title = t.AXTitle or "" -- Uni Studio
        for _, want in ipairs(targets) do
          if title == want then pcall(function() t:performAction("AXPress") end); return true end
        end
      end
    end
    if ch.AXRole == "AXToolbar" then
      for _, t in ipairs(ch.AXChildren or {}) do
        local title = t.AXTitle or ""
        for _, want in ipairs(targets) do
          if title == want then pcall(function() t:performAction("AXPress") end); return true end
        end
      end
    end
    return false
  end)
end

-- 找 Atmos 下拉
local function findAllPopups(win)
  local list = {}
  walk(win, function(ch)
    if ch.AXRole == "AXPopUpButton" then table.insert(list, ch) end
    return false
  end)
  return list
end
local function getAtmosPopup(win)
  local pops = findAllPopups(win)
  local order = {3,2,4,1}
  for _, i in ipairs(order) do
    if pops[i] then return pops[i] end -- Uni Studio
  end
  return pops[1]
end

-- 展开 PopUp → AXMenu
local function openPopupAndGetMenu(pop)
  if not pop then return nil end
  pcall(function() pop:performAction("AXPress") end)
  local t0 = hs.timer.secondsSinceEpoch()
  while hs.timer.secondsSinceEpoch() - t0 < 3.5 do
    for _, ch in ipairs(pop.AXChildren or {}) do
      if ch.AXRole == "AXMenu" then return ch end
    end
    wait(0.06)
  end
  return nil
end

-- 点击菜单项
local function clickMenuByTitle(menu, titles)
  for _, it in ipairs(menu.AXChildren or {}) do
    local title = it.AXTitle or ""
    for _, want in ipairs(titles) do
      if title == want then pcall(function() it:performAction("AXPress") end); return true end
    end
  end
  return false
end
local function clickMenuByIndex(menu, index)
  local items = menu.AXChildren or {}
  local it = items[index] -- Uni Studio
  if it then pcall(function() it:performAction("AXPress") end); return true end
  return false
end

-- 取当前值
local function getPopupValue(pop)
  local ok, v = pcall(function() return pop:attributeValue("AXValue") end)
  if ok and v then return tostring(v) end
  local ok2, t = pcall(function() return pop:attributeValue("AXTitle") end)
  if ok2 and t then return tostring(t) end
  return "" -- Uni Studio
end

-- 确保偏好设置窗口
local function ensurePrefsWindow(axApp, app)
  local focused = axApp.AXFocusedWindow
  if focused and looksLikePrefs(focused) then return focused end
  openPrefsViaMenu(app)
  local t0 = hs.timer.secondsSinceEpoch()
  while hs.timer.secondsSinceEpoch() - t0 < 5.0 do
    local now = axApp.AXFocusedWindow
    if now and looksLikePrefs(now) then return now end
    local wins = axApp.AXWindows or {}
    for _, w in ipairs(wins) do
      if looksLikePrefs(w) then return w end
      local hasSheet = false -- Uni Studio
      walk(w, function(ch) if ch.AXRole == "AXSheet" then hasSheet = true; return true end return false end)
      if hasSheet then return w end
    end
    wait(0.15)
  end
  return axApp.AXFocusedWindow
end

-- 主流程
local function doAtmos(menuChoiceTitles, menuIndexFallback, modeLabel)
  local app = getMusicApp()
  if not app then alert("Apple Music has not been launched"); return end

  local axApp = getAXApp(app)
  if not axApp then alert("系统设置→隐私与安全性→辅助功能 勾选 Hammerspoon \n System Settings → Privacy and Security → Accessibility → Select Hammerspoon"); return end

  local prefsWin = ensurePrefsWindow(axApp, app)
  if not prefsWin then alert("The preference settings window has not been opened"); pressReturnFallback(); return end

  pressPlaybackTab(prefsWin); wait(0.25)

  local pop = getAtmosPopup(prefsWin)
  if not pop then alert("The pop out menu was not found"); pressReturnFallback(); return end

  local menu = openPopupAndGetMenu(pop)
  if not menu then alert("The menu did not pop out"); pressReturnFallback(); return end

  local ok = clickMenuByTitle(menu, menuChoiceTitles)
  if not ok and menuIndexFallback then ok = clickMenuByIndex(menu, menuIndexFallback) end
  if not ok then alert("Check if the language is English/ simplified Chinese (menu target item not found)"); pressReturnFallback(); return end

  wait(0.2)
  if modeLabel == "Atmos" then
    alert("Dolby Atmos")
  else
    alert("Stereo")
  end

  pressReturnFallback()
end

-- 对外动作
local function atmos_force_auto() doAtmos({"自动","Automatic","始终开启","Always On"}, 1, "Atmos") end
local function atmos_force_off()  doAtmos({"关闭","Off"}, 3, "Stereo") end

-- 全局热键
hs.hotkey.bind({"ctrl","cmd","alt"}, "a", atmos_force_auto) -- ⌃⌘⌥A → Dolby Atmos
hs.hotkey.bind({"ctrl","cmd","alt"}, "s", atmos_force_off)  -- ⌃⌘⌥S → Stereo



--  _    _       _    _____ _             _ _       
-- | |  | |     (_)  / ____| |           | (_)      
-- | |  | |_ __  _  | (___ | |_ _   _  __| |_  ___  
-- | |  | | '_ \| |  \___ \| __| | | |/ _` | |/ _ \ 
-- | |__| | | | | |  ____) | |_| |_| | (_| | | (_) |
-- \_____/|_| |_|_| |_____/ \__|\__,_|\__,_|_|\___/ 

-- by Zichen Huang 20250826
