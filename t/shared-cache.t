# Native shared-cache policy regressions. All decisions are checked against
# origin executions, cache reads, actual writes, and the TTL passed to storage.
use lib 'lib';
use Test::Nginx::Socket;

plan 'no_plan';
no_shuffle();

our $http_config = <<'NGINX';
lua_shared_dict policy 1m;
init_by_lua_block { ngx.shared.policy:flush_all() }
NGINX

our $fixture = <<'NGINX';
location = /_read {
    internal;
    content_by_lua_block {
        local s = ngx.shared.policy
        s:incr('reads', 1, 0)
        local entry = s:get('entry')
        if not entry then return ngx.exit(404) end
        ngx.print(entry)
    }
}
location = /_write {
    internal;
    content_by_lua_block {
        local s = ngx.shared.policy
        ngx.req.read_body()
        s:incr('writes', 1, 0)
        s:set('ttl', ngx.var.args)
        -- A zero TTL is intentionally indefinite, like real simple-cache.
        s:set('entry', ngx.req.get_body_data(), tonumber(ngx.var.args))
        return ngx.exit(201)
    }
}
location = /_stats {
    content_by_lua_block {
        local s = ngx.shared.policy
        ngx.say((s:get('origins') or 0) .. ':' .. (s:get('reads') or 0)
            .. ':' .. (s:get('writes') or 0) .. ':' .. (s:get('ttl') or '-'))
    }
}
NGINX


