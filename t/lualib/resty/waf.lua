local _M = {}

_M.version = "0.8.2"

local actions       = require "resty.waf.actions"
local calc          = require "resty.waf.rule_calc"
local collections_t = require "resty.waf.collections"
local logger        = require "resty.waf.log"
local operators     = require "resty.waf.operators"
local options       = require "resty.waf.options"
local opts          = require "resty.waf.opts"
local phase_t       = require "resty.waf.phase"
local random        = require "resty.waf.random"
local storage       = require "resty.waf.storage"
local transform_t   = require "resty.waf.transform"
local util          = require "resty.waf.util"

local table_sort   = table.sort
local string_lower = string.lower

local mt = { __index = _M }

-- default list of rulesets
local _global_rulesets = {
	"11000_whitelist",
	"20000_http_violation",
	"21000_http_anomaly",
	"35000_user_agent",
	"40000_generic_attack",
	"41000_sqli",
	"42000_xss",
	"90000_custom",
	"99000_scoring"
}

-- ruleset table cache
local _ruleset_defs = {}

-- default options
-- local _M.default_opts = util.table_copy(opts.defaults)

-- get a subset or superset of request data collection
local function _parse_collection(self, collection, parse)
	if (type(collection) ~= "table" and parse) then
		-- if a collection isn't a table it can't be parsed,
		-- so we shouldn't return the original collection as
		-- it may have an illegal operator called on it
		return nil
	end

	if (type(collection) ~= "table" or not parse) then
		-- this collection isnt parseable but it's not unsafe to use
		return collection
	end

	-- get the next (first)(only) k/v pair in the parse table
	local key, value = next(parse)

	return util.parse_collection[key](self, collection, value)
end

-- buffer a single log event into the per-request ctx table
-- all event logs will be written out at the completion of the transaction if either:
-- 1. the transaction was altered (e.g. a rule matched with an ACCEPT or DENY action), or
-- 2. the event_log_altered_only option is unset
local function _log_event(self, rule, value, ctx)
	local t = {
		id    = rule.id,
		match = value
	}

	if (self._event_log_verbosity > 1) then
		t.msg = util.parse_dynamic_value(self, rule.msg, ctx.collections)
	end

	if (self._event_log_verbosity > 2) then
		t.opts   = rule.opts
		t.action = rule.actions.disrupt
	end

	if (self._event_log_verbosity > 3) then
		t.var = rule.var
	end

	if (rule.logdata) then
		t.logdata = util.parse_dynamic_value(self, rule.logdata, ctx.collections)
	end

	ctx.log_entries_n = ctx.log_entries_n + 1
	ctx.log_entries[ctx.log_entries_n] = t
end

-- restore options from a previous phase
local function _load(self, opts)
	for k, v in pairs(opts) do
		self[k] = v
	end
end

-- save options to the ctx table to be used in another phase
local function _save(self, ctx)
	local opts = {}

	for k, v in pairs(self) do
		opts[k] = v
	end

	ctx.opts = opts
end

local function _transaction_id_header(self, ctx)
	-- upstream request header
	if (self._req_tid_header) then
		ngx.req.set_header("X-Lua-Resty-WAF-ID", self.transaction_id)
	end

	-- downstream response header
	if (self._res_tid_header) then
		ngx.header["X-Lua-Resty-WAF-ID"] = self.transaction_id
	end

	ctx.t_header_set = true
end

-- cleanup
local function _finalize(self, ctx)
	-- set X-Lua-Resty-WAF-ID headers as appropriate
	if (not ctx.t_header_set) then
		_transaction_id_header(self, ctx)
	end

	-- save our options for the next phase
	_save(self, ctx)

	-- persistent variable storage
	storage.persist(self, ctx.storage)

	-- store the local copy of the ctx table
	ngx.ctx = ctx
end

-- use the lookup table to figure out what to do
local function _rule_action(self, action, ctx, collections)
	if (not action) then
		return
	end

	if (util.table_has_key(action, actions.alter_actions)) then
		ctx.altered[ctx.phase] = true
		_finalize(self, ctx)
	end

	if (self._hook_actions[action]) then
		self._hook_actions[action](self, ctx)
	else
		actions.disruptive_lookup[action](self, ctx)
	end
end

