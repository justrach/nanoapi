-- wrk script: pipeline N requests per write per connection (default 16).
-- Usage: wrk -t4 -c64 -d15s --latency -s pipeline.lua http://host/path
init = function(args)
  local depth = tonumber(args[1]) or 16
  local r = {}
  for i = 1, depth do
    r[i] = wrk.format()
  end
  req = table.concat(r)
end

request = function()
  return req
end
