--[[
	================================================================
	 AutoFarm.lua — 自动刷怪（输入模拟版）
	================================================================

	 设计原则：只发【真实输入】，不伪造任何 Remote。

	   · 左键攻击 → mouse1click()（执行器提供的真鼠标点击）
	   · 技能     → keypress / keyrelease（真按键）
	   · 贴脸     → 改自己角色的 CFrame（复用落点做法）

	 为什么这么做：这样游戏自己的战斗逻辑照常跑，客户端没有伪造任何请求。
	 比手工构造 attack Remote 安全得多 —— 那类服务端基本都会校验距离/朝向/冷却。

	 它也同时适用于两种情况（工具驱动 / Remote 驱动），因为按下去的
	 就是真实的键，游戏内部怎么实现都不用管。

	 依赖执行器函数：mouse1click、keypress、keyrelease。
	 缺哪个脚本启动时会明确告诉你，不会静默失败。

	 请在你自己拥有或有权限的场所内使用，账号风险自行承担。
--]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")

local PLR = Players.LocalPlayer
if not PLR then
	warn("[Farm] 找不到 LocalPlayer，请在 Roblox 客户端内执行。")
	return
end

local CAM = workspace.CurrentCamera

--------------------------------------------------------------------------------
-- 配置
--------------------------------------------------------------------------------
local CONFIG = {
	keyToggle = Enum.KeyCode.Insert,   -- 开关自动刷怪
	keyUnload = Enum.KeyCode.End,      -- 卸载
	keyChest  = Enum.KeyCode.K,        -- 自动开箱开关（副本模式）
	keySpawn  = Enum.KeyCode.L,        -- 传送到最近的刷怪点
	keyTrigger = Enum.KeyCode.T,       -- 挨个走一遍所有刷怪点（触发刷怪）
	keyAuto   = Enum.KeyCode.Y,        -- ★ 自动完成一二部分 ★
	keyRecordWp = Enum.KeyCode.N,      -- 就地记录当前站坐标（卡住时用）
	keyDoor   = Enum.KeyCode.O,        -- 传送到 Key 门
	keySavePos = Enum.KeyCode.P,       -- 记录当前坐标
	keyGoPos  = Enum.KeyCode.J,        -- 传送到记录的坐标

	-- 目标识别
	--
	-- 从探针输出得知：
	--   怪都在   Workspace.MobFolder/<怪名>/Enemy
	--   NPC 都在 Workspace.NPCs
	-- 所以只扫 MobFolder：
	--   ① 快得多 —— 不用遍历整个 workspace（这正是"运行失败"的根因）
	--   ② 准得多 —— NPC、训练假人、其他玩家都不会被当成怪
	-- 留空 = 退回遍历整个 workspace（万一容器改名了还能用）
	mobContainers  = { "MobFolder" },
	npcContainers  = { "NPCs" },

	mobMatch      = {},                            -- 空 = 所有带 Humanoid 的 Model 都算怪
	                                               -- 想只打特定名字就填，例如 { "slime", "goblin" }
	-- 名字含这些的不打。探针里实际出现的：
	--   DPS Dummy R6 / R15  → 训练假人
	--   Infinity Module     → 练习靶（HP 是 inf，打不死）
	excludeNames  = { "dummy", "infinity", "training", "test", "summon", "totem" },
	excludePlayers = true,                         -- 不打其他玩家

	-- 刷怪列表刷新间隔（秒）。
	-- 这个必须存在：找出怪要遍历容器，很贵。
	-- 放进每帧的 Heartbeat 里会把客户端拖死（表现就是"运行失败"或游戏卡住）。
	-- 所以：贵的遍历按这个间隔做，每帧只在缓存里算距离。
	mobRefreshInterval = 1.5,

	-- 按键发送方式："auto"（先试 VirtualInputManager）/ "executor"（只用 keypress）
	-- 如果技能和走位都没反应，先看控制台那行"按键方式"是不是打出来了。
	keyMethod = "auto",

	-- 战斗距离。你的武器是【剑气，远程】——
	-- 站在怪脸上既危险又没必要，应该站远了打。
	-- 之前 standOffset = 5 是给近战设计的，对远程武器是错的。
	combatDistance     = 100,  -- 想和怪保持的距离（studs）。你要求拉到 100。
	repositionTolerance = 25,  -- 比这个数近了/远了才重新站位（免得一直抖）
	                           -- 距离拉到 100 之后容差也要跟着放大，
	                           -- 否则怪一动就触发重新站位，会疯狂瞬移。
	repositionCooldown  = 1.5, -- 两次重新站位之间至少隔多久（秒）
	                           -- 这游戏拦连续瞬移，别站得太勤

	-- 贴脸（只在 combatDistance 用不了时兜底）
	autoTeleport     = true,
	range            = 30,    -- 超过这个距离才考虑传送（近了就不用动）
	standOffset      = 5,     -- 老的"站侧面"偏移，已被 combatDistance 取代
	maxDropBelowMob  = 10,    -- 落点最多比怪低多少 studs（怪悬空时别掉到地上）
	pinAfterTp       = 0.25,  -- 传送后钉住多少秒
	switchDelay      = 0.35,  -- 换了目标之后等多久再开打

	-- 走位：打的时候左右横移，别站着不动当靶子。
	--
	-- 这是"打副本死太快"最直接的解法之一：站定输出 = 怪的每一刀都命中，
	-- 横向移动能让相当一部分攻击落空。
	--
	-- 用的是【真实按键】A / D，不是改 CFrame —— 游戏收到的是普通移动输入。
	-- 配合上面的自动瞄准（相机对着怪），A/D 就是绕着它转圈。
	strafe = true,
	strafeSwitchEvery = 1.2,   -- 多久换一次方向（秒），原地左右晃太机械
	strafeMode = "cframe",     -- "cframe" = 直接移动角色（不依赖按键）★默认
	                           -- "move"   = Humanoid:Move（Roblox 官方移动 API）
	                           -- "key"    = 按 A/D 键。你反馈按键没反应，所以默认不用它。
	strafeSpeed = 90,          -- cframe / move 模式的横移速度（studs/秒）
	                           -- 「走位偏移增大」调的就是它：越大，一趟横移划出的弧越长

	-- ★ 锁定最近的怪 ★
	-- 当前目标死了当然要换；但更要紧的是：旁边有更近的怪时也该换过去，
	-- 否则会出现"追着远处那只打，近的站旁边看"。
	nearestSwitchMargin = 20,  -- 更近超过这么多 studs 才换目标
	                           -- 太小会在两只距离相近的怪之间来回切

	-- 保命：副本里贴脸容易被一起秒。
	-- 血掉到阈值就撤到高处悬停，回到阈值再继续打。
	autoRetreat   = true,
	hpRetreatAt   = 0.2,    -- HP 低于这个比例 → 撤（按你要求从 0.55 降到 0.2）
	                        -- 注意：阈值越低意味着你会硬吃更多伤害才撤。
	                        -- 想让它在 20% 就触发、又要回得快，把 hpResumeAt 也降下来。
	hpResumeAt    = 0.70,   -- ★ 撤退取消线：HP 回到这个比例 → 继续打 ★（你要求的，原 0.85）
	retreatUp     = 200,    -- 撤到比怪高多少 studs（按你要求从 80 拉高到 200）
	                        -- 太高可能撞到副本天花板/地形，卡住就调小
	retreatAway   = 40,     -- 同时水平拉开多少 studs（脱离范围攻击）

	-- ★ 撤退时每隔一段时间再往外瞬移一段 ★
	-- 追踪的怪会一直追上来 —— 钉在一个点上不动，等于站着等它追上。
	retreatHopInterval = 1.0,   -- 每隔多久再挪一段（秒），按你要求 1 秒
	retreatHopDistance = 45,    -- 每次往外挪多少 studs（你要求 45）

	-- ★ 撤退的多方向跳 ★
	-- 一直朝同一个方向直线跑的问题：容易撞墙 / 撞地图边界卡住，
	-- 而且追踪的怪顺着一条直线跟就行。
	-- 这里每跳一次就把方向左右偏转一下（正负交替），走成之字形。
	retreatHopSpread = 60,      -- 每跳偏转多少度（0 = 一直直线跑）
	retreatHopUp     = 0,       -- 每跳额外往上抬多少 studs（0 = 不额外抬）

	-- ★ 打完怪之后回到开启位置 ★
	-- 开了脚本之后会被传送追怪追得到处跑，怪清完应该回原位。
	-- ★ 默认关掉 ★
	-- 跑副本时会把你从刷怪点拽回起始位置：
	-- 流程期间它本来就被禁止（见 Chest.flowEngaged），
	-- 但【流程跑完那一刻】禁止就解除了，于是又把你拉回去。
	-- 想要普通刷怪时自动回位，再把它打开。
	returnHome      = false,
	returnHomeDelay = 3.0,    -- 持续这么久没目标才回去（免得怪刚死就来回跑）
	returnHomeRange = 40,     -- 离原位超过这么远才值得回

	-- ★ 撤退时是否也用技能 ★
	-- false（默认）= 撤退时只平A。你的武器在 CD 中放技能会【扣最大生命】，
	--                撤退途中正是最不该扣的时候。
	-- true         = 撤退时平A + 技能（你上一条要的行为）
	retreatUseSkills = false,

	-- ★ 自动喝血药 ★
	-- 5 号位是血药，冷却 30 秒，可以无限喝（不用管数量）。
	-- 有了它撤退阈值就不用那么保守，也不会因为残血长时间停摆。
	autoPotion     = true,
	potionSlot     = 5,      -- 热键栏第几格
	potionCooldown = 30.0,   -- 冷却（秒）
	potionAt       = 0.75,    -- 普通：HP 低于这个比例就喝（原来 0.5，太晚）
	-- 撤退中：血不满就尝试喝。
	-- 撤退时血已经很低，早一秒喝上就早一秒脱离危险。
	potionAtRetreat = 1.0,
	-- 血药实际冷却 30 秒 —— 但"什么时候冷却好"脚本不知道。
	-- 撤退时改成每 3 秒试一次：试早了游戏会拒绝（不会浪费），试到冷却好为止。
	potionRetreatRetry = 3.0,
	-- 平时 HP 低于这个比例就喝，比 hpRetreatAt(0.2) 高，也就是【先喝药再考虑撤】
	-- "equip+click" = 按数字键装备，再【左键】使用 ★默认（你说的方法）
	-- "equip+use"   = 按数字键装备，再用 Tool:Activate()
	-- "key"         = 只按数字键（有些游戏按了就喝）
	potionMethod   = "equip+click",
	-- 装备之后先等多久再开始点左键。
	-- 装备动作有前摇，太早点会点空 —— 你说"拿出时间太短"就是这个。
	potionEquipDelay = 0.3,
	-- 然后【连续点左键】这个时长（秒），不是点一下就完。
	-- 点一下很可能落在前摇里打空；连点 0.5 秒才稳。
	potionClickWindow = 0.5,
	-- ★ 撤退时给更长的时间 ★（你反馈的"撤退时拿药的时间太短"）
	-- 撤退时血掉得快，装备动作也更可能被打断 —— 多等一会儿、多连点一会儿，
	-- 别因为"拿出时间不够"就喝空了。这两个值只在撤退中用。
	potionEquipDelayRetreat = 0.6,
	potionClickWindowRetreat = 1.2,

	-- ★ 传送/撤退后的"飞行"状态 ★
	-- 传到没地面的地方（怪悬空、地图边缘）会直接掉出地图。
	-- 这段时间里每帧写回高度 = 悬停，掉不下去。
	hoverAfterTp      = 3.0,    -- 传送后至少悬停这么久（秒）
	hoverWhenAirborne = true,   -- 悬停到期时如果脚下还是空的，就继续续期
	                            -- （靠 Humanoid.FloorMaterial 判断，Air = 悬空）
	                            -- 这样只有真悬空才继续飞，落地就自然结束

	-- 输出
	autoAim   = true,         -- 自动把视角对准怪
	autoClick = true,         -- 自动左键
	autoSkill = true,         -- 自动按技能

	clickInterval = 0.05,     -- 平A连点间隔（秒）。0.05 = 每秒 20 次。
	                          -- 大部分游戏的平A是按动画/内置冷却走的，比它快不会更快 ——
	                          -- 快过阈值就纯属多发输入了。还想更快就调到 0.03。

	-- 放完技能之后暂停平A多久（秒）。
	--
	-- 为什么要这个：平A现在很快（20 次/秒），有可能把技能的施法/后摇动作
	-- 取消掉 —— 那样技能等于白放。点得慢的时候不明显，快了之后风险变大。
	-- 这段时间只是不点左键，技能照放。
	--
	-- 如果你确认平A不会打断技能，设 0 关掉，DPS 更高。
	skillCastLockout = 0.35,

	-- 攻击方式。
	-- "mouse"    = mouse1click（你现在平A好使，所以默认保留它）
	-- "activate" = Tool:Activate() —— Roblox 官方 API。
	--              key-probe 探针已验证它能真的触发 Activated 事件，
	--              而且不依赖鼠标、不依赖窗口焦点。
	-- "both"     = 两个都发
	attackMethod = "mouse",

	-- 自动装备武器。
	-- 主要场景是【死了重生之后武器会掉】—— 手上没武器就只剩平A，甚至完全不打。
	autoEquip    = true,
	equipMethod  = "auto",    -- "auto" = 先按游戏热键栏（发数字键，最忠实：格位由游戏自己决定），
	                          --          按几次没效果就自动改用 Humanoid:EquipTool 兜底 ★默认
	                          -- "key"  = 只用数字键
	                          -- "api"  = 只用 Humanoid:EquipTool（按背包顺序取第 N 个）
	                          -- 为什么 auto 先试 key：格位是游戏定义的，最准；
	                          -- 但"背包顺序 == 热键栏顺序"只是惯例，不保证，所以留 API 兜底。
	equipSlot    = 3,         -- 热键栏第几格（1-9）。你说想用的在三号位。
	equipByName  = "",        -- 填了武器名就按【名字】装 —— 比格位稳，格位会随物品增减串位
	                          -- 填了它就用 "api" 方式，equipSlot 失效
	equipForce   = false,     -- false = 只在"手上没武器"时装（默认，免得和你手动选的打架）
	                          -- true  = 手上不是目标武器就换掉
	equipCheckInterval = 2.0, -- 多久检查一次（秒）
	equipMaxTries = 3,        -- 连续几次没装上就放弃并放慢重试
	                          -- （某一格是空的、或数字键不生效时，别每 2 秒按一次刷屏）

	-- 技能轮转：每个技能【各自一条计时器】。
	--
	-- 之前是"每 1.2 秒把 Q/E/R/F 全按一遍" —— 一刀切，两个后果：
	--   · 冷却短的技能在干等（本来能多放几次）
	--   · 冷却长的技能在空放（空放 = 零伤害，纯粹浪费按键）
	-- 现在谁好了按谁。
	--
	-- interval 填多少：对着你游戏里 Q/E/R/F 那几条冷却横条填。
	-- 填得比实际冷却略长最安全（略短只是空放，不会有坏处）。
	-- 留空的话退回下面的 skillKeys + skillInterval 老写法。
	-- 默认技能表（当前武器没在下面的表里时用它）。
	-- 你这把武器没有 Q，所以只填 E/R/F。
	skillRotation = {
		{ key = Enum.KeyCode.E, interval = 10.0 },
		{ key = Enum.KeyCode.R, interval = 20.0 },
		{ key = Enum.KeyCode.F, interval = 40.0 },
	},

	-- 按【武器名】分别配技能表。
	-- 你背包里有 6 把武器，各自技能大概率不同 —— 换武器时脚本会自动切表并重排计时器。
	-- 武器名要和游戏里 Tool 的名字完全一致（探针第 1 节列出来的那些）。
	-- 没列到的武器就退回上面的 skillRotation。
	skillRotationByWeapon = {
		-- 示例（把武器名换成你实际在用的，冷却填实测值）：
		-- ["Tyrannical Greatsword"] = {
		--     { key = Enum.KeyCode.E, interval = 10.0 },
		--     { key = Enum.KeyCode.R, interval = 20.0 },
		--     { key = Enum.KeyCode.F, interval = 40.0 },
		-- },
		-- ["Pandemonium"] = {
		--     { key = Enum.KeyCode.Q, interval = 6.0 },
		--     { key = Enum.KeyCode.E, interval = 15.0 },
		-- },
	},

	-- 每个技能冷却之外再多等这么久。
	-- ★ 你这把武器的特性是：CD 中按技能会【消耗最大生命】强放 ★
	--    所以"提前按"不是没效果，而是要付出代价 —— 早按一次就亏一次最大生命。
	--    客户端计时和服务器判定常有差，这里必须留足余量。
	--    觉得技能放得太频繁（或在掉最大生命）就把这个调大。
	skillBuffer = 1.0,

	-- 整体再乘一个系数，额外留余量。1.1 = 多等 10%。
	skillScale = 1.1,

	-- 观察到【最大生命下降】就自动继续拉长技能间隔。
	-- 这是"按早了"最直接的证据 —— 武器特性扣的就是最大生命。
	-- 自动放大之后还会在控制台告警，方便你调准冷却值。
	skillAutoBackoff = true,
	skillBackoffStep = 1.25,   -- 每次发现掉最大生命，间隔乘多少

	-- ★ 止损地板 ★
	-- 自动拉长间隔只是在"退让"，如果冷却值本身就填错了，最大生命还是会被
	-- 一点点扣光。掉到下面这个比例就【彻底停用技能】，把损失摁住。
	-- 停用后控制台会告警 —— 那时候应该去核对 interval，而不是继续挂着。
	skillMinMaxHp = 0.7,       -- 最大生命低于初始值的 70% 就停技能（1 = 关掉这道保险）

	-- 最大生命的【原始值】。填了它就按它算地板，比自动探测可靠。
	--
	-- 自动探测是"脚本运行期间见过的最大值"—— 如果你在装脚本之前就已经被扣过，
	-- 探测值会偏小，地板就保护不到。你的最大生命是 2550（探针截图里看到的），
	-- 想严格保护就把这里填 2550。
	skillMaxHpBase = 0,        -- 0 = 自动探测

	-- 老写法（skillRotation 留空时才用）：所有技能共用一个间隔
	skillInterval = 1.2,
	skillKeys     = { Enum.KeyCode.Q, Enum.KeyCode.E, Enum.KeyCode.R, Enum.KeyCode.F },

	-- 间隔随机抖动比例。两个作用：
	--  ① 别把节奏踩得太死，避免同一毫秒反复打服务端
	--  ② 机器般精确的间隔本身就是最明显的特征
	jitter = 0.25,

	debug = true,
}

local function log(...)
	if CONFIG.debug then print("[Farm]", ...) end
end

--------------------------------------------------------------------------------
-- 执行器能力探测（缺什么就明确说，别静默失败）
--------------------------------------------------------------------------------
local CAP = {
	click  = type(mouse1click) == "function",
	press  = type(mouse1press) == "function" and type(mouse1release) == "function",
	key    = type(keypress) == "function" and type(keyrelease) == "function",
}

--------------------------------------------------------------------------------
-- 状态
--------------------------------------------------------------------------------
local running   = false
local target, targetPart
local lastClick, lastSkill, switchAt = 0, 0, 0
local clickGap = nil        -- 本次连点实际用的间隔（带抖动，每次重抽）
local castLockedUntil = 0   -- 放完技能后暂停平A到这个时刻
local clicks, retargets, startAt = 0, 0, 0
local skillNext, skillFired = {}, 0
-- 技能间隔的自动放大系数。
-- 武器的特性是"CD 中按技能会消耗最大生命强放" ——
-- 一旦观察到最大生命掉了，就说明还在提前按，自动继续拉长间隔。
local skillPenalty = 1.0
local lastMaxHp = nil
-- 止损：见过的最大的最大生命（当基准），以及是否已经因为掉太多而停用技能
local baseMaxHp = nil
local skillDisabledForHp = false
local retreating, retreatPos = false, nil
local retreatNextHop, retreatAwayDir = 0, nil
local retreatHopSign = 1     -- 多方向跳：左右交替偏转
-- "飞行"状态：传送/撤退后锁住高度，免得掉出地图
local hoverUntil, hoverY = 0, nil
-- 喝药相关
local nextPotion = 0
local potionsUsed = 0
local potionsClicked = 0    -- 喝药时点了多少次左键（诊断用）
-- 回位相关
local homePos = nil
local noTargetSince, returnedHome = nil, false
-- 喝完药手上是药瓶 —— 要强制把武器装回来一次，
-- 否则会一直拿着药瓶平A（ensureEquipped 默认"手上有工具就不动"，不会帮你换）
local forceEquipOnce = false
local strafeDir, strafeSwitchAt = nil, 0
local strafeSign = 1        -- cframe/move 模式的横移方向（+1 / -1 来回换）
-- 只警告一次的记录表。
-- ★ 必须声明在【所有使用者之前】★
-- Lua 的 local 只在其后的代码里可见 —— 声明晚了，前面用的地方会解析成
-- 全局变量 nil，一到执行就崩。这里踩过一次：reposition 里的
-- "瞬移被拦"告警用了它，而它声明在 400 行之后，只有在真的被拦时才触发。
local warnedOnce = {}
-- 副本模块（真正的定义在下面，这里先声明）
local Chest = nil
-- ★ 自动流程要能把"自动刷怪"自己开起来 ★
-- 不然按了「自动完成一二」，刷怪没开 → onHeartbeat 第一行就 return，
-- 什么都不动（你反馈的就是这个）。
--
-- 不能直接调 setRunning：它声明在 Chest 模块【之后】，
-- 模块里读到的是全局 nil（这个坑在这个项目里出现过好几次）。
-- 所以在 setRunning 定义完之后回填这两个钩子。
local chestStartFarm, chestStopFarm = nil, nil
local conns = {}

local function track(c) table.insert(conns, c) return c end
local function disconnectAll()
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	conns = {}
end

local function jitter(base)
	local j = CONFIG.jitter
	if j <= 0 then return base end
	return base * (1 - j + math.random() * 2 * j)
end

-- 冷却类间隔专用的抖动：【只能加，不能减】。
--
-- 共用上面那个对称抖动会出问题：10 秒冷却的技能最短 7.5 秒就按，
-- 那时还在冷却中，按了等于空放 —— 表现出来就是"技能间隔太短"。
local function jitterUp(base)
	local j = CONFIG.jitter
	if j <= 0 then return base end
	return base * (1 + math.random() * j)
end

--------------------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------------------
local ui = {}

local function row(parent, name, order, h)
	local b = Instance.new("TextButton")
	b.Name, b.LayoutOrder, b.Size = name, order, UDim2.new(1, 0, 0, h or 24)
	b.BackgroundColor3 = Color3.fromRGB(44, 44, 52)
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Enum.Font.Code
	b.TextSize = 13
	b.TextColor3 = Color3.fromRGB(220, 220, 230)
	b.Text = name
	b.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 5)
	c.Parent = b
	return b