our $redirect_fixture = $fixture;
$redirect_fixture =~ s/location = \/_read \{/location = \/_read { rewrite ^ \/_read_target last; }\nlocation = \/_read_target {/;
$redirect_fixture =~ s/location = \/_write \{/location = \/_write { rewrite ^ \/_write_target last; }\nlocation = \/_write_target {/;

# Every internal redirect gets fresh main-request policy state. The cache
# subrequests above must instead recover their internal identity after redirect.
our $main_redirect = <<'NGINX';
location = /redirect {
    srcache_shared_cache on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block { return ngx.exec('/case') }
}
NGINX

run_tests();
__DATA__
=== TEST 1: numeric TTL
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 2: quoted TTL
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=\"60\""


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 3: mixed case and whitespace
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "  MaX-aGe \t=\t \"60\"  "


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 4: repeated fields
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = {"unknown=1","max-age=60"}


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 5: s-maxage precedence
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=1,s-maxage=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 6: positive s-maxage overrides max-age zero
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=0,s-maxage=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 7: selected s-maxage ignores malformed lower source
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=bad,s-maxage=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 8: selected s-maxage ignores duplicate lower source
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=0,max-age=0,s-maxage=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 9: unknown quoted extensions
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "x=\"max-age=0,private,no-store\",max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 10: complete directive names
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "x-private,x-no-store,x-max-age=0,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 11: escaped unknown quoted string
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "x=\"an\\\"example,max-age=0,private\",max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 12: maximum numeric bound
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=999999999"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:999999999\n"]
--- no_error_log
[error]


=== TEST 13: default TTL
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 14: reject s-maxage=0,max-age=60
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "s-maxage=0,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 15: reject s-maxage="0",max-age=60
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "s-maxage=\"0\",max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 16: reject max-age=0
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=0"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 17: reject max-age="0"
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=\"0\""


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 18: reject max-age
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 19: reject max-age=
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age="


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 20: reject max-age=bad
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=bad"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 21: reject max-age=-1
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=-1"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 22: reject max-age=1.5
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=1.5"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 23: reject max-age=60,max-age=60
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 24: reject s-maxage=60,s-maxage=60
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "s-maxage=60,s-maxage=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 25: reject s-maxage=bad,max-age=60
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "s-maxage=bad,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 26: reject max-age=1000000000
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=1000000000"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 27: reject max-age=99999999999999999999999
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=99999999999999999999999"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 28: reject max-age="60,private"
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=\"60,private\""


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 29: reject x="unterminated,max-age=60
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "x=\"unterminated,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 30: duplicate max-age across fields
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = {"max-age=60","max-age=60"}


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 31: duplicate s-maxage across fields
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = {"s-maxage=60","s-maxage=30"}


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 32: response private veto
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "private,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 33: response no-cache veto
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "no-cache=\"Authorization,Cookie\",max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 34: response no-store veto
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "no-store,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 35: per-veto options cannot override shared policy
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;
srcache_store_private on; srcache_store_no_cache on; srcache_store_no_store on;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "private,no-cache,no-store,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 36: forced private,max-age=60
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;
srcache_response_cache_control off;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "private,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 37: forced no-cache,max-age=60
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;
srcache_response_cache_control off;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "no-cache,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 38: forced no-store,max-age=60
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;
srcache_response_cache_control off;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "no-store,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 39: forced still validates freshness
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;
srcache_response_cache_control off;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "private,max-age=0"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 40: maximum TTL applies to response
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;
srcache_max_expire 10s;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:10\n"]
--- no_error_log
[error]


=== TEST 41: maximum TTL applies to default
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;
srcache_max_expire 10s;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:10\n"]
--- no_error_log
[error]


=== TEST 42: future Expires is capped
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;
srcache_max_expire 10s;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Expires"] = "Wed, 01 Jan 2031 00:00:00 GMT"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:10\n"]
--- no_error_log
[error]


=== TEST 43: past Expires
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Expires"] = "Wed, 01 Jan 2020 00:00:00 GMT"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 44: invalid Expires
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Expires"] = "invalid"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 45: higher precedence ignores invalid Expires
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Expires"] = "invalid"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 46: Vary Cookie
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Vary"] = "Cookie"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 47: Vary Accept-Language
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Vary"] = "Accept-Language"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 48: Vary *
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Vary"] = "*"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 49: empty Vary is eligible
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Vary"] = ""


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 50: Age 1
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Age"] = "1"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 51: Age -1
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Age"] = "-1"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 52: Age abc
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Age"] = "abc"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 53: Age 0,0
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Age"] = "0,0"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 54: Age "0"
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Age"] = "\"0\""


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 55: Age
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Age"] = " "


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 56: Age ['0', '0']
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Age"] = {"0","0"}


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 57: zero Age 0
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Age"] = "0"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 58: zero Age 00
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Age"] = "00"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 59: zero Age  0
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Age"] = " 0 "


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 60: partial status
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;
srcache_store_ranges on;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.status = 206


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- error_code eval
[206, 206, 200]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 61: partial header
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"
ngx.header["Content-Range"] = "bytes 0-3/100"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 62: authorization cannot store without permission
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["Authorization: Bearer client", "Authorization: Bearer client", ""]
--- response_body eval
["origin-1\n", "origin-2\n", "2:0:0:-\n"]
--- no_error_log
[error]


=== TEST 63: authorized shared permission public,max-age=60
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "public,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["Authorization: Bearer client", "", ""]
--- response_body eval
["origin-1\n", "origin-1\n", "1:1:1:60\n"]
--- no_error_log
[error]


=== TEST 64: authorized shared permission must-revalidate,max-age=60
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "must-revalidate,max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["Authorization: Bearer client", "", ""]
--- response_body eval
["origin-1\n", "origin-1\n", "1:1:1:60\n"]
--- no_error_log
[error]


=== TEST 65: authorized shared permission s-maxage=60
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "s-maxage=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["Authorization: Bearer client", "", ""]
--- response_body eval
["origin-1\n", "origin-1\n", "1:1:1:60\n"]
--- no_error_log
[error]


=== TEST 66: authorized lookup bypasses populated key
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["", "Authorization: Bearer client", "", ""]
--- response_body eval
["origin-1\n", "origin-2\n", "origin-1\n", "2:2:1:60\n"]
--- no_error_log
[error]


=== TEST 67: Range cannot read populated key or replace full entry
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["", "Range: bytes=0-3", "", ""]
--- response_body eval
["origin-1\n", "origin-2\n", "origin-1\n", "2:2:1:60\n"]
--- no_error_log
[error]


=== TEST 68: Range on fresh key cannot store
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["Range: bytes=0-3", "", ""]
--- response_body eval
["origin-1\n", "origin-2\n", "2:1:1:60\n"]
--- no_error_log
[error]


=== TEST 69: request no-store fresh key
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["Cache-Control: no-store", "", ""]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:1:60\n"]
--- no_error_log
[error]


=== TEST 70: request no-store may read an existing hit
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["", "Cache-Control: no-store", ""]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 71: request no-cache bypass can store a replacement
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["", "Cache-Control: no-cache", "", ""]
--- response_body eval
["origin-1\n", "origin-2\n", "origin-2\n", "2:2:2:60\n"]
--- no_error_log
[error]


=== TEST 72: request no-cache plus no-store
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["Cache-Control: no-cache, no-store", "", ""]
--- response_body eval
["origin-1\n", "origin-2\n", "2:1:1:60\n"]
--- no_error_log
[error]


=== TEST 73: request control disabled
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control off;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["Cache-Control: no-store", "", ""]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 74: fetch skip remains an application veto
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;
srcache_fetch_skip 1;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:0:2:60\n"]
--- no_error_log
[error]


=== TEST 75: zero skip variables are false
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;
srcache_fetch_skip 0; srcache_store_skip 0;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 76: store skip remains an application veto
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;
srcache_store_skip 1;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-2\n", "2:2:0:-\n"]
--- no_error_log
[error]


=== TEST 77: body consumes response TTL
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=1"


        ngx.say("origin-" .. n)
ngx.flush(true)
ngx.sleep(1.2)
    }
}

