/*
 * Copyright (C) X4B
 */

#include "ngx_http_srcache_policy.h"

static ngx_uint_t ngx_http_srcache_token(u_char c);
static ngx_int_t ngx_http_srcache_delta(ngx_str_t *value, time_t *result);
static void ngx_http_srcache_parse_cache_control(ngx_str_t *field,
    ngx_http_srcache_policy_t *policy);

#define srcache_name(value, literal)                                         \
    ((value)->len == sizeof(literal) - 1                                    \
     && ngx_strncasecmp((value)->data, (u_char *) literal,                   \
                        sizeof(literal) - 1) == 0)

static ngx_uint_t
ngx_http_srcache_token(u_char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
           || (c >= '0' && c <= '9') || c == '!' || c == '#'
           || c == '$' || c == '%' || c == '&' || c == '\'' || c == '*'
           || c == '+' || c == '-' || c == '.' || c == '^' || c == '_'
           || c == '`' || c == '|' || c == '~';
}

static ngx_int_t
ngx_http_srcache_delta(ngx_str_t *value, time_t *result)
{
    size_t  i;
    time_t  n;

    if (value->len == 0) {
        return NGX_ERROR;
    }

    n = 0;
    for (i = 0; i < value->len; i++) {
        if (value->data[i] < '0' || value->data[i] > '9'
            || n > (NGX_HTTP_SRCACHE_MAX_DELTA
                    - (value->data[i] - '0')) / 10)
        {
            return NGX_ERROR;
        }
        n = n * 10 + value->data[i] - '0';
    }

    *result = n;
    return NGX_OK;
}

static void
ngx_http_srcache_parse_cache_control(ngx_str_t *field,
    ngx_http_srcache_policy_t *policy)
{
    u_char                        *p, *end, *start;
    ngx_str_t                      name, value;
    ngx_http_srcache_freshness_t   *freshness;
    unsigned                       has_value, escaped;

    p = field->data;
    end = p + field->len;

    while (p < end) {
        while (p < end && (*p == ' ' || *p == '\t' || *p == ',')) {
            p++;
        }
        if (p == end) {
            return;
        }

        start = p;
        while (p < end && ngx_http_srcache_token(*p)) {
            p++;
        }
        name.data = start;
        name.len = p - start;
        if (name.len == 0) {
            policy->malformed = 1;
            return;
        }

        while (p < end && (*p == ' ' || *p == '\t')) {
            p++;
        }
        has_value = p < end && *p == '=';
        escaped = 0;
        value.data = p;
        value.len = 0;

        if (has_value) {
            p++;
            while (p < end && (*p == ' ' || *p == '\t')) {
                p++;
            }

            if (p < end && *p == '"') {
                start = ++p;
                while (p < end && *p != '"') {
                    if (*p == '\\') {
                        escaped = 1;
                        if (++p == end) {
                            break;
                        }
                    }
                    p++;
                }
                if (p == end) {
                    policy->malformed = 1;
                    return;
                }
                value.data = start;
                value.len = p++ - start;

            } else {
                start = p;
                while (p < end && ngx_http_srcache_token(*p)) {
                    p++;
                }
                value.data = start;
                value.len = p - start;
            }

            while (p < end && (*p == ' ' || *p == '\t')) {
                p++;
            }
        }

        if (p < end && *p != ',') {
            policy->malformed = 1;
            return;
        }

        freshness = NULL;
        if (srcache_name(&name, "s-maxage")) {
            freshness = &policy->s_maxage;
        } else if (srcache_name(&name, "max-age")) {
            freshness = &policy->max_age;
        } else if (srcache_name(&name, "private")) {
            policy->private = 1;
        } else if (srcache_name(&name, "no-cache")) {
            policy->no_cache = 1;
        } else if (srcache_name(&name, "no-store")) {
            policy->no_store = 1;
        } else if (!has_value && srcache_name(&name, "public")) {
            policy->public = 1;
        } else if (!has_value && srcache_name(&name, "must-revalidate")) {
            policy->must_revalidate = 1;
        }

        if (freshness != NULL) {
            freshness->count++;
            if (!has_value || escaped
                || ngx_http_srcache_delta(&value, &freshness->value)
                   != NGX_OK)
            {
                freshness->invalid = 1;
            }
        }
    }
}

