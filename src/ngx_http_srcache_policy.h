/*
 * Copyright (C) X4B
 */

#ifndef _NGX_HTTP_SRCACHE_POLICY_H_INCLUDED_
#define _NGX_HTTP_SRCACHE_POLICY_H_INCLUDED_

#include "ngx_http_srcache_filter_module.h"

/* Match the former site's nine-digit limit and simple-cache's signed TTL. */
#define NGX_HTTP_SRCACHE_MAX_DELTA  999999999

typedef struct {
    time_t       value;
    ngx_uint_t   count;
    unsigned     invalid:1;
} ngx_http_srcache_freshness_t;

typedef struct {
    ngx_http_srcache_freshness_t  s_maxage;
    ngx_http_srcache_freshness_t  max_age;
    ngx_http_srcache_freshness_t  expires;
    ngx_uint_t                   age_count;
    unsigned                     private:1;
    unsigned                     no_cache:1;
    unsigned                     no_store:1;
    unsigned                     public:1;
    unsigned                     must_revalidate:1;
    unsigned                     vary:1;
    unsigned                     age_invalid:1;
    unsigned                     content_range:1;
    unsigned                     malformed:1;
} ngx_http_srcache_policy_t;

void ngx_http_srcache_parse_response(ngx_http_request_t *r,
    ngx_http_srcache_policy_t *policy);
ngx_int_t ngx_http_srcache_shared_response(ngx_http_request_t *r,
    ngx_http_srcache_loc_conf_t *conf, ngx_http_srcache_ctx_t *ctx);

#endif
