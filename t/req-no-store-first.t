# vi:filetype=

use lib 'lib';
use Test::Nginx::Socket;

plan tests => repeat_each() * 4 * blocks();

$ENV{TEST_NGINX_MEMCACHED_PORT} ||= 11211;
no_shuffle();
run_tests();

__DATA__

=== TEST 1: clear the cache
--- config
    location /flush {
        set $memc_cmd 'flush_all';
        memc_pass 127.0.0.1:$TEST_NGINX_MEMCACHED_PORT;
    }
--- request
GET /flush
--- response_headers
Content-Type: text/plain
Content-Length: 4
--- response_body eval: "OK\r\n"


=== TEST 2: no-store on a fresh key reaches the origin
--- config
    location /fresh-no-store {
        default_type text/css;
        srcache_fetch GET /memc $uri;
        srcache_store PUT /memc $uri;
        srcache_request_cache_control on;
        echo first;
    }
    location /memc {
        internal;
        set $memc_key $query_string;
        set $memc_exptime 300;
        memc_pass 127.0.0.1:$TEST_NGINX_MEMCACHED_PORT;
    }
--- request
GET /fresh-no-store
--- more_headers
Cache-Control: no-store
--- response_headers
Content-Type: text/css
Content-Length:
--- response_body
first


=== TEST 3: the first response was not stored
--- config
    location /fresh-no-store {
        default_type text/css;
        srcache_fetch GET /memc $uri;
        srcache_store PUT /memc $uri;
        srcache_request_cache_control on;
        echo second;
    }
    location /memc {
        internal;
        set $memc_key $query_string;
        set $memc_exptime 300;
        memc_pass 127.0.0.1:$TEST_NGINX_MEMCACHED_PORT;
    }
--- request
GET /fresh-no-store
--- response_headers
Content-Type: text/css
Content-Length:
--- response_body
second


=== TEST 4: the ordinary response is stored
--- config
    location /fresh-no-store {
        default_type text/css;
        srcache_fetch GET /memc $uri;
        srcache_store PUT /memc $uri;
        srcache_request_cache_control on;
        echo third;
    }
    location /memc {
        internal;
        set $memc_key $query_string;
        set $memc_exptime 300;
        memc_pass 127.0.0.1:$TEST_NGINX_MEMCACHED_PORT;
    }
--- request
GET /fresh-no-store
--- response_headers
Content-Type: text/css
Content-Length: 7
--- response_body
second


=== TEST 5: no-store in a second Cache-Control field reaches the origin
--- config
    location /split-no-store {
        default_type text/css;
        srcache_fetch GET /memc $uri;
        srcache_store PUT /memc $uri;
        srcache_request_cache_control on;
        echo first;
    }
    location /memc {
        internal;
        set $memc_key $query_string;
        set $memc_exptime 300;
        memc_pass 127.0.0.1:$TEST_NGINX_MEMCACHED_PORT;
    }
--- request
GET /split-no-store
--- more_headers
Cache-Control: max-age=60
Cache-Control: no-store
--- response_headers
Content-Type: text/css
Content-Length:
--- response_body
first


=== TEST 6: the split-header response was not stored
--- config
    location /split-no-store {
        default_type text/css;
        srcache_fetch GET /memc $uri;
        srcache_store PUT /memc $uri;
        srcache_request_cache_control on;
        echo second;
    }
    location /memc {
        internal;
        set $memc_key $query_string;
        set $memc_exptime 300;
        memc_pass 127.0.0.1:$TEST_NGINX_MEMCACHED_PORT;
    }
--- request
GET /split-no-store
--- response_headers
Content-Type: text/css
Content-Length:
--- response_body
second


=== TEST 7: the split-header follow-up is stored
--- config
    location /split-no-store {
        default_type text/css;
        srcache_fetch GET /memc $uri;
        srcache_store PUT /memc $uri;
        srcache_request_cache_control on;
        echo third;
    }
    location /memc {
        internal;
        set $memc_key $query_string;
        set $memc_exptime 300;
        memc_pass 127.0.0.1:$TEST_NGINX_MEMCACHED_PORT;
    }
--- request
GET /split-no-store
--- response_headers
Content-Type: text/css
Content-Length: 7
--- response_body
second


=== TEST 8: no-store is ignored when request cache control is off
--- config
    location /ignored-no-store {
        default_type text/css;
        srcache_fetch GET /memc $uri;
        srcache_store PUT /memc $uri;
        srcache_request_cache_control off;
        echo first;
    }
    location /memc {
        internal;
        set $memc_key $query_string;
        set $memc_exptime 300;
        memc_pass 127.0.0.1:$TEST_NGINX_MEMCACHED_PORT;
    }
--- request
GET /ignored-no-store
--- more_headers
Cache-Control: no-store
--- response_headers
Content-Type: text/css
Content-Length:
--- response_body
first


=== TEST 9: request cache control off stored the response
--- config
    location /ignored-no-store {
        default_type text/css;
        srcache_fetch GET /memc $uri;
        srcache_store PUT /memc $uri;
        srcache_request_cache_control off;
        echo second;
    }
    location /memc {
        internal;
        set $memc_key $query_string;
        set $memc_exptime 300;
        memc_pass 127.0.0.1:$TEST_NGINX_MEMCACHED_PORT;
    }
--- request
GET /ignored-no-store
--- response_headers
Content-Type: text/css
Content-Length: 6
--- response_body
first
