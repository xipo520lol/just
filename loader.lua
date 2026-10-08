--[[
	================================================================
	 loader.lua — 从 GitHub 拉取并运行 dungeon.lua（自续链 / 全自动）
	================================================================

	 用法：
	   1. dungeon.lua 和这个 loader.lua 都放在同一个【公开】仓库
	   2. 确认下面的 SCRIPT_URL 是 dungeon.lua 的 raw 链接
	   3. 在 Xeno 里执行【这个文件】一次

	 v6 —— 实测日志定位到根因：
	   request 状态=403 Body=nil
	   403 = Forbidden。raw.githubusercontent.com 会【拒绝没有 User-Agent
	   的请求】。我的 PowerShell 带了 UA 所以次次 200，执行器的 request
	   不带 UA 所以次次 403 —— 现象完全对得上。

	  修法两条一起上：
	   ① request 里带上 User-Agent（关键修复）
	   ② 加 jsDelivr 备用源：cdn.jsdelivr.net/gh/用户/仓库@main/文件
	      jsDelivr 不挑 UA，而且有 CDN 缓存，通常更快更稳
	  两个源轮着试，任何一个成功就继续。
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
--  ★ 从一个 raw 链接推出 jsDelivr 备用链接 ★
--  raw:      https://raw.githubusercontent.com/用户/仓库/refs/heads/main/文件
--  jsDelivr: https://cdn.jsdelivr.net/gh/用户/仓库@main/文件
-- ══════════════════════════════════════════════════════════
local function toJsdelivr(url)  -- 用 fastly 节点（实测 cdn 节点连不上）
	local user, repo, branch, file =
		url:match("raw%.githubusercontent%.com/([^/]+)/([^/]+)/refs/heads/([^/]+)/(.+)$")
	if not user then
		user, repo, branch, file =
			url:match("raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.+)$")
	end
	if not user then return nil end
	return string.format("https://cdn.jsdelivr.net/gh/%s/%s@%s/%s", user, repo, branch, file)
end

-- 候选链接列表（先 raw，失败后自动换 jsDelivr）
local function candidates(url)
	local out = { url }
	local j = toJsdelivr(url)
	if j then out[#out + 1] = j end
	return out
end

local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

-- ══════════════════════════════════════════════════════════
--  ★ HTTP 拉取 ★
--  返回 body, 错误信息（错误里带状态码，方便定位）
-- ══════════════════════════════════════════════════════════
local function httpGet(url)
	local sep = string.find(url, "?", 1, true) and "&" or "?"
	local u = url .. sep .. "t=" .. tostring(os.time())
	local errs = {}

	-- ① request —— ★ 必须带 User-Agent，不然 GitHub 回 403 ★
	-- 但实测：加了 UA 还是 403。多半是执行器根本没把我们给的 Headers 发出去。
	-- 所以这里把【几种常见的 Headers 写法全带上】——
	-- 各执行器认哪个不一样，多写不冲突，认的那一种就能生效。
	local req = (syn and syn.request) or request
	if req then
		local ok, res = pcall(function()
			return req({
				Url = u,
				Method = "GET",
				-- 写法 A：Headers
				Headers = {
					["User-Agent"] = UA,
					["Accept"] = "*/*",
				},
				-- 写法 B：HttpHeaders（有些执行器只认这个）
				HttpHeaders = {
					["User-Agent"] = UA,
					["Accept"] = "*/*",
				},
				-- 写法 C：顶层字段（还有的执行器把 UA 当独立参数）
				UserAgent = UA,
			})
		end)
		if ok and type(res) == "table" then
			local body = res.Body or res.body or res.Data or res.data
			if type(body) == "string" and #body > 0 then return body end
			errs[#errs + 1] = string.format("request 状态=%s 长度=%s",
				tostring(res.StatusCode or res.Status or "?"),
				body and #body or "nil")
		else
			errs[#errs + 1] = "request ok=" .. tostring(ok) .. " -> " .. tostring(res)
		end
	end

	-- ② game:HttpGet（部分执行器会自己带 UA）
	if game and game.HttpGet then
		local ok, res = pcall(function() return game:HttpGet(u) end)
		if ok and type(res) == "string" and #res > 0 then return res end
		errs[#errs + 1] = "game:HttpGet -> " .. tostring(res)
	end

	-- ③ 全局 httpget
	if httpget then
		local ok, res = pcall(function() return httpget(u) end)
		if ok and type(res) == "string" and #res > 0 then return res end
		errs[#errs + 1] = "httpget -> " .. tostring(res)
	end

	if #errs == 0 then
		return nil, "这个执行器没有任何可用的 HTTP 方法"
	end
	return nil, table.concat(errs, " | ")
end

-- 带重试的拉取 = 【无限重试直到成功】
-- 每轮会依次试 raw 和 fastly 两个源，并把【每个源各自的结果】打出来，
-- 这样日志能直接看出是哪个源、什么状态，而不用猜。
local function httpGetForever(url, label)
	local urls = candidates(url)
	local n = 0
	-- ★ 一开始就把候选链接打出来 ★ 日志里能看到实际用的是哪两个
	print(string.format("[Loader] %s 的候选源：", label))
	for i, u in ipairs(urls) do print(string.format("[Loader]   %d) %s", i, u)) end
	while true do
		n = n + 1
		local detail = {}
		for i, u in ipairs(urls) do
			local body, err = httpGet(u)
			if body then
				if n > 1 then
					print(string.format("[Loader] %s 第 %d 次尝试成功", label, n))
				end
				if i > 1 then
					print(string.format("[Loader] （用的是第 %d 个源：%s）", i, u))
				end
				return body
			end
			detail[#detail + 1] = string.format("源%d[%s]", i, tostring(err))
		end
		if n == 1 or n % 5 == 0 then
			print(string.format("[Loader] %s 第 %d 次失败，3 秒后继续重试…（%s）",
				label, n, table.concat(detail, " ; ")))
		end
		task.wait(3)
	end
end

-- ★ 本地缓存文件名 ★
-- 首次成功拉到之后，把源码写进这个文件。换服后【先读本地】，
-- 读不到再走网络 —— 这样换服完全不受网络时好时坏的影响。
-- （执行器的 workspace 文件在换服后依然存在）
local CACHE_FILE = "dungeon_cache.lua"

local function runUrl(url, what)
	local src = httpGetForever(url, what)
	if #src < 80 then
		return false, string.format("%s 内容太短（%d 字节），可能拉到了错误页", what, #src)
	end
	-- ★ 存一份到本地，供换服后直接读取 ★
	if writefile then
		local okW = pcall(writefile, CACHE_FILE, src)
		if okW then print(string.format("[Loader] 已缓存到本地：%s", CACHE_FILE))
		else print("[Loader] 本地缓存写入失败（不影响本次运行）") end
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
--  内嵌同样的逻辑：带 UA 的 request + jsDelivr 备用源 + 无限重试
--  （注意：模板里除了 %q，其它 % 都必须写成 %% —— 否则外层 :format
--    会把它当占位符，报 "missing argument"。这里踩过坑。）
-- ══════════════════════════════════════════════════════════
local QUEUED = ([[
	local RAW = %q
	local CACHE = %q
	local function toJs(u)
		-- 注意：这里是【模板内部】。Lua 模式里的百分号必须写成两个，
		-- 否则外层 format 会把它当占位符，报 missing argument。
		local a, b, c, d = u:match("raw%%.githubusercontent%%.com/([^/]+)/([^/]+)/refs/heads/([^/]+)/(.+)$")
		if not a then a, b, c, d = u:match("raw%%.githubusercontent%%.com/([^/]+)/([^/]+)/([^/]+)/(.+)$") end
		if not a then return nil end
		return string.format("https://fastly.jsdelivr.net/gh/%%s/%%s@%%s/%%s", a, b, c, d)
	end
	local RAW2 = toJs(RAW)
	local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

	local function g(u)
		u = u .. (string.find(u, "?", 1, true) and "&" or "?") .. "t=" .. tostring(os.time())
		local req = (syn and syn.request) or request
		if req then
			-- ★ 带 User-Agent，否则 GitHub 回 403 ★
			local ok, res = pcall(function()
				return req({
					Url = u, Method = "GET",
					Headers = { ["User-Agent"] = UA, ["Accept"] = "*/*" },
					HttpHeaders = { ["User-Agent"] = UA, ["Accept"] = "*/*" },
					UserAgent = UA,
				})
			end)
			if ok and type(res) == "table" then
				local b = res.Body or res.body or res.Data
				if type(b) == "string" and #b > 0 then return b end
				return nil, string.format("状态=%%s", tostring(res.StatusCode or res.Status or "?"))
			end
		end
		if game and game.HttpGet then
			local ok, res = pcall(function() return game:HttpGet(u) end)
			if ok and type(res) == "string" and #res > 0 then return res end
			return nil, "HttpGet=nil"
		end
		return nil, "没有可用的 HTTP 方法"
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

	-- ★★ 第一步：先读本地缓存 ★★
	-- 换服后网络常常拉不到，但本地文件一直在。
	-- 有缓存就直接用，完全不需要网络。
	local src
	if readfile and isfile then
		local okf, has = pcall(isfile, CACHE)
		if okf and has then
			local okr, cached = pcall(readfile, CACHE)
			if okr and type(cached) == "string" and #cached > 80 then
				src = cached
				print(string.format("[Loader] 换服后已从本地缓存加载（%%d 字节，不用网络）", #src))
			end
		end
	end

	-- ★★ 第二步：本地没有才走网络，两个源轮着试，无限重试 ★★
	local n = 0
	while not src do
		n = n + 1
		local detail = {}
		for i, u in ipairs({ RAW, RAW2 }) do
			if u then
				local s, e = g(u)
				if s and #s > 80 then src = s
					print(string.format("[Loader] 换服后从源 %%d 拉到（第 %%d 次尝试）", i, n))
					break
				end
				detail[#detail + 1] = string.format("源%%d[%%s]", i, tostring(e))
			end
		end
		if not src then
			if n == 1 or n %% 5 == 0 then
				warn(string.format("[Loader] 换服后拉取失败第 %%d 次，3 秒后继续…（%%s）",
					n, table.concat(detail, " ; ")))
			end
			task.wait(3)
		end
	end

	-- 网络拿到的顺手也缓存一份
	if writefile and src ~= nil then pcall(writefile, CACHE, src) end
	local fn = loadstring(src)
	if fn then pcall(fn) end
]]):format(LOADER_URL, CACHE_FILE)

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
		warn("[Loader] " .. tostring(errRun))
		warn("[Loader] 内容问题不是网络问题 —— 检查 GitHub 上那个文件本身。")
	end
end)
