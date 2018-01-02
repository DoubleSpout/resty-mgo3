local mgo3 = require("resty.mgo3")
local cjson = require("cjson")

local conf = {
		isReplicSet = false,
		addr = {
			{'127.0.0.1', 27017},
		},
		database = "admin",
		user = "root",
		passwd = "123456" ,
		poolSize = 1000,
}	-- mongodb conf




local mgoConn = mgo3:new(conf)
local db = mgoConn:new_db_handle("test")
local data, err = mgoConn:getCollection('test'):find(
        {}, {}, nil, {
			SlaveOk=true,
		})

if err then
    ngx.say(string.format('%s',err))
else
    for i, v in ipairs(data) do
        ngx.say(string.format('%s_%s',i, v['_id']))
    end
    ngx.say(type(data))
end