--[[
	================================================================
	 loader.lua — 从 GitHub 拉取并运行 dungeon.lua（自续链 / 全自动）
	================================================================

	 用法：
	   1. dungeon.lua 和这个 loader.lua 都放在同一个【公开】仓库
	   2. 确认下面的 SCRIPT_URL 是 dungeon.lua 的 raw 链接
	   3. 在 Xeno 里执行【这个文件】一次

	 v4 依据实测日志修的：
	   日志显示 —— game:HttpGet ok=true -> nil（调用成功但返回 nil，静默失败）
	              request    ok=true -> table:0x...（★ 其实成功了 ★）
	   所以：request 放第一位，并且放宽对返回格式的接受（Body / body / 直接字符串）。
--]]

-- ══════════════════════════════════════════════════════════
local SCRIPT_URL = "https://raw.githubusercontent.com/xipo520lol/just/refs/heads/main/dungeon.lua"
-- ══════════════════════════════════════════════════════════

-- ★ 开关：不想要"换服后自动拉取"就改成 false（只拉一次，不续链）
local AUTO_RECUR = true
-- ══════════════════════════════════════════════════════════

-- 加载器自己的链接：换文件名即可（所以 loader.lua 必须也在同一仓库）
local LOADER_URL = SCRIPT_URL:gsub("dungeon%.lua", "loader.lua")

-- ══════════════════════════════════════════════════════════
--  ★ HTTP 拉取（按实测顺序）★
--  ① request   —— 实测这个能用
--  ② game:HttpGet —— 实测返回 nil，放后面兜底
--  ③ httpget   —— 有些执行器只有这个
--  返回 body, 错误信息（错误里带状态码，方便定位）
-- ══════════════════════════════════════════════════════════
local function httpGet(url)
	local sep = string.find(url, "?", 1, true) and "&" or "?"
	local u = url .. sep .. "t=" .. tostring(os.time())
	local errs = {}

	-- ① request（syn.request 或全局 request）
	local req = (syn and syn.request) or request
	if req then
		local ok, res = pcall(function()
			return req({ Url = u, Method = "GET" })
		end)
		if ok and type(res) == "table" then
			-- 不同执行器字段名不一样，都试一下
			local body = res.Body or res.body or res.Data or res.data
			if type(body) == "string" and #body > 0 then return body end
			errs[#errs + 1] = string.format("request 状态=%s Body=%s 长度=%s",
				tostring(res.StatusCode or res.Status or "?"),
				type(body), body and #body or "nil")
		else
			errs[#errs + 1] = "request ok=" .. tostring(ok) .. " -> " .. tostring(res)
		end
	end

	-- ② game:HttpGet
	if game and game.HttpGet then
		local ok, res = pcall(function() return game:HttpGet(u) end)
		if ok and type(res) == "string" and #res > 0 then return res end
		errs[#errs + 1] = "game:HttpGet ok=" .. tostring(ok) .. " -> " .. tostring(res)
	end

	-- ③ 全局 httpget
	if httpget then
		local ok, res = pcall(function() return httpget(u) end)
		if ok and type(res) == "string" and #res > 0 then return res end
		errs[#errs + 1] = "httpget ok=" .. tostring(ok) .. " -> " .. tostring(res)
	end

	if #errs == 0 then
		return nil, "这个执行器没有任何可用的 HTTP 方法"
	end
	return nil, table.concat(errs, " | ")
end

-- 带重试的拉取 = 【无限重试直到成功】
-- 实测网络不稳定：同一个链接有时 200、有时超时。
-- 所以不设上限 —— 一直试，每隔几秒一次，成功为止。
-- （放在独立线程里调用，不会挡住排队/UI。）
local function httpGetForever(url, label)
	local n = 0
	while true do
		n = n + 1
		local body, err = httpGet(url)
		if body then
			if n > 1 then
				print(string.format("[Loader] %s 第 %d 次尝试成功", label, n))
			end
			return body
		end
		-- 第 1 次和之后每 5 次报一次，别刷屏
		if n == 1 or n % 5 == 0 then
			print(string.format("[Loader] %s 第 %d 次失败，3 秒后继续重试…（%s）",
				label, n, tostring(err)))
		end
		task.wait(3)
	end
end

local function runUrl(url, what)
	local src = httpGetForever(url, what)
	if #src < 80 then
		return false, string.format("%s 内容太短（%d 字节），可能拉到了错误页", what, #src)
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
--  内嵌一份精简版的多方法拉取（不能只靠 game:HttpGet —— 实测它返回 nil）
-- ══════════════════════════════════════════════════════════
local QUEUED = ([[
	local LOADER = %q
	local function g(u)
		u = u .. (string.find(u, "?", 1, true) and "&" or "?") .. "t=" .. tostring(os.time())
		local req = (syn and syn.request) or request
		if req then
			local ok, res = pcall(function() return req({ Url = u, Method = "GET" }) end)
			if ok and type(res) == "table" then
				local b = res.Body or res.body or res.Data
				if type(b) == "string" and #b > 0 then return b end
			end
		end
		if game and game.HttpGet then
			local ok, res = pcall(function() return game:HttpGet(u) end)
			if ok and type(res) == "string" and #res > 0 then return res end
		end
		return nil
	end
	-- 等角色出来
	local PLR = game:GetService("Players").LocalPlayer
	local waited = 0
	while waited < 30 do
		local c = PLR and PLR.Character
		if c and c:FindFirstChildOfClass("Humanoid") then break end
		task.wait(0.5)
		waited = waited + 0.5
	end
	task.wait(1)
	-- ★ 无限重试直到拉到 ★（换服后也一样，网络不稳时别放弃）
	local src
	local n = 0
	while not src do
		n = n + 1
		local s = g(LOADER)
		if s and #s > 80 then src = s break end
		if n == 1 or n % 5 == 0 then
			warn(string.format("[Loader] 换服后拉取加载器第 %d 次失败，3 秒后继续…", n))
		end
		task.wait(3)
	end
	local fn = loadstring(src)
	if fn then pcall(fn) end
]]):format(LOADER_URL)

-- ══════════════════════════════════════════════════════════
--  排队 + 立即执行
-- ══════════════════════════════════════════════════════════
if AUTO_RECUR and queue_on_teleport then
	local ok = pcall(function() queue_on_teleport(QUEUED) end)
	if ok then
		print("[Loader] 已排队：换服后自动回来（可续链，无限次）")
	else
		warn("[Loader] queue_on_teleport 调用失败 —— 换服后需要手动再执行一次。")
	end
elseif not AUTO_RECUR then
	print("[Loader] AUTO_RECUR = false：只拉这一次，不排队续链")
else
	warn("[Loader] 没有 queue_on_teleport —— 换服后需要手动再执行一次。")
end

print("[Loader] 正在拉取 dungeon.lua（首次，失败会自动无限重试）…")
-- ★ 放独立线程：里面有"无限重试"，不能挡住排队和后面的代码 ★
task.spawn(function()
	local okRun, errRun = runUrl(SCRIPT_URL, "dungeon.lua")
	if not okRun then
		-- 这里只会在"拉到了但内容有问题（太短/语法错/执行错）"时才到
		warn("[Loader] " .. tostring(errRun))
		warn("[Loader] 内容问题不是网络问题 —— 检查 GitHub 上那个文件本身。")
	end
end)