void
ngx_http_srcache_parse_response(ngx_http_request_t *r,
    ngx_http_srcache_policy_t *policy)
{
    ngx_list_part_t   *part;
    ngx_table_elt_t   *h;
    ngx_uint_t        i;
    ngx_str_t         value;
    time_t            age;

    ngx_memzero(policy, sizeof(*policy));
    part = &r->headers_out.headers.part;
    h = part->elts;

    for (i = 0; /* void */; i++) {
        if (i >= part->nelts) {
            if (part->next == NULL) {
                break;
            }
            part = part->next;
            h = part->elts;
            i = 0;
        }
        if (h[i].hash == 0) {
            continue;
        }

        if (srcache_name(&h[i].key, "Cache-Control")) {
            ngx_http_srcache_parse_cache_control(&h[i].value, policy);

        } else if (srcache_name(&h[i].key, "Expires")) {
            policy->expires.count++;
            policy->expires.value = ngx_http_parse_time(h[i].value.data,
                                                       h[i].value.len);
            if (policy->expires.value == NGX_ERROR) {
                policy->expires.invalid = 1;
            }

        } else if (srcache_name(&h[i].key, "Vary")) {
            if (h[i].value.len) {
                policy->vary = 1;
            }

        } else if (srcache_name(&h[i].key, "Content-Range")) {
            policy->content_range = 1;

        } else if (srcache_name(&h[i].key, "Age")) {
            policy->age_count++;
            value = h[i].value;
            while (value.len && (value.data[0] == ' '
                                || value.data[0] == '\t'))
            {
                value.data++;
                value.len--;
            }
            while (value.len && (value.data[value.len - 1] == ' '
                                || value.data[value.len - 1] == '\t'))
            {
                value.len--;
            }
            if (ngx_http_srcache_delta(&value, &age) != NGX_OK || age != 0) {
                policy->age_invalid = 1;
            }
        }
    }
}

ngx_int_t
ngx_http_srcache_shared_response(ngx_http_request_t *r,
    ngx_http_srcache_loc_conf_t *conf, ngx_http_srcache_ctx_t *ctx)
{
    ngx_http_srcache_policy_t       policy;
    ngx_http_srcache_freshness_t   *selected;
    time_t                         ttl, now;

    ngx_http_srcache_parse_response(r, &policy);

    if (r->headers_in.range != NULL
        || r->headers_out.status == NGX_HTTP_PARTIAL_CONTENT
        || policy.content_range || policy.vary || policy.age_invalid
        || policy.age_count > 1 || policy.malformed)
    {
        return NGX_DECLINED;
    }

    if (conf->resp_cache_control
        && (policy.private || policy.no_cache || policy.no_store))
    {
        return NGX_DECLINED;
    }

    if (r->headers_in.authorization != NULL
        && !policy.public && !policy.must_revalidate
        && !(policy.s_maxage.count == 1 && !policy.s_maxage.invalid))
    {
        return NGX_DECLINED;
    }

    now = ngx_time();
    if (policy.s_maxage.count) {
        selected = &policy.s_maxage;
    } else if (policy.max_age.count) {
        selected = &policy.max_age;
    } else if (policy.expires.count) {
        selected = &policy.expires;
    } else {
        selected = NULL;
    }

    if (selected != NULL) {
        if (selected->count != 1 || selected->invalid) {
            return NGX_DECLINED;
        }
        ttl = selected->value;
        if (selected == &policy.expires) {
            if (ttl <= now) {
                return NGX_DECLINED;
            }
            ttl -= now;
        }
    } else {
        ttl = conf->default_expire;
    }

    if (conf->max_expire > 0 && ttl > conf->max_expire) {
        ttl = conf->max_expire;
    }

    if (ttl <= 0 || now > NGX_MAX_TIME_T_VALUE - ttl) {
        return NGX_DECLINED;
    }

    ctx->valid_sec = now + ttl;
    return NGX_OK;
}
