--[[
	================================================================
	 loader.lua — 从 GitHub 拉取并运行 dungeon.lua（自续链 / 全自动）
	================================================================

	 用法：
	   1. 把 dungeon.lua 【和这个 loader.lua】都传到同一个公开仓库
	   2. 确认下面的 SCRIPT_URL 是你的 dungeon.lua raw 链接
	   3. 在 Xeno 里执行【这个文件】一次

	 之后就是全自动：
	   随便换多少次服务器都会自己回来。

	 为什么能续链：
	   排队的代码去重新拉取【加载器自己】（链接是从 SCRIPT_URL 推导的），
	   加载器每次运行又会再排一次队 —— 于是无限续下去。
	   （早先的版本排队的是 dungeon.lua，它自己不再排队，
	     所以只能自动一次，第二次换服就断了。）

	 注意：仓库必须【公开】，私有仓库的 raw 链接需要登录，拉不到。
--]]

-- ══════════════════════════════════════════════════════════
--  ★ 这一行你已填好：dungeon.lua 的 raw 链接 ★
-- ══════════════════════════════════════════════════════════
local SCRIPT_URL = "https://raw.githubusercontent.com/xipo520lol/just/refs/heads/main/dungeon.lua"

-- ══════════════════════════════════════════════════════════
--  加载器自己的链接：把文件名换成 loader.lua
--  （所以 loader.lua 必须也传到同一个仓库）
-- ══════════════════════════════════════════════════════════
local LOADER_URL = SCRIPT_URL:gsub("dungeon%.lua", "loader.lua")

-- 加时间戳绕开 GitHub 缓存
local function withBust(url)
	local sep = string.find(url, "?", 1, true) and "&" or "?"
	return url .. sep .. "t=" .. tostring(os.time())
end

-- 拉取并执行一段代码；返回 是否成功, 错误信息
local function runUrl(url, what)
	local ok, src = pcall(function() return game:HttpGet(withBust(url)) end)
	if not ok or type(src) ~= "string" or #src < 80 then
		return false, string.format("拉取 %s 失败: %s", what, tostring(src))
	end
	local fn, err = loadstring(src)
	if not fn then
		return false, string.format("%s 语法错误: %s", what, tostring(err))
	end
	local ok2, err2 = pcall(fn)
	if not ok2 then
		return false, string.format("%s 执行出错: %s", what, tostring(err2))
	end
	print(string.format("[Loader] %s 已加载 %d 字节", what, #src))
	return true
end

-- ══════════════════════════════════════════════════════════
--  ★ 换服后排队的代码 ★
--  它做的事：重新拉取【加载器自己】并执行。
--  加载器一跑，又会调用 queue_on_teleport 再排一次 —— 自续链。
-- ══════════════════════════════════════════════════════════
local QUEUED = ([[
	local LOADER = %q
	-- 换服后角色要几秒才出来，先等它有 Humanoid
	local PLR = game:GetService("Players").LocalPlayer
	local waited = 0
	while waited < 30 do
		local c = PLR and PLR.Character
		if c and c:FindFirstChildOfClass("Humanoid") then break end
		task.wait(0.5)
		waited = waited + 0.5
	end
	task.wait(1)
	local sep = string.find(LOADER, "?", 1, true) and "&" or "?"
	local ok, src = pcall(function() return game:HttpGet(LOADER .. sep .. "t=" .. tostring(os.time())) end)
	if not ok or type(src) ~= "string" then
		warn("[Loader] 换服后拉取加载器失败: " .. tostring(src))
		return
	end
	local fn = loadstring(src)
	if fn then pcall(fn) end
]]):format(LOADER_URL)

-- ══════════════════════════════════════════════════════════
--  排队 + 立即执行
-- ══════════════════════════════════════════════════════════
if queue_on_teleport then
	local ok = pcall(function() queue_on_teleport(QUEUED) end)
	if ok then
		print("[Loader] 已排队：换服后自动回来（可续链，无限次）")
	else
		warn("[Loader] queue_on_teleport 调用失败 —— 换服后需要手动再执行一次。")
	end
else
	warn("[Loader] 这个执行器没有 queue_on_teleport —— 换服后需要手动再执行一次。")
end

print("[Loader] 正在拉取 dungeon.lua（首次）…")
local okRun, errRun = runUrl(SCRIPT_URL, "dungeon.lua")
if not okRun then
	warn("[Loader] " .. tostring(errRun))
	warn("[Loader] 检查：仓库公开吗？URL 是 raw.githubusercontent.com 形式吗？")
end