end

local function buildHud()
	local pg = PLR:FindFirstChildOfClass("PlayerGui") or PLR:WaitForChild("PlayerGui", 10)
	if not pg then return false end

	local gui = Instance.new("ScreenGui")
	gui.Name = "AutoFarmHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	if syn and syn.protect_gui then pcall(syn.protect_gui, gui) end

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Position = UDim2.new(0, 12, 0, 78)
	panel.Size = UDim2.new(0, 190, 0, 264)
	panel.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
	panel.BackgroundTransparency = 0.18
	panel.BorderSizePixel = 0
	panel.Active = false
	panel.Parent = gui

	local pc = Instance.new("UICorner"); pc.CornerRadius = UDim.new(0, 8); pc.Parent = panel

	local title = Instance.new("TextButton")
	title.Size = UDim2.new(1, 0, 0, 26)
	title.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
	title.BorderSizePixel = 0
	title.AutoButtonColor = true
	title.Font = Enum.Font.Code
	title.TextSize = 13
	title.TextColor3 = Color3.fromRGB(255, 205, 70)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "  AutoFarm  [−]"
	title.Parent = panel
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 8); tc.Parent = title

	local body = Instance.new("Frame")
	body.Position = UDim2.new(0, 8, 0, 30)
	body.Size = UDim2.new(1, -16, 0, 228)
	body.BackgroundTransparency = 1
	body.Parent = panel
	local lay = Instance.new("UIListLayout")
	lay.Padding = UDim.new(0, 4)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Parent = body

	local status = Instance.new("TextLabel")
	status.LayoutOrder = 0
	status.Size = UDim2.new(1, 0, 0, 32)
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.Code
	status.TextSize = 12
	status.TextColor3 = Color3.fromRGB(160, 255, 200)
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextWrapped = true
	status.Text = "..."
	status.Parent = body

	ui.tgFarm  = row(body, "自动刷怪", 1)
	ui.tgTp    = row(body, "贴脸传送", 2)
	ui.tgAim   = row(body, "自动瞄准", 3)
	ui.tgChest = row(body, "自动开箱", 3.5)
	ui.tgKey = row(body, "自动拿钥匙", 3.8)

	--------------------------------------------------------------------------------
	-- ★ 副本流程面板（和刷怪、传送都分开）★
	--------------------------------------------------------------------------------
	local fPanel = Instance.new("Frame")
	fPanel.Name = "DungeonFlowPanel"
	fPanel.Position = UDim2.new(0, 210, 0, 78)
	fPanel.Size = UDim2.new(0, 200, 0, 172)
	fPanel.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
	fPanel.BackgroundTransparency = 0.18
	fPanel.BorderSizePixel = 0
	fPanel.Active = false
	fPanel.Parent = gui
	local fpc = Instance.new("UICorner"); fpc.CornerRadius = UDim.new(0, 8); fpc.Parent = fPanel

	local fTitle = Instance.new("TextButton")
	fTitle.Size = UDim2.new(1, 0, 0, 26)
	fTitle.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
	fTitle.BorderSizePixel = 0
	fTitle.AutoButtonColor = true
	fTitle.Font = Enum.Font.Code
	fTitle.TextSize = 13
	fTitle.TextColor3 = Color3.fromRGB(255, 190, 120)
	fTitle.TextXAlignment = Enum.TextXAlignment.Left
	fTitle.Text = "  副本流程  [-]"
	fTitle.Parent = fPanel
	local ftc = Instance.new("UICorner"); ftc.CornerRadius = UDim.new(0, 8); ftc.Parent = fTitle

	local fBody = Instance.new("Frame")
	fBody.Position = UDim2.new(0, 8, 0, 30)
	fBody.Size = UDim2.new(1, -16, 0, 136)
	fBody.BackgroundTransparency = 1
	fBody.Parent = fPanel

	local fStatus = Instance.new("TextLabel")
	fStatus.Size = UDim2.new(1, 0, 0, 32)
	fStatus.BackgroundTransparency = 1
	fStatus.Font = Enum.Font.Code
	fStatus.TextSize = 12
	fStatus.TextColor3 = Color3.fromRGB(255, 220, 160)
	fStatus.TextXAlignment = Enum.TextXAlignment.Left
	fStatus.TextWrapped = true
	fStatus.Text = "未开始"
	fStatus.Parent = fBody

	ui.actAuto = row(fBody, "自动完成一二 [Y]", 1)
	ui.actAuto.Position = UDim2.new(0, 0, 0, 36)
	ui.actAuto.Size = UDim2.new(1, 0, 0, 24)

	-- ★ 开箱选项放在流程面板上 ★（同一份配置，流程和普通刷怪都生效）
	local optLabel = Instance.new("TextLabel")
	optLabel.Position = UDim2.new(0, 0, 0, 64)
	optLabel.Size = UDim2.new(1, 0, 0, 16)
	optLabel.BackgroundTransparency = 1
	optLabel.Font = Enum.Font.Code
	optLabel.TextSize = 11
	optLabel.TextColor3 = Color3.fromRGB(150, 150, 160)
	optLabel.TextXAlignment = Enum.TextXAlignment.Left
	optLabel.Text = "开哪些箱子："
	optLabel.Parent = fBody

	ui.tgOnlyTerror = row(fBody, "只开 Terror", 2)
	ui.tgOnlyTerror.Position = UDim2.new(0, 0, 0, 82)
	ui.tgOnlyTerror.Size = UDim2.new(1, 0, 0, 24)
	ui.tgShadow = row(fBody, "开 Shadow 箱", 3)
	ui.tgShadow.Position = UDim2.new(0, 0, 0, 110)
	ui.tgShadow.Size = UDim2.new(1, 0, 0, 24)
	ui.tgQuestion = row(fBody, "开问号假箱", 4)
	ui.tgQuestion.Position = UDim2.new(0, 0, 0, 138)
	ui.tgQuestion.Size = UDim2.new(1, 0, 0, 24)

	fTitle.MouseButton1Click:Connect(function()
		ui.fCollapsed = not ui.fCollapsed
		fBody.Visible = not ui.fCollapsed
		fPanel.Size = UDim2.new(0, 200, 0, ui.fCollapsed and 30 or 172)
		fTitle.Text = ui.fCollapsed and "  副本流程  [+]" or "  副本流程  [-]"
	end)

	ui.fStatus = fStatus

	--------------------------------------------------------------------------------
	-- 传送面板（和主体分开）
	--------------------------------------------------------------------------------
	local tPanel = Instance.new("Frame")
	tPanel.Name = "TeleportPanel"
	tPanel.Position = UDim2.new(0, 12, 0, 340)
	tPanel.Size = UDim2.new(0, 190, 0, 176)
	tPanel.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
	tPanel.BackgroundTransparency = 0.18
	tPanel.BorderSizePixel = 0
	tPanel.Active = false
	tPanel.Parent = gui
	local tpc = Instance.new("UICorner"); tpc.CornerRadius = UDim.new(0, 8); tpc.Parent = tPanel

	local tTitle = Instance.new("TextButton")
	tTitle.Size = UDim2.new(1, 0, 0, 26)
	tTitle.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
	tTitle.BorderSizePixel = 0
	tTitle.Font = Enum.Font.Code
	tTitle.TextSize = 13
	tTitle.TextColor3 = Color3.fromRGB(120, 220, 255)
	tTitle.TextXAlignment = Enum.TextXAlignment.Left
	tTitle.Text = "  传送  [-]" 
	tTitle.Parent = tPanel
	local ttc = Instance.new("UICorner"); ttc.CornerRadius = UDim.new(0, 8); ttc.Parent = tTitle

	local tBody = Instance.new("Frame")
	tBody.Position = UDim2.new(0, 8, 0, 30)
	tBody.Size = UDim2.new(1, -16, 0, 140)
	tBody.BackgroundTransparency = 1
	tBody.Parent = tPanel
	local tlay = Instance.new("UIListLayout")
	tlay.Padding = UDim.new(0, 4)
	tlay.SortOrder = Enum.SortOrder.LayoutOrder
	tlay.Parent = tBody

	ui.actSpawn   = row(tBody, "传送·刷怪点  [L]", 1)
	ui.actTrigger = row(tBody, "触发刷怪     [T]", 2)
	ui.actKeyDoor = row(tBody, "传送·Key门   [O]", 3)
	ui.actSavePos = row(tBody, "记录坐标     [P]", 4)
	ui.actGoPos   = row(tBody, "传送·坐标    [J]", 5)

	-- 自己的一套拖动 + 折叠（和主面板互不影响）
	local tDrag, tFrom, tStart, tMoved = false, nil, nil, false
	local function tEndDrag()
		if not tDrag then return end
		tDrag = false
		if tMoved then return end
		ui.tCollapsed = not ui.tCollapsed
		tBody.Visible = not ui.tCollapsed
		tPanel.Size = UDim2.new(0, 190, 0, ui.tCollapsed and 30 or 176)
		tTitle.Text = ui.tCollapsed and "  传送  [+]" or "  传送  [-]"
	end
	tTitle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			tDrag, tMoved = true, false
			tFrom = input.Position
			tStart = tPanel.Position
		end
	end)
	track(UIS.InputChanged:Connect(function(input)
		if not tDrag then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local d = input.Position - tFrom
			if math.abs(d.X) > 3 or math.abs(d.Y) > 3 then tMoved = true end
			tPanel.Position = UDim2.new(tStart.X.Scale, tStart.X.Offset + d.X,
				tStart.Y.Scale, tStart.Y.Offset + d.Y)
		end
	end))
	track(UIS.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			tEndDrag()
		end
	end))

	ui.tPanel = tPanel

	ui.actNext = row(body, "换目标", 4)
	ui.actUn   = row(body, "卸载    [End]", 5)
	ui.actUn.TextColor3 = Color3.fromRGB(255, 140, 140)

	ui.gui, ui.panel, ui.title, ui.body, ui.status = gui, panel, title, body, status

	-- 拖动 + 轻点折叠（拖动完松手也会触发 Click，所以折叠放在 InputEnded 里判断有没有移动）
	local dragging, dragFrom, startPos, moved = false, nil, nil, false

	local function endDrag()
		if not dragging then return end
		dragging = false
		if moved then return end
		ui.collapsed = not ui.collapsed
		body.Visible = not ui.collapsed
		panel.Size = UDim2.new(0, 190, 0, ui.collapsed and 30 or 264)
		title.Text = ui.collapsed and "  AutoFarm  [+]" or "  AutoFarm  [−]"
	end

	title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging, moved = true, false
			dragFrom = input.Position
			startPos = panel.Position
		end
	end)

	track(UIS.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local d = input.Position - dragFrom
			if math.abs(d.X) > 3 or math.abs(d.Y) > 3 then moved = true end
			panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))

	track(UIS.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			endDrag()
		end
	end))

	gui.Parent = pg
	return true
end

local function paint(btn, on)
	btn.BackgroundColor3 = on and Color3.fromRGB(28, 92, 58) or Color3.fromRGB(52, 40, 42)
	btn.TextColor3 = on and Color3.fromRGB(165, 255, 200) or Color3.fromRGB(210, 150, 150)
end

local function refresh()
	if not ui.tgFarm then return end
	ui.tgFarm.Text = "自动刷怪      " .. (running and "开" or "关")
	ui.tgTp.Text   = "贴脸传送      " .. (CONFIG.autoTeleport and "开" or "关")
	ui.tgAim.Text  = "自动瞄准      " .. (CONFIG.autoAim and "开" or "关")
	ui.tgChest.Text = "自动开箱      " .. (Chest.isEnabled() and "开" or "关")
	paint(ui.tgChest, Chest.isEnabled())
	local cst = Chest.status()
	ui.tgOnlyTerror.Text = "只开 Terror   " .. (cst.onlyTerror and "开" or "关")
	ui.tgQuestion.Text = "开问号假箱    " .. (cst.openQuestion and "开" or "关")
	paint(ui.tgOnlyTerror, cst.onlyTerror)
	paint(ui.tgQuestion, cst.openQuestion)
	ui.tgKey.Text = "自动拿钥匙    " .. (cst.autoKey and "开" or "关")
	paint(ui.tgKey, cst.autoKey)
	-- 副本流程面板的状态
	if ui.fStatus then
		local ast = Chest.autoStatus()
		local txt
		if ast.active then
			txt = string.format("进行中 %d/%d\n%s", ast.idx, ast.total, ast.name or "?")
		elseif Chest.flowEngaged() then
			txt = "已暂停（按 Y 继续）"
		elseif ast.idx > 0 then
			txt = "已完成"
		else
			txt = "未开始"
		end
		ui.fStatus.Text = txt
		ui.actAuto.Text = ast.active and "停止流程     [Y]" or "自动完成一二 [Y]"
		paint(ui.actAuto, ast.active)
	end
	paint(ui.tgFarm, running)
	paint(ui.tgTp, CONFIG.autoTeleport)
	paint(ui.tgAim, CONFIG.autoAim)
end

--------------------------------------------------------------------------------
-- 找怪
--------------------------------------------------------------------------------
local function otherCharacters()
	local set = {}
	if CONFIG.excludePlayers then
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= PLR and p.Character then set[p.Character] = true end
		end
	end
	return set
end

local function getPart(m)
	return m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
end

local function isMob(o, others)
	if not o:IsA("Model") then return false end
	if o == PLR.Character or others[o] then return false end

	local hum = o:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false end

	local n = string.lower(o.Name)
	for _, x in ipairs(CONFIG.excludeNames or {}) do
		if string.find(n, string.lower(x), 1, true) then return false end
	end

	if #CONFIG.mobMatch > 0 then
		local hit = false
		for _, k in ipairs(CONFIG.mobMatch) do
			if string.find(n, string.lower(k), 1, true) then hit = true break end
		end
		if not hit then return false end
	end

	return getPart(o) ~= nil, hum
end

local function findNearestMobUncached()
	local char = PLR.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return nil end

	local others = otherCharacters()
	local myPos = root.Position
	local best, bestPart, bestDist = nil, nil, math.huge

	for _, o in ipairs(workspace:GetDescendants()) do
		local ok, hum = isMob(o, others)
		if ok then
			local part = getPart(o)
			local d = (part.Position - myPos).Magnitude
			if d < bestDist then best, bestPart, bestDist = o, part, d end
		end
	end
	return best, bestPart, bestDist
end

--------------------------------------------------------------------------------
-- 怪列表缓存
--
-- 为什么不每帧直接扫：workspace:GetDescendants() 在大场景里非常贵，
-- 每帧跑一遍会把客户端拖垮（表现就是"运行失败"或游戏卡死）。
-- 所以：贵的遍历按 mobRefreshInterval 做一次，每帧只在缓存里比距离。
--------------------------------------------------------------------------------
-- cacheAt 用 -inf 当哨兵：首帧必定刷新一次，不用等到 1.5 秒后
local mobCache, cacheAt = {}, -math.huge

