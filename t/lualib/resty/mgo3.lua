local mongo = require("resty.mongol")
local object_id = require("resty.mongol.object_id")
local cjson = require("cjson")
local _M = {
	_VERSION = "0.0.1"
}

local metatable = { __index = _M }

-- 创建objectId
_M.ObjectId = function(str)
	local buf = (str:gsub('..', function (cc)
		return string.char(tonumber(cc, 16))
		end))
	return object_id.new(buf)
end
--[[
    @desc
        Creates a MongoClient instance. 
    @params
        opts    		@type 	table
    @return
		table 			@type 	table 	A MongoClient instance
 ]]
function _M.new(self, opts)
    opts = opts or {}

    local timeout 	= opts.timeout or 3000
	local passwd    = opts.passwd or ""
	local user    =  opts.user or ""
    local database  = opts.database or "admin"
    local keepalive = (opts.keepalive and opts.keepalive * 1000) or 60000
    local poolSize  = opts.poolSize or 1000

	local host, port, addr

	-- 如果是副本集
	if opts.isReplicSet then
		if type(opts.addr) ~= "table" or table.getn(opts.addr) == 0 then
			error("mongodb replic set need set addr info", 2)
		end
		addr = opts.addr
	elseif type(opts.addr) == "table" and type(opts.addr[1]) == "table" then	-- 非副本集
		host = opts.addr[1][1] or "localhost"
     	port = opts.addr[1][2] or 27017
	end
  
    return setmetatable({
            timeout  	= timeout,
            host 	 	= host or "localhost",
	    	port	 	= tostring(port or 27017),
	    	user 	 	= user,
	    	passwd 		= passwd,
	    	database 	= database,
	    	keepalive 	= keepalive,
	    	poolSize 	= poolSize,
			isReplicSet = opts.isReplicSet or false,
			addr		= addr or {},
			addrLen 	= table.getn(addr or {}),
	    	_db			= database,
	    	_user		= user,
	    	_passwd 	= passwd,
			_sort       = {},
			_limit      = 100,
			_skip       = 0,
			}, metatable)
end



local chooseCount = 0
local function ChooseOneServer(serverLength)
	local pos = (chooseCount % serverLength) + 1
	chooseCount = chooseCount + 1
	return pos
end





--[[
    @desc
        get mongodb's connection objects. 
 ]]
local function getMgoConn(mgoConfig, isWrite)

	-- 获取连接对象
	local mgoConn = mongo:new()
	if not mgoConn then
		return nil, "get mongo connection occur error"
	end
	
	-- 设置链接超时
	mgoConn:set_timeout(mgoConfig.timeout)
	
	-- 非副本集，直接连接
	if not mgoConfig.isReplicSet then
		--获取连接客户端
		local ok, err =mgoConn:connect(mgoConfig.host, mgoConfig.port)
		if not ok then 
			return nil, err
		end 
		return mgoConn, nil
	end

	
	-- 获取地址数组长度
	local addrLen = mgoConfig.addrLen
	-- 防止一台挂掉出错
	for i = 1, addrLen, 1 do
		-- 副本集连接
		local pos = ChooseOneServer(addrLen)
		
		if type(mgoConfig.addr[pos]) ~= "table" or type(mgoConfig.addr[pos][1]) ~= "string" or type(mgoConfig.addr[pos][2]) ~= "number" then
			error("invalid mongodb replicset addr postion ".. tostring(pos), 2)	-- 地址配置错误
		end

		local host = mgoConfig.addr[pos][1]
		local port = mgoConfig.addr[pos][2]
		-- 
		local ok, err = mgoConn:connect(host, port)
		if ok and not err then	--当没有错误继续，有错误就循环
			if not isWrite then	--非写操作，直接返回mongodb连接即可
				return mgoConn, nil
			end
			-- 如果是写操作，那么要判断当前连接是不是写
			local isMaster, hosts = mgoConn:ismaster()

			-- ngx.log(ngx.ERR, "=====", host, port, isMaster)
			
			if isMaster then
				return mgoConn, nil
			end
			-- 如果不是master
			local newConn, err = mgoConn:getprimary()	--获取主节点的链接
			if err then	--获取出错
				return nil, err
			end

			-- 这里无需把旧的获取的链接放回连接池
			-- 返回新的写的连接
			return newConn, nil

		else
			--出错记录日志，for循环继续
			tools.saveFrameworkLog(string.format("getMgoConn | conn mongodb host[%s:%s] error %s", host, port, err))
		end

	end
	
	return nil, "all replicset addr is invalid"

end

--[[
    @desc
        pack connection commands. 
 ]]
local function backConnCmd(self, mgoConn, cmd, ... )	
	local result, err = mgoConn[cmd](mgoConn, ... )

	mgoConn:set_keepalive(self.keepalive, self.poolSize)
	
	return result, err
end

--[[
    @desc
        this is a map of mongol.conn's command. 
 ]]
local connCmd = {
    isMaster 		= "ismaster",
    getPrimary 		= "getprimary",
    getReusedTime 	= "get_reused_times",
    dbs 			= "databases",		   
}
for k,v in pairs(connCmd) do
	
    _M[k] =
            function (self, ...)
	           	--获取连接客户端
				local mgoConn, err = getMgoConn(self)
				if not mgoConn then 
				    return nil, err
				end 
                return backConnCmd(self, mgoConn, v, ...)
            end
