package.path = package.path .. ";../src/?.lua"

require "luarocks.require"
require "telescope"
require "redis"

local settings = {
    host     = '127.0.0.1',
    port     = 6379,
    database = 14,
    password = nil,
}

function table.merge(self, tbl2)
    local new_table = {}
    for k,v in pairs(self) do new_table[k] = v end
    for k,v in pairs(tbl2) do new_table[k] = v end
    return new_table
end

function table.keys(self)
    local keys = {}
    for k, _ in pairs(self) do table.insert(keys, k) end
    return keys
end

function table.values(self)
    local values = {}
    for _, v in pairs(self) do table.insert(values, v) end
    return values
end

function table.contains(self, value)
    for _, v in pairs(self) do
        if v == value then return true end
    end
    return false
end

function table.slice(self, first, length)
    -- TODO: must be improved
    local new_table = {}
    for i = first, first + length - 1 do
        table.insert(new_table, self[i])
    end
    return new_table
end

function table.compare(self, other)
    -- NOTE: the body of this function was taken and slightly adapted from 
    --       Penlight (http://github.com/stevedonovan/Penlight)
    if #self ~= #other then return false end
    local visited = {}
    for i = 1, #self do
        local val, gotcha = self[i], nil
        for j = 1, #other do
            if not visited[j] then
                if (type(val) == 'table') then
                    if (table.compare(val, other[j])) then
                        gotcha = j
                        break
                    end
                else
                    if val == other[j] then
                        gotcha = j
                        break
                    end
                end
            end
        end
        if not gotcha then return false end
        visited[gotcha] = true
    end
    return true
end

function parse_version(version_str)
    local info, pattern = {}, "^(%d+)%.(%d+)%.(%d+)%-?(%w-)$"
    local major, minor, patch, status,ff = version_str:match(pattern)
    if major and minor and patch then
        info.major  = tonumber(major)
        info.minor  = tonumber(minor)
        info.patch  = tonumber(patch)
        if status then
            info.status = status
        end
    else
        info.unrecognized = true
    end
    return info
end

local utils = {
    create_client = function(parameters)
        local redis = Redis.connect(parameters.host, parameters.port)
        if settings.password then redis:auth(parameters.password) end
        if settings.database then redis:select(parameters.database) end
        redis:flushdb()

        local info = redis:info()
        local version = parse_version(info.redis_version)
        if version.major < 1 or (version.major == 1 and version.minor < 2) then
            error("redis-lua does not support Redis < 1.2.0 (current: "..info.redis_version..")")
        end

        return redis, version
    end,
    rpush_return = function(client, key, values, wipe)
        if wipe then client:del(key) end
        for _, v in ipairs(values) do
            client:rpush(key, v)
        end
        return values
    end,
    sadd_return = function(client, key, values, wipe)
        if wipe then client:del(key) end
        for _, v in ipairs(values) do
            client:sadd(key, v)
        end
        return values
    end,
    zadd_return = function(client, key, values, wipe)
        if wipe then client:del(key) end
        for k, v in pairs(values) do
            client:zadd(key, v, k)
        end
        return values
    end,
    sleep = function(sec)
        socket.select(nil, nil, sec)
    end,
}

local shared = {
    kvs_table = function()
        return {
            foo    = 'bar',
            hoge   = 'piyo',
            foofoo = 'barbar',
        }
    end,
    kvs_ns_table = function()
        return {
            ['metavars:foo']    = 'bar',
            ['metavars:hoge']   = 'piyo',
            ['metavars:foofoo'] = 'barbar',
        }
    end,
    lang_table = function()
        return { 
            italian  = "ciao",
            english  = "hello",
            japanese = "こんいちは！",
        }
    end,
    numbers = function()
        return { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' }
    end,
    zset_sample = function()
        return { a = -10, b = 0, c = 10, d = 20, e = 20, f = 30 }
    end,
}

make_assertion("table_values", "'%s' to have the same values as '%s'", table.compare)

-- ------------------------------------------------------------------------- --

context("Client initialization", function()
    test("Can connect successfully", function()
        local redis = Redis.connect(settings.host, settings.port)
        assert_type(redis, 'table')
        assert_true(table.contains(table.keys(redis), 'socket'))

        redis.socket:send("PING\r\n")
        assert_equal(redis.socket:receive('*l'), '+PONG')
    end)

    test("Accepts an URI for connection parameters", function()
        local uri = 'redis://'..settings.host..':'..settings.port
        local redis = Redis.connect(uri)
        assert_type(redis, 'table')
    end)

    test("Accepts a table for connection parameters", function()
        local redis = Redis.connect(settings)
        assert_type(redis, 'table')
    end)
end)

context("Client features", function()
    before(function()
        redis = utils.create_client(settings)
    end)

    test("Send raw commands", function()
        assert_equal(redis:raw_cmd("PING\r\n"), 'PONG')
        assert_true(redis:raw_cmd("SET foo 3\r\nbar\r\n"))
        assert_equal(redis:raw_cmd("GET foo\r\n"), 'bar')
    end)

    test("Define new commands or redefine existing ones", function()
        redis:add_command('doesnotexist')
        assert_not_nil(redis.doesnotexist)
        assert_error(function() redis:doesnotexist() end)

        redis:add_command('ping')
        assert_not_nil(redis.ping)
        assert_equal(redis:ping(), 'PONG')

        redis:add_command('ping', {
            request = redis.requests.inline
        })
        assert_not_nil(redis.ping)
        assert_equal(redis:ping(), 'PONG')

        redis:add_command('ping', {
            request  = redis.requests.inline,
            response = function(reply) return reply == 'PONG' end
        })
        assert_not_nil(redis.ping)
        assert_true(redis:ping())

    end)

    test("Pipelining commands", function()
        local replies = redis:pipeline(function()
            ping()
            exists('counter')
            incrby('counter', 10)
            incrby('counter', 30)
            exists('counter')
            get('counter')
            mset({ foo = 'bar', hoge = 'piyo'})
            del('foo', 'hoge')
            mget('does_not_exist', 'counter')
            info()
        end)

        assert_type(replies, 'table')
        assert_equal(#replies, 10)
        assert_true(replies[1])
        assert_type(replies[9], 'table')
        assert_equal(replies[9][2], '40')
        assert_type(replies[10], 'table')
        assert_true(table.contains(table.keys(replies[10]), 'redis_version'))
    end)

    after(function()
        redis:quit()
    end)
end)

context("Redis commands", function() 
    before(function()
        redis, version = utils.create_client(settings)
    end)

    after(function()
        redis:quit()
    end)

    context("Miscellaneous commands", function() 
        test("PING (redis:ping)", function() 
            assert_true(redis:ping())
        end)

        test("ECHO (redis:echo)", function() 
            local str_ascii, str_utf8 = "Can you hear me?", "聞こえますか？"

            assert_equal(redis:echo(str_ascii), str_ascii)
            assert_equal(redis:echo(str_utf8), str_utf8)
        end)
    end)

    context("Commands operating on string values", function() 
        test("SET (redis:set)", function() 
            assert_true(redis:set('foo', 'bar'))
            assert_equal(redis:get('foo'), 'bar')
        end)

        test("GET (redis:get)", function() 
            redis:set('foo', 'bar')

            assert_equal(redis:get('foo'), 'bar')
            assert_nil(redis:get('hoge'))

            assert_error(function()
                redis:rpush('metavars', 'foo')
                redis:get('metavars')
            end)
        end)

        test("EXISTS (redis:exists)", function() 
            redis:set('foo', 'bar')

            assert_true(redis:exists('foo'))
            assert_false(redis:exists('hoge'))
        end)

        test("SETNX (redis:setnx)", function() 
            assert_true(redis:setnx('foo', 'bar'))
            assert_false(redis:setnx('foo', 'baz'))
            assert_equal(redis:get('foo'), 'bar')
        end)

        test("MSET (redis:mset)", function()
            local kvs = shared.kvs_table()

            assert_true(redis:mset(kvs))
            for k,v in pairs(kvs) do 
                assert_equal(redis:get(k), v)
            end

            assert_true(redis:mset('a', '1', 'b', '2', 'c', '3'))
            assert_equal(redis:get('a'), '1')
            assert_equal(redis:get('b'), '2')
            assert_equal(redis:get('c'), '3')
        end)

        test("MSETNX (redis:msetnx)", function()
           assert_true(redis:msetnx({ a = '1', b = '2' }))
           assert_false(redis:msetnx({ c = '3', a = '100'}))
           assert_equal(redis:get('a'), '1')
           assert_equal(redis:get('b'), '2')
        end)

        test("MGET (redis:mget)", function() 
            local kvs = shared.kvs_table()
            local keys, values = table.keys(kvs), table.values(kvs)

            assert_true(redis:mset(kvs))
            assert_table_values(redis:mget(unpack(keys)), values)
        end)

        test("GETSET (redis:getset)", function() 
            assert_nil(redis:getset('foo', 'bar'))
            assert_equal(redis:getset('foo', 'barbar'), 'bar')
            assert_equal(redis:getset('foo', 'baz'), 'barbar')
        end)

        test("INCR (redis:incr)", function() 
            assert_equal(redis:incr('foo'), 1)
            assert_equal(redis:incr('foo'), 2)

            assert_true(redis:set('hoge', 'piyo'))
            if version.major < 2 then
                assert_equal(redis:incr('hoge'), 1)
            else
                assert_error(function()
                    redis:incr('hoge')
                end)
            end
        end)

        test("INCRBY (redis:incrby)", function() 
            redis:set('foo', 2)
            assert_equal(redis:incrby('foo', 20), 22)
            assert_equal(redis:incrby('foo', -12), 10)
            assert_equal(redis:incrby('foo', -110), -100)
        end)

        test("DECR (redis:decr)", function()  
            assert_equal(redis:decr('foo'), -1)
            assert_equal(redis:decr('foo'), -2)

            assert_true(redis:set('hoge', 'piyo'))
            if version.major < 2 then
                assert_equal(redis:decr('hoge'), -1)
            else
                assert_error(function()
                    redis:decr('hoge')
                end)
            end
        end)

        test("DECRBY (redis:decrby)", function() 
            redis:set('foo', -2)
            assert_equal(redis:decrby('foo', 20), -22)
            assert_equal(redis:decrby('foo', -12), -10)
            assert_equal(redis:decrby('foo', -110), 100)
        end)

        test("DEL (redis:del)", function() 
            redis:mset(shared.kvs_table())

            assert_equal(redis:del('doesnotexist'), 0)
            assert_equal(redis:del('foofoo'), 1)
            assert_equal(redis:del('foo', 'hoge', 'doesnotexist'), 2)
        end)

        test("TYPE (redis:type)", function() 
            assert_equal(redis:type('doesnotexist'), 'none')

            redis:set('fooString', 'bar')
            assert_equal(redis:type('fooString'), 'string')

            redis:rpush('fooList', 'bar')
            assert_equal(redis:type('fooList'), 'list')

            redis:sadd('fooSet', 'bar')
            assert_equal(redis:type('fooSet'), 'set')

            redis:zadd('fooZSet', 0, 'bar')
            assert_equal(redis:type('fooZSet'), 'zset')
        end)
    end)

    context("Commands operating on the key space", function() 
        test("KEYS (redis:keys)", function() 
            local kvs_prefixed   = shared.kvs_ns_table()
            local kvs_unprefixed = { aaa = 1, aba = 2, aca = 3 }
            local kvs_all = table.merge(kvs_prefixed, kvs_unprefixed)

            redis:mset(kvs_all)

            assert_empty(redis:keys('nokeys:*'))
            assert_table_values(
                table.values(redis:keys('*')), 
                table.keys(kvs_all)
            )
            assert_table_values(
                table.values(redis:keys('metavars:*')), 
                table.keys(kvs_prefixed)
            )
            assert_table_values(
                table.values(redis:keys('a?a')), 
                table.keys(kvs_unprefixed)
            )
        end)

        test("RANDOMKEY (redis:randomkey)", function() 
            local kvs = shared.kvs_table()

            assert_nil(redis:randomkey())
            redis:mset(kvs)
            assert_true(table.contains(table.keys(kvs), redis:randomkey()))
        end)

        test("RENAME (redis:rename)", function() 
            local kvs = shared.kvs_table()
            redis:mset(kvs)

            assert_true(redis:rename('hoge', 'hogehoge'))
            assert_false(redis:exists('hoge'))
            assert_equal(redis:get('hogehoge'), 'piyo')

            -- rename overwrites existing keys
            assert_true(redis:rename('foo', 'foofoo'))
            assert_false(redis:exists('foo'))
            assert_equal(redis:get('foofoo'), 'bar')

            -- rename fails when the key does not exist
            assert_error(function()
                redis:rename('doesnotexist', 'fuga')
            end)
        end)

        test("RENAMENX (redis:renamenx)", function() 
            local kvs = shared.kvs_table()
            redis:mset(kvs)

            assert_true(redis:renamenx('hoge', 'hogehoge'))
            assert_false(redis:exists('hoge'))
            assert_equal(redis:get('hogehoge'), 'piyo')

            -- rename overwrites existing keys
            assert_false(redis:renamenx('foo', 'foofoo'))
            assert_true(redis:exists('foo'))

            -- rename fails when the key does not exist
            assert_error(function()
                redis:renamenx('doesnotexist', 'fuga')
            end)
        end)

        test("TTL (redis:ttl)", function() 
            redis:set('foo', 'bar')
            assert_equal(redis:ttl('foo'), -1)

            assert_true(redis:expire('foo', 5))
            assert_equal(redis:ttl('foo'), 5)
        end)

        test("EXPIRE (redis:expire)", function() 
            redis:set('foo', 'bar')
            assert_true(redis:expire('foo', 1))
            assert_true(redis:exists('foo'))
            assert_equal(redis:ttl('foo'), 1)
            utils.sleep(2)
            assert_false(redis:exists('foo'))

            redis:set('foo', 'bar')
            assert_true(redis:expire('foo', 100))
            utils.sleep(3)
            assert_equal(redis:ttl('foo'), 97)

            assert_true(redis:expire('foo', -100))
            assert_false(redis:exists('foo'))
        end)

        test("EXPIREAT (redis:expireat)", function() 
            redis:set('foo', 'bar')
            assert_true(redis:expireat('foo', os.time() + 2))
            assert_equal(redis:ttl('foo'), 2)
            utils.sleep(3)
            assert_false(redis:exists('foo'))

            redis:set('foo', 'bar')
            assert_true(redis:expireat('foo', os.time() - 100))
            assert_false(redis:exists('foo'))
        end)

        test("DBSIZE (redis:dbsize)", function() 
            assert_equal(redis:dbsize(), 0)
            redis:mset(shared.kvs_table())
            assert_greater_than(redis:dbsize(), 0)
        end)
    end)

    context("Commands operating on lists", function() 
        test("RPUSH (redis:rpush)", function() 
            if version.major < 2 then
                assert_true(redis:rpush('metavars', 'foo'))
                assert_true(redis:rpush('metavars', 'hoge'))
            else
                assert_equal(redis:rpush('metavars', 'foo'), 1)
                assert_equal(redis:rpush('metavars', 'hoge'), 2)
            end
            assert_error(function()
                redis:set('foo', 'bar')
                redis:rpush('foo', 'baz')
            end)
        end)

        test("LPUSH (redis:lpush)", function() 
            if version.major < 2 then
                assert_true(redis:lpush('metavars', 'foo'))
                assert_true(redis:lpush('metavars', 'hoge'))
            else
                assert_equal(redis:lpush('metavars', 'foo'), 1)
                assert_equal(redis:lpush('metavars', 'hoge'), 2)
            end
            assert_error(function()
                redis:set('foo', 'bar')
                redis:lpush('foo', 'baz')
            end)
        end)

        test("LLEN (redis:llen)", function() 
            local kvs = shared.kvs_table()
            for _, v in pairs(kvs) do
                redis:rpush('metavars', v)
            end

            assert_equal(redis:llen('metavars'), 3)
            assert_equal(redis:llen('doesnotexist'), 0)
            assert_error(function()
                redis:set('foo', 'bar')
                redis:llen('foo')
            end)
        end)

        test("LRANGE (redis:lrange)", function() 
            local numbers = utils.rpush_return(redis, 'numbers', shared.numbers())

            assert_table_values(redis:lrange('numbers', 0, 3), table.slice(numbers, 1, 4))
            assert_table_values(redis:lrange('numbers', 4, 8), table.slice(numbers, 5, 5))
            assert_table_values(redis:lrange('numbers', 0, 0), table.slice(numbers, 1, 1))
            assert_empty(redis:lrange('numbers', 1, 0))
            assert_table_values(redis:lrange('numbers', 0, -1), numbers)
            assert_table_values(redis:lrange('numbers', 5, -5), { '5' })
            assert_empty(redis:lrange('numbers', 7, -5))
            assert_table_values(redis:lrange('numbers', -5, -2), table.slice(numbers, 6, 4))
            assert_table_values(redis:lrange('numbers', -100, 100), numbers)
        end)

        test("LTRIM (redis:ltrim)", function() 
            local numbers = utils.rpush_return(redis, 'numbers', shared.numbers(), true)
            assert_true(redis:ltrim('numbers', 0, 2))
            assert_table_values(redis:lrange('numbers', 0, -1), table.slice(numbers, 1, 3))

            local numbers = utils.rpush_return(redis, 'numbers', shared.numbers(), true)
            assert_true(redis:ltrim('numbers', 5, 9))
            assert_table_values(redis:lrange('numbers', 0, -1), table.slice(numbers, 6, 5))

            local numbers = utils.rpush_return(redis, 'numbers', shared.numbers(), true)
            assert_true(redis:ltrim('numbers', 0, -6))
            assert_table_values(redis:lrange('numbers', 0, -1), table.slice(numbers, 1, 5))

            local numbers = utils.rpush_return(redis, 'numbers', shared.numbers(), true)
            assert_true(redis:ltrim('numbers', -5, -3))
            assert_table_values(redis:lrange('numbers', 0, -1), table.slice(numbers, 6, 3))

            local numbers = utils.rpush_return(redis, 'numbers', shared.numbers(), true)
            assert_true(redis:ltrim('numbers', -100, 100))
            assert_table_values(redis:lrange('numbers', 0, -1), numbers)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:ltrim('foo', 0, 1)
            end)
        end)

        test("LINDEX (redis:lindex)", function() 
            local numbers = utils.rpush_return(redis, 'numbers', shared.numbers())

            assert_equal(redis:lindex('numbers', 0), numbers[1])
            assert_equal(redis:lindex('numbers', 5), numbers[6])
            assert_equal(redis:lindex('numbers', 9), numbers[10])
            assert_nil(redis:lindex('numbers', 100))

            assert_equal(redis:lindex('numbers', -0), numbers[1])
            assert_equal(redis:lindex('numbers', -1), numbers[10])
            assert_equal(redis:lindex('numbers', -3), numbers[8])
            assert_nil(redis:lindex('numbers', -100))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:lindex('foo', 0)
            end)
        end)

        test("LSET (redis:lset)", function() 
            utils.rpush_return(redis, 'numbers', shared.numbers())

            assert_true(redis:lset('numbers', 5, -5))
            assert_equal(redis:lindex('numbers', 5), '-5')

            assert_error(function()
                redis:lset('numbers', 99, 99)
            end)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:lset('foo', 0, 0)
            end)
        end)

        test("LREM (redis:lrem)", function() 
            local mixed = { '0', '_', '2', '_', '4', '_', '6', '_' }

            utils.rpush_return(redis, 'mixed', mixed, true)
            assert_equal(redis:lrem('mixed', 2, '_'), 2)
            assert_table_values(redis:lrange('mixed', 0, -1), { '0', '2', '4', '_', '6', '_' })

            utils.rpush_return(redis, 'mixed', mixed, true)
            assert_equal(redis:lrem('mixed', 0, '_'), 4)
            assert_table_values(redis:lrange('mixed', 0, -1), { '0', '2', '4', '6' })

            utils.rpush_return(redis, 'mixed', mixed, true)
            assert_equal(redis:lrem('mixed', -2, '_'), 2)
            assert_table_values(redis:lrange('mixed', 0, -1), { '0', '_', '2', '_', '4', '6' })

            utils.rpush_return(redis, 'mixed', mixed, true)
            assert_equal(redis:lrem('mixed', 2, '|'), 0)
            assert_table_values(redis:lrange('mixed', 0, -1), mixed)

            assert_equal(redis:lrem('doesnotexist', 2, '_'), 0)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:lrem('foo', 0, 0)
            end)
        end)

        test("LPOP (redis:lpop)", function() 
            local numbers = utils.rpush_return(redis, 'numbers', { '0', '1', '2', '3', '4' })

            assert_equal(redis:lpop('numbers'), numbers[1])
            assert_equal(redis:lpop('numbers'), numbers[2])
            assert_equal(redis:lpop('numbers'), numbers[3])

            assert_table_values(redis:lrange('numbers', 0, -1), { '3', '4' })

            redis:lpop('numbers')
            redis:lpop('numbers')
            assert_nil(redis:lpop('numbers'))

            assert_nil(redis:lpop('doesnotexist'))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:lpop('foo')
            end)
        end)

        test("RPOP (redis:rpop)", function() 
            local numbers = utils.rpush_return(redis, 'numbers', { '0', '1', '2', '3', '4' })

            assert_equal(redis:rpop('numbers'), numbers[5])
            assert_equal(redis:rpop('numbers'), numbers[4])
            assert_equal(redis:rpop('numbers'), numbers[3])

            assert_table_values(redis:lrange('numbers', 0, -1), { '0', '1' })

            redis:rpop('numbers')
            redis:rpop('numbers')
            assert_nil(redis:rpop('numbers'))

            assert_nil(redis:rpop('doesnotexist'))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:rpop('foo')
            end)
        end)

        test("RPOPLPUSH (redis:rpoplpush)", function() 
            local numbers = utils.rpush_return(redis, 'numbers', { '0', '1', '2' }, true)
            assert_equal(redis:llen('temporary'), 0)
            assert_equal(redis:rpoplpush('numbers', 'temporary'), '2')
            assert_equal(redis:rpoplpush('numbers', 'temporary'), '1')
            assert_equal(redis:rpoplpush('numbers', 'temporary'), '0')
            assert_equal(redis:llen('numbers'), 0)
            assert_equal(redis:llen('temporary'), 3)

            local numbers = utils.rpush_return(redis, 'numbers', { '0', '1', '2' }, true)
            redis:rpoplpush('numbers', 'numbers')
            redis:rpoplpush('numbers', 'numbers')
            redis:rpoplpush('numbers', 'numbers')
            assert_table_values(redis:lrange('numbers', 0, -1), numbers)

            assert_nil(redis:rpoplpush('doesnotexist1', 'doesnotexist2'))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:rpoplpush('foo', 'hoge')
            end)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:rpoplpush('temporary', 'foo')
            end)
        end)
    end)

    context("Commands operating on sets", function() 
        test("SADD (redis:sadd)", function() 
            assert_true(redis:sadd('set', 0))
            assert_true(redis:sadd('set', 1))
            assert_false(redis:sadd('set', 0))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:sadd('foo', 0)
            end)
        end)

        test("SREM (redis:srem)", function() 
            utils.sadd_return(redis, 'set', { '0', '1', '2', '3', '4' })

            assert_true(redis:srem('set', 0))
            assert_true(redis:srem('set', 4))
            assert_false(redis:srem('set', 10))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:srem('foo', 0)
            end)
        end)

        test("SPOP (redis:spop)", function() 
            local set = utils.sadd_return(redis, 'set', { '0', '1', '2', '3', '4' })

            assert_true(table.contains(set, redis:spop('set')))
            assert_nil(redis:spop('doesnotexist'))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:spop('foo')
            end)
        end)

        test("SMOVE (redis:smove)", function() 
            utils.sadd_return(redis, 'setA', { '0', '1', '2', '3', '4', '5' })
            utils.sadd_return(redis, 'setB', { '5', '6', '7', '8', '9', '10' })

            assert_true(redis:smove('setA', 'setB', 0))
            assert_false(redis:srem('setA', 0))
            assert_true(redis:srem('setB', 0))

            assert_true(redis:smove('setA', 'setB', 5))
            assert_false(redis:smove('setA', 'setB', 100))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:smove('foo', 'setB', 5)
            end)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:smove('setA', 'foo', 5)
            end)
        end)

        test("SCARD (redis:scard)", function() 
            utils.sadd_return(redis, 'setA', { '0', '1', '2', '3', '4', '5' })

            assert_equal(redis:scard('setA'), 6)

            -- empty set
            redis:sadd('setB', 0)
            redis:spop('setB')
            assert_equal(redis:scard('doesnotexist'), 0)

            -- non-existent set
            assert_equal(redis:scard('doesnotexist'), 0)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:scard('foo')
            end)
        end)

        test("SISMEMBER (redis:sismember)", function() 
            utils.sadd_return(redis, 'set', { '0', '1', '2', '3', '4', '5' })

            assert_true(redis:sismember('set', 3))
            assert_false(redis:sismember('set', 100))
            assert_false(redis:sismember('doesnotexist', 0))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:sismember('foo', 0)
            end)
        end)

        test("SMEMBERS (redis:smembers)", function() 
            local set = utils.sadd_return(redis, 'set', { '0', '1', '2', '3', '4', '5' })

            assert_table_values(redis:smembers('set'), set)
            -- this behaviour has changed in redis 2.0
            assert_nil(redis:smembers('doesnotexist'))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:smembers('foo')
            end)
        end)

        test("SINTER (redis:sinter)", function() 
            local setA = utils.sadd_return(redis, 'setA', { '0', '1', '2', '3', '4', '5', '6' })
            local setB = utils.sadd_return(redis, 'setB', { '1', '3', '4', '6', '9', '10' })

            assert_table_values(redis:sinter('setA'), setA)
            assert_table_values(redis:sinter('setA', 'setB'), { '3', '4', '6', '1' })

            -- this behaviour has changed in redis 2.0
            assert_nil(redis:sinter('setA', 'doesnotexist'))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:sinter('foo')
            end)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:sinter('setA', 'foo')
            end)
        end)

        test("SINTERSTORE (redis:sinterstore)", function() 
            local setA = utils.sadd_return(redis, 'setA', { '0', '1', '2', '3', '4', '5', '6' })
            local setB = utils.sadd_return(redis, 'setB', { '1', '3', '4', '6', '9', '10' })

            assert_equal(redis:sinterstore('setC', 'setA'), #setA)
            assert_table_values(redis:smembers('setC'), setA)

            redis:del('setC')
            -- this behaviour has changed in redis 2.0
            assert_equal(redis:sinterstore('setC', 'setA', 'setB'), 4)
            assert_table_values(redis:smembers('setC'), { '1', '3', '4', '6' })

            redis:del('setC')
            assert_equal(redis:sinterstore('setC', 'doesnotexist'), 0)
            assert_false(redis:exists('setC'))

            -- existing keys are replaced by SINTERSTORE
            redis:set('foo', 'bar')
            assert_equal(redis:sinterstore('foo', 'setA'), #setA)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:sinterstore('setA', 'foo')
            end)
        end)

        test("SUNION (redis:sunion)", function() 
            local setA = utils.sadd_return(redis, 'setA', { '0', '1', '2', '3', '4', '5', '6' })
            local setB = utils.sadd_return(redis, 'setB', { '1', '3', '4', '6', '9', '10' })

            assert_table_values(redis:sunion('setA'), setA)
            assert_table_values(
                redis:sunion('setA', 'setB'), 
                { '0', '1', '10', '2', '3', '4', '5', '6', '9' }
            )

            -- this behaviour has changed in redis 2.0
            assert_table_values(redis:sunion('setA', 'doesnotexist'), setA)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:sunion('foo')
            end)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:sunion('setA', 'foo')
            end)
        end)

        test("SUNIONSTORE (redis:sunionstore)", function() 
            local setA = utils.sadd_return(redis, 'setA', { '0', '1', '2', '3', '4', '5', '6' })
            local setB = utils.sadd_return(redis, 'setB', { '1', '3', '4', '6', '9', '10' })

            assert_equal(redis:sunionstore('setC', 'setA'), #setA)
            assert_table_values(redis:smembers('setC'), setA)

            redis:del('setC')
            assert_equal(redis:sunionstore('setC', 'setA', 'setB'), 9)
            assert_table_values(
                redis:smembers('setC'), 
                { '0' ,'1' , '10', '2', '3', '4', '5', '6', '9' }
            )

            redis:del('setC')
            assert_equal(redis:sunionstore('setC', 'doesnotexist'), 0)
            -- this behaviour has changed in redis 2.0
            assert_true(redis:exists('setC'))
            assert_equal(redis:scard('setC'), 0)

            -- existing keys are replaced by SUNIONSTORE
            redis:set('foo', 'bar')
            assert_equal(redis:sunionstore('foo', 'setA'), #setA)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:sunionstore('setA', 'foo')
            end)
        end)

        test("SDIFF (redis:sdiff)", function() 
            local setA = utils.sadd_return(redis, 'setA', { '0', '1', '2', '3', '4', '5', '6' })
            local setB = utils.sadd_return(redis, 'setB', { '1', '3', '4', '6', '9', '10' })

            assert_table_values(redis:sdiff('setA'), setA)
            assert_table_values(redis:sdiff('setA', 'setB'), { '5', '0', '2' })
            assert_table_values(redis:sdiff('setA', 'doesnotexist'), setA)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:sdiff('foo')
            end)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:sdiff('setA', 'foo')
            end)
        end)

        test("SDIFFSTORE (redis:sdiffstore)", function() 
            local setA = utils.sadd_return(redis, 'setA', { '0', '1', '2', '3', '4', '5', '6' })
            local setB = utils.sadd_return(redis, 'setB', { '1', '3', '4', '6', '9', '10' })

            assert_equal(redis:sdiffstore('setC', 'setA'), #setA)
            assert_table_values(redis:smembers('setC'), setA)

            redis:del('setC')
            assert_equal(redis:sdiffstore('setC', 'setA', 'setB'), 3)
            assert_table_values(redis:smembers('setC'), { '5', '0', '2' })

            redis:del('setC')
            assert_equal(redis:sdiffstore('setC', 'doesnotexist'), 0)
            -- this behaviour has changed in redis 2.0
            assert_true(redis:exists('setC'))
            assert_equal(redis:scard('setC'), 0)

            -- existing keys are replaced by SDIFFSTORE
            redis:set('foo', 'bar')
            assert_equal(redis:sdiffstore('foo', 'setA'), #setA)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:sdiffstore('setA', 'foo')
            end)
        end)

        test("SRANDMEMBER (redis:srandmember)", function() 
            local setA = utils.sadd_return(redis, 'setA', { '0', '1', '2', '3', '4', '5', '6' })

            assert_true(table.contains(setA, redis:srandmember('setA')))
            assert_nil(redis:srandmember('doesnotexist'))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:srandmember('foo')
            end)
        end)
    end)

    context("Commands operating on zsets", function() 
        test("ZADD (redis:zadd)", function() 
            assert_true(redis:zadd('zset', 0, 'a'))
            assert_true(redis:zadd('zset', 1, 'b'))
            assert_true(redis:zadd('zset', -1, 'c'))

            assert_false(redis:zadd('zset', 2, 'b'))
            assert_false(redis:zadd('zset', -22, 'b'))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:zadd('foo', 0, 'a')
            end)
        end)

        test("ZINCRBY (redis:zincrby)", function() 
            assert_equal(redis:zincrby('doesnotexist', 1, 'foo'), '1')
            assert_equal(redis:type('doesnotexist'), 'zset')

            utils.zadd_return(redis, 'zset', shared.zset_sample())
            assert_equal(redis:zincrby('zset', 5, 'a'), '-5')
            assert_equal(redis:zincrby('zset', 1, 'b'), '1')
            assert_equal(redis:zincrby('zset', 0, 'c'), '10')
            assert_equal(redis:zincrby('zset', -20, 'd'), '0')
            assert_equal(redis:zincrby('zset', 2, 'd'), '2')
            assert_equal(redis:zincrby('zset', -30, 'e'), '-10')
            assert_equal(redis:zincrby('zset', 1, 'x'), '1')

            assert_error(function()
                redis:set('foo', 'bar')
                redis:zincrby('foo', 1, 'a')
            end)
        end)

        test("ZREM (redis:zrem)", function() 
            utils.zadd_return(redis, 'zset', shared.zset_sample())

            assert_true(redis:zrem('zset', 'a'))
            assert_false(redis:zrem('zset', 'x'))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:zrem('foo', 'bar')
            end)
        end)

        test("ZRANGE (redis:zrange)", function() 
            local zset = utils.zadd_return(redis, 'zset', shared.zset_sample())

            assert_table_values(redis:zrange('zset', 0, 3), { 'a', 'b', 'c', 'd' })
            assert_table_values(redis:zrange('zset', 0, 0), { 'a' })
            assert_empty(redis:zrange('zset', 1, 0))
            assert_table_values(redis:zrange('zset', 0, -1), table.keys(zset))
            assert_table_values(redis:zrange('zset', 3, -3), { 'd' })
            assert_empty(redis:zrange('zset', 5, -3))
            assert_table_values(redis:zrange('zset', -100, 100), table.keys(zset))

            assert_table_values(
                redis:zrange('zset', 0, 2, 'withscores'),
                  { { 'a', '-10' }, { 'b', '0' }, { 'c', '10' } }
            )

            assert_error(function()
                redis:set('foo', 'bar')
                redis:zrange('foo', 0, -1)
            end)
        end)

        test("ZREVRANGE (redis:zrevrange)", function() 
            local zset = utils.zadd_return(redis, 'zset', shared.zset_sample())

            assert_table_values(redis:zrevrange('zset', 0, 3), { 'f', 'e', 'd', 'c' })
            assert_table_values(redis:zrevrange('zset', 0, 0), { 'f' })
            assert_empty(redis:zrevrange('zset', 1, 0))
            assert_table_values(redis:zrevrange('zset', 0, -1), table.keys(zset))
            assert_table_values(redis:zrevrange('zset', 3, -3), { 'c' })
            assert_empty(redis:zrevrange('zset', 5, -3))
            assert_table_values(redis:zrevrange('zset', -100, 100), table.keys(zset))

            assert_table_values(
                redis:zrevrange('zset', 0, 2, 'withscores'),
                { { 'f', '30' }, { 'e', '20' }, { 'd', '20' } }
            )

            assert_error(function()
                redis:set('foo', 'bar')
                redis:zrevrange('foo', 0, -1)
            end)
        end)

        test("ZRANGEBYSCORE (redis:zrangebyscore)", function() 
            local zset = utils.zadd_return(redis, 'zset', shared.zset_sample())

            assert_table_values(redis:zrangebyscore('zset', -10, -10), { 'a' })
            assert_table_values(redis:zrangebyscore('zset', 10, 30), { 'c', 'd', 'e', 'f' })
            assert_table_values(redis:zrangebyscore('zset', 20, 20), { 'd', 'e' })
            assert_empty(redis:zrangebyscore('zset', 30, 0))

            -- TODO: should return a kind of tuple when using 'withscores'
            assert_table_values(
                redis:zrangebyscore('zset', 10, 20, 'withscores'),
                { 'c', '10', 'd', '20', 'e', '20' }
            )

            assert_error(function()
                redis:set('foo', 'bar')
                redis:zrangebyscore('foo', 0, -1)
            end)
        end)

        test("ZCARD (redis:zcard)", function() 
            local zset = utils.zadd_return(redis, 'zset', shared.zset_sample())

            assert_equal(redis:zcard('zset'), #table.keys(zset))

            redis:zrem('zset', 'a')
            assert_equal(redis:zcard('zset'), #table.keys(zset) - 1)

            redis:zadd('zsetB', 0, 'a')
            redis:zrem('zsetB', 'a')
            assert_equal(redis:zcard('zsetB'), 0)

            assert_equal(redis:zcard('doesnotexist'), 0)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:zcard('foo')
            end)
        end)

        test("ZSCORE (redis:zscore)", function() 
            utils.zadd_return(redis, 'zset', shared.zset_sample())

            assert_equal(redis:zscore('zset', 'a'), '-10')
            assert_equal(redis:zscore('zset', 'c'), '10')
            assert_equal(redis:zscore('zset', 'e'), '20')

            assert_nil(redis:zscore('zset', 'x'))
            assert_nil(redis:zscore('doesnotexist', 'a'))

            assert_error(function()
                redis:set('foo', 'bar')
                redis:zscore('foo', 'a')
            end)
        end)

        test("ZREMRANGEBYSCORE (redis:zremrangebyscore)", function() 
            utils.zadd_return(redis, 'zset', shared.zset_sample())

            assert_equal(redis:zremrangebyscore('zset', -10, 0), 2)
            assert_table_values(redis:zrange('zset', 0, -1), { 'c', 'd', 'e', 'f' })

            assert_equal(redis:zremrangebyscore('zset', 10, 10), 1)
            assert_table_values(redis:zrange('zset', 0, -1), { 'd', 'e', 'f' })

            assert_equal(redis:zremrangebyscore('zset', 100, 100), 0)

            assert_equal(redis:zremrangebyscore('zset', 0, 100), 3)
            assert_equal(redis:zremrangebyscore('zset', 0, 100), 0)

            assert_error(function()
                redis:set('foo', 'bar')
                redis:zremrangebyscore('foo', 0, 0)
            end)
        end)
    end)

    context("Sorting", function() 
        -- TODO: missing tests for params GET and BY

        before(function()
            -- TODO: code duplication!
            list01, list01_values = "list01", { "4","2","3","5","1" }
            for _,v in ipairs(list01_values) do redis:rpush(list01,v) end

            list02, list02_values = "list02", { "1","10","2","20","3","30" }
            for _,v in ipairs(list02_values) do redis:rpush(list02,v) end
        end)

        test("SORT (redis:sort)", function() 
            local sorted = redis:sort(list01)
            assert_table_values(sorted, { "1","2","3","4","5" })
        end)

        test("SORT (redis:sort) with parameter ASC/DESC", function() 
            assert_table_values(redis:sort(list01, { sort = 'asc'}),  { "1","2","3","4","5" })
            assert_table_values(redis:sort(list01, { sort = 'desc'}), { "5","4","3","2","1" })
        end)

        test("SORT (redis:sort) with parameter LIMIT", function() 
            assert_table_values(redis:sort(list01, { limit = { 0,3 } }), { "1","2", "3" })
            assert_table_values(redis:sort(list01, { limit = { 3,2 } }), { "4","5" })
        end)

        test("SORT (redis:sort) with parameter ALPHA", function() 
            assert_table_values(redis:sort(list02, { alpha = false }), { "1","2","3","10","20","30" })
            assert_table_values(redis:sort(list02, { alpha = true }),  { "1","10","2","20","3","30" })
        end)

        test("SORT (redis:sort) with multiple parameters", function() 
            assert_table_values(redis:sort(list02, { 
                alpha = false, 
                sort  = 'desc', 
                limit = { 1, 4 }
            }), { "20","10","3","2" })
        end)

        test("SORT (redis:sort) with parameter STORE", function() 
            assert_equal(redis:sort(list01, { store = 'list01_ordered' }), 5)
            assert_true(redis:exists('list01_ordered'))
        end)
    end)

    context("Multiple databases handling commands", function() 
        test("SELECT (redis:select)", function() 
            if not settings.database then return end

            assert_true(redis:select(0))
            assert_true(redis:select(settings.database))
            assert_error(function() redis:select(100) end)
            assert_error(function() redis:select(-1) end)
        end)

        test("FLUSHDB (redis:flushdb)", function() 
            assert_true(redis:flushdb())
        end)

        test("MOVE (redis:move)", function() 
            if not settings.database then return end

            local other_db = settings.database + 1
            redis:set('foo', 'bar')
            redis:select(other_db)
            redis:flushdb()
            redis:select(settings.database)

            assert_true(redis:move('foo', other_db))
            assert_false(redis:move('foo', other_db))
            assert_false(redis:move('doesnotexist', other_db))

            redis:set('hoge', 'piyo')
            assert_error(function() redis:move('hoge', 100) end)
        end)
    end)

    context("Remote server control commands", function() 
        test("INFO (redis:info)", function() 
            local server_info = redis:info()
            assert_not_nil(server_info.redis_version)
            assert_type(server_info, 'table')
            assert_greater_than(tonumber(server_info.uptime_in_seconds), 0)
            assert_greater_than(tonumber(server_info.total_connections_received), 0)
        end)

        test("SLAVEOF (redis:slaveof)", function() 
            local master_host, master_port = 'www.google.com', 80

            assert_true(redis:slaveof(master_host, master_port))
            local server_info = redis:info()
            assert_equal(server_info.role, 'slave')
            assert_equal(server_info.master_host, master_host)
            assert_equal(server_info.master_port, tostring(master_port))

            -- SLAVE OF NO ONE (explicit)
            assert_true(redis:slaveof('NO', 'ONE'))
            local server_info = redis:info()
            assert_equal(server_info.role, 'master')
        end)
    end)

    context("Persistence control commands", function() 
        test("SAVE (redis:save)", function() 
            assert_true(redis:save())
        end)

        test("BGSAVE (redis:bgsave)", function() 
            assert_equal(redis:bgsave(), 'Background saving started')
        end)

        test("BGREWRITEAOF (redis:bgrewriteaof)", function() 
            assert_equal(redis:bgrewriteaof(), 'Background append only file rewriting started')
        end)

        test("LASTSAVE (redis:lastsave)", function() 
            assert_greater_than(tonumber(redis:lastsave()), 0)
        end)
    end)
end)