NGINX
--- request eval
["GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "1:1:0:-\n"]
--- no_error_log
[error]


=== TEST 78: body consumes default TTL
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 1s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)


        ngx.say("origin-" .. n)
ngx.flush(true)
ngx.sleep(1.2)
    }
}

NGINX
--- request eval
["GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "1:1:0:-\n"]
--- no_error_log
[error]


=== TEST 79: legacy forced caching remains unchanged
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    srcache_shared_cache off;
srcache_response_cache_control off;
    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "private,max-age=0"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 80: omitting shared policy retains legacy auth lookups
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- more_headers eval
["", "Authorization: Bearer client", ""]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]


=== TEST 81: cache subrequest redirects do not recurse
--- http_config eval: $::http_config
--- config eval
$::redirect_fixture . <<'NGINX'
location = /case {
    srcache_shared_cache on;

    srcache_default_expire 60s;
    srcache_store_statuses 200 206;
    srcache_request_cache_control on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        local n = ngx.shared.policy:incr('origins', 1, 0)
        ngx.header["Cache-Control"] = "max-age=60"


        ngx.say("origin-" .. n)
    }
}

NGINX
--- request eval
["GET /case", "GET /case", "GET /_stats"]
--- response_body eval
["origin-1\n", "origin-1\n", "1:2:1:60\n"]
--- no_error_log
[error]

=== TEST 82: main request redirect resets eligibility and expiration
--- http_config eval: $::http_config
--- config eval
$::fixture . $::main_redirect . <<'NGINX'
location = /case {
    srcache_shared_cache on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        ngx.shared.policy:incr('origins', 1, 0)
        ngx.header['Cache-Control'] = 'max-age=60'
        ngx.say('redirected')
    }
}
NGINX
--- request eval
['GET /redirect', 'GET /redirect', 'GET /_stats']
--- response_body eval
["redirected\n", "redirected\n", "1:3:1:60\n"]
--- no_error_log
[error]

=== TEST 83: store skip is checked again after the body
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
location = /case {
    set $late_skip 0;
    srcache_shared_cache on;
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    srcache_store_skip $late_skip;
    content_by_lua_block {
        ngx.shared.policy:incr('origins', 1, 0)
        ngx.header['Cache-Control'] = 'max-age=60'
        ngx.print('body')
        ngx.flush(true)
        ngx.var.late_skip = '1'
    }
}
NGINX
--- request eval
['GET /case', 'GET /_stats']
--- response_body eval
['body', "1:1:0:-\n"]
--- no_error_log
[error]

=== TEST 84: shared policy is inherited from the server
--- http_config eval: $::http_config
--- config eval
$::fixture . <<'NGINX'
srcache_shared_cache on;
location = /case {
    srcache_fetch GET /_read;
    srcache_store PUT /_write $srcache_expire;
    content_by_lua_block {
        ngx.shared.policy:incr('origins', 1, 0)
        ngx.header['Cache-Control'] = 's-maxage=0'
        ngx.say('body')
    }
}
NGINX
--- request eval
['GET /case', 'GET /_stats']
--- response_body eval
["body\n", "1:1:0:-\n"]
--- no_error_log
[error]