local function refreshMobCache()
	local others = otherCharacters()

	-- 只扫指定的容器（探针输出：怪都在 MobFolder 里）。
	-- 找不到容器就退回整个 workspace，保证换个游戏还能用。
	local roots = {}
	for _, n in ipairs(CONFIG.mobContainers or {}) do
		local c = workspace:FindFirstChild(n)
		if c then roots[#roots + 1] = c end
	end
	if #roots == 0 then roots = { workspace } end

	-- NPC 容器里的东西一律不打
	local npcs = {}
	for _, n in ipairs(CONFIG.npcContainers or {}) do
		local c = workspace:FindFirstChild(n)
		if c then npcs[#npcs + 1] = c end
	end

	local function underNpc(inst)
		for _, c in ipairs(npcs) do
			if inst == c or inst:IsDescendantOf(c) then return true end
		end
		return false
	end

	local list, seen = {}, {}
	local function consider(o)
		if seen[o] or underNpc(o) then return end
		local ok, hum = isMob(o, others)
		if ok then
			seen[o] = true
			list[#list + 1] = { model = o, part = getPart(o), hum = hum }
		end
	end

	for _, root in ipairs(roots) do
		if root:IsA("Model") then consider(root) end
		for _, o in ipairs(root:GetDescendants()) do consider(o) end
	end

	mobCache = list
	cacheAt = os.clock()
end

local function cacheAlive(m)
	return m.model.Parent ~= nil and m.part.Parent ~= nil and m.hum.Parent ~= nil
		and m.hum.Health > 0
end

local function pickFromCache()
	local root = PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart")
	if not root then return nil end

	local myPos = root.Position
	local best, bestPart, bestDist = nil, nil, math.huge
	for _, m in ipairs(mobCache) do
		if cacheAlive(m) then
			local d = (m.part.Position - myPos).Magnitude
			if d < bestDist then best, bestPart, bestDist = m.model, m.part, d end
		end
	end
	return best, bestPart, bestDist
end

--------------------------------------------------------------------------------
-- 位移（沿用 chestfinder 那套：直接写 root.CFrame + 钉几帧）
--
-- ★ lookAt 这个参数不是可选的装饰 ★
-- 你的武器是"剑气飞向前方"，前方 = 角色朝向。
-- 原来这里（和 pinPos）都只写 CFrame.new(pos) —— 单参数 = 朝向被清掉。
-- 而 pinPos 会在每次瞬移后【持续写 15 帧】，等于瞬移后 0.25 秒内
-- 角色朝向被反复重置，剑气就胡乱飞。
-- 所以位移必须一并把朝向带过去。
--------------------------------------------------------------------------------
local function applyPos(root, pos, lookAt)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.CFrame = lookAt and CFrame.new(pos, lookAt) or CFrame.new(pos)
end

local function pinPos(pos, duration, lookAt)
	task.spawn(function()
		local deadline = os.clock() + duration
		local frames = math.max(1, math.floor(duration * 60))
		for _ = 1, frames do
			if os.clock() >= deadline then break end
			local char = PLR.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if not root or not root.Parent then return end
			-- 带朝向，别把 combatPose 刚设好的朝向冲掉
			root.CFrame = lookAt and CFrame.new(pos, lookAt) or CFrame.new(pos)
			root.AssemblyLinearVelocity = Vector3.zero
			task.wait()
		end
	end)
end

-- 保持战斗距离：站到离怪 combatDistance 处，方位沿用当前朝向。
--
-- 为什么不是"贴上去"：你的武器是剑气（远程），贴脸只会白挨打。
-- 玩家应该站在远处把剑气打过去。
local lastReposition = -math.huge

local function reposition(mob, part)
	local char = PLR.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root or not part then return false end

	local now = os.clock()
	if now - lastReposition < CONFIG.repositionCooldown then return false end

	local p = part.Position
	local cur = root.Position

	-- 从怪指向自己的水平方向（保持现在的方位，只改距离）
	local dir = Vector3.new(cur.X - p.X, 0, cur.Z - p.Z)
	if dir.Magnitude < 0.5 then dir = Vector3.new(1, 0, 0) end
	dir = dir.Unit

	local want = CONFIG.combatDistance
	local spot = Vector3.new(p.X + dir.X * want, p.Y, p.Z + dir.Z * want)
	-- 朝向：对准怪（水平）。瞬移和钉住都必须带上它，否则剑气就飞歪。
	local look = Vector3.new(p.X, spot.Y, p.Z)

	lastReposition = now
	applyPos(root, spot, look)
	if CONFIG.pinAfterTp > 0 then pinPos(spot, CONFIG.pinAfterTp, look) end

	-- 传送后进入"飞行"状态：传到没地面的地方不会直接掉出去
	-- （怪悬空的时候落点也在空中，pinAfterTp 一结束就会开始掉）
	hoverY = spot.Y
	hoverUntil = now + (CONFIG.hoverAfterTp or 0)

	-- 核对一下这次瞬移到底有没有生效。
	-- 这游戏拦连续瞬移，被拦时位置不会变 —— 不报出来的话
	-- 只会看到"站在怪脸上挨打"而不知道为什么。
	local after = root.Position
	local moved = (after - spot).Magnitude
	if moved > 8 and not warnedOnce.reposition then
		warnedOnce.reposition = true
		warn("[Farm] 重新站位没生效（差 %.0f studs）—— 可能被这游戏的移动校验拦了。", moved)
		warn("[Farm]   会继续按 repositionCooldown 重试。想减少瞬移就把 combatDistance 调小。")
	end
	return true
end

local function goToMob(mob, part, dist)
	if not CONFIG.autoTeleport then return false end
	if dist and dist <= CONFIG.range then return false end

	local char = PLR.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return false end

	-- 兜底路径（combatDistance 关掉时才用）：站在怪的侧面，高度和它齐平。
	local p = part.Position
	local pos = Vector3.new(p.X + CONFIG.standOffset, p.Y, p.Z)
	local look = Vector3.new(p.X, pos.Y, p.Z)

	applyPos(root, pos, look)
	if CONFIG.pinAfterTp > 0 then pinPos(pos, CONFIG.pinAfterTp, look) end
	return true
end

--------------------------------------------------------------------------------
-- 瞄准
--------------------------------------------------------------------------------
local function aimAt(part)
	local cam = CAM or workspace.CurrentCamera
	if not cam or not part then return end
	local from = cam.CFrame.Position
	cam.CFrame = CFrame.new(from, part.Position)
end

--------------------------------------------------------------------------------
-- 输出：左键 + 技能
--------------------------------------------------------------------------------
-- Tool:Activate() —— Roblox 官方 API，等价于"使用当前武器"。
-- key-probe 探针确认它能真的触发 Activated 事件，所以是一条不依赖鼠标的可靠攻击路径。
local function activateTool()
	local char = PLR.Character
	local tool = char and char:FindFirstChildWhichIsA("Tool")
	if not tool then return false, "手上没有武器" end
	local ok, err = pcall(function() tool:Activate() end)
	return ok, err
end

local function clickOnce()
	local mode = CONFIG.attackMethod or "mouse"

	if mode == "activate" or mode == "both" then
		local ok, err = activateTool()
		if mode == "activate" then return ok, err end
		-- mode == "both"：activate 之后再补一发鼠标
	end

	if CAP.click then
		local ok, err = pcall(mouse1click)
		return ok, err
	elseif CAP.press then
		local ok, err = pcall(function()
			mouse1press()
			task.wait(0.03)
			mouse1release()
		end)
		return ok, err
	end
	return false, "执行器没有 mouse1click，也没有 mouse1press/mouse1release"
end

--------------------------------------------------------------------------------
-- 按键：候选方式逐个验证，用 UserInputService 确认"游戏真的收到了"
--
-- ★ 这一层的教训 ★
-- 之前是"逐个 pcall，谁不报错就用谁"。结果 keypress(数字码) 不报错、
-- 但游戏根本收不到 —— 脚本以为发成功了，实际技能/走位/装武器全都没反应。
-- 现在改成：每种方式按下去之后用 UserInputService:IsKeyDown 验证状态真的变了，
-- 只有验证通过的才采用。全都不通过就明确报告，不装作成功了。
--------------------------------------------------------------------------------
local VIMSVC = nil
pcall(function() VIMSVC = game:GetService("VirtualInputManager") end)

-- 参数写法在不同执行器/版本里不一样，所以全都列出来，逐个用 IsKeyDown 验证。
--
-- ★ key-probe 实测结果（Xeno）：第 4 个参数要的是【对象】而不是布尔 ★
--     SendKeyEvent(t, KEY, false, false)      → 失败: Unable to cast value to Object
--     SendKeyEvent(t, KEY, false, game)       → IsKeyDown=true  ★ 能用
--     SendKeyEvent(t, KEY, false, workspace)  → IsKeyDown=true  ★ 能用
--     SendKeyEvent(t, KEY, false, nil)        → IsKeyDown=true  ★ 能用
--   所以把能用的那个排在最前面，减少启动时的试探耗时。
local function buildKeyMethods()
	local out = {}

	if VIMSVC then
		local function vim(d)
			return function(k) VIMSVC:SendKeyEvent(d, k, false, game) end
		end
		out[#out + 1] = { name = "VIM(t,KEY,f,game)", down = vim(true), up = vim(false) }

		out[#out + 1] = { name = "VIM(t,KEY,f,nil)",
			down = function(k) VIMSVC:SendKeyEvent(true, k, false, nil) end,
			up   = function(k) VIMSVC:SendKeyEvent(false, k, false, nil) end }
		out[#out + 1] = { name = "VIM(t,KEY,f,workspace)",
			down = function(k) VIMSVC:SendKeyEvent(true, k, false, workspace) end,
			up   = function(k) VIMSVC:SendKeyEvent(false, k, false, workspace) end }
		out[#out + 1] = { name = "VIM(t,KEY,f,f)",
			down = function(k) VIMSVC:SendKeyEvent(true, k, false, false) end,
			up   = function(k) VIMSVC:SendKeyEvent(false, k, false, false) end }
	end

	if type(keypress) == "function" and type(keyrelease) == "function" then
		out[#out + 1] = { name = "keypress(数字码)",
			down = function(k) keypress(k.Value) end,
			up   = function(k) keyrelease(k.Value) end }
		out[#out + 1] = { name = "keypress(Enum)",
			down = function(k) keypress(k) end,
			up   = function(k) keyrelease(k) end }
		out[#out + 1] = { name = "keypress(字符串)",
			down = function(k) keypress(k.Name:lower()) end,
			up   = function(k) keyrelease(k.Name:lower()) end }
	end

	return out
end

local keyMethods = nil
local activeKeyMethod = nil
local keyProbed = false

local function probeKeyMethods()
	keyMethods = keyMethods or buildKeyMethods()

	-- 用 F13 试：游戏基本不可能绑这个键，所以按下去不会产生副作用
	local TEST = Enum.KeyCode.F13

	for _, m in ipairs(keyMethods) do
		pcall(m.up, TEST)

		local okCall = pcall(m.down, TEST)
		if okCall then
			task.wait(0.06)
			local seen = UIS:IsKeyDown(TEST)
			pcall(m.up, TEST)
			task.wait(0.03)
			if seen then return m end
		end
	end
	return nil
end

local function ensureKeyMethod()
	if keyProbed then return activeKeyMethod end
	keyProbed = true

	activeKeyMethod = probeKeyMethods()
	if activeKeyMethod then
		print("[Farm] 按键方式已验证可用: " .. activeKeyMethod.name)
	else
		warn("[Farm] ✗ 所有按键方式都送不进游戏 —— 技能按键会无效。")
		warn("[Farm]   （走位和装备武器不依赖按键，不受影响。）")
		warn("[Farm]   跑一次 key-probe.lua 能看到每种方式的具体报错。")
	end
	return activeKeyMethod
end

local function sendKey(key, down)
	local m = ensureKeyMethod()
	if not m then return false, "没有可用的按键方式" end
	local ok, err = pcall(down and m.down or m.up, key)
	return ok, err
end

local function pressKey(k)
	local ok, err = sendKey(k, true)
	if not ok then return false, "所有按键方式都发不出去（游戏收不到）" end
	task.wait(jitter(0.05))
	sendKey(k, false)
	return true
end

-- 走位用的按住 / 松开。
-- 走位和技能不一样：技能是"按一下"，走位是"按住不放"，
-- 所以必须保证【按下的键最终一定会被松开】—— 否则脚本停了角色还在跑。
local function strafeHold(k)
	return (sendKey(k, true))
end

local function strafeRelease()
	if not strafeDir then return end
	sendKey(strafeDir, false)
	strafeDir = nil
end

-- 绕 Y 轴旋转一个水平向量（度）。
-- 用来让撤退的每一跳左右偏转，走成之字形 ——
-- 一直朝同一个方向直线跑，容易撞墙/撞地图边界卡住，
-- 而且追踪的怪顺着一条直线跟就行。
local function rotateY(v, deg)
	local r = math.rad(deg or 0)
	local c, s = math.cos(r), math.sin(r)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

-- 位置（走位）+ 朝向（对准目标）。
--
-- ★ 为什么"朝向"要单独做 ★
-- 你的武器是【创造剑气飞向前方】—— 前方 = 角色的朝向。
-- 而 Roblox 默认角色是【朝移动方向】转的，所以横移走位时角色会侧过身，
-- 剑气就直接飞歪了。自动瞄准只改相机，管不了角色朝向。
-- 之前只有 cframe 走位顺手设过一次朝向，走位一关就完全没人管 ——
-- 技能打不中很可能就是这个原因。
local function combatPose(dt, root, hum, allowMove)
	if not root then return end

	local pos = root.Position
	local look = nil
	local hasTarget = targetPart ~= nil and targetPart.Parent ~= nil

	-- ① 位置：走位横移（有目标才走）
	if hasTarget and allowMove and CONFIG.strafe then
		local tgt = targetPart.Position
		local toMe = pos - tgt
		local flat = Vector3.new(toMe.X, 0, toMe.Z)
		if flat.Magnitude > 0.5 then
			local radial = flat.Unit
			local tangent = Vector3.new(-radial.Z, 0, radial.X) * strafeSign
			local step = CONFIG.strafeSpeed * (dt or 0)

			if CONFIG.strafeMode == "move" and hum then
				hum:Move(tangent, false)      -- 官方移动 API，让它自己走
			elseif step > 0 then
				pos = pos + tangent * step    -- 直接平移
			end
		end
	end

	-- ② 悬停（"飞行"状态）。
	--    传送/撤退会把角色放到空中（怪悬空、地图边缘），不锁高度就会自由落体
	--    掉出地图。这里是每帧写回高度，不是真的飞行系统。
	--
	--    ★ 必须放在"有没有目标"之外 ★
	--    原来整段函数在没有目标时直接 return —— 那样"传到空中、目标正好死了"
	--    就会开始自由落体，正是最需要防的情况。
	local now = os.clock()
	if hoverY then
		if now < hoverUntil then
			pos = Vector3.new(pos.X, hoverY, pos.Z)
		elseif CONFIG.hoverWhenAirborne and hum
			and hum.FloorMaterial == Enum.Material.Air then
			-- 悬停到期了但脚下还是空的 → 下面是地图外，继续续期
			hoverUntil = now + 0.5
			pos = Vector3.new(pos.X, hoverY, pos.Z)
		else
			hoverY = nil      -- 落地了，恢复正常
		end
	end

	-- ③ 朝向：水平对准目标。
	--    用目标同样的高度算朝向 —— 否则角色会仰着或趴着打，
	--    剑气也会带上俯仰角。
	if hasTarget then
		local tgt = targetPart.Position
		look = Vector3.new(tgt.X, pos.Y, tgt.Z)
	end

	local flatDist = look and (look - pos).Magnitude or 0
	if look and flatDist > 0.5 then
		root.CFrame = CFrame.new(pos, look)
	elseif pos ~= root.Position then
		root.CFrame = CFrame.new(pos)
	end
end

-- 当前生效的技能表。
-- 按【当前装备的武器名】查 skillRotationByWeapon，查不到就用默认的 skillRotation。
-- 换武器时自动重排计时器，不用重开脚本 —— 你背包里有 6 把武器，会经常换。
local curRotation, curRotationKey = nil, nil

local function rotationFor()
	local tool = PLR.Character and PLR.Character:FindFirstChildWhichIsA("Tool")
	local name = tool and tool.Name or ""

	if name ~= curRotationKey then
		local r = (CONFIG.skillRotationByWeapon or {})[name]
		curRotation = (r and #r > 0) and r or CONFIG.skillRotation
		curRotationKey = name

		-- 重排计时器：错开一点，别让几个技能同一帧全丢出去
		skillNext, skillFired = {}, 0
		local t0 = os.clock()
		for i = 1, #curRotation do
			skillNext[i] = t0 + (i - 1) * 0.2
		end
		if name ~= "" then
			print(string.format("[Farm] 当前武器 %s → %d 个技能", name, #curRotation))
		end
	end
	return curRotation
end

--------------------------------------------------------------------------------
-- 自动装备武器
--------------------------------------------------------------------------------
local SLOT_KEYS = {
	Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four,
	Enum.KeyCode.Five, Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight,
	Enum.KeyCode.Nine,
}

local lastEquipAt = -math.huge
local equipWarned = false
local equipTries = 0
-- 按格位键时我们【看不到第 N 格装的是哪把武器】，只能用"按下前后有没有变化"来判断。
-- 不这么做的话，equipForce 会每 2 秒按一次键，永远停不下来。
local slotEquippedName = nil
local probeSlot, probeBeforeName = false, nil
local equipSlotWarned = false

local function toolNames(backpack)
	local t = {}
	for _, c in ipairs(backpack:GetChildren()) do
		if c:IsA("Tool") then t[#t + 1] = c.Name end
	end
	return #t > 0 and table.concat(t, ", ") or "（空）"
end

local function ensureEquipped()
	if not CONFIG.autoEquip then return end

	local now = os.clock()
	local force = forceEquipOnce          -- 喝完药要强装一次武器

	-- auto 模式：先按热键栏，按了几次没效果就改用官方 API 兜底。
	-- 必须在退避判断【之前】算出来 —— 见下面的注释。
	local useApi = (CONFIG.equipMethod == "api")
		or (CONFIG.equipMethod == "auto" and equipTries >= (CONFIG.equipMaxTries or 3))

	-- 退避：同一种方式反复失败才放慢，别每 2 秒按一次刷屏。
	--
	-- ★ 换用 API 时不能退避 ★
	-- 那是另一种机制，很可能一次就成。之前把退避放在前面，
	-- 导致 equipTries 一到 3 就整个函数 15 秒不干活 ——
	-- auto 的 API 兜底在手边却永远走不到。
	--
	-- ★ force 时也不能退避 ★
	-- 喝完药必须【立刻】把武器装回来，等 2 秒或 15 秒都是白挨打。
	local interval = CONFIG.equipCheckInterval
	if not useApi and not force and equipTries >= (CONFIG.equipMaxTries or 3) then
		interval = math.max(interval, 15)
	end
	if not force and now - lastEquipAt < interval then return end

	local char = PLR.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local backpack = PLR:FindFirstChild("Backpack")
	if not (char and hum and backpack) then return end

	local equipped = char:FindFirstChildWhichIsA("Tool")
	if equipped then equipTries = 0 end   -- 手上有武器了，计数归零

	-- ① 按名字装（最稳，也最明确）：不管手上是什么，都要装上指定的那把。
	--    用 Roblox 官方的 Humanoid:EquipTool，不是伪造任何东西。
	if CONFIG.equipByName and CONFIG.equipByName ~= "" then
		if equipped and equipped.Name == CONFIG.equipByName then return end

		lastEquipAt = now
		for _, t in ipairs(backpack:GetChildren()) do
			if t:IsA("Tool") and t.Name == CONFIG.equipByName then
				local ok = pcall(function() hum:EquipTool(t) end)
				print(string.format("[Farm] 装备 %s → %s", t.Name, ok and "成功" or "失败"))
				return
			end
		end
		if not equipWarned then
			equipWarned = true
			print(string.format("[Farm] 背包里没有 %s。现有：%s", CONFIG.equipByName, toolNames(backpack)))
		end
		return
	end

	-- ② 按格位：走游戏自己的热键栏，发真实数字键。
	--
	--    默认只在「手上没武器」时装 —— 死了重生武器会掉，这才是主要场景。
	--
	--    equipForce = true 想"永远换成三号位"，但有个硬限制：
	--    我们看不到"第 3 格是哪把武器"。所以按下键之后比较前后变化，
	--    记住装上的那把；以后只要还是它，就认为已经对了。
	if probeSlot then
		probeSlot = false
		local nowName = equipped and equipped.Name or nil
		if nowName and nowName ~= probeBeforeName then
			slotEquippedName = nowName     -- 按键确实生效了
			equipTries = 0
		end
	end

	if equipped then
		if slotEquippedName and equipped.Name == slotEquippedName then return end
		if not CONFIG.equipForce and not force then return end
	end

	local k = SLOT_KEYS[CONFIG.equipSlot or 0]
	if not k then return end

	lastEquipAt = now
	if force then
		forceEquipOnce = false           -- 这次强装过了，清掉标记
		-- 强装时也要把 slotEquippedName 清掉，否则会被"已经装对了"挡回去
		slotEquippedName = nil
	end
	-- （useApi 已经在函数开头算好了，退避判断要用到它）

	if useApi then
		-- api 方式能直接指定工具，装完就知道装的是谁，不需要探测
		local tools = {}
		for _, t in ipairs(backpack:GetChildren()) do
			if t:IsA("Tool") then tools[#tools + 1] = t end
		end
		local t = tools[CONFIG.equipSlot]
		if t then
			local ok = pcall(function() hum:EquipTool(t) end)
			print(string.format("[Farm] 装备格位 %d 的 %s → %s",
				CONFIG.equipSlot, t.Name, ok and "成功" or "失败"))
			slotEquippedName = t.Name
		elseif not equipSlotWarned then
			-- 背包里不够那么多格：说清楚，别静默什么都不做
			equipSlotWarned = true
			print(string.format("[Farm] 背包里只有 %d 个工具，没有第 %d 格 —— 装不了。",
				#tools, CONFIG.equipSlot))
			print("[Farm]   核对 CONFIG.equipSlot，或改用 equipByName 按名字装。")
		end
	else
		probeBeforeName = equipped and equipped.Name or nil
		pressKey(k)
		probeSlot = true            -- 下一拍比较前后变化，判断按键有没有生效
		equipTries = equipTries + 1
		if equipTries <= 1 then
			print(string.format("[Farm] 按 %d 键装备武器", CONFIG.equipSlot))
		elseif equipTries == (CONFIG.equipMaxTries or 3) and not equipWarned then
			equipWarned = true
			print(string.format("[Farm] 按了 %d 次「%d」键都没装上武器 —— 先放慢重试。",
				equipTries, CONFIG.equipSlot))
			print("[Farm]   可能原因：那一格是空的 / 数字键不生效 / 需要先打开背包。")
			print("[Farm]   更稳的做法：CONFIG.equipByName = \"你的武器名\"（直接按名字调 API 装）")
		end
	end
end


--------------------------------------------------------------------------------
-- ★ 副本模块：自动开箱 ★
--
-- 从 chestfinder.lua 移植的核心 —— 扫描的排除逻辑和开箱的确认逻辑，
-- 那是 81 项断言在测的东西，不重写、不"简化"。
--
-- 整个模块包在一个函数作用域里：它自己的 C / scan / openEntry 这些名字
-- 不会和农场那边撞车（两边的顶层重名有 CONFIG / ui / PLR / UIS / conns 等）。
--
-- 没搬的部分（都有理由）：
--   · 全图隔空开箱 —— 你实测过"无效果"，服务端拒绝远距触发
--   · 标记用的 Highlight / BillboardGui —— 刷副本不需要，标记功能仍在 chestfinder.lua
--   · 独立面板和快捷键 —— 统一用农场那套 UI
--------------------------------------------------------------------------------
Chest = (function()
	local C = {
		keywords      = { "terror chest", "shadow chest" },
		-- ★ 流程默认：只开 Terror 箱子 ★
		onlyTerror    = true,
		onlyKeywords  = { "terror" },
		-- ★ Shadow 箱子开关（默认关）★
		-- keywords 里本来含 shadow chest，这个开关让你能把它排除掉。
		openShadow    = false,
		shadowKeywords = { "shadow" },
		-- ★ UI 开关：要不要开"假箱子"（带问号的）★
		-- 问号是游戏用来标记【假箱子】的。默认不开 —— 开了就是白跑一趟。
		-- 打开它主要是让你自己验证"哪些是真箱子"。
		openQuestion  = false,
		questionMarks = { "?", "？" },
		-- ★ UI 开关：自动拿钥匙 ★
		-- Shadow Key 之类的掉落物，实现方式和开箱【完全一样】：
		-- 扫描 → 锁定最近的 → 传送过去 → 按 E（走 ProximityPrompt）。
		--
		-- 我一开始猜"碰到就捡"，是错的 —— 你说了是【按 E 拿】，
		-- 所以直接复用开箱那条路，不另搞一套触碰逻辑。
		autoKey       = false,
		-- ★ 按你给的实际名字：ShadowRaidKey1 / ShadowRaidKey2 … ★
		-- normName 去掉空格/下划线/连字符再转小写，所以
		-- "ShadowRaidKey1" → "shadowraidkey1"，含 "shadowraidkey" ✓
		--
		-- 之前填的 "key" 太宽 —— KeyDoor 里也含 key，被当成钥匙反复传送却永远拿不到。
		-- 用具体名字从根上解决，下面那张排除表就只是保险了。
		keyKeywords   = { "shadowraidkey" },
		-- 关键词已经很具体（shadowraidkey），这张表其实用不上了。
		-- 留着是保险：万一以后有人把 keyKeywords 改回 "key" 这种短词，
		-- 这里能挡住 Monkey / KeyDoor 那一类误伤。
		keyIgnore     = { "monkey", "keydoor", "door", "keypad", "keyword",
		                  "keychain", "turkey", "donkey", "keyboard" },

		-- ★ 手动传送目标 ★
		-- 按名字找最近的并传送过去（UI 上两个按钮 + L / O 键）。
		spawnKeywords  = { "spawn" },      -- 刷怪触发点
		keyDoorKeywords = { "keydoor" },   -- Key 门
		spawnStandOff  = 8,                -- 传送落点离目标多远
		triggerMaxPoints = 8,              -- 一次最多走几个触发点
		triggerWait    = 0.8,              -- 每个触发点停多久（等刷怪生效）
		dedupeRange    = 25,               -- 相距小于这个数的触发点算同一个

		-- ★ 自定义坐标 ★
		-- UI 上「记录坐标」把当前位置存进来，「传送·坐标」送你过去。
		-- 想固化就直接写在这里，例如：
		--     customPos = Vector3.new(-8494, 1066, 3844),
		customPos      = nil,

		-- ★ 自动完成一二部分（一键跑完整个副本流程）★
		--
		-- 流程（按你给的坐标）：
		--   大门(-7964,1250,111) 按E → 进去就是刷怪一
		--   打完刷怪一 → 开箱子 + 捡钥匙
		--   刷怪二(-9108,1066,3814) 按E → 打完 → 开箱 + 钥匙
		--   刷怪三(-7725,1062,3810) 按E → 打完 → 开箱 + 钥匙
		--   → 第一层完毕
		--   Key门 按E → 进第二层
		--   刷怪四 按E → 打完 → 整个流程完成
		--
		-- ★ 缺的坐标用 auto 找（关键词匹配）；收到准确坐标后填 pos 即可 ★
		autoRun = true,
		waypoints = {
			-- ★ 大门：只开门，不刷怪、不掉东西 ★
			-- 你实测确认的：和大门互动后【走到刷怪一才会出怪】。
			-- 所以这站必须 fight = false（不然会白等怪 60 秒），
			-- loot = false（这站本来就没有掉落）。
			{ name = "大门",   pos = Vector3.new(-7964, 1250, 111),  interact = true,
			  fight = false, loot = false, quiet = false,
			  -- ★ 这站不用战斗，缓一下就赶紧走 ★（你要求的"时间改短"）
			  settle = 0.4 },
			-- ★ 刷怪点：只打怪，【什么都不捡】★
			-- 你要求的：打完一二三之后一起开箱子 + 拿钥匙。
			{ name = "刷怪一", pos = Vector3.new(-8471.5, 1065.3, 3595), interact = false,
			  loot = false },
			{ name = "刷怪二", pos = Vector3.new(-9108, 1066, 3814), interact = false,
			  loot = false },
			{ name = "刷怪三", pos = Vector3.new(-7725, 1062, 3810), interact = false,
			  loot = false },
			-- ★ 收战利品：打完一二三之后，一次把三个点的箱子和钥匙都收了 ★
			-- 站在刷怪三（离一 777、离二 1383 studs），
			-- keyRange = 2500 保证三个点都扫得到。
			-- lootTimeout = 10：★ 只有这一步是"10 秒没开到箱就走" ★（你要求的）
			{ name = "收战利品", pos = Vector3.new(-7725, 1062, 3810), interact = false,
			  fight = false, keyRange = 2500, lootTimeout = 10,
			  -- ★ 必须凑够 3 把钥匙才推进 ★（你要求的）
			  needKeys = 3,
			  -- ★ 不要把它拉回原点 ★
			  -- 这站要跑 2500 studs 去收东西，拉回来就变成来回瞬移了。
			  hold = false },
			-- ★ Key门：准确坐标（你给的）★
			-- 只负责"按 E 进门" —— 进去之后的刷怪点四交给第七步。
			{ name = "Key门",  pos = Vector3.new(-8470, 1109, 4080), interact = true,
			  fight = false, loot = false, settle = 0.6 },
			-- ★ 第七步：刷怪点四 ★
			-- 进门之后人已经在那儿了，刷怪点是靠近触发的，所以【不传送】，
			-- 原地打怪 + 收战利品。
			{ name = "刷怪四", noMove = true, interact = false },
			-- ★ 第八步：重启地牢 ★
			-- 切到 6 号位，然后一直左键（点那个道具来重开地牢）。
			-- clickFor 是点多久（秒）—— 30 秒不够就加大。
			{ name = "重启地牢", noMove = true, interact = false,
			  fight = false, loot = false,
			  slot = 6, clickFor = 30, settle = 0.5 },
		},
		-- ★ 与门互动要【长按 E 5 秒】★（你实测出来的）
		autoInteractHold = 5.0,
		-- 互动前先收起武器。
		-- ★ 为什么必须收 ★：武器在手上时 E 会被武器技能吃掉，
		-- 门根本收不到这次按键 —— 这就是"互动了但门没开"的原因。
		unequipBeforeInteract = true,
		autoInteractPresses = 3,   -- 每个点按几次真实 E
		interactRange  = 40,       -- 传送后多大范围内找门的交互件
		-- ★ 每站必须真的出现过怪，否则不算打完 ★
		-- 不然"E 没触发成刷怪"会被当成"打完了"，
		-- 流程会静默跑完四站还报完成 —— 那比报错还糟。
		autoSpawnTimeout = 10,     -- ★ 等怪最多 10 秒，没有就推进下一站 ★（你要求的）
		-- 等掉落出现最多等多久（秒）。可以按站覆盖（wp.lootTimeout）。
		-- 这是【默认值】：第六步（Key门）用这个，因为刷怪点四的掉落
		-- 可能比第五步慢一点。
		autoLootTimeout  = 25,
		-- ★ 打怪中途不许判定完成 ★
		-- 怪死的瞬间 target 会短暂为空，那时候推进下一站就错了。
		-- 要求连续这么久没见过怪目标才算这站打完。
		fightQuietTime   = 5.0,
		-- 锁着的目标超过这么久没进展 → 强制放掉（防"wait 卡死"）
		lockStuckTime    = 10,

		-- ★ 注入后自动开始副本流程 ★
		-- 配合 Xeno 的"自动执行"用：注进来就自动跑，不用按 Y。
		-- 不想自动开始就改成 false。
		autoStart = false,
		autoStartDelay = 3.0,      -- 等游戏加载/角色就位再开始（秒）

		-- ★ 换服后自动重跑 ★
		-- 第 8 步重启地牢会【换服务器】，脚本会被卸载 —— 这里排队一个
		-- "换服后执行"的指令，让它在新服里自动再跑一遍。
		--
		-- 填脚本的【直链】才有效，例如 GitHub raw / pastebin raw：
		--   reinjectUrl = "https://raw.githubusercontent.com/你/仓库/main/dungeon.lua",
		-- 留空 = 不做（换服后脚本就没了）。
		reinjectUrl = "",
		-- ★ 没事可做时回到传送点等着 ★
		-- 刷怪点是"靠近就触发"的：跑到别处（比如去开远处的箱子）就离开触发区了。
		-- 所以在"等怪/等掉落"期间把自己拉回站点坐标。
		holdAtPoint      = true,
		holdRange        = 20,     -- 离传送点超过这么多就拉回去
		autoStepWait   = 1.0,      -- 按完 E 等多久再进下一阶段
		autoLootIdleTime = 6.0,    -- 连续这么久"没进展"才算这站收完（恐怖箱要按住4秒，留余量）

		-- 排除词。和 chestfinder 一致。
		-- 注意 "?" / "？" 这两个会被 openQuestion 开关单独控制，不在这里写死。
		ignoreKeywords = { "spawner", "effect", "glow", "prompt", "highlight", "?", "？" },
		trackRange    = 1200,
		maxTracked    = 150,
		openRange     = 30,
		openCooldown  = 0.8,
		openHoldExtra = 0.4,
		retryDelay    = 2.0,
		maxOpenRetries = 3,
		keyOpen       = Enum.KeyCode.E,
		-- ★ 按住时长覆盖表 ★
		-- 为什么需要：游戏常把"要按多久"做在服务端，客户端的 prompt.HoldDuration
		-- 读到的是 0 或者偏小 —— 照它按必被拒（你反馈 Terror 箱子按不够就是这个）。
		-- 这里按关键词给下限，取"读到的值"和"表里的值"中较大的那个。
		holdByKeyword = { ["terror"] = 4.0, ["shadow"] = 1.0 },
		-- 重试时按住时长自动往上加：按了没开就说明不够，下次多按一会儿。
		-- 有了它就不必一次猜准 —— 第一次按 4s 没开，第二次 6s，第三次 8s。
		holdGrowPerRetry = 0.5,   -- 每次重试把按住时长增加 50%
		sweepInterval = 1.2,    -- 两次尝试之间至少隔多久
		sweepMaxHops  = 60,     -- 一次巡回最多开几个（防止死循环）
		standOff      = 6,      -- 落到箱子旁边多少 studs
		settle        = 0.6,    -- 触发后等多久再确认箱子有没有消失
		                        -- ★ 注意是 C.settle，不是 CONFIG.cycleSettle ★
		                        -- 那是 chestfinder 的配置项，农场的 CONFIG 里没有 —— 
		                        -- 移植时写成 CONFIG.cycleSettle 会直接 arithmetic on nil。
	}

	local enabled = false
	-- ★ 自动流程的状态，必须【声明在最早】★
	-- kindOf（很前面）要读 auto.active 来判断钥匙要不要认。
	-- 声明在后面的话，那里读到的是全局 nil，一执行就崩 ——
	-- 这个坑在这个项目里已经是第四次了，所以直接放最前面。
	local auto = { active = false, idx = 0, phase = "idle", idleSince = nil, phaseAt = 0,
		sawMobs = false, stationAt = 0,
		-- engaged：从按下「自动完成一二」到流程跑完/手动停止之间都为 true。
		-- 回位靠它判断"别把正在跑副本的人拽回原位"（含暂停期间）。
		engaged = false,
		-- busy：互动阶段正在跑（那里面有 task.wait）。
		-- 靠它挡住 onHeartbeat 的重入 —— 不挡的话同一站会被并发执行很多次。
		busy = false,
		-- 当前这一站要不要捡钥匙（wp.keys == false 时只开箱子）
		keysAllowed = true,
		-- 当前这一站的扫描范围加成（最后一站要扫到前几站掉的钥匙）
		rangeBoost = 0,
		-- paused：手动停过但还没跑完 → 再按 Y 从当前站继续
		paused = false }
	local opening = false
	local lastOpenTime = -math.huge
	local openedSet, retryAfter, retryCount = {}, {}, {}
	local openedCount, fails = 0, 0
	-- ★ 钥匙单独计数 ★ 第五步要求"凑够三把才推进"
	local keysTaken = 0
	local holdLogged = {}
	local lastSweepAt = -math.huge
	local hops = 0
	local current = nil     -- ★ 当前锁定的目标（箱子或钥匙）：处理完才换 ★
	local currentKind = nil
	local lastChest = nil

	-- 规范化：去掉空格/下划线/连字符再转小写，
	-- 这样 "Terror Chest" / "TerrorChest" / "terror_chest" 都能被命中。
	local function normName(s)
		return (string.lower(s):gsub("[%s_%-]", ""))
	end

	local function isQuestion(s)
		for _, q in ipairs(C.questionMarks or {}) do
			if s == q then return true end
		end
		return false
	end

	local function matchesKeywords(name, list)
		local n = normName(name)
		for _, kw in ipairs(list or {}) do
			local k = normName(kw)
			if k ~= "" and string.find(n, k, 1, true) then return true end
		end
		return false
	end

	local function nameExcluded(name)
		if type(name) ~= "string" then return false end
		local n = normName(name)
		for _, bad in ipairs(C.ignoreKeywords or {}) do
			-- 开了"开问号箱子"就跳过问号那几个排除词 —— 别的地方照旧排除
			if not (C.openQuestion and isQuestion(bad)) then
				local b = normName(bad)
				if b ~= "" and string.find(n, b, 1, true) then return true end
			end
		end
		return false
	end

	local function matches(target)
		if nameExcluded(target.Name) then return false end
		local n = normName(target.Name)

		local hit = false
		for _, kw in ipairs(C.keywords) do
			local k = normName(kw)
			if k ~= "" and string.find(n, k, 1, true) then hit = true break end
		end
		if not hit then return false end

		-- "只开 Terror 箱子"开关：再加一道门槛
		if C.onlyTerror then
			local ok = false
			for _, kw in ipairs(C.onlyKeywords or {}) do
				local k = normName(kw)
				if k ~= "" and string.find(n, k, 1, true) then ok = true break end
			end
			if not ok then return false end
		end

		-- Shadow 箱子开关：默认不开（只开 Terror）
		if C.openShadow == false
			and matchesKeywords(target.Name, C.shadowKeywords) then
			return false
		end
		return true
	end

	-- 整个子树都要查。★这是"带问号的箱子还是会开"的修复★
	-- 关键：ProximityPrompt 显示给玩家的文字是 ObjectText，和实例名字是两回事。
	-- 游戏原生提示框显示 "Shadow Chest?"，而实例名字是干净的。
	local TEXT_CLASSES = { TextLabel = true, TextButton = true, TextBox = true }

	local function treeExcluded(inst)
		if nameExcluded(inst.Name) then return true end
		for _, d in ipairs(inst:GetDescendants()) do
			-- 两道护栏，否则会把自己的箱子全误杀：
			--  ① 名字 == 类名 = 开发者没改过名（ProximityPrompt 等默认就叫类名），
			--     "prompt" 是排除词，不跳过的话所有带 prompt 的箱子当场全灭。
			--  ② 脚本类不参与。
			if d.Name ~= d.ClassName
				and not d:IsA("Script")
				and not d:IsA("LocalScript")
				and not d:IsA("ModuleScript") then
				if nameExcluded(d.Name) then return true end
			end
			if TEXT_CLASSES[d.ClassName] then
				local txt = d.Text
				if type(txt) == "string" and txt ~= "" and nameExcluded(txt) then
					return true
				end
			end
			if d.ClassName == "ProximityPrompt" then
				for _, prop in ipairs({ "ObjectText", "ActionText" }) do
					local v = d[prop]
					if type(v) == "string" and v ~= "" and nameExcluded(v) then
						return true
					end
				end
			end
		end
		return false
	end

	-- 这个东西属于哪一类： "key" / "chest" / nil（不处理）
	-- 钥匙先判 —— 万一某个东西同时像两者，按钥匙处理更安全。
	local function kindOf(target)
		if nameExcluded(target.Name) then return nil end
		if (C.autoKey or (auto.active and auto.keysAllowed ~= false))
			and matchesKeywords(target.Name, C.keyKeywords) then
			-- "key" 太短，先过一遍钥匙专用的排除表（Monkey 之类），
			-- 否则一只叫 Monkey 的怪会被当成钥匙去"拿"。
			if not matchesKeywords(target.Name, C.keyIgnore) and not treeExcluded(target) then
				return "key"
			end
		end
		if matches(target) then return "chest" end
		return nil
	end

	local function stillTargetable(target)
		return kindOf(target) ~= nil
	end

	local function resolveOwner(obj, kind)
		local cur, bestM = obj, nil
		while cur and cur ~= workspace do
			if not cur:IsA("Model") then bestM = nil end
			if cur:IsA("Model") and kindOf(cur) == kind then bestM = cur end
			cur = cur.Parent
		end
		return bestM or obj
	end

	local function isLocalChar(obj)
		local char = PLR.Character
		if not char then return false end
		return obj:IsDescendantOf(char)
	end

	local function findInteractable(target)
		local prompt, click
		local function consider(obj)
			if not prompt and obj:IsA("ProximityPrompt") and obj.Enabled then
				prompt = obj
			elseif not click and obj:IsA("ClickDetector") then
				click = obj
			end
		end
		consider(target)
		for _, d in ipairs(target:GetDescendants()) do consider(d) end
		return prompt, click
	end

	local function hostPart(target, prompt)
		local p = prompt and prompt.Parent
		if p and p:IsA("BasePart") then return p end
		if target:IsA("BasePart") then return target end
		return target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
	end

	-- 这个箱子该按住多久。
	-- ① 取"客户端读到的 HoldDuration"和"按关键词配的覆盖值"里较大的那个
	-- ② 重试时继续往上加 —— 按了没开就说明不够，下次多按一会儿。
	--    有了 ② 就不必一次猜准，所以覆盖值给个保守的初值就行。
	local function holdFor(target, prompt, tries)
		local base = math.max(tonumber(prompt and prompt.HoldDuration) or 0, 0)
		local best = nil
		if target then
			local n = normName(target.Name)
			for kw, secs in pairs(C.holdByKeyword or {}) do
				local k = normName(kw)
				if k ~= "" and string.find(n, k, 1, true) then
					secs = tonumber(secs) or 0
					if best == nil or secs > best then best = secs end
				end
			end
		end
		local h = (best and math.max(base, best)) or base

		local t = tonumber(tries) or 1
		if t > 1 and C.holdGrowPerRetry and C.holdGrowPerRetry > 0 then
			h = h * (1 + C.holdGrowPerRetry * (t - 1))
		end
		return h
	end

	-- ★ 没有交互件时的兜底：发真实的 E 键 ★
	--
	-- 为什么需要：钥匙这类掉落物常常【没有 ProximityPrompt】——
	-- 游戏是在客户端脚本里自己监听 E 键的。只认 prompt 的话，
	-- 它永远不会被锁定（你反馈的"不会拿钥匙"就是这个）。
	-- 所以没有交互件时，站过去发真实 E。
	local function pressPickupKey(tries)
		local n = 2 + (tonumber(tries) or 1)   -- 重试时多按几次
		for _ = 1, n do
			pressKey(C.keyOpen)
			task.wait(0.12)
		end
		return true
	end

	local function fireInteract(prompt, click, target, tries)
		if prompt then
			local hold = holdFor(target, prompt, tries)
			local key = target and target.Name
			if key and not holdLogged[key] then
				holdLogged[key] = true
				print(string.format("[Chest] %s：按住 %.2fs", key, hold))
			end
			pcall(function() prompt:InputHoldBegin() end)
			if hold > 0 then task.wait(hold + C.openHoldExtra) end
			pcall(function() prompt:InputHoldEnd() end)
			return true
		end
		if click then
			if not fireclickdetector then
				return false, "这个执行器没有 fireclickdetector"
			end
			local ok, err = pcall(fireclickdetector, click)
			return ok, err
		end
		return false, "没有交互件"
	end

	-- 找范围内所有能拿的东西（箱子 + 钥匙），按距离升序返回。
	-- 每次调用都重新扫 —— 箱子/钥匙开完即销毁，缓存反而会拿到死引用。
	local function scanTargets()
		local char = PLR.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local myPos = root and root.Position

		local cands, seen = {}, {}
		for _, obj in ipairs(workspace:GetDescendants()) do
			if obj:IsA("Model") or obj:IsA("BasePart") then
				local kind = kindOf(obj)
				-- 钥匙可能是散落的 Part，所以两类都从 obj 往上看 owner
				if kind and not isLocalChar(obj) then
					local owner = resolveOwner(obj, kind)
					if not seen[owner] then
						seen[owner] = true
						local part = owner:IsA("BasePart") and owner
							or owner.PrimaryPart
							or owner:FindFirstChildWhichIsA("BasePart", true)
						if part and part.Parent and not treeExcluded(owner)
							and not openedSet[owner] then
							local d = myPos and (part.Position - myPos).Magnitude or 0
							-- 最后一站要能扫到前几站掉的钥匙 → rangeBoost
							local trackRange = math.max(C.trackRange or 1200,
								(auto.active and auto.rangeBoost) or 0)
							if d <= trackRange then
								cands[#cands + 1] = {
									target = owner, part = part, dist = d, kind = kind,
								}
							end
						end
					end
				end
			end
		end
		table.sort(cands, function(a, b) return a.dist < b.dist end)

		local out = {}
		for i = 1, math.min(#cands, C.maxTracked) do out[i] = cands[i] end
		return out
	end

	-- 落到箱子旁边（带朝向）。用的是农场那套位移 + 悬停，
	-- 这样传到悬空箱子旁边也不会掉出地图。
	local function goTo(part, standOff)
		local char = PLR.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root then return false end

		local p = part.Position
		local cur = root.Position
		local dir = Vector3.new(cur.X - p.X, 0, cur.Z - p.Z)
		if dir.Magnitude < 0.5 then dir = Vector3.new(1, 0, 0) end
		dir = dir.Unit

		local off = standOff or C.standOff
		local spot = Vector3.new(p.X + dir.X * off, p.Y, p.Z + dir.Z * off)
		local look = Vector3.new(p.X, spot.Y, p.Z)
		applyPos(root, spot, look)
		if CONFIG.pinAfterTp > 0 then pinPos(spot, CONFIG.pinAfterTp, look) end
		hoverY = spot.Y
		hoverUntil = os.clock() + (CONFIG.hoverAfterTp or 0)
		return true
	end

	local function openEntry(entry, prompt, click)
		if opening then return false end
		local now = os.clock()
		if now - lastOpenTime < C.openCooldown then return false end
		lastOpenTime = now
		opening = true

		local target = entry.target
		-- ★ 故意不在这里标记"已开" ★
		-- 之前是触发前就标记 —— 被服务端拒掉的那次也被算成"已开"，
		-- 那个箱子之后再也不会被尝试。这就是"有部分箱子不会自动开"。
		-- 改成：先挂重试冷却，等确认箱子真的没了才标记。
		local tries = (retryCount[target] or 0) + 1
		retryCount[target] = tries
		retryAfter[target] = now + C.retryDelay

		task.spawn(function()
			if prompt or click then
				local effHold = prompt and holdFor(target, prompt, tries) or 0
				if effHold > 0 then
					print(string.format("[Chest] %s %s（按住 %.1fs，第 %d 次）…",
						(entry.kind == "key") and "拿" or "开箱", target.Name, effHold, tries))
				end

				local ok, err = fireInteract(prompt, click, target, tries)
				opening = false
				if not ok then
					print("[Chest] 触发失败: " .. tostring(err))
					-- ★ 不能直接 return ★
					-- 直接返回会跳过下面的"试够次数就放弃"判断 ——
					-- 于是每次失败只挂个 2 秒冷却，tries 一直在涨却永远不放弃，
					-- current 被永久锁住，step 永远返回 "wait"。
					-- 实测表现：卡在收战利品 655 秒，act=wait，扫到=0。
					if tries >= (C.maxOpenRetries or 3) then
						openedSet[target] = true
						retryAfter[target], retryCount[target] = nil, nil
						print(string.format("[Chest] %s 触发失败 %d 次，放弃它",
							target.Name, tries))
					else
						retryAfter[target] = os.clock() + (C.retryDelay or 2)
					end
					return
				end
			else
				-- 没有 ProximityPrompt / ClickDetector：游戏自己在客户端听 E 键，
				-- 那就发真实的 E。已经站在它旁边了。
				print(string.format("[Chest] %s %s（没有交互件，发真实 E 键，第 %d 次）…",
					(entry.kind == "key") and "拿" or "开箱", target.Name, tries))
				pressPickupKey(tries)
				opening = false
			end

			-- 等一小段看服务端到底认没认
			for _ = 1, math.max(1, math.floor(C.settle * 60)) do task.wait() end

			if target.Parent == nil then
				-- 目标没了 = 服务端认了这次交互
				openedSet[target] = true
				openedCount = openedCount + 1
				retryAfter[target], retryCount[target] = nil, nil
				-- ★ 钥匙单独计数 ★
				-- 第五步要求"凑够三把钥匙才推进"，所以得能数出拿了几把。
				if entry.kind == "key" then keysTaken = keysTaken + 1 end
				print(string.format("[Chest] %s %s",
					(entry.kind == "key") and "已拿" or "已开", target.Name))
			elseif tries >= C.maxOpenRetries then
				openedSet[target] = true
				retryAfter[target] = nil
				print(string.format("[Chest] %s 试了 %d 次都没成，放弃", target.Name, tries))
			else
				retryAfter[target] = os.clock() + C.retryDelay
				print(string.format("[Chest] %s 没成功（第 %d 次），稍后重试", target.Name, tries))
			end
		end)
		return true
	end

	-- 一步巡回。
	--
	-- ★ 核心规则：锁定一只，开完（或放弃）才换下一只 ★
	--
	-- 之前不是这样：每次都在"当前最近的能开的箱子"里挑，挑到够不着就传过去。
	-- 结果列表顺序一变、或手里那只进了重试冷却，它就会【丢下手里这只】
	-- 跑去传送下一只 —— 表现是到处飞但不怎么开箱。
	--
	-- 返回："off" / "wait" / "none" / "moved" / "opened" / "restart"
	-- ★ 手动传送：按名字找最近的并过去 ★
	--
	-- 两趟：
	--   ① 名字本身命中（BossSpawn 这种 Part / Model）
	--   ② 没有的话，看命中名字的【文件夹】里面有什么（Spawns 是个 Folder，
	--      真正的位置在它子件里）
	-- 这个游戏里探针看到的是 Workspace.MapStorage.Earth Biome.Spawns (Folder)
	-- 和 BossSpawn (Part)，所以两趟都需要。
	local function findNearestByName(list)
		local char = PLR.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local myPos = root and root.Position
		if not myPos then return nil end

		local best, bestPart, bestD = nil, nil, math.huge
		local function consider(obj)
			local part = obj:IsA("BasePart") and obj
				or obj.PrimaryPart
				or obj:FindFirstChildWhichIsA("BasePart", true)
			if part and part.Parent then
				local d = (part.Position - myPos).Magnitude
				if d < bestD then best, bestPart, bestD = obj, part, d end
			end
		end

		-- ① 名字直接命中
		for _, obj in ipairs(workspace:GetDescendants()) do
			if (obj:IsA("Model") or obj:IsA("BasePart"))
				and matchesKeywords(obj.Name, list) and not isLocalChar(obj) then
				consider(obj)
			end
		end

		-- ② 命中名字的文件夹里面找
		if not best then
			for _, obj in ipairs(workspace:GetDescendants()) do
				if obj:IsA("Folder") and matchesKeywords(obj.Name, list) then
					for _, c in ipairs(obj:GetChildren()) do
						if c:IsA("Model") or c:IsA("BasePart") then consider(c) end
					end
				end
			end
		end
		return best, bestPart, bestD
	end

	local function gotoByName(list, label)
		local obj, part, d = findNearestByName(list)
		if not obj then
			print(string.format("[Chest] 没找到 %s（关键词：%s）",
				label, table.concat(list or {}, " / ")))
			return false
		end
		goTo(part, C.spawnStandOff)
		print(string.format("[Chest] → %s：%s（%.0f studs）", label, obj.Name, d or 0))
		return true
	end

	-- 直接传到一个坐标（不依赖 workspace 里有实体）
	local function goToPos(pos, lookAt)
		local char = PLR.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root or not pos then return false end
		applyPos(root, pos, lookAt)
		if CONFIG.pinAfterTp > 0 then pinPos(pos, CONFIG.pinAfterTp, lookAt) end
		hoverY = pos.Y
		hoverUntil = os.clock() + (CONFIG.hoverAfterTp or 0)
		return true
	end

	-- ★ 自定义坐标：记录 / 传送 ★
	local function saveCustomPos()
		local char = PLR.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root then return false end
		local p = root.Position
		C.customPos = Vector3.new(p.X, p.Y, p.Z)
		print(string.format("[Chest] 已记录当前坐标：%.1f, %.1f, %.1f", p.X, p.Y, p.Z))
		print(string.format(
			"[Chest]   想固化就写进 CONFIG：customPos = Vector3.new(%.1f, %.1f, %.1f),",
			p.X, p.Y, p.Z))
		return true
	end

	local function goCustomPos()
		if not C.customPos then
			print("[Chest] 还没记录坐标 —— 先走到地方，点「记录坐标」或按 P。")
			return false
		end
		local p = C.customPos
		-- 朝向随便给一个（坐标传送没有"目标"可对）
		goToPos(p, p + Vector3.new(100, 0, 0))
		print(string.format("[Chest] → 坐标（%.1f, %.1f, %.1f）", p.X, p.Y, p.Z))
		return true
	end

	-- ★ 触发刷怪：把匹配到的刷怪点【全部走一遍】★
	--
	-- 副本里有多个触发点（你说有两个），只去最近的那个不够 ——
	-- 要挨个传送过去才算把怪刷出来。
	local function findAllByName(list)
		local char = PLR.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local myPos = root and root.Position
		if not myPos then return {} end

		local cands, seen = {}, {}
		local function consider(obj)
			if seen[obj] then return end
			local part = obj:IsA("BasePart") and obj
				or obj.PrimaryPart
				or obj:FindFirstChildWhichIsA("BasePart", true)
			if part and part.Parent then
				seen[obj] = true
				cands[#cands + 1] = { obj = obj, part = part,
					dist = (part.Position - myPos).Magnitude }
			end
		end

		-- ① 名字直接命中
		for _, obj in ipairs(workspace:GetDescendants()) do
			if (obj:IsA("Model") or obj:IsA("BasePart"))
				and matchesKeywords(obj.Name, list) and not isLocalChar(obj) then
				consider(obj)
			end
		end
		-- ② 命中名字的文件夹里面找
		for _, obj in ipairs(workspace:GetDescendants()) do
			if obj:IsA("Folder") and matchesKeywords(obj.Name, list) then
				for _, c in ipairs(obj:GetChildren()) do
					if c:IsA("Model") or c:IsA("BasePart") then consider(c) end
				end
			end
		end

		table.sort(cands, function(a, b) return a.dist < b.dist end)

		-- 按距离去重：同一个触发点常由好几个部件组成，
		-- 挨个传过去纯属浪费时间。相距很近的算一个点。
		local out = {}
		for _, e in ipairs(cands) do
			local dup = false
			for _, k in ipairs(out) do
				if (k.part.Position - e.part.Position).Magnitude < (C.dedupeRange or 25) then
					dup = true
					break
				end
			end
			if not dup then out[#out + 1] = e end
		end
		return out
	end

	local function triggerSpawns()
		local list = findAllByName(C.spawnKeywords)
		if #list == 0 then
			print(string.format("[Chest] 没找到刷怪点（关键词：%s）",
				table.concat(C.spawnKeywords or {}, " / ")))
			return false
		end

		local n = math.min(#list, C.triggerMaxPoints or 8)
		print(string.format("[Chest] 找到 %d 个刷怪点，挨个传送过去触发", n))
		for i = 1, n do
			local e = list[i]
			goToPos(e.part.Position, e.part.Position + Vector3.new(100, 0, 0))
			print(string.format("[Chest]   触发点 %d/%d：%s（%.0f studs）",
				i, n, e.obj.Name, e.dist))
			-- 每个点停一下，让刷怪触发生效再走下一处
			task.wait(C.triggerWait or 0.8)
		end
		print("[Chest] 触发完成")
		return true
	end

	-- 找离某个位置最近的交互件（门多半是 ProximityPrompt / ClickDetector）。
	-- 自动流程用：传送到大门/刷怪点之后，附近的交互件就是那道门。
	local function findNearestInteractable(pos, range)
		local best, bestD = nil, math.huge
		for _, obj in ipairs(workspace:GetDescendants()) do
			if obj:IsA("ProximityPrompt") or obj:IsA("ClickDetector") then
				local host = obj.Parent
				if host and host:IsA("BasePart") then
					local d = (host.Position - pos).Magnitude
					if d <= (range or 40) and d < bestD then
						bestD = d
						best = {
							obj = host,
							prompt = obj:IsA("ProximityPrompt") and obj or nil,
							click = obj:IsA("ClickDetector") and obj or nil,
							dist = d,
						}
					end
				end
			end
		end
		return best
	end

	-- 强制放掉当前锁定的目标（用于"锁死了"的保护）
	local function releaseLock()
		if not current then return false end
		openedSet[current] = true          -- 别再挑它
		retryAfter[current], retryCount[current] = nil, nil
		current, currentKind = nil, nil
		return true
	end

	-- ★ 把"已放弃"的钥匙重新放回候选 ★
	--
	-- 为什么需要：钥匙重试 maxOpenRetries 次后会被标成 openedSet，
	-- 之后【永远不再尝试】。第五步要求凑够三把钥匙 ——
	-- 少一把就永远凑不齐（你反馈的"停止收集钥匙"）。
	-- 所以在钥匙不够时，把场上还存在的钥匙重新放回可尝试列表。
	local function rearmKeys()
		local n = 0
		for obj in pairs(openedSet) do
			if obj ~= nil and obj.Parent ~= nil
				and matchesKeywords(obj.Name, C.keyKeywords) then
				openedSet[obj] = nil
				retryAfter[obj], retryCount[obj] = nil, nil
				n = n + 1
			end
		end
		return n
	end

	local function step(force)
		-- 开箱和拿钥匙是【两个独立开关】——
		-- 只开"自动拿钥匙"不开"自动开箱"时必须也能跑。
		-- force：自动流程调的，不受开关限制，而且钥匙箱子都要。
		if not enabled and not C.autoKey and not force and not auto.active then return "off" end
		local now = os.clock()
		if now - lastSweepAt < C.sweepInterval then return "wait" end
		lastSweepAt = now

		if hops >= C.sweepMaxHops then
			hops = 0
			current = nil
			return "restart"
		end

		local char = PLR.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root then return "none" end

		----------------------------------------------------------------
		-- ① 手里有锁定目标 → 只看它，不换
		----------------------------------------------------------------
		if current then
			if current.Parent == nil then
				current, currentKind = nil, nil      -- 拿到了/开掉了 → 下一个
			elseif openedSet[current] then
				current, currentKind = nil, nil      -- 试够次数放弃了 → 下一个
			elseif retryAfter[current] and now < retryAfter[current] then
				-- ★ 兜底：冷却中也要检查"是不是该放弃了" ★
				-- 万一有别的路径没走到放弃逻辑（比如触发失败早退），
				-- current 就会被永久锁住、step 永远返回 "wait" ——
				-- 实测表现是卡在收战利品 655 秒、act=wait、扫到=0。
				if (retryCount[current] or 0) >= (C.maxOpenRetries or 3) then
					openedSet[current] = true
					retryAfter[current], retryCount[current] = nil, nil
					print(string.format("[Chest] %s 重试 %d 次仍未成，放掉它",
						current.Name, retryCount[current] or C.maxOpenRetries or 3))
					current, currentKind = nil, nil
				else
					-- 刚触发过 / 失败了，在等确认或重试冷却 —— 就等着，别跑去别处
					return "wait"
				end
			else
				local prompt, click = findInteractable(current)
				-- ★ 不再要求"必须有交互件" ★
				-- 钥匙常常没有 ProximityPrompt（游戏自己在客户端听 E 键），
				-- 要求会把它整个排除掉 —— 那就是"不会拿钥匙"的原因。
				if not stillTargetable(current) then
					current, currentKind = nil, nil  -- 不能拿了 → 下一个
				else
					local part = hostPart(current, prompt)
					if not part or not part.Parent then
						current, currentKind = nil, nil
					else
						local dist = (part.Position - root.Position).Magnitude
						local reach = prompt and (prompt.MaxActivationDistance or 10)
							or (click and (click.MaxActivationDistance or C.openRange) or 0)
						if dist > math.max(reach, 8) then
							hops = hops + 1
							goTo(part)
							print(string.format("[Chest] → %s（%.0f studs）%s", current.Name, dist,
								currentKind == "key" and " [钥匙]" or ""))
							return "moved"
						elseif openEntry({ target = current, part = part, kind = currentKind }, prompt, click) then
							hops = hops + 1
							return "opened"
						end
						return "wait"              -- 冷却中，等
					end
				end
			end
		end

		----------------------------------------------------------------
		-- ② 没有锁定目标 → 挑"最近的能拿的"（箱子 + 钥匙一起算距离），锁定它
		----------------------------------------------------------------
		local list = scanTargets()
		for _, e in ipairs(list) do
			local t = e.target
			-- 关掉的那一类不挑
			if (e.kind == "key" and (C.autoKey or auto.active or force))
				or (e.kind == "chest" and (enabled or force or auto.active)) then
				if not (retryAfter[t] and now < retryAfter[t]) then
					-- 同样不再要求有交互件：钥匙没有 prompt，靠发 E 键拿
					if stillTargetable(t) then
						current = t
						currentKind = e.kind
						lastChest = t
						print(string.format("[Chest] 锁定 %s（%.0f studs）%s",
							t.Name, e.dist, e.kind == "key" and " [钥匙]" or ""))
						return "picked"
					end
				end
			end
		end

		hops = 0
		return "none"
	end

	-- ★ 自动流程：大门 → 刷怪二 → 刷怪三 → Key门 → 刷怪四 ★
	--
	-- 为什么这么排：打怪完全交给农场那边（有怪的时候 Heartbeat 根本走不到这里），
	-- 所以流程机只需要在【没怪的时候】做三件事：
	--   ① 传送到下一个点并按 E
	--   ② 让正常巡检去开箱/捡钥匙
	--   ③ 巡检连续一段时间没事可做 → 这一步算完，进下一步
	local function autoAdvance()
		auto.idx = auto.idx + 1
		auto.phase = "go"
		auto.idleSince = nil
		-- 设成"过去"：让 go 阶段的重试节流【不耽误第一次动作】
		-- （否则刚进这一站要白等 3 秒才传送）
		auto.phaseAt = os.clock() - 10
		auto.lastMissTick = -1
		auto.lastStuckTick, auto.lastStuckLootTick = -1, -1
		local wp = C.waypoints[auto.idx]
		if not wp then
			auto.active = false
			auto.engaged = false       -- 跑完了，回位可以恢复了
			auto.phase = "idle"
			print("[Chest] ★★★ 自动流程全部完成 ★★★")
			return
		end
		print(string.format("[Chest] ▶ 第 %d/%d 步：%s", auto.idx, #C.waypoints, wp.name))
	end

	local function doGoPhase(wp)
		-- ★ pos 必须声明在 if 之外 ★
		-- 之前它写在 else 块里 —— 于是下面互动用的 pos 变成了全局 nil，
		-- 直接报 "attempt to index a nil value"（Vector3 减 nil）。
		local pos = wp.pos
		-- ★ noMove：不传送 ★
		-- 进门之后人已经在那儿了（刷怪四靠靠近触发），不需要再传一次。
		if wp.noMove then
			print(string.format("[Chest]   %s：原地不动（进去就在这儿）", wp.name))
		else
		-- 落点：给了坐标就用坐标，否则按关键词找
		if not pos and wp.findKeywords then
			local obj, part = findNearestByName(wp.findKeywords)
			if part then
				pos = part.Position
				print(string.format("[Chest]   %s 按关键词找到：%s", wp.name, obj.Name))
			end
		end

		if not pos then
			-- ★ 不暂停 ★ 你要求流程一直跑，直到你手动停。
			-- 留在这个阶段，过几秒自动重试 —— 你按 N 记录坐标之后，
			-- 下一次重试就会用上，流程自己接着走。
			local t = math.floor((os.clock() - (auto.phaseAt or 0)) / 20)
			if t > (auto.lastMissTick or -1) then
				auto.lastMissTick = t
				print(string.format("[Chest] ⚠ 第 %d 步「%s」没有坐标（流程继续，正在重试）",
					auto.idx, wp.name))
				print("[Chest]   办法一：走到它旁边按 N 就地记录，流程会自动接上。")
				print("[Chest]   办法二：用 coords.lua 抄下坐标，填进 CONFIG.waypoints。")
				print("[Chest]   想停下就按 Y。")
			end
			return false
		end

		goToPos(pos, pos + Vector3.new(100, 0, 0))
		print(string.format("[Chest]   已传送到 %s（%.0f, %.0f, %.0f）",
			wp.name, pos.X, pos.Y, pos.Z))
		end   -- noMove 分支结束

		-- ★ 第八步用：切到某个背包栏位 ★
		-- 你要求"把物品切到六号位一直左键" —— 先按对应数字键。
		if wp.slot then
			local sk = SLOT_KEYS[wp.slot]
			if sk then
				pressKey(sk)
				task.wait(jitter(0.4))
				print(string.format("[Chest]   已切到 %d 号位", wp.slot))
			else
				print(string.format("[Chest] ⚠ %d 号位没有对应按键，跳过", wp.slot))
			end
		end

		-- ★ 一直左键 ★ 用于重启地牢那种"点道具"的操作
		if wp.clickFor then
			local dur = tonumber(wp.clickFor) or 30
			local until_ = os.clock() + dur
			local n = 0
			print(string.format("[Chest]   开始连续左键 %.0f 秒（重启地牢）…", dur))
			-- 按次数循环而不是看时钟：替身里 task.wait 不推进 os.clock
			local steps = math.max(1, math.floor(dur / 0.1))
			for _ = 1, steps do
				clickOnce()
				n = n + 1
				task.wait(jitter(0.1))
			end
			print(string.format("[Chest]   连续左键结束（点了 %d 次）", n))
		end

		if wp.interact ~= false then
			-- ★ ① 先收起武器 ★
			-- 武器在手上时 E 会被武器技能吃掉，门收不到这次按键。
			if C.unequipBeforeInteract ~= false then
				local hum0 = PLR.Character and PLR.Character:FindFirstChildOfClass("Humanoid")
				if hum0 and hum0.UnequipTools then
					pcall(function() hum0:UnequipTools() end)
					task.wait(0.25)
				end
			end

			local hold = wp.holdE or C.autoInteractHold or 5.0
			local used = {}

			-- ★ ② 附近有交互件就用官方 API，按住同样的时长 ★
			local near = findNearestInteractable(pos, C.interactRange or 40)
			if near and near.prompt then
				local ph = math.max(tonumber(near.prompt.HoldDuration) or 0, hold)
				pcall(function() near.prompt:InputHoldBegin() end)
				task.wait(ph + 0.3)
				pcall(function() near.prompt:InputHoldEnd() end)
				used[#used + 1] = string.format("Prompt(%s)按住%.1fs", near.obj.Name, ph)
			elseif near and near.click then
				if fireclickdetector then pcall(fireclickdetector, near.click) end
				used[#used + 1] = string.format("ClickDetector(%s)", near.obj.Name)
			end

			-- ★ ③ 再【按住】真实 E 键 hold 秒 ★
			sendKey(C.keyOpen, true)
			task.wait(hold)
			sendKey(C.keyOpen, false)
			used[#used + 1] = string.format("按住真实E %.1fs", hold)

			print(string.format("[Chest]   已在 %s 互动：%s", wp.name, table.concat(used, " + ")))

			-- ★ ⑤ 验证门到底开了没有 ★
			-- 原来互动完只等 settle(0.4s) 就走 —— 门没开也照样推进到下一步
			-- （你反馈的"阶段一开门之前不要推到阶段二"）。
			-- 判定：刚才用的那个交互件如果【还在且还启用】，就认为门没开，
			-- 按同样的方式再按一次，最多 interactAttempts 次。
			local attempts = tonumber(C.interactAttempts) or 4
			for i = 2, attempts do
				task.wait(0.6)          -- 给游戏一点处理时间
				local again = findNearestInteractable(pos, C.interactRange or 40)
				local stillThere = again and again.obj == near and again.obj.Parent ~= nil
				-- prompt 被禁用/消失也算"门开了"
				if stillThere and again.prompt ~= nil
					and again.prompt.Enabled == false then
					stillThere = false
				end
				if not stillThere then
					print(string.format("[Chest]   %s 开门确认通过（第 %d 次尝试）", wp.name, i - 1))
					break
				end
				print(string.format("[Chest]   %s 还没开（第 %d 次重试）…", wp.name, i))
				if again and again.prompt then
					local ph2 = math.max(tonumber(again.prompt.HoldDuration) or 0, hold)
					pcall(function() again.prompt:InputHoldBegin() end)
					task.wait(ph2 + 0.3)
					pcall(function() again.prompt:InputHoldEnd() end)
				end
				sendKey(C.keyOpen, true)
				task.wait(hold)
				sendKey(C.keyOpen, false)
				if i == attempts then
					print(string.format(
						"[Chest] ⚠ %s：按了 %d 次仍没确认开门，继续往下走（不影响流程）",
						wp.name, attempts))
				end
			end

			-- ★ ④ 互动完把武器装回来 ★
			forceEquipOnce = true
		end
		return true
	end

	-- ★ 没事可做 → 回到传送点待着 ★
	-- 刷怪点是"靠近就触发"的：跑去开远处的箱子就离开触发区了，
	-- 怪可能就不刷了。所以在等待期间把自己拉回站点坐标。
	-- 上一次"拉回点位"的时间（节流用）。函数本身不能挂字段。
	local holdLastAt = 0

	local function holdAtWaypoint(wp, why)
		if C.holdAtPoint == false or not wp.pos then return end
		-- ★ 按站关闭 ★
		-- 收战利品那站要跑很远去捡东西（keyRange=2500），
		-- 拉回原点等于"跑出去→拉回来→再跑出去"，一直瞬移（你反馈的）。
		if wp.hold == false then return end
		-- ★ 节流 ★ 别一秒拉好几次
		local nowH = os.clock()
		if nowH - holdLastAt < (C.holdMinInterval or 3.0) then return end
		local r = PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart")
		if not r then return end
		local d = (r.Position - wp.pos).Magnitude
		if d > (C.holdRange or 20) then
			holdLastAt = nowH
			goToPos(wp.pos, wp.pos + Vector3.new(100, 0, 0))
			print(string.format("[Chest]   回到 %s 的传送点等待（%s，跑远了 %.0f studs）",
				wp.name, why, d))
		end
	end

	local function autoStep(hasTarget)
		if not auto.active then return "skip" end		-- ★ 防重入 ★
		-- onHeartbeat 每帧都调进来，而"go"阶段要 yield（长按 E 5 秒）。
		-- 不锁的话等待期间会被并发重入 —— 同一站被重复执行 20 次，
		-- 20 个 5 秒长按叠在一起，门直接开不了（截图里刷屏就是这个）。
		if auto.busy then return "busy" end
		local now = os.clock()
		local wp = C.waypoints[auto.idx]
		if not wp then auto.active = false return "skip" end

		if auto.phase == "go" then
			-- 重试节流：没坐标等情况别每帧重试一遍
			if now - (auto.phaseAt or 0) < 3 then return "busy" end
			-- 放到独立线程里跑，autoStep 立刻返回 —— 这样不会再被重入。
			-- 注意【不要】用 pcall 包住：Lua 5.3 里 pcall 不能跨 yield，
			-- 而 doGoPhase 里有 task.wait（长按 E）。单独的 API 调用各自有 pcall。
			auto.busy = true
			task.spawn(function()
				local ok = doGoPhase(wp)
				auto.busy = false
				if ok then
					auto.phase = "loot"
					auto.idleSince = os.clock()
					auto.phaseAt = os.clock()
					auto.stationAt = os.clock()
					auto.sawMobs = false        -- 这一站还没见过怪
					auto.lastMobAt = os.clock() -- "安静期"从这一刻开始算
					auto.spawnGaveUp = false    -- 每站重置（上一站给过不代表这站也给）
					auto.lastWaitTick = -1      -- 等怪进度提示的节流
					auto.lastLootTick = -1
					auto.lootBase = openedCount -- 这一站开始时已经捡了多少
					auto.keyBase = keysTaken   -- 这一站开始时已经拿了几把钥匙
				else
					-- ★ 不暂停 ★ 留在"go"阶段过几秒自动重试
					-- （你按 N 记录坐标之后，下次重试就能用上）
					auto.phase = "go"
					auto.phaseAt = os.clock()
				end
			end)
			return "busy"
		end

		if auto.phase == "loot" then
			-- ★ 诊断放最前面 ★
			-- 原来它在 hasTarget 判断【之后】—— 如果一直被怪挡着，
			-- 那行日志根本不会打，看起来就像"卡住了没反应"。
			-- 现在无论什么情况都打，直接看出卡在哪。
			local t10d = math.floor(now / 10)
			if t10d > (auto.lastDiagTick or -1) then
				auto.lastDiagTick = t10d
				local scanned = #scanTargets()
				print(string.format(
					"[Chest] [状态] 第%d/%d步 %s | 阶段=%s | 有目标=%s 撤退=%s | 见过怪=%s | 扫到=%d | 本站已捡=%d | 上次act=%s | 本站已 %ds",
					auto.idx, #C.waypoints, wp.name, tostring(auto.phase),
					hasTarget and "是" or "否", retreating and "是" or "否",
					auto.sawMobs and "是" or "否", scanned,
					openedCount - (auto.lootBase or 0),
					tostring(auto.lastAct),          -- ★ 上次巡检返回值（挪诊断时弄丢的）★
					math.floor(now - (auto.stationAt or now))))
			end

			-- 打怪优先：还有怪就等它打完，别去抢传送
			if hasTarget then
				auto.sawMobs = true
				auto.lastMobAt = now          -- 记下最近一次"确实有怪"
				return "busy"
			end

			-- ★ 别在打怪中途判定完成 ★
			-- 怪死的瞬间 target 会短暂为空。刷怪点都是 loot=false，
			-- 那时候就会立刻推进下一站（你反馈的"打怪中途判定完成"）。
			-- 所以要求"已经有一阵子没见到怪目标"才准走。
			--
			-- ★ 用户要求：第 2~8 步全局都这样 —— 有怪就不推进 ★
			-- 所以默认【每一站】都要过安静期，只有第 1 步（大门）例外，
			-- 它自己声明了 quiet = false。fight 只管"要不要等怪出现"。
			local quiet = now - (auto.lastMobAt or 0)
			local needQuiet = wp.quiet ~= false
			local quietTime = C.fightQuietTime or 5.0

			-- ★ 先确认这一站真的刷出怪了 ★
			-- 判定"打完"的依据是"没怪"，可如果 E 压根没触发成刷怪，
			-- 那也是"没怪" —— 会被当成打完了，然后静默跑完剩下所有站。
			-- 所以必须等到【出现过怪】才算这一站开始过。
			--
			-- wp.fight == false：这站本来就不刷怪（比如"大门"——
			-- 开门不刷怪，怪是下一个点刷的），就跳过等待。
			if wp.fight ~= false and not auto.sawMobs then
				-- 等怪期间也别跑远 —— 跑出触发区就更不刷了
				holdAtWaypoint(wp, "等刷怪")
				local waited = now - auto.stationAt
				local lim = C.autoSpawnTimeout or 60
				-- ★ 不暂停 ★ 过了时限也只是提醒一句，然后【继续等】。
				-- 你要求流程一直跑，直到手动按 Y 停。
				if waited < lim then
					-- 每 10 秒说一声，不然等待看起来像卡死
					local t10 = math.floor(waited / 10)
					if t10 > (auto.lastWaitTick or -1) then
						auto.lastWaitTick = t10
						print(string.format("[Chest]   等 %s 刷怪… %.0f/%.0f 秒",
							wp.name, waited, lim))
					end
				else
					-- ★ 10 秒没等到怪 → 推进到下一站 ★（你要求的）
					-- 之前是"超时后照常去开箱"，现在直接走。
					if not auto.spawnGaveUp then
						auto.spawnGaveUp = true
						print(string.format(
							"[Chest] ⚠ %s：%.0f 秒没等到怪，推进下一站。",
							wp.name, waited))
					end
					auto.sawMobs = true
					-- 这站本来就不捡东西 → 直接下一站
					-- （但也要过了"安静期"，别在打怪中途溜走）
					if wp.loot == false then
						if needQuiet and quiet < quietTime then return "busy" end
						print(string.format("[Chest]   %s 完成（没怪，直接下一站）", wp.name))
						autoAdvance()
						return "busy"
					end
					-- 要捡东西 → 交给下面的巡检去收，收完再走
				end
				return "busy"
			end


			-- wp.loot == false：这站不用捡东西 → 直接进下一站
			-- 但要先缓一下：E 刚松开就传送走，门可能还没处理完
			-- （开门动画/服务端状态需要一点时间）。
			-- 这就是你看到的"与大门互动后直接推到 2"—— 太快了。
			if wp.loot == false then
				local settle = wp.settle or C.autoStepWait or 1.0
				if now - auto.phaseAt < settle then return "busy" end
				-- ★ 同样要过安静期 ★ 不然打怪中途就会走
				if needQuiet and quiet < quietTime then return "busy" end
				print(string.format("[Chest]   %s 完成（这站不捡东西，缓了 %.1fs）",
					wp.name, settle))
				autoAdvance()
				return "busy"
			end

			-- ★ 顺序很重要：先跑巡检，再看有没有捡到 ★
			-- 反过来的话就是死锁：没跑巡检 → 不可能捡到东西 →
			-- "必须捡到过"永远不满足 → 死等超时。实测里表现为"完全不开箱子"。
			if now - auto.phaseAt < (C.autoStepWait or 1.0) then return "busy" end

			-- ★ 按站控制捡不捡钥匙 / 扫多远 ★
			-- wp.keys == false      → 这站只开箱子，钥匙留着
			-- wp.keyRange = 1800    → 这站能扫到很远（收前几站掉的钥匙）
			auto.keysAllowed = wp.keys ~= false
			auto.rangeBoost = wp.keyRange or 0

			local act = step(true)          -- true = 强制跑（不受开关限制）
			auto.lastAct = act

			-- ★ 锁死保护 / 空闲判定 ★
			-- act 会在 wait 和 none 之间来回跳 —— 原来两边都要求"连续"，
			-- 于是谁也攒不满：放锁攒不到 10 秒，空闲攒不到 4 秒，永远不推进。
			-- 实测：卡在第 5 步 158 秒，act=wait，扫到=0。
			--
			-- 改法：只有【真的在推进】的动作才重置计时；
			-- wait（锁着等冷却）和 none（没东西可拿）都算"没进展"。
			local progressed = (act == "picked" or act == "moved" or act == "opened")
			if progressed then
				auto.waitSince = nil
				auto.idleSince = nil
			else
				-- act 是 wait / none / off 之一
				local dt = now - (auto.lastTickAt or now)
				auto.waitSince = (auto.waitSince or now)   -- 只记起点
				auto.waitAcc = (auto.waitAcc or 0) + dt
				if auto.waitAcc > (C.lockStuckTime or 10) then
					auto.waitAcc = 0
					if releaseLock() then
						print(string.format("[Chest] 锁住超过 %d 秒没进展，放掉它，继续找下一件",
							C.lockStuckTime or 10))
					end
				end
			end
			auto.lastTickAt = now

			if act == "off" or act == "none" or act == "wait" then
				-- ★ 没怪、也没箱子/钥匙可拿 → 回传送点待着 ★
				holdAtWaypoint(wp, "等掉落")

				-- ★★ 钥匙没拿够就不许推进 ★★（你要求的）
				-- 第五步要求凑够三把钥匙。这个检查在【所有推进判断之前】，
				-- 而且不看超时 —— 少一把就一直等，直到你手动停。
				local needK = wp.needKeys or 0
				local gotK = keysTaken - (auto.keyBase or 0)
				if gotK < needK then
					-- ★ 还不够就必须继续找 ★
					-- 把之前被"放弃"的钥匙重新放回候选 ——
					-- 不然它永远凑不齐，就卡在这了（你反馈的"停止收集钥匙"）。
					local rearmed = rearmKeys()
					if rearmed > 0 then
						print(string.format(
							"[Chest]   钥匙还差 %d 把 → 把场上 %d 把已放弃的钥匙重新放回候选",
							needK - gotK, rearmed))
					end
					local waited = now - auto.stationAt
					local t20 = math.floor(waited / 20)
					if t20 > (auto.lastKeyTick or -1) then
						auto.lastKeyTick = t20
						print(string.format(
							"[Chest]   等 %s 的钥匙… 已拿 %d/%d 把（已等 %.0f 秒）",
							wp.name, gotK, needK, waited))
					end
					return "busy"
				end

				-- 再确认这一站有没有捡到过东西。
				-- 判定"捡完了"是"连续 4 秒没东西可拿"，
				-- 但箱子可能是怪死后过一会儿才出现的 —— 那就等它出现。
				if (openedCount - (auto.lootBase or 0)) <= 0 then
					local waited = now - auto.stationAt
					-- 按站覆盖：收战利品那站用 10 秒，其他站用全局默认
					local lim = wp.lootTimeout or C.autoLootTimeout or 25
					-- ★ 不暂停 ★ 过了时限只提醒，继续等
					if waited < lim then
						local t10 = math.floor(waited / 10)
						if t10 > (auto.lastLootTick or -1) then
							auto.lastLootTick = t10
							print(string.format("[Chest]   等 %s 掉箱子/钥匙… %.0f/%.0f 秒",
								wp.name, waited, lim))
						end
					else
						-- ★ 超时不再死等 ★ 提醒一次，然后进下一站
						if not auto.lootGaveUp then
							auto.lootGaveUp = true
							print(string.format(
								"[Chest] ⚠ %s：%.0f 秒没等到掉落，先进下一站。",
								wp.name, waited))
							print("[Chest]   若这站本来就不掉东西，给它加 loot = false。")
						end
						print(string.format("[Chest]   %s 完成", wp.name))
						autoAdvance()
						return "busy"
					end
					return "busy"
				end

				-- 捡到过了 → 用"连续一段时间没事可做"判定这站完成
				if not auto.idleSince then auto.idleSince = now end
				if now - auto.idleSince >= (C.autoLootIdleTime or 4) then
					print(string.format("[Chest]   %s 完成", wp.name))
					autoAdvance()
					return "busy"
				end
			else
				auto.idleSince = nil
			end
			return "busy"
		end

		return "busy"
	end

	return {
		setEnabled = function(v) enabled = v and true or false; if enabled then hops, fails = 0, 0 end end,
		isEnabled = function() return enabled end,
		step = step,
		holdFor = holdFor,          -- 暴露出来给测试验"重试时按住时长会加长"
		reset = function()
			openedSet, retryAfter, retryCount = {}, {}, {}
			openedCount, fails, hops, lastChest = 0, 0, 0, nil
			current = nil
			lastSweepAt = -math.huge
		end,
		status = function()
			return { enabled = enabled, opened = openedCount, hops = hops, opening = opening,
				current = current and current.Name or nil,
				onlyTerror = C.onlyTerror, openQuestion = C.openQuestion,
				openShadow = C.openShadow,
				autoKey = C.autoKey }
		end,
		setAutoKey = function(v)
			C.autoKey = v and true or false
			current, currentKind = nil, nil     -- 条件变了，重新挑
		end,
		-- 手动传送：UI 按钮和快捷键都调这两个
		goSpawn = function() return gotoByName(C.spawnKeywords, "刷怪点") end,
		triggerSpawns = triggerSpawns,      -- 挨个走一遍所有刷怪点
		goKeyDoor = function() return gotoByName(C.keyDoorKeywords, "Key 门") end,
		-- 自定义坐标：UI 按钮和快捷键都调这两个
		saveCustomPos = saveCustomPos,
		goCustomPos = goCustomPos,
		-- ★ 自动完成一二部分 ★
		autoActive = function() return auto.active end,
		autoStep = autoStep,
		-- 农场那边一旦有怪目标就调这个 —— 自动流程靠它判断"这一站真的刷出怪了"
		-- ★ 同时刷新"最近一次有怪"的时间 ★
		-- 这一条原来漏了：它只设 sawMobs，没刷新 lastMobAt。
		-- 而 lastMobAt 只在【巡检段】里更新，那段又只在【没怪】时才会被调用 ——
		-- 于是打怪全程 lastMobAt 都不动，安静计时器一路涨到很大，
		-- 怪一消失就立刻"超时" → 照样误推进下一站。
		noteMobs = function()
			if auto.active then
				auto.sawMobs = true
				auto.lastMobAt = os.clock()
			end
		end,
		startAuto = function()
			-- ★ 中途停过的 → 从当前这一站【继续】，不回到第一步 ★
			-- （你反馈的"恢复后又会回到第一步"就是这个：
			--   原来这里写死 auto.idx = 0，每次按 Y 都从头开始。）
			if auto.paused and auto.idx >= 1 and auto.idx <= #C.waypoints then
				auto.active, auto.paused = true, false
				auto.busy = false
				auto.stationAt = os.clock()
				auto.phaseAt = os.clock() - 10      -- 立刻可以继续动作
				auto.idleSince = nil
				auto.lastWaitTick, auto.lastLootTick = -1, -1
				auto.lastStuckTick, auto.lastStuckLootTick = -1, -1
				if chestStartFarm then chestStartFarm() end
				print(string.format("[Chest] ⏵ 继续第 %d/%d 步：%s（没有回到第一步）",
					auto.idx, #C.waypoints, C.waypoints[auto.idx].name))
				return
			end
			-- 全新开始（或上一轮已经跑完）
			auto.active, auto.idx, auto.phase = true, 0, "idle"
			auto.engaged, auto.paused = true, false
			auto.busy = false
			auto.idleSince, auto.phaseAt = nil, os.clock()
			auto.lastMissTick = -1
			if chestStartFarm then chestStartFarm() end
			print("[Chest] ═══ 开始自动完成一二部分 ═══")
			autoAdvance()
		end,
		stopAuto = function()
			-- ★ 只停不清进度 ★ 这样再按 Y 能从这一站继续
			auto.active, auto.phase = false, auto.phase or "idle"
			auto.paused = (auto.idx >= 1 and auto.idx <= #C.waypoints)
			auto.busy = false
			if auto.paused then
				print(string.format("[Chest] ⏸ 已停下（停在第 %d/%d 步：%s）。再按 Y 从这里继续。",
					auto.idx, #C.waypoints, C.waypoints[auto.idx].name))
			else
				auto.engaged = false
				print("[Chest] 自动流程已停止")
			end
		end,
		autoPaused = function() return auto.paused end,
		-- 注入后自动开始（给游戏一点加载时间）。Xeno 设了"自动执行"就用得上。
		autoStartSoon = function()
			if C.autoStart ~= true then return end
			local d = C.autoStartDelay or 3.0
			print(string.format("[Chest] 已设置自动开始，%.0f 秒后启动（想取消就按 Y）", d))
			task.spawn(function()
				task.wait(d)
				if not auto.active then
					print("[Chest] 自动开始副本流程")
					-- 直接调内部逻辑（避免重复定义）
					auto.active, auto.idx, auto.phase = true, 0, "idle"
					auto.engaged, auto.paused, auto.busy = true, false, false
					auto.idleSince, auto.phaseAt = nil, os.clock()
					auto.lastMissTick = -1
					if chestStartFarm then chestStartFarm() end
					autoAdvance()
				end
			end)
		end,
		-- 清掉进度（想重新从第一站开始时用）
		resetAuto = function()
			auto.active, auto.idx, auto.phase = false, 0, "idle"
			auto.engaged, auto.paused, auto.busy = false, false, false
			auto.sawMobs, auto.keysAllowed, auto.rangeBoost = false, true, 0
			auto.lastMobAt, auto.spawnGaveUp = os.clock(), false
		end,
		-- 回位用它判断：流程在跑（或暂停中）就别把玩家拽回原位
		flowEngaged = function() return auto.engaged end,
		-- ★ 就地记录：把当前位置写进【当前这一站】★
		-- 不用去抄坐标 —— 走到地方按一下就行。
		recordCurrentWaypoint = function()
			local char = PLR.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if not root then print("[Chest] 角色不可用") return false end
			if not auto.idx or auto.idx < 1 or not C.waypoints[auto.idx] then
				print("[Chest] 当前没有待记录的站点 —— 先按 Y 启动流程，卡住时再按 N 记录。")
				return false
			end
			-- ★ 注意：这里【不能】要求 auto.active ★
			-- 就地记录正是给"流程因为缺坐标暂停了"用的，
			-- 要求流程在跑就等于把这个功能废掉（测试抓出来的）。
			local p = root.Position
			local wp = C.waypoints[auto.idx]
			wp.pos = Vector3.new(p.X, p.Y, p.Z)
			print(string.format("[Chest] ✓ 已把当前位置记录到第 %d 步「%s」：%.1f, %.1f, %.1f",
				auto.idx, wp.name, p.X, p.Y, p.Z))
			print(string.format(
				"[Chest]   想固化就写进 CONFIG.waypoints：{ name = \"%s\", pos = Vector3.new(%.1f, %.1f, %.1f), interact = true },",
				wp.name, p.X, p.Y, p.Z))
			return true
		end,
		autoStatus = function()
			local wp = C.waypoints[auto.idx]
			return { active = auto.active, idx = auto.idx, total = #C.waypoints,
				phase = auto.phase, name = wp and wp.name or nil }
		end,
		setOpenQuestion = function(v)
			C.openQuestion = v and true or false
			current = nil
		end,
		setOpenShadow = function(v)
			C.openShadow = v and true or false
			current = nil
		end,
		setOnlyTerror = function(v)
			C.onlyTerror = v and true or false
			current = nil
		end,
		config = C,
	}
end)()

--------------------------------------------------------------------------------
-- 主循环
--------------------------------------------------------------------------------

local function onHeartbeat(dt)
	if not running then
		strafeRelease()   -- 停了就把走位键松开，否则角色会一直跑
		return
	end

	-- 贵的遍历按间隔做，不要每帧
	if os.clock() - cacheAt >= CONFIG.mobRefreshInterval then
		refreshMobCache()
	end

	-- 先确保手上有武器 —— 死了重生会掉，不装回来就只剩平A甚至完全不打
	ensureEquipped()

	--------------------------------------------------------------------------------
	-- 保命：血掉了就撤到高处悬停，回到阈值再继续
	--------------------------------------------------------------------------------
	local me = PLR.Character and PLR.Character:FindFirstChildOfClass("Humanoid")
	local frac = (me and me.MaxHealth and me.MaxHealth > 0)
		and (me.Health / me.MaxHealth) or 1

	--------------------------------------------------------------------------------
	-- ★ 自动喝血药 ★
	-- 5 号位血药，冷却 30 秒，可以无限喝。
	-- 阈值比你调低的撤退阈值(0.2)高 —— 先喝药，喝不上再考虑撤。
	--------------------------------------------------------------------------------
	if CONFIG.autoPotion and me and me.MaxHealth and me.MaxHealth > 0 then
		local pf = me.Health / me.MaxHealth
		local now2 = os.clock()
		-- 撤退中用更积极的阈值：撤退时血已经很低，能喝就喝，
		-- 喝上就能早点把血拉回 hpResumeAt、结束撤退回去打。
		local thr = (retreating and CONFIG.potionAtRetreat) or CONFIG.potionAt or 0.5
		if pf <= thr and now2 >= nextPotion then
			local slotKey = SLOT_KEYS[CONFIG.potionSlot or 0]
			if slotKey then
				-- ★ 撤退时重试更勤 ★
				-- 血药实际 30 秒冷却，但"什么时候冷却好"脚本不知道。
				-- 撤退时每 3 秒试一次：试早了游戏会拒绝（不浪费），试到好为止 ——
				-- 这就是"撤退时优先喝药"。
				local cd = (retreating and (CONFIG.potionRetreatRetry or 3.0))
					or (CONFIG.potionCooldown or 30)
				nextPotion = now2 + cd
				pressKey(slotKey)
				-- 装备之后还要"用"一下。这个游戏的用法是【装备后左键】。
				--
				-- ★ 为什么要连点 0.5 秒而不是点一下 ★
				-- 装备动作有前摇，点一下就落在前摇里、点空了 ——
				-- 表现就是"喝了但没喝上"。连点一段时间把前摇盖过去才稳。
				local pm = CONFIG.potionMethod or "equip+click"
				if pm == "equip+click" then
					-- ★ 撤退时用更长的时间 ★
					-- 血掉得快、动作更容易被打断，短窗口容易"拿出来了但没喝上"。
					local delay = (retreating and (CONFIG.potionEquipDelayRetreat or 0.6))
						or (CONFIG.potionEquipDelay or 0.3)
					local win = (retreating and (CONFIG.potionClickWindowRetreat or 1.2))
						or (CONFIG.potionClickWindow or 0.5)
					task.wait(jitter(delay))
					-- 按次数循环而不是"看时钟"：这样在替身里也能终止
					-- （替身的 task.wait 不推进 os.clock，看时钟会死循环）。
					local n = math.max(1, math.floor(win / 0.08))
					for _ = 1, n do
						clickOnce()
						potionsClicked = potionsClicked + 1
						task.wait(jitter(0.08))
					end
				elseif pm == "equip+use" or pm == "key+use" then
					task.wait(jitter(0.12))
					activateTool()
				end
				potionsUsed = potionsUsed + 1
				forceEquipOnce = true       -- 喝完把武器装回来
				print(string.format("[Farm] 喝血药（当前 %.0f%%），下次 %.0fs 后",
					pf * 100, CONFIG.potionCooldown or 30))
			end
		end
	end

	--------------------------------------------------------------------------------
	-- 最大生命监控：武器特性会在 CD 中按技能时【消耗最大生命】强放
	--
	-- 所以最大生命掉下来 = "技能按早了"的直接证据。
	-- 检测到就自动把技能间隔继续拉长，并告警 —— 免得一直亏最大生命。
	--------------------------------------------------------------------------------
	if CONFIG.skillAutoBackoff and CONFIG.autoSkill and me and me.MaxHealth then
		local mh = me.MaxHealth

		-- 基准 = 见过的最大的最大生命（重生/换装后会自己抬高）。
		-- 也可以用 CONFIG.skillMaxHpBase 直接指定原始值 —— 更可靠。
		local configured = CONFIG.skillMaxHpBase
		if configured and configured > 0 then
			baseMaxHp = configured
		elseif not baseMaxHp or mh > baseMaxHp then
			baseMaxHp = mh
		end

		if lastMaxHp and mh < lastMaxHp - 0.5 then
			skillPenalty = skillPenalty * (CONFIG.skillBackoffStep or 1.25)
			print(string.format(
				"[Farm] 最大生命 %.0f → %.0f —— 技能按早了（CD 中被强放）。", lastMaxHp, mh))
			print(string.format(
				"[Farm]   技能间隔已自动 ×%.2f。冷却值可能填小了，建议核对后调大 interval。",
				skillPenalty))
		end

		-- 止损地板：掉太多就彻底停技能，别让最大生命被一点点扣光
		local floor = CONFIG.skillMinMaxHp
		if floor and floor < 1 and baseMaxHp and mh < baseMaxHp * floor then
			if not skillDisabledForHp then
				skillDisabledForHp = true
				warn(string.format(
					"[Farm] ✗ 最大生命已跌到 %.0f / %.0f（低于 %.0f%%）—— 技能已自动停用。",
					mh, baseMaxHp, floor * 100))
				warn("[Farm]   这说明 interval 填得比实际冷却小。核对 Q/E/R/F 的真实冷却后改 CONFIG.skillRotation。")
				warn("[Farm]   想继续用技能：调大 skillBuffer，或把 skillMinMaxHp 调低（1 = 关掉这道保险）。")
			end
		end

		lastMaxHp = mh
	end

	if CONFIG.autoRetreat then
		local root0 = PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart")

		if not retreating and frac <= CONFIG.hpRetreatAt then
			retreating = true
			-- ★ 撤退一开始就把血药冷却"解开" ★
			-- nextPotion 是"上次喝药 + 30 秒"。如果撤退前刚喝过一次，
			-- 这个值还在 30 秒后 —— 于是撤退全程一次都不会尝试（你反馈的）。
			-- 重置成 0 让它立刻试：真在冷却里游戏会拒绝，不会浪费药。
			nextPotion = 0

			-- 撤退点：往上抬 + 水平背离目标（脱离近战仇恨和范围攻击）
			local base = root0 and root0.Position or Vector3.zero
			local away = Vector3.zero
			if root0 and targetPart and targetPart.Parent then
				local d = root0.Position - targetPart.Position
				d = Vector3.new(d.X, 0, d.Z)
				if d.Magnitude > 0.1 then away = d.Unit end
			end
			retreatPos = base + away * CONFIG.retreatAway
				+ Vector3.new(0, CONFIG.retreatUp, 0)
			print(string.format("[Farm] 血量 %.0f%% → 撤退到高处", frac * 100))

		elseif retreating and frac >= CONFIG.hpResumeAt then
			retreating = false
			retreatPos = nil
			print(string.format("[Farm] 血量回到 %.0f%% → 继续刷", frac * 100))
		end
	end

	if retreating then
		strafeRelease()   -- 撤退时别横移，专心往上跑
		-- 持续钉在撤退点：不这么写的话会被重力拉回去，等于白撤
		local root = PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart")
		if root and retreatPos then
			-- ★ 每隔一段时间再往外瞬移一段 ★
			-- 追踪的怪会一直追上来，钉在一个点上不动等于站着等被追上。
			local now = os.clock()
			if now >= retreatNextHop then
				retreatNextHop = now + (CONFIG.retreatHopInterval or 1.0)
				-- 背离目标的方向；目标没了就沿用上一次的方向
				if targetPart and targetPart.Parent then
					local d = retreatPos - targetPart.Position
					d = Vector3.new(d.X, 0, d.Z)
					if d.Magnitude > 0.5 then retreatAwayDir = d.Unit end
				end
				if retreatAwayDir then
					-- 多方向：每跳把方向左右交替偏转，走之字形。
					-- 一直直线跑容易撞墙卡住，追踪的怪也只要顺着直线跟。
					retreatHopSign = -retreatHopSign
					local dir = retreatAwayDir
					local spread = CONFIG.retreatHopSpread or 0
					if spread > 0 then
						dir = rotateY(dir, spread * retreatHopSign)
					end
					retreatAwayDir = dir          -- 下一跳基于新方向继续偏
					retreatPos = retreatPos + dir * (CONFIG.retreatHopDistance or 30)
						+ Vector3.new(0, CONFIG.retreatHopUp or 0, 0)
				end
			end

			root.CFrame = CFrame.new(retreatPos)
			root.AssemblyLinearVelocity = Vector3.zero
			-- 撤退期间一直处于"飞行"状态，别人够不着，也不会掉出地图
			hoverY = retreatPos.Y
			hoverUntil = now + 0.5
		end
		-- ★ 这里【不再 return】★
		-- 你的武器是远程剑气 —— 边撤边打才是对的，撤退期间一律停火白白浪费输出。
		-- 位置由上面这段管；下面照常走瞄准 / 平A / 技能。
		-- 唯一要跳过的是【距离管理】，否则它会把你拽回怪身边，撤退就白做了。
	end

	-- ★ 自动完成一二部分：在打怪之前先推进流程 ★
	-- 传送/按E 由它负责；打怪照常交给下面。两者互不打架：
	--   "go" 阶段   只传一次 + 按 E，然后照常打怪
	--   "loot" 阶段 有怪就等（打怪优先），没怪才去清战利品
	if Chest.autoActive() then
		-- ★ 撤退也算"还在战斗" ★
		-- 撤退时 target 会被清掉 —— 只看 target 的话流程会以为这站打完了，
		-- 于是开始巡检甚至推进下一站（你反馈的）。
		-- 而且撤退期间本来也不该去传送开箱子（会和撤退抢位置）。
		Chest.autoStep(target ~= nil or retreating)
		noTargetSince = os.clock()     -- 别让"回位"把流程打断
	end

	-- 目标没了 / 死了 → 换目标
	if target and (not target.Parent or not targetPart or not targetPart.Parent) then
		target, targetPart = nil, nil
	end
	if target then
		local hum = target:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then target, targetPart = nil, nil end
	end

	-- ★ 锁定最近的怪 ★
	-- 目标还活着的时候也要看一眼：旁边有更近的，就换过去。
	-- 只在"更近超过 nearestSwitchMargin"时才换 —— 否则两只距离相近的怪
	-- 会让你在它们之间来回切，反而两边都打不死。
	if target then
		local r0 = PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart")
		local m, p, d = pickFromCache()
		if r0 and m and m ~= target and d then
			local curD = (targetPart.Position - r0.Position).Magnitude
			if curD - d > (CONFIG.nearestSwitchMargin or 20) then
				log(string.format("更近的怪：%s（%.0f → %.0f studs）", m.Name, curD, d))
				target, targetPart = m, p
				retargets = retargets + 1
				switchAt = os.clock() + CONFIG.switchDelay
			end
		end
	end

	if not target then
		-- 只在缓存里挑，不在这里补刷 ——
		-- 补刷会让"一只怪都没有"的时候每帧都遍历一遍 workspace，
		-- 性能问题原样回来。刷新由上面那个定时检查负责。
		local m, p, d = pickFromCache()
		if m then
			target, targetPart = m, p
			retargets = retargets + 1
			switchAt = os.clock() + CONFIG.switchDelay
			noTargetSince, returnedHome = nil, false   -- 又有怪了，重置回位状态
			log(string.format("目标 → %s（%.0f studs）", m.Name, d or 0))
		else
			strafeRelease()   -- 没目标就别乱跑
			-- ★ 没怪了 → 去开箱子 / 拿钥匙（副本模式的核心协调）★
			-- 有怪先打怪，怪清完了才做这些 —— 它们都要控制角色位置，
			-- 同时跑会互相抢传送。这里天然串行。
			--
			-- 自动流程【不在这里跑】——
			-- 它必须能在【有怪的时候】也启动，否则站在入口（周围有怪）时
			-- 农场会一直打怪、永远走不到这一行，整个流程就永远不启动。
			-- 这正是你反馈的"没有传送到大门"。
			-- 它现在在 Heartbeat 靠前的位置被调用（见下面 onHeartbeat 那段替换）。
			if Chest.isEnabled() or Chest.status().autoKey then
				local act = Chest.step()
				if act == "restart" then
					print("[Chest] 巡回一圈结束，重新开始")
				end
				-- ★ 副本那边有事在做 → 把"闲了多久"重置 ★
				-- 这样上面的"打完怪回到开启位置"就不会启动。
				-- 不这么做的话，回位会把正在赶过去的角色拽回来，
				-- 巡回又把他拉过去 —— 两边互相抢传送（日志里那个
				-- "→ KeyDoor(283) → KeyDoor(297) → KeyDoor(69)" 就是它）。
				if act ~= "off" and act ~= "none" then
					noTargetSince = os.clock()
				end
			end
			-- ★ 怪清完了 → 回到"开启自动刷怪时"站的位置 ★
			-- 开了脚本之后会被传送追怪追得到处跑，打完应该回原位，
			-- 否则你会停在一个随机的怪点，下次开还得重新跑过去。
			if CONFIG.returnHome and not (Chest and Chest.flowEngaged and Chest.flowEngaged())
				and homePos and not returnedHome then
				local now3 = os.clock()
				if not noTargetSince then noTargetSince = now3 end
				local r2 = PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart")
				local far = r2 and (r2.Position - homePos).Magnitude > (CONFIG.returnHomeRange or 40)
				if r2 and far and now3 - noTargetSince >= (CONFIG.returnHomeDelay or 3) then
					applyPos(r2, homePos)
					if CONFIG.pinAfterTp > 0 then pinPos(homePos, CONFIG.pinAfterTp) end
					hoverY = homePos.Y
					hoverUntil = now3 + (CONFIG.hoverAfterTp or 0)
					returnedHome = true
					print(string.format("[Farm] 怪清完了，回到开启自动刷怪的位置（%.0f, %.0f, %.0f）",
						homePos.X, homePos.Y, homePos.Z))
				end
			end
		end
		return
	end

	local root = PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local dist = (targetPart.Position - root.Position).Magnitude

	-- 距离管理：目标是和怪保持 combatDistance（你的武器是远程剑气，贴脸只会白挨打）。
	-- 太近（怪贴上来了）或太远（脱手了）都重新站位；有容差 + 冷却，不会来回抖。
	--
	-- ★ 撤退期间必须跳过这段 ★
	-- 否则它会把刚撤出去的你拽回怪身边，撤退就完全白做了。
	local want = CONFIG.combatDistance or 0
	if retreating then
		-- 撤退中：不管距离，位置由上面的撤退逻辑负责
	elseif want > 0 and math.abs(dist - want) > CONFIG.repositionTolerance then
		if reposition(target, targetPart) then
			strafeRelease()       -- 要位移了，先把走位键松开
			switchAt = os.clock() + CONFIG.switchDelay
			return
		end
		-- 冷却中就先继续打，别站着干等
	elseif want <= 0 and dist > CONFIG.range then
		-- 兜底路径（combatDistance 关掉时）
		strafeRelease()
		if goToMob(target, targetPart, dist) then
			switchAt = os.clock() + CONFIG.switchDelay
		end
		return
	end

	-- 换目标后先等一下，别一过去就狂点
	if os.clock() < switchAt then return end

	if CONFIG.autoAim then aimAt(targetPart) end
	if Chest and Chest.autoActive and Chest.autoActive() then Chest.noteMobs() end

	local now = os.clock()

	-- 走位换向
	local useKeyStrafe = CONFIG.strafe and (CONFIG.strafeMode == "key")
	if CONFIG.strafe and now >= strafeSwitchAt then
		strafeSwitchAt = now + jitter(CONFIG.strafeSwitchEvery)
		strafeSign = -strafeSign                     -- cframe / move 用这个换向
		if useKeyStrafe then
			local next_ = (strafeDir == Enum.KeyCode.A) and Enum.KeyCode.D or Enum.KeyCode.A
			strafeRelease()
			strafeDir = next_
			strafeHold(strafeDir)
		end
	end

	-- 位置 + 朝向。
	-- 朝向【每种模式都要做】—— 剑气朝角色前方飞，不对准怪就是白放。
	--
	-- 撤退时：位置由上面的撤退逻辑控制，这里【只补朝向】——
	-- 边飞边把剑气对着怪打过去。allowMove 传 false 就不会横移去抢位置。
	combatPose(dt, root, PLR.Character:FindFirstChildOfClass("Humanoid"),
		(not useKeyStrafe) and (not retreating))

	-- 平A连点。
	-- 间隔用抖动而不是固定值：完美周期既容易被看出是脚本，
	-- 也容易和游戏的攻击节奏错拍（固定 0.05 打 0.05 冷却时会周期性漏拍）。
	-- castLockedUntil：刚放完技能时先别点，免得把技能动作取消掉。
	if CONFIG.autoClick and now >= castLockedUntil
		and now - lastClick >= (clickGap or CONFIG.clickInterval) then
		lastClick = now
		clickGap = jitter(CONFIG.clickInterval)
		local ok, err = clickOnce()
		if ok then
			clicks = clicks + 1
		elseif not warnedOnce.click then
			warnedOnce.click = true
			warn("[Farm] 左键模拟失败：" .. tostring(err))
		end
	end

	if CONFIG.autoSkill and not skillDisabledForHp
		and not (retreating and not CONFIG.retreatUseSkills) then
		local rot = rotationFor()
		if #rot > 0 then
			-- 每个技能各自计时：一帧最多放一个，谁到点放谁。
			-- 一帧只放一个是有意的 —— 几个技能全挤在同一帧没有意义，
			-- 而且会互相覆盖后摇。
			for i, s in ipairs(rot) do
				if now >= (skillNext[i] or 0) then
					-- 间隔 = 冷却 × 整体系数 × 自动放大系数，再加缓冲。
					-- 【只能往后推】：提前按 = 扣最大生命强放（你这把武器的特性）。
					local gap = (s.interval * (CONFIG.skillScale or 1) * skillPenalty)
						+ (CONFIG.skillBuffer or 0)
					skillNext[i] = now + jitterUp(gap)
					-- 放完技能先别点平A，免得把技能动作取消掉
					castLockedUntil = now + (CONFIG.skillCastLockout or 0)
					local ok, err = pressKey(s.key)
					if CONFIG.debug then
						print(string.format("[Farm] 放技能 %s（下次 %.1fs 后）%s",
							s.key.Name, s.interval, ok and "" or "  ← 发出去了但没生效"))
					end
					if not ok and not warnedOnce.key then
						warnedOnce.key = true
						warn("[Farm] 技能模拟失败：" .. tostring(err))
					end
					-- 只在真的发成功时计数 —— 否则"技能数"会骗人
					if ok then skillFired = skillFired + 1 end
					break
				end
			end
		elseif #CONFIG.skillKeys > 0 and now - lastSkill >= CONFIG.skillInterval then
			-- 老写法：所有技能共用一个间隔
			lastSkill = now
			for _, k in ipairs(CONFIG.skillKeys) do
				local ok, err = pressKey(k)
				if not ok and not warnedOnce.key then
					warnedOnce.key = true
					warn("[Farm] 技能模拟失败：" .. tostring(err))
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- HUD 刷新
--------------------------------------------------------------------------------
local renderAcc = 0
local function onRender(dt)
	renderAcc = renderAcc + (dt or 0)
	if renderAcc < 0.2 then return end
	renderAcc = 0

	-- 每次周期性刷新时也刷一遍标签（流程进度、开关状态）
	-- 原来只在按键/点按钮时刷 —— 于是流程走过去了，面板还停在旧文字上。
	if refresh then refresh() end

	if not ui.status then return end
	local root = PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart")
	local hum = PLR.Character and PLR.Character:FindFirstChildOfClass("Humanoid")
	local dist = (target and targetPart and targetPart.Parent and root)
		and (targetPart.Position - root.Position).Magnitude or nil

	local hp = (hum and hum.MaxHealth and hum.MaxHealth > 0)
		and string.format("%d%%", math.floor(hum.Health / hum.MaxHealth * 100)) or "-"
	-- 最大生命要显示出来：武器特性会在 CD 中强放时扣它，
	-- 掉没掉必须一眼看得见，否则你在悄悄亏属性却不知道。
	local maxTxt = hum and hum.MaxHealth and string.format("%.0f", hum.MaxHealth) or "-"

	ui.status.Text = string.format("%s   HP %s  上限 %s%s\n目标 %s  距离 %s\n点击 %d  换目标 %d",
		retreating and "撤退中" or (running and "运行中" or "已停止"),
		hp, maxTxt,
		skillDisabledForHp and " 技能已停" or "",
		target and target.Name or "无",
		dist and string.format("%.0f", dist) or "-",
		clicks, retargets)
	refresh()
end

--------------------------------------------------------------------------------
-- 开关 / 卸载
--------------------------------------------------------------------------------
local function setRunning(on)
	running = on
	if on then
		startAt = os.clock()
		-- ★ 记住"开启自动刷怪时"站的位置 ★
		-- 开了之后会被传送追怪追得到处跑，怪清完要回得来。
		local r0 = PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart")
		homePos = r0 and r0.Position or nil
		noTargetSince, returnedHome = nil, false
		-- 让 rotationFor 在下一拍重新按当前武器建表并重排计时器
		curRotationKey = nil
		skillNext, skillFired = {}, 0
		-- 重新开始时就立刻再试一次装备 —— 否则之前的退避会让它干等 15 秒
		equipTries = 0
		lastEquipAt = -math.huge
		slotEquippedName = nil
		probeSlot, probeBeforeName = false, nil
		-- 喝药计时也重置：重新开就是重新开始，别被上一轮的 30 秒冷却压着
		nextPotion = 0
		potionsUsed = 0
		-- 止损状态重置。
		-- ★ 注意【不要】重置 baseMaxHp / lastMaxHp ★
		-- baseMaxHp 是"见过的最大生命"，重置等于把已经永久损失掉的血量忘掉，
		-- 止损地板就再也保护不到了。lastMaxHp 也要留着，否则
		-- "停止期间被扣了最大生命"这件事就检测不到。
		skillDisabledForHp = false
		log("自动刷怪已开启")
	else
		target, targetPart = nil, nil
		retreating, retreatPos = false, nil
		strafeRelease()          -- 必须松开，否则角色会一直朝一个方向跑
		log("自动刷怪已停止")
	end
	refresh()
end

-- 回填：让副本流程能自己开关"自动刷怪"
chestStartFarm = function() if not running then setRunning(true) end end
chestStopFarm = function() if running then setRunning(false) end end

local function unload()
	running = false
	strafeRelease()              -- 卸载前一定松开走位键
	disconnectAll()
	if ui.gui then pcall(function() ui.gui:Destroy() end) end
	ui = {}
	pcall(function()
		if getgenv then getgenv().AutoFarm = nil end
	end)
	print("[Farm] 已卸载，角色恢复正常。")
end

--------------------------------------------------------------------------------
-- 接线
--------------------------------------------------------------------------------
local function wire()
	ui.tgFarm.MouseButton1Click:Connect(function() setRunning(not running) end)
	ui.tgTp.MouseButton1Click:Connect(function()
		CONFIG.autoTeleport = not CONFIG.autoTeleport
		refresh()
	end)
	ui.tgAim.MouseButton1Click:Connect(function()
		CONFIG.autoAim = not CONFIG.autoAim
		refresh()
	end)
	ui.tgChest.MouseButton1Click:Connect(function()
		Chest.setEnabled(not Chest.isEnabled())
		if Chest.isEnabled() then Chest.reset() end
		refresh()
	end)
	ui.tgOnlyTerror.MouseButton1Click:Connect(function()
		Chest.setOnlyTerror(not Chest.status().onlyTerror)
		refresh()
	end)
	ui.tgQuestion.MouseButton1Click:Connect(function()
		Chest.setOpenQuestion(not Chest.status().openQuestion)
		refresh()
	end)
	ui.tgKey.MouseButton1Click:Connect(function()
		Chest.setAutoKey(not Chest.status().autoKey)
		refresh()
	end)
	ui.actSpawn.MouseButton1Click:Connect(function() Chest.goSpawn() end)
	ui.actTrigger.MouseButton1Click:Connect(function() Chest.triggerSpawns() end)
	ui.actAuto.MouseButton1Click:Connect(function()
		if Chest.autoActive() then Chest.stopAuto() else Chest.startAuto() end
	end)
	ui.actKeyDoor.MouseButton1Click:Connect(function() Chest.goKeyDoor() end)
	ui.actSavePos.MouseButton1Click:Connect(function() Chest.saveCustomPos() end)
	ui.actGoPos.MouseButton1Click:Connect(function() Chest.goCustomPos() end)
	ui.actNext.MouseButton1Click:Connect(function()
		target, targetPart = nil, nil
		log("手动换目标")
	end)
	ui.actUn.MouseButton1Click:Connect(function() unload() end)
end

--------------------------------------------------------------------------------
-- 启动
--------------------------------------------------------------------------------
if not buildHud() then
	warn("[Farm] PlayerGui 不可用，无法创建界面。")
	return
end

print("[Farm] 执行器能力检查：")
print(string.format("[Farm]   mouse1click        : %s", CAP.click and "有" or "没有"))
print(string.format("[Farm]   mouse1press/release: %s", CAP.press and "有" or "没有"))
print(string.format("[Farm]   keypress/keyrelease: %s", CAP.key and "有" or "没有"))
if not (CAP.click or CAP.press) then
	warn("[Farm] 不能模拟鼠标左键 —— 攻击打不出去，脚本只能帮你贴脸和瞄准。")
end
if not CAP.key then
	warn("[Farm] 不能模拟按键 —— 技能放不出来。")
end

track(UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == CONFIG.keyToggle then
		setRunning(not running)
	elseif input.KeyCode == CONFIG.keyChest then
		Chest.setEnabled(not Chest.isEnabled())
		if Chest.isEnabled() then Chest.reset() end
		print(string.format("[Chest] 自动开箱 %s", Chest.isEnabled() and "开" or "关"))
		refresh()
	elseif input.KeyCode == CONFIG.keySpawn then
		Chest.goSpawn()
	elseif input.KeyCode == CONFIG.keyRecordWp then
		Chest.recordCurrentWaypoint()
	elseif input.KeyCode == CONFIG.keyAuto then
		if Chest.autoActive() then Chest.stopAuto() else Chest.startAuto() end
	elseif input.KeyCode == CONFIG.keyTrigger then
		Chest.triggerSpawns()
	elseif input.KeyCode == CONFIG.keyDoor then
		Chest.goKeyDoor()
	elseif input.KeyCode == CONFIG.keySavePos then
		Chest.saveCustomPos()
	elseif input.KeyCode == CONFIG.keyGoPos then
		Chest.goCustomPos()
	elseif input.KeyCode == CONFIG.keyUnload then
		unload()
	end
end))

track(RunService.Heartbeat:Connect(onHeartbeat))
track(RunService.RenderStepped:Connect(onRender))

wire()

if getgenv then
	getgenv().AutoFarm = {
		start = function() setRunning(true) end,
		stop  = function() setRunning(false) end,
		toggle = function() setRunning(not running) end,
		next  = function() target, targetPart = nil, nil end,
		state = function()
			local hum = PLR.Character and PLR.Character:FindFirstChildOfClass("Humanoid")
			local rp = PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart")
			return { running = running, target = target and target.Name or nil,
			         targetPos = (targetPart and targetPart.Parent) and targetPart.Position or nil,
			         rootPos = rp and rp.Position or nil,
			         clicks = clicks, retargets = retargets, skillFired = skillFired,
			         retreating = retreating,
			         retreatPos = retreatPos,
			         potionsUsed = potionsUsed,
			         nextPotion = nextPotion,
			         skillDisabledForHp = skillDisabledForHp,
			         baseMaxHp = baseMaxHp,
			         skillPenalty = skillPenalty,
			         equipTries = equipTries,
			         equipped = (PLR.Character and PLR.Character:FindFirstChildWhichIsA("Tool"))
			                    and PLR.Character:FindFirstChildWhichIsA("Tool").Name or nil,
			         hp = hum and hum.Health or nil,
			         maxHp = hum and hum.MaxHealth or nil }
		end,
		config = CONFIG,
		chest = Chest,
		-- 暴露 ui / refresh：方便看面板文字，测试也靠它验"面板有没有跟着流程更新"
		ui = ui, refresh = refresh,
		unload = unload,
	}
end

print("[Farm] 已加载 | Insert 开关 | End 卸载 | K 自动开箱 | 面板可拖动、点标题折叠")
print("[Chest] 副本模式：先打怪，怪清完了自动去开箱子（需要箱子符合 CONFIG 里的关键词）")
print("[Farm] ★ 版本 v33 | 换服自动重跑(填 reinjectUrl) + autoStart | 8站 ★")
-- ★ 注入后自动开始副本流程 ★
-- 配合 Xeno 的"自动执行"：注进来就自己跑，不用按 Y。
if Chest and Chest.autoStartSoon then Chest.autoStartSoon() end
-- ★ 排队"换服后自动重跑" ★
-- 重启地牢会换服务器，脚本会被卸载；填了 reinjectUrl 就能自己回来。
do
	local url = (Chest and Chest.config and Chest.config.reinjectUrl) or ""
	if url ~= "" then
		if queue_on_teleport then
			pcall(function()
				queue_on_teleport(string.format("loadstring(game:HttpGet(%q))()", url))
			end)
			print("[Farm] 已排队：换服后自动重新执行（" .. url .. "）")
		else
			warn("[Farm] 这个执行器没有 queue_on_teleport —— 换服后脚本不会自己回来。")
		end
	end
end
print("[Farm] 目标识别：所有带 Humanoid 的 Model 都算怪。想只打特定名字，改 CONFIG.mobMatch。")
print("[Farm] 技能键：按武器分别配在 CONFIG.skillRotationByWeapon（默认表是 E/R/F）。")

refresh()