end


--[[
    @desc
        switch db by dbName and auth your id 
    @params

    @return
		Returns a database object, or nil.
 ]]
function _M.useDatabase(self, dbName, user, passwd)
   	--获取连接客户端
   	self._db = dbName
   	self._user = user or self._user
   	self._passwd = passwd or self._psswd
   	return string.format("%s %s","current database is", dbName)
end

function _M.ping( self )
   	--获取连接客户端
	local mgoConn, err = getMgoConn(self)
	if not mgoConn then 
	    return nil, err
	end	
		
	local db = mgoConn:new_db_handle(self._db)
	if not db then
		return nil, "get database occur error"
	end

	--用户授权
	local count, err = mgoConn:get_reused_times()

	if (count == 0) or err then
		if self._user and self._passwd and self._user ~= "" and self._passwd ~= "" then
			local ok, err = db:auth_scram_sha1(self._user, self._passwd)
			if not ok then 
			    return nil, err
			end 
		end
	end
	return "ok", nil
end

--[[
    @desc
        switch db by self.dbName and auth your id 
    @params
        dbName    		@type 	table 	@default	self.database
		user 			@type 	string 	@default	self.user
		passwd 			@type 	string  @default 	self.passwd
    @return
		Returns a database object, or nil.
 ]]
local function getDB(self, isWrite)
   	--获取连接客户端
	local mgoConn, err = getMgoConn(self, isWrite)
	if not mgoConn then 
	    return nil, nil, err
	end	

	local db = mgoConn:new_db_handle(self._db)
	if not db then
		return nil, nil, "get database occur error"
	end

	--用户授权
	local count, err = mgoConn:get_reused_times()

	
	if (count == 0) or err then
		if self._user and self._passwd and self._user ~= "" and self._passwd ~= "" then
			local ok, err = db:auth_scram_sha1(self._user, self._passwd)
			if not ok then 
			    return nil, nil, err
			end 
		end
	end
	return db, mgoConn, nil
end

local dbCmd = {
    addUser 		= "add_user",
    -- getColl 		= "get_col",
    -- getGrid 	    = "get_grid", 
    dropDatabase 	= "dropDatabase", 
}

--[[
    @desc
        pack database commands. 
 ]]
local function backDBCmd(self, db, mgoConn, cmd, ... )	
	local result, err = db[cmd](db, ... )

	mgoConn:set_keepalive(self.keepalive, self.poolSize)
	
	return result, err
end

for k,v in pairs(dbCmd) do
	
    _M[k] =
            function (self, ...)
	           	--获取连接客户端
			    local db, mgoConn, err = getDB(self, true)
			    if not db then
			    	return nil, "get current database occur error " .. err
			    end
			    return backDBCmd(self, db, mgoConn, v, ...)
            end
end

function _M.list( self )
   	--获取连接客户端
    local db, mgoConn, err = getDB(self)
    if not db then
    	return nil, "get current database occur error " .. err
    end
    -- return packDBCmd(self, db, mgoConn, v, ...)
    local cursor, err = db:listcollections()
	if not cursor then
		return nil, string.format("%s %s %s", "system.namespaces", "find occur error", err)
	end
	local results = {}
	for index, item in cursor:pairs() do
		table.insert(results, item)
	end
	
	mgoConn:set_keepalive(self.keepalive, self.poolSize)
	
	return result, err
end

function _M.getCollection( self, collName )
	self.collName = collName
	return self
end

local collCmd = {
    count 	= "count",
    drop 	= "drop",
    update 	= "update",	
    insert  = "insert",  
    delete 	= "delete", 
}

--[[
    @desc
        pack collection's commands. 
 ]]
local function backCollCmd(self, db, mgoConn, cmd, ... )	
	--获取集合
	local coll = db:get_col(self.collName)
	if not coll then
		return nil, "get collection occur error"
	end

	local result, err = coll[cmd](coll, ... )

	mgoConn:set_keepalive(self.keepalive, self.poolSize)
	
	return result, err
end

for k,v in pairs(collCmd) do
	
    _M[k] =
            function (self, ...)
	           	--获取连接客户端
			    local db, mgoConn, err = getDB(self, true)
			    if not db then
			    	return nil, "get current database occur error " .. err
			    end
			    return backCollCmd(self, db, mgoConn, v, ...)
            end
end

function _M.sort( self, fields )
	self._sort = fields
	return self
end

function _M.limit( self, num )
	self._limit = num 
	return self
end

function _M.skip( self, num )
	self._skip = num
	return self
end

function _M.find( self, ... )
   	--获取连接客户端
    local db, mgoConn, err = getDB(self)
    if not db then
    	return nil, "get current database occur error " .. err
    end
    --获取集合
	local coll, err = db:get_col(self.collName)
	
	if not coll then
		return nil, "get collection occur error"
	end

	local cursor, err = coll["find"](coll, ... )
	if not cursor then
		return nil, string.format("%s %s %s", self.collName, "find occur error", err)
	end

	cursor:limit(self._limit)
	cursor:skip(self._skip)
	cursor = cursor:sort(self._sort)
	local results = {}
	for index, item in cursor:pairs() do
		table.insert(results, item)
	end
	mgoConn:set_keepalive(self.keepalive, self.poolSize)
	return results, err	
end

return _M