-- transform collection values based on rule opts
local function _do_transform(self, collection, transform)
	local t = {}

	if (type(transform) == "table") then
		t = collection

		for k, v in ipairs(transform) do
			t = _do_transform(self, t, transform[k])
		end
	else
		-- if the collection is a table, loop through it and add the values to the tmp table
		-- otherwise, this returns directly to _process_rule or a recursed call from multiple transforms
		if (type(collection) == "table") then
			for k, v in pairs(collection) do
				t[k] = _do_transform(self, collection[k], transform)
			end
		else
			if (not collection) then
				return collection -- dont transform if the collection was nil, i.e. a specific arg key dne
			end

			logger.log(self, "doing transform of type " .. transform .. " on collection value " .. tostring(collection))
			return transform_t.lookup[transform](self, collection)
		end
	end

	return t
end

-- process an individual rule
local function _process_rule(self, rule, collections, ctx)
	local id       = rule.id
	local vars     = rule.vars
	local opts     = rule.opts or {}
	local pattern  = rule.pattern
	local operator = rule.operator
	local offset

	ctx.id = id

	ctx.rule_status = nil

	for k, v in ipairs(vars) do
		local collection, var
		var = vars[k]

		if (var.unconditional) then
			collection = true
		else
			local collection_key = var.collection_key

			logger.log(self, "Checking for collection_key " .. collection_key)

			if (not var.storage and not ctx.transform_key[collection_key]) then
				logger.log(self, "Collection cache miss")
				collection = _parse_collection(self, collections[var.type], var.parse)

				if (opts.transform) then
					collection = _do_transform(self, collection, opts.transform)
				end

				ctx.transform[collection_key]     = collection
				ctx.transform_key[collection_key] = true
			elseif (var.storage) then
				logger.log(self, "Forcing cache miss")
				collection = _parse_collection(self, collections[var.type], var.parse)
			else
				logger.log(self, "Collection cache hit!")
				collection = ctx.transform[collection_key]
			end

			if (var.length) then
				if (type(collection) == 'table') then
					collection = #collection
				elseif(collection) then
					collection = 1
				else
					collection = 0
				end
			end
		end

		if (not collection) then
			logger.log(self, "No values for this collection")
			offset = rule.offset_nomatch
		else
			if (opts.parsepattern) then
				logger.log(self, "Parsing dynamic pattern: " .. pattern)
				pattern = util.parse_dynamic_value(self, pattern, collections)
			end

			local match, value

			if (var.unconditional) then
				match = true
				value = 1
			else
				match, value = operators.lookup[operator](self, collection, pattern, ctx)
			end

			if (rule.op_negated) then
				match = not match
			end

			if (match) then
				logger.log(self, "Match of rule " .. id)

				-- store this match as the most recent match
				collections.MATCHED_VAR      = value
				collections.MATCHED_VAR_NAME = var

				-- also add the match to our list of matches for the transaction
				if value then
					local match_n = ctx.match_n + 1
					collections.MATCHED_VARS[match_n] = value
					collections.MATCHED_VAR_NAMES[match_n] = var
					ctx.match_n = match_n
				end

				-- auto populate collection elements
				if (not rule.op_negated) then
					if (operator == "REGEX") then
						collections.TX["0"] = value[0]
						for i in ipairs(value) do
							collections.TX[tostring(i)] = value[i]
						end
					else
						collections.TX["0"] = value
					end
				end
				collections.RULE = rule

				local nondisrupt = rule.actions.nondisrupt or {}
				for _, action in ipairs(nondisrupt) do
					actions.nondisruptive_lookup[action.action](self, action.data, ctx, collections)
				end

				-- log the event
				if (rule.actions.disrupt ~= "CHAIN" and not opts.nolog) then
					_log_event(self, rule, value, ctx)
				end

				-- wrapper for the rules action
				_rule_action(self, rule.actions.disrupt, ctx, collections)

				offset = rule.offset_match

				break
			else
				offset = rule.offset_nomatch
			end
		end
	end

	logger.log(self, "Returning offset " .. tostring(offset))
	return offset
end

-- calculate rule jump offsets
local function _calculate_offset(ruleset)
	for phase, i in pairs(phase_t.phases) do
		if (ruleset[phase]) then
			calc.calculate(ruleset[phase])
		else
			ruleset[phase] = {}
		end
	end

	ruleset.initted = true
end

