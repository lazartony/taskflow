#!lua name=taskflow

--[[
GCRA (Generic Cell Rate Algorithm) rate limiter.

Why GCRA rather than a fixed or sliding window:
  fixed window        1 int,  allows 2x the limit across a boundary
  sliding window log  N timestamps, exact but O(N) memory per key
  sliding window ctr  2 ints, approximate
  token bucket        2 fields
  GCRA                1 timestamp, smooth pacing, exact Retry-After   <-- this

Why a Redis Function and not application code:
  Rate limiting must be ATOMIC across every replica. A read-then-write from
  the application is a race; MULTI/EXEC can't branch on an intermediate read;
  WATCH causes retry storms under contention. A single server-side script is
  the only correct option. Redis's own rate-limiting guide says the same.

Registered as a FUNCTION (not EVAL'd ad hoc) so it is versioned and replicated
with the dataset.

  KEYS[1] rate limit key      e.g. taskflow:dev:ratelimit:tasks:usr_abc123
  ARGV[1] period_ms           window in ms          e.g. 60000
  ARGV[2] limit               requests per window   e.g. 100
  ARGV[3] cost                usually 1
  returns { allowed(0|1), limit, remaining, retry_after_ms, reset_after_ms }

CLOCK: this uses redis.call('TIME') — the SERVER's clock — deliberately.
Passing the caller's clock would mean five services with skewed clocks compute
different windows, and your rate-limit conformance tests would disagree for
reasons that take a day to find. With Redis Functions and effect-based
replication, calling TIME inside a function is safe.
]]

local function now_ms()
  local t = redis.call('TIME')          -- { seconds, microseconds }
  return (tonumber(t[1]) * 1000) + (tonumber(t[2]) / 1000)
end

local function ratelimit(keys, args)
  local key       = keys[1]
  local period_ms = tonumber(args[1])
  local limit     = tonumber(args[2])
  local cost      = tonumber(args[3]) or 1

  if not key or not period_ms or not limit or period_ms <= 0 or limit <= 0 then
    return redis.error_reply('ratelimit: bad arguments (key, period_ms>0, limit>0)')
  end

  local now = now_ms()

  -- emission interval: ms of quota consumed per unit of work
  local emission  = period_ms / limit
  -- burst tolerance: how far ahead of "now" the theoretical arrival time may
  -- run. One full window == the caller may burst the whole limit at once.
  local delay_tol = period_ms

  -- TAT = Theoretical Arrival Time of the next conforming request.
  local tat = tonumber(redis.call('GET', key)) or now
  if tat < now then tat = now end

  local new_tat  = tat + (emission * cost)
  local allow_at = new_tat - delay_tol
  local diff     = now - allow_at

  if diff < 0 then
    -- Denied. Do NOT advance the TAT: a rejected request must not push the
    -- caller further into debt, or a hot loop of denied requests would extend
    -- the block indefinitely.
    local retry_after = math.ceil(-diff)
    local remaining   = math.floor(math.max(0, (delay_tol - (tat - now)) / emission))
    local reset_after = math.ceil(math.max(0, tat - now))
    return { 0, limit, remaining, retry_after, reset_after }
  end

  -- Allowed. TTL covers the full burst window plus one emission so the key
  -- expires naturally once the caller goes quiet — no cleanup job needed.
  redis.call('SET', key, new_tat, 'PX', math.ceil(delay_tol + emission))

  local remaining   = math.floor(diff / emission)
  local reset_after = math.ceil(new_tat - now)
  return { 1, limit, remaining, 0, reset_after }
end

--[[
Cache-aside stampede lock.
  KEYS[1] lock key
  ARGV[1] ttl_ms
  ARGV[2] token (unique per caller, so only the holder can release)
  returns 1 if acquired, 0 otherwise
]]
local function lock_acquire(keys, args)
  local ok = redis.call('SET', keys[1], args[2], 'NX', 'PX', tonumber(args[1]))
  return ok and 1 or 0
end

-- Release only if we still hold it. Without the token check, a caller whose
-- lock already expired would delete the NEXT caller's lock.
local function lock_release(keys, args)
  if redis.call('GET', keys[1]) == args[1] then
    return redis.call('DEL', keys[1])
  end
  return 0
end

--[[
Invalidate every cache key registered under an index set, then drop the index.
  KEYS[1] index set key   e.g. taskflow:dev:tasks:usr_abc123:keys
  returns number of keys deleted
]]
local function invalidate_index(keys, args)
  local members = redis.call('SMEMBERS', keys[1])
  local n = 0
  if #members > 0 then
    -- Chunked: UNLINK with tens of thousands of args can block the server.
    for i = 1, #members, 512 do
      local chunk = {}
      for j = i, math.min(i + 511, #members) do
        chunk[#chunk + 1] = members[j]
      end
      n = n + redis.call('UNLINK', unpack(chunk))
    end
  end
  redis.call('DEL', keys[1])
  return n
end

redis.register_function('ratelimit',        ratelimit)
redis.register_function('lock_acquire',     lock_acquire)
redis.register_function('lock_release',     lock_release)
redis.register_function('invalidate_index', invalidate_index)