-- merge the default and any custom rules
local function _merge_rulesets(self)
	local default = _global_rulesets
	local added   = self._add_ruleset
	local added_s = self._add_ruleset_string
	local ignored = self._ignore_ruleset

	local t = {}

	for k, v in ipairs(default) do
		t[v] = true
	end

	for k, v in ipairs(added) do
		logger.log(self, "Adding ruleset " .. v)
		t[v] = true
	end

	for k, v in pairs(added_s) do
		logger.log(self, "Adding ruleset string " .. k)

		if (not _ruleset_defs[k]) then
			local rs, err = util.parse_ruleset(v)

			if (err) then
				logger.fatal_fail("Could not load " .. k)
			else
				logger.log(self, "Doing offset calculation of " .. k)
				_calculate_offset(rs)

				_ruleset_defs[k] = rs
			end
		end

		t[k] = true
	end

	for k, v in ipairs(ignored) do
		logger.log(self, "Ignoring ruleset " .. v)
		t[v] = nil
	end

	t = util.table_keys(t)

	-- rulesets will be processed in numeric order
	table_sort(t, function(a, b)
		return string_lower(a) < string_lower(b)
	end)

	self._active_rulesets = t
end

-- main entry point
function _M.exec(self)
	if (self._mode == "INACTIVE") then
		logger.log(self, "Operational mode is INACTIVE, not running")
		return
	end

	local phase = ngx.get_phase()

	if (not phase_t.is_valid_phase(phase)) then
		logger.fatal_fail("lua-resty-waf should not be run in phase " .. phase)
	end

	local ctx         = ngx.ctx
	local collections = ctx.collections or {}

	-- restore options from a previous phase
	if (ctx.opts) then
		_load(self, ctx.opts)
	end

	ctx.lrw_initted   = true
	ctx.altered       = ctx.altered or {}
	ctx.col_lookup    = ctx.col_lookup or {}
	ctx.log_entries   = ctx.log_entries or {}
	ctx.log_entries_n = ctx.log_entries_n or 0
	ctx.storage       = ctx.storage or {}
	ctx.transform     = ctx.transform or {}
	ctx.transform_key = ctx.transform_key or {}
	ctx.t_header_set  = ctx.t_header_set or false
	ctx.phase         = phase
	ctx.match_n       = ctx.match_n or 0
	ctx.nameservers   = self._nameservers

	-- pre-initialize the TX collection
	ctx.storage["TX"]    = ctx.storage["TX"] or {}
	ctx.col_lookup["TX"] = "TX"

	-- see https://groups.google.com/forum/#!topic/openresty-en/LVR9CjRT5-Y
	if (ctx.altered[phase]) then
		logger.log(self, "Transaction was already altered, not running!")
		return
	end

	-- populate the collections table
	collections_t.lookup[phase](self, collections, ctx)

	-- don't run through the rulesets if we're going to be here again
	-- (e.g. multiple chunks are going through body_filter)
	if ctx.short_circuit then return end

	-- store the collections table in ctx, which will get saved to ngx.ctx
	ctx.collections = collections

	-- build rulesets
	if (self.need_merge) then
		_merge_rulesets(self)
	end

	-- set up tracking tables and flags if we're using redis for persistent storage
	if (self._storage_backend == 'redis') then
		self._storage_redis_delkey_n = 0
		self._storage_redis_setkey_t = false
		self._storage_redis_delkey   = {}
		self._storage_redis_setkey   = {}
	end

	logger.log(self, "Beginning run of phase " .. phase)

	for _, ruleset in ipairs(self._active_rulesets) do
		logger.log(self, "Beginning ruleset " .. ruleset)

		local rs = _ruleset_defs[ruleset]

		if (not rs) then
			local err
			rs, err = util.load_ruleset_file(ruleset)

			if (err) then
				logger.fatal_fail(err)
			else
				logger.log(self, "Doing offset calculation of " .. ruleset)
				_calculate_offset(rs)

				_ruleset_defs[ruleset] = rs
			end
		end

		local offset = 1
		local rule   = rs[phase][offset]

		while rule do
			local id = rule.id

			if (not util.table_has_key(id, self._ignore_rule)) then
				logger.log(self, "Processing rule " .. id)

				local returned_offset = _process_rule(self, rule, collections, ctx)
				if (returned_offset) then
					offset = offset + returned_offset
				else
					offset = nil
				end
			else
				logger.log(self, "Ignoring rule " .. id)

				local rule_nomatch = rule.offset_nomatch

				if (rule_nomatch) then
					offset = offset + rule_nomatch
				else
					offset = nil
				end
			end

			if not offset then break end

			rule = rs[phase][offset]
		end
	end

	_finalize(self, ctx)
end

-- instantiate a new instance of the module
function _M.new(self)
	-- we need a separate copy of this table since we will
	-- potentially override values with set_option
	local t = util.table_copy(_M.default_opts)

	t.transaction_id = random.random_bytes(10)

	-- handle conditions where init() wasnt called
	-- and the default rulesets weren't merged
	if (not t._active_rulesets) then
		t.need_merge = true
	end

	return setmetatable(t, mt)
end

-- configuraton wrapper for per-instance options
function _M.set_option(self, option, value, data)
	if (type(value) == "table") then
		for _, v in ipairs(value) do
			_M.set_option(self, option, v, data)
		end
	else
		if (options.lookup[option]) then
			options.lookup[option](self, value, data)
		else
			local _option = "_" .. option
			self[_option] = value
		end
	end
end

-- configuraton wrapper for default options
function _M.default_option(option, value, data)
	if (type(value) == "table") then
		for _, v in ipairs(value) do
			_M.default_option(option, v, data)
		end
	else
		if (options.lookup[option]) then
			options.lookup[option](_M.default_opts, value, data)
		else
			local _option = "_" .. option
			_M.default_opts[_option] = value
		end
	end
end

-- reset the given option to its static default
function _M.reset_option(self, option)
	local _option = "_" .. option
	self[_option] = opts.defaults[_option]

	if (option == "add_ruleset" or option == "ignore_ruleset") then
		self.need_merge = true
	end
end

-- init_by_lua handler precomputations
function _M.init()
	-- do an initial rule merge based on default_option calls
	-- this prevents have to merge every request in scopes
	-- which do not further alter elected rulesets
	_merge_rulesets(_M.default_opts)

	-- do offset jump calculations for default rulesets
	-- this is also lazily handled in exec() for rulesets
	-- that dont appear here
	for _, ruleset in ipairs(_M.default_opts._active_rulesets) do
		local rs, err, calc

		if (not _ruleset_defs[ruleset]) then
			rs, err = util.load_ruleset_file(ruleset)
			calc = true
		end

		if (err) then
			ngx.log(ngx.ERR, err)
		elseif (calc) then
			_calculate_offset(rs)

			_ruleset_defs[ruleset] = rs
		end
	end

	-- clear this flag if we handled additional rulesets
	-- so its not passed to new objects
	_M.default_opts.need_merge = false
end

-- push log data regarding matching rule(s) to the configured target
-- in the case of socket or file logging, this data will be buffered
function _M.write_log_events(self)
	-- there is a small bit of code duplication here to get our context
	-- because this lives outside exec()
	local ctx = ngx.ctx
	if (ctx.opts) then
		_load(self, ctx.opts)
	end

	if (not ctx.lrw_initted) then
		-- we never ran. this could happen due to something like #157
		ngx.log(ngx.DEBUG, "Not attempting to write log as lua-resty-waf was never exec'd")
		return
	end

	if (table.getn(util.table_keys(ctx.altered)) == 0 and self._event_log_altered_only) then
		logger.log(self, "Not logging a request that wasn't altered")
		return
	end

	if (ctx.log_entries_n == 0) then
		logger.log(self, "Not logging a request that had no rule alerts")
		return
	end

	local entry = {
		timestamp = ngx.time(),
		client    = ctx.collections["REMOTE_ADDR"],
		method    = ctx.collections["METHOD"],
		uri       = ctx.collections["URI"],
		alerts    = ctx.log_entries,
		id        = self.transaction_id,
	}

	if self._event_log_request_arguments then
		entry.uri_args = ctx.collections["URI_ARGS"]
	end

	if self._event_log_request_headers then
		entry.request_headers = ctx.collections["REQUEST_HEADERS"]
	end

	if self._event_log_request_body then
		entry.request_body = ctx.collections["REQUEST_BODY"]
	end

	if (table.getn(util.table_keys(self._event_log_ngx_vars)) ~= 0) then
		entry.ngx = {}
		for k, v in pairs(self._event_log_ngx_vars) do
			entry.ngx[k] = ngx.var[k]
		end
	end

	logger.write_log_events[self._event_log_target](self, entry)
end

return _